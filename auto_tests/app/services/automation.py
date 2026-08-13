from __future__ import annotations

import logging
import re
import tempfile
import time
from collections.abc import Callable, Sequence
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import UTC, datetime
from pathlib import Path, PureWindowsPath

from app.api_runtime import mark_capture_workspace_owned
from app.clients.proxmox import ProxmoxClient
from app.clients.vision_llm import VisionLLMClient
from app.clients.vnc import VNCClient
from app.config import Settings, VMConfig
from app.distributions import load_distribution_profile
from app.errors import WorkflowError
from app.models import OperationResult, SourceMode, StepResult
from app.services.automation_monitoring import InstallationMonitoringMixin
from app.services.automation_postinstall import PostInstallValidationMixin
from app.services.automation_preflight import AutomationPreflight
from app.services.automation_types import AutomationOptions, WizardProfile
from app.services.automation_wizard import WizardAutomationMixin
from app.services.common import ResultBuilder
from app.services.validation import ValidationService

logger = logging.getLogger(__name__)


class AutomationService(
    WizardAutomationMixin,
    InstallationMonitoringMixin,
    PostInstallValidationMixin,
):
    """Automate the Libertix wizard through the real VNC desktop.

    Profiles come exclusively from configured VM metadata. The service reuses
    the build and deployment workflow, streams compact progress, and keeps disk
    changes behind the explicit apply option.
    """

    REFERENCE_WIDTH = 1024
    REFERENCE_HEIGHT = 768

    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self._capture_dir = Path(settings.capture_dir)
        self.validation = ValidationService(settings)
        self.preflight = AutomationPreflight(self._proxmox, settings)
        self.vnc = VNCClient(settings.vnc_timeout_seconds)
        self.vision_llm = VisionLLMClient(
            settings.llm_api_key.get_secret_value(),
            settings.llm_api_url,
            settings.llm_model,
            settings.llm_timeout_seconds,
            reasoning_effort=settings.llm_reasoning_effort,
            max_attempts=settings.llm_max_attempts,
            retry_base_seconds=settings.llm_retry_base_seconds,
        )

    def run(
        self,
        vm_selectors: Sequence[str] | None = None,
        *,
        apply: bool,
        linux_username: str,
        linux_password: str,
        distribution: str = "mint",
        monitor_iso: bool,
        share_windows_files_in_linux: bool = True,
        share_linux_files_in_windows: bool = True,
        simulate_fog_clone_boot_entries: bool = False,
        source: SourceMode = "remote",
        on_step: Callable[[StepResult], None] | None = None,
    ) -> OperationResult:
        self.settings.capture_dir.mkdir(parents=True, exist_ok=True)
        capture_workspace = tempfile.TemporaryDirectory(
            prefix="automation-", dir=self.settings.capture_dir
        )
        mark_capture_workspace_owned(Path(capture_workspace.name))
        previous_capture_dir = self._capture_dir
        self._capture_dir = Path(capture_workspace.name)
        result = ResultBuilder("automation", on_step=on_step)
        try:
            if apply and not monitor_iso:
                raise WorkflowError(
                    "automation.monitor_required",
                    "Apply requires visual monitoring until the live environment starts",
                )
            selected_vms = self.validation.select_vms(vm_selectors)
            profiles = self._automation_profiles(selected_vms, vm_selectors)
            # Restore every selected VM after one all-VM preflight barrier so
            # parallel nominal runs start from one coherent clean baseline.
            self._restore_clean_snapshots(result, [profiles[vm.name] for vm in selected_vms])
            executable = self.validation.prepare_server(result, source=source)
            windows_path = self.validation.to_windows_share_path(executable)
            result.ok(
                "automation.release_path",
                "Libertix executable ready for UI automation",
                path=str(windows_path),
            )
            options = AutomationOptions(
                apply=apply,
                linux_username=linux_username,
                linux_password=linux_password,
                monitor_iso=monitor_iso,
                distribution=load_distribution_profile(distribution),
                share_windows_files_in_linux=share_windows_files_in_linux,
                share_linux_files_in_windows=share_linux_files_in_windows,
                use_default_filepool=source == "published",
                simulate_fog_clone_boot_entries=simulate_fog_clone_boot_entries,
            )
            with ThreadPoolExecutor(max_workers=len(selected_vms)) as executor:
                futures = {
                    executor.submit(
                        self._run_vm_isolated,
                        vm,
                        windows_path,
                        options,
                        profiles[vm.name],
                        on_step,
                    ): vm
                    for vm in selected_vms
                }
                failures: list[OperationResult] = []
                for future in as_completed(futures):
                    vm_result = future.result()
                    result.steps.extend(vm_result.steps)
                    if vm_result.status == "error":
                        failures.append(vm_result)
                if failures:
                    messages = "; ".join(item.message for item in failures)
                    return OperationResult(
                        status="error",
                        operation="automation",
                        message=f"Automation failed on one or more VMs: {messages}",
                        steps=result.steps,
                    )
            suffix = (
                "installation and Linux/Windows validation completed"
                if apply and monitor_iso
                else "Apply click sent without final-state validation"
                if apply
                else "interface launched only"
            )
            return result.success(f"Libertix automation on {len(selected_vms)} VM(s): {suffix}")
        except WorkflowError as exc:
            return result.failure(exc)
        except Exception as exc:
            logger.exception("Unexpected internal error during UI automation")
            return result.failure(
                WorkflowError(
                    "automation.internal",
                    "Unexpected internal error",
                    details={"type": type(exc).__name__},
                )
            )
        finally:
            self._capture_dir = previous_capture_dir
            capture_workspace.cleanup()

    def _automation_profile_for_vm(self, vm: VMConfig) -> WizardProfile | None:
        if not vm.automation_enabled:
            return None
        return WizardProfile(
            name=vm.firmware,
            vm_name=vm.name,
            vm_host=vm.host,
            vmid=vm.vmid,
            launch_only_label=vm.firmware.upper(),
        )

    def _automation_profiles(
        self, selected_vms: Sequence[VMConfig], selectors: Sequence[str] | None
    ) -> dict[str, WizardProfile]:
        """Return validated UI automation profiles for every selected VM.

        Validation can target every configured VM, but UI automation is only
        allowed for profiles whose click path has been manually validated. This
        permits the explicitly supported BIOS/UEFI VMs to run in parallel while
        still refusing unknown machines.
        """

        profiles: dict[str, WizardProfile] = {}
        unsupported: list[VMConfig] = []
        for vm in selected_vms:
            profile = self._automation_profile_for_vm(vm)
            if profile is None:
                unsupported.append(vm)
                continue
            profiles[vm.name] = profile

        if profiles and not unsupported:
            return profiles

        raise WorkflowError(
            "automation.scope",
            "Libertix auto-click refused for one or more selected VMs. Select only "
            "configured VMs whose automation_enabled flag is true.",
            details={
                "requested_selectors": list(selectors or []),
                "selected_vms": [vm.name for vm in selected_vms],
                "unsupported_vms": [
                    {"name": vm.name, "host": vm.host, "os": vm.os} for vm in unsupported
                ],
                "allowed": [
                    {"vmid": profile.vmid, "name": profile.vm_name, "host": profile.vm_host}
                    for profile in (self._automation_profile_for_vm(vm) for vm in self.settings.vms)
                    if profile is not None
                ],
            },
        )

    def _proxmox(self) -> ProxmoxClient:
        s = self.settings
        return ProxmoxClient(
            s.proxmox_url,
            s.proxmox_token_id,
            s.proxmox_token_secret.get_secret_value(),
            timeout=s.proxmox_timeout_seconds,
            task_timeout=s.proxmox_task_timeout_seconds,
            verify_tls=s.proxmox_verify_tls,
            ca_bundle=s.proxmox_ca_bundle,
        )

    def _restore_clean_snapshot(self, result: ResultBuilder, profile: WizardProfile) -> None:
        self.preflight.restore_clean_snapshot(result, profile)

    def _restore_clean_snapshots(
        self, result: ResultBuilder, profiles: Sequence[WizardProfile]
    ) -> None:
        self.preflight.restore_clean_snapshots(result, profiles)

    def _run_vm_isolated(
        self,
        vm: VMConfig,
        executable: PureWindowsPath,
        options: AutomationOptions,
        profile: WizardProfile,
        on_step: Callable[[StepResult], None] | None,
    ) -> OperationResult:
        result = ResultBuilder("automation", on_step=on_step)
        try:
            self._prepare_windows_test_vm(vm, result)
            local_executable = self.validation.deploy_to_documents(vm, executable)
            result.ok(
                "automation.deploy",
                "Libertix release copied locally before automation",
                target=vm.host,
                vm=vm.name,
                executable=str(local_executable),
            )
            if options.simulate_fog_clone_boot_entries:
                self._inject_fog_clone_boot_entry(vm, local_executable, result)
            launch = self._launch_elevated(
                vm,
                local_executable,
                use_default_filepool=options.use_default_filepool,
            )
            result.ok(
                "automation.launch_elevated",
                "Libertix launched as administrator through an interactive scheduled task",
                target=vm.host,
                vm=vm.name,
                **launch,
            )
            monitor_outcome = self._click_wizard(vm, options, profile, result)
            if options.apply and options.monitor_iso:
                if monitor_outcome is None:
                    raise WorkflowError(
                        "automation.post_install",
                        "Installed-system monitoring ended without a boot outcome",
                        details={"vm": vm.name, "host": vm.host},
                    )
                self._run_post_install_validation(vm, options, result, monitor_outcome)
            return result.success(f"Automation completed on {vm.name}")
        except WorkflowError as exc:
            return result.failure(exc)

    def _prepare_windows_test_vm(self, vm: VMConfig, result: ResultBuilder) -> None:
        values: dict[str, str] = {}
        for attempt in range(1, 4):
            try:
                with self.validation.ssh(
                    vm.host,
                    vm.username,
                    self.settings.windows_ssh_password.get_secret_value(),
                    remote_os="windows",
                ) as ssh:
                    response = self.validation.run_windows_script(
                        ssh,
                        script_name="prepare_windows_test_vm.ps1",
                        config={"utc_now": datetime.now(UTC).isoformat()},
                        step="automation.prepare_vm",
                        timeout=60,
                    )
                values = self.validation.parse_powershell_results(
                    response.stdout,
                    prefixes=(
                        "UTC_NOW",
                        "CLOCK_SKEW_SECONDS",
                        "TOAST_NOTIFICATIONS_DISABLED",
                        "WINDOWS_BACKUP_NOTIFICATIONS_DISABLED",
                        "WINDOWS_NOTIFICATION_SERVICES_DISABLED",
                        "WINDOWS_SETUP_REMINDER_DISABLED",
                    ),
                )
                if (
                    not values.get("UTC_NOW")
                    or not values.get("CLOCK_SKEW_SECONDS")
                    or values.get("TOAST_NOTIFICATIONS_DISABLED") != "True"
                    or values.get("WINDOWS_BACKUP_NOTIFICATIONS_DISABLED") != "True"
                    or values.get("WINDOWS_NOTIFICATION_SERVICES_DISABLED") != "True"
                    or values.get("WINDOWS_SETUP_REMINDER_DISABLED") != "True"
                ):
                    raise WorkflowError(
                        "automation.prepare_vm",
                        "Windows test VM did not confirm its clock and notification policy",
                        details={"vm": vm.name, "host": vm.host},
                    )
                break
            except WorkflowError:
                if attempt == 3:
                    raise
                logger.warning(
                    "Windows VM preparation attempt %s/3 failed; retrying",
                    attempt,
                    extra={"step": "automation.prepare_vm_retry", "target": vm.host},
                )
                time.sleep(3)
        result.ok(
            "automation.prepare_vm",
            "Windows test VM clock synchronized and notifications disabled after snapshot restore",
            vm=vm.name,
            target=vm.host,
            utc_now=values["UTC_NOW"],
            clock_skew_seconds=int(values["CLOCK_SKEW_SECONDS"]),
            toast_notifications_disabled=True,
            windows_backup_notifications_disabled=True,
            windows_notification_services_disabled=True,
            windows_setup_reminder_disabled=True,
        )

    def _inject_fog_clone_boot_entry(
        self,
        vm: VMConfig,
        executable: PureWindowsPath,
        result: ResultBuilder,
    ) -> None:
        if vm.firmware != "uefi":
            raise WorkflowError(
                "automation.fog_clone_fixture",
                "The FOG clone boot-entry fixture is valid only for UEFI VMs",
                details={"vm": vm.name, "firmware": vm.firmware},
            )
        with self.validation.ssh(
            vm.host,
            vm.username,
            self.settings.windows_ssh_password.get_secret_value(),
            remote_os="windows",
        ) as ssh:
            response = self.validation.run_windows_script(
                ssh,
                script_name="inject_fog_clone_boot_entry.ps1",
                config={"release_root": str(executable.parent)},
                step="automation.fog_clone_fixture",
                timeout=60,
            )
        values = self.validation.parse_powershell_results(
            response.stdout,
            prefixes=("STALE_BOOT_VARIABLE", "STALE_PARTITION_GUID"),
        )
        if not re.fullmatch(
            r"Boot[0-9A-F]{4}", values.get("STALE_BOOT_VARIABLE", "")
        ) or not re.fullmatch(
            r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}",
            values.get("STALE_PARTITION_GUID", ""),
        ):
            raise WorkflowError(
                "automation.fog_clone_fixture",
                "The VM did not confirm the stale cloned UEFI entry",
                details={"vm": vm.name, "host": vm.host},
            )
        result.ok(
            "automation.fog_clone_fixture",
            "A stale cloned UEFI Libertix entry was injected before installation",
            vm=vm.name,
            target=vm.host,
            boot_variable=values["STALE_BOOT_VARIABLE"],
            stale_partition_guid=values["STALE_PARTITION_GUID"],
        )

    def _launch_elevated(
        self,
        vm: VMConfig,
        executable: PureWindowsPath,
        *,
        use_default_filepool: bool = False,
    ) -> dict[str, object]:
        task_name = f"LibertixAutoInstall_{vm.name}"
        values = self.validation.launch_elevated_process(
            vm,
            executable,
            task_name=task_name,
            step="automation.launch_elevated",
            use_default_filepool=use_default_filepool,
        )
        return {
            "pid": int(values["PID"]),
            "session_id": int(values["SESSION_ID"]),
            "task_name": values.get("TASK_NAME", task_name),
        }
