from __future__ import annotations

import logging
import tempfile
from collections.abc import Callable, Sequence
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path, PureWindowsPath

from app.clients.proxmox import ProxmoxClient
from app.clients.vision_llm import VisionLLMClient
from app.clients.vnc import VNCClient
from app.config import Settings, VMConfig
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

    The old standalone VM500 script was useful for proving the path. This
    service is the API version: it works from configured VM metadata, reuses the
    existing build/deploy code, streams steps, and keeps destructive Apply behind
    an explicit option.
    """

    REFERENCE_WIDTH = 1024
    REFERENCE_HEIGHT = 768

    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self._capture_dir = Path(settings.capture_dir)
        self.validation = ValidationService(settings)
        self.preflight = AutomationPreflight(self._proxmox)
        self.vnc = VNCClient()
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
        monitor_iso: bool,
        source: SourceMode = "remote",
        on_step: Callable[[StepResult], None] | None = None,
    ) -> OperationResult:
        self.settings.capture_dir.mkdir(parents=True, exist_ok=True)
        capture_workspace = tempfile.TemporaryDirectory(
            prefix="automation-", dir=self.settings.capture_dir
        )
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
            # Preflight every VM before starting any rollback, then restore all
            # selected snapshots concurrently. A triple run therefore starts
            # from one coherent clean baseline instead of resetting one VM at a time.
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
            "Libertix auto-click refused: this option is validated only on "
            "VM500/vm1 BIOS, VM501/vm2 UEFI, and VM502/vm3 UEFI. Use ?vm=vm1, "
            "?vm=vm2, ?vm=vm3, or an explicit vms request body.",
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
            local_executable = self.validation.deploy_to_documents(vm, executable)
            result.ok(
                "automation.deploy",
                "Libertix release copied locally before automation",
                target=vm.host,
                vm=vm.name,
                executable=str(local_executable),
            )
            launch = self._launch_elevated(vm, local_executable)
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

    def _launch_elevated(self, vm: VMConfig, executable: PureWindowsPath) -> dict[str, object]:
        task_name = f"LibertixAutoInstall_{vm.name}"
        # The scheduled task launches into the interactive desktop session while
        # keeping the process elevated. SSH alone would start a non-visible UI.
        with self.validation.ssh(
            vm.host, vm.username, self.settings.windows_ssh_password.get_secret_value()
        ) as ssh:
            response = self.validation.run_windows_script(
                ssh,
                script_name="launch_libertix_elevated.ps1",
                config={
                    "executable": str(executable),
                    "task_name": task_name,
                    "filepool_base_url": self.settings.filepool_base_url,
                    "development_static_ipv4": vm.host,
                    "development_static_ipv4_prefix_length": (
                        self.settings.development_static_ipv4_prefix_length
                    ),
                    "development_static_ipv4_gateway": (
                        self.settings.development_static_ipv4_gateway
                    ),
                    "development_dns_servers": list(self.settings.development_dns_servers),
                },
                step="automation.launch_elevated",
                timeout=90,
            )
        values = self.validation.parse_powershell_results(
            response.stdout, prefixes=("PID", "SESSION_ID", "TASK_NAME", "EXECUTABLE")
        )
        if not values.get("PID", "").isdigit() or not values.get("SESSION_ID", "").isdigit():
            raise WorkflowError(
                "automation.launch_elevated",
                "Elevated Libertix process was not confirmed",
                details={"vm": vm.name, "host": vm.host, "stdout": response.stdout[-4000:]},
            )
        if PureWindowsPath(values.get("EXECUTABLE", "")) != executable:
            raise WorkflowError(
                "automation.launch_elevated",
                "The launched process does not match the deployed executable",
                details={"vm": vm.name, "expected": str(executable)},
            )
        return {
            "pid": int(values["PID"]),
            "session_id": int(values["SESSION_ID"]),
            "task_name": values.get("TASK_NAME", task_name),
        }
