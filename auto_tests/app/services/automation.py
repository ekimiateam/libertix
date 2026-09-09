from __future__ import annotations

import json
import logging
import re
import threading
import time
from collections.abc import Callable, Sequence
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from pathlib import Path, PureWindowsPath
from typing import Literal

from app.api_runtime import (
    cleanup_operation_artifacts,
    create_capture_workspace,
    mark_capture_workspace_complete,
)
from app.clients.proxmox import ProxmoxClient
from app.clients.proxmox_serial import ProxmoxSerialCapture, SerialCaptureReport
from app.clients.ssh import SSHClient
from app.clients.vision_llm import VisionLLMClient
from app.clients.vnc import VNCClient
from app.config import Settings, VMConfig
from app.distributions import load_distribution_profile
from app.errors import WorkflowError
from app.models import STAGING_VOLUME_LABELS, OperationResult, SourceMode, StepResult
from app.services.automation_monitoring import InstallationMonitoringMixin
from app.services.automation_postinstall import PostInstallValidationMixin
from app.services.automation_preflight import AutomationPreflight
from app.services.automation_types import AutomationOptions, WizardProfile
from app.services.automation_wizard import WizardAutomationMixin
from app.services.common import ResultBuilder
from app.services.validation import ValidationService
from app.services.windows_lab_login import ensure_secondary_windows_session
from app.storage_fixtures import (
    StorageFixtureInventory,
    StorageFixtureRequest,
    plan_storage_fixture,
    verify_storage_fixture_creation,
)

logger = logging.getLogger(__name__)


@dataclass
class _SerialCaptureSession:
    destination: Path
    stop_event: threading.Event
    ready_event: threading.Event
    thread: threading.Thread
    report: SerialCaptureReport | None = None
    error: Exception | None = None


class AutomationService(
    WizardAutomationMixin,
    InstallationMonitoringMixin,
    PostInstallValidationMixin,
):
    """Run unattended Libertix installations on the configured test VMs.

    Profiles come exclusively from configured VM metadata. The service reuses
    the build and deployment workflow and streams compact progress.
    """

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
        linux_username: str,
        linux_password: str,
        linux_size_gib: int = 100,
        installation_target: Literal["windows", "secondary"] = "windows",
        distribution: str = "mint",
        monitor_iso: bool,
        share_windows_files_in_linux: bool = True,
        share_linux_files_in_windows: bool = True,
        migrate_windows_preferences: bool = False,
        preference_wallpaper: Literal["custom", "windows-default"] = "custom",
        storage_fixture: StorageFixtureRequest | None = None,
        secondary_snapshot: bool = False,
        simulate_stale_firmware_entries: bool = False,
        force_offline_ntfs_resize: bool = False,
        boot_guardian_fault: Literal[
            "none",
            "bios-rollback",
            "bios-controller-disconnect",
            "bios-postinstall-rollback",
            "uefi-postinstall-rollback",
            "boot-order",
            "bootnext-fallback",
            "bootnext-rollback",
            "preferred-path",
            "preferred-path-rollback",
        ] = "none",
        first_boot: Literal["windows", "linux"] = "windows",
        source: SourceMode = "remote",
        on_step: Callable[[StepResult], None] | None = None,
        run_workspace: Path | None = None,
    ) -> OperationResult:
        owns_workspace = run_workspace is None
        workspace = run_workspace or create_capture_workspace(self.settings, "automation")
        capture_dir = workspace / "captures"
        capture_dir.mkdir(mode=0o700, exist_ok=True)
        previous_capture_dir = self._capture_dir
        self._capture_dir = capture_dir
        result = ResultBuilder("automation", on_step=on_step)
        try:
            result.ok(
                "automation.run_workspace",
                "Automation run workspace initialized",
                path=str(workspace),
                capture_path=str(capture_dir),
            )
            if not monitor_iso:
                raise WorkflowError(
                    "automation.monitor_required",
                    "Installation automation requires monitoring through post-install validation",
                )
            selected_vms = self.validation.select_vms(vm_selectors)
            profiles = self._automation_profiles(selected_vms, vm_selectors)
            fixture = storage_fixture or StorageFixtureRequest()
            if installation_target not in {"windows", "secondary"} or (
                installation_target == "secondary" and not secondary_snapshot
            ):
                raise WorkflowError(
                    "automation.installation_target.scope",
                    "Secondary installation requires the secondary-disk snapshot mode",
                )
            if fixture.secondary_data and not secondary_snapshot:
                raise WorkflowError(
                    "automation.storage_fixture.scope",
                    "A secondary-data fixture requires the secondary-disk snapshot mode",
                )
            if boot_guardian_fault != "none":
                expected_firmware = (
                    "bios"
                    if boot_guardian_fault
                    in {"bios-rollback", "bios-postinstall-rollback", "bios-controller-disconnect"}
                    else "uefi"
                )
                if len(selected_vms) != 1 or selected_vms[0].firmware != expected_firmware:
                    raise WorkflowError(
                        "automation.boot_guardian_fault_scope",
                        "The selected recovery test requires exactly one matching firmware VM",
                        details={
                            "selected_vms": [vm.name for vm in selected_vms],
                            "fault": boot_guardian_fault,
                        },
                    )
                if first_boot != "windows":
                    raise WorkflowError(
                        "automation.boot_guardian_fault_order",
                        "A boot guardian fault test requires first_boot=windows",
                        details={"fault": boot_guardian_fault, "first_boot": first_boot},
                    )
            # Restore every selected VM after one all-VM preflight barrier so
            # parallel nominal runs start from one coherent clean baseline.
            self._restore_clean_snapshots(result, [profiles[vm.name] for vm in selected_vms])
            if secondary_snapshot and installation_target == "secondary":
                self._prepare_secondary_boot_devices(result, selected_vms, profiles)
            executable = self.validation.prepare_server(result, source=source)
            windows_path = self.validation.to_windows_share_path(executable)
            result.ok(
                "automation.release_path",
                "Libertix executable ready for UI automation",
                path=str(windows_path),
            )
            options = AutomationOptions(
                linux_username=linux_username,
                linux_password=linux_password,
                linux_size_gib=linux_size_gib,
                installation_target=installation_target,
                monitor_iso=monitor_iso,
                distribution=load_distribution_profile(distribution),
                share_windows_files_in_linux=share_windows_files_in_linux,
                share_linux_files_in_windows=share_linux_files_in_windows,
                migrate_windows_preferences=migrate_windows_preferences,
                preference_wallpaper=preference_wallpaper,
                storage_fixture=fixture,
                secondary_snapshot=secondary_snapshot,
                use_default_filepool=source == "published",
                simulate_stale_firmware_entries=simulate_stale_firmware_entries,
                force_offline_ntfs_resize=force_offline_ntfs_resize,
                boot_guardian_fault=boot_guardian_fault,
                first_boot=first_boot,
            )
            with ThreadPoolExecutor(max_workers=len(selected_vms)) as executor:
                for vm in selected_vms:
                    result.ok(
                        "automation.vm_started", "VM installation workflow started", vm=vm.name
                    )
                futures = {
                    executor.submit(
                        self._run_vm_isolated,
                        vm,
                        windows_path,
                        options,
                        on_step,
                    ): vm
                    for vm in selected_vms
                }
                failures: list[OperationResult] = []
                for future in as_completed(futures):
                    vm_result = future.result()
                    result.steps.extend(vm_result.steps)
                    result.ok(
                        "automation.vm_finished",
                        "VM installation workflow terminated",
                        vm=futures[future].name,
                        vm_status=vm_result.status,
                    )
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
            return result.success(
                f"Libertix automation on {len(selected_vms)} VM(s): "
                "selected scenario completed and verified"
            )
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
            if owns_workspace:
                mark_capture_workspace_complete(workspace)
                cleanup_operation_artifacts(self.settings)

    def _automation_profile_for_vm(self, vm: VMConfig) -> WizardProfile | None:
        if not vm.automation_enabled:
            return None
        return WizardProfile(
            name=vm.firmware,
            vm_name=vm.name,
            vm_host=vm.host,
            vmid=vm.vmid,
        )

    def _automation_profiles(
        self, selected_vms: Sequence[VMConfig], selectors: Sequence[str] | None
    ) -> dict[str, WizardProfile]:
        """Return validated unattended profiles for every selected VM.

        Validation can target every configured VM, but destructive automation is
        allowed only for explicitly enabled BIOS/UEFI test machines.
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
            "Libertix unattended automation refused one or more selected VMs. Select "
            "only configured VMs whose automation_enabled flag is true.",
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

    def _restore_clean_snapshots(
        self, result: ResultBuilder, profiles: Sequence[WizardProfile]
    ) -> None:
        self.preflight.restore_clean_snapshots(result, profiles)

    def _prepare_secondary_boot_devices(
        self, result: ResultBuilder, vms: Sequence[VMConfig], profiles: dict[str, WizardProfile]
    ) -> None:
        for vm in vms:
            if not vm.secondary_disk_boot_order:
                continue
            if vm.vmid not in self.settings.allowed_proxmox_vmids or not vm.automation_enabled:
                raise WorkflowError(
                    "automation.boot_order_scope", "Boot-order target is not authorized"
                )
            with self._proxmox() as proxmox:
                node = proxmox.locate_vm(vm.vmid)
                proxmox.configure_test_boot_order(node, vm.vmid, vm.secondary_disk_boot_order)
                # A restored RAM snapshot retains the old firmware device enumeration.
                # A guest reboot alone does not reconstruct QEMU's bootindex properties.
                proxmox.shutdown_vm(node, vm.vmid)
                proxmox.start_vm(node, vm.vmid)
                proxmox.wait_for_vm_status(
                    node, vm.vmid, "running", timeout=60, step="automation.boot_devices_started"
                )
                ensure_secondary_windows_session(self, proxmox, node, vm)
                self.preflight.configure_windows_guest_network(proxmox, node, profiles[vm.name])
            result.ok(
                "automation.secondary_boot_devices",
                "Configured test boot devices are enabled",
                vm=vm.name,
                vmid=vm.vmid,
                devices=vm.secondary_disk_boot_order,
            )

    def _run_vm_isolated(
        self,
        vm: VMConfig,
        executable: PureWindowsPath,
        options: AutomationOptions,
        on_step: Callable[[StepResult], None] | None,
    ) -> OperationResult:
        result = ResultBuilder("automation", on_step=on_step)
        serial_session: _SerialCaptureSession | None = None
        failure: WorkflowError | None = None
        try:
            self._prepare_windows_test_vm(vm, result)
            vm_options = options
            if options.storage_fixture.enabled:
                vm_options = replace(
                    vm_options,
                    storage_fixture_receipt=self._configure_storage_fixture(vm, options, result),
                )
            if options.migrate_windows_preferences:
                vm_options = replace(
                    vm_options,
                    preference_fixture=self._configure_windows_preference_fixture(
                        vm, result, wallpaper_mode=options.preference_wallpaper
                    ),
                )
            if options.boot_guardian_fault in {
                "bios-rollback",
                "bios-controller-disconnect",
                "bios-postinstall-rollback",
                "uefi-postinstall-rollback",
                "bootnext-rollback",
                "preferred-path-rollback",
            }:
                vm_options = replace(
                    vm_options,
                    rollback_baseline=self._capture_rollback_baseline(vm, result),
                )
            local_executable = self.validation.deploy_to_documents(vm, executable)
            result.ok(
                "automation.deploy",
                "Libertix release copied locally before automation",
                target=vm.host,
                vm=vm.name,
                executable=str(local_executable),
            )
            if options.simulate_stale_firmware_entries:
                self._inject_stale_firmware_entry(vm, local_executable, result)
            serial_session = self._start_serial_capture(vm, result)
            launch = self._launch_elevated(
                vm,
                local_executable,
                vm_options,
                use_default_filepool=vm_options.use_default_filepool,
            )
            result.ok(
                "automation.launch_elevated",
                "Libertix launched as administrator through an interactive scheduled task",
                target=vm.host,
                vm=vm.name,
                **launch,
            )
            monitor_outcome = self._run_unattended_wizard(vm, vm_options, result, launch)
            self._run_post_install_validation(vm, vm_options, result, monitor_outcome)
        except WorkflowError as exc:
            failure = exc
        except Exception as exc:
            logger.exception(
                "Unexpected internal error during automation on %s",
                vm.name,
                extra={"step": "automation.internal", "target": vm.host},
            )
            failure = WorkflowError(
                "automation.internal",
                f"Unexpected internal error during automation on {vm.name}",
                details={
                    "vm": vm.name,
                    "target": vm.host,
                    "type": type(exc).__name__,
                },
            )
        finally:
            if serial_session is not None:
                try:
                    self._stop_serial_capture(vm, serial_session, result)
                except WorkflowError as serial_error:
                    if failure is None:
                        failure = serial_error
                    else:
                        serial_context = dict(serial_error.details)
                        serial_context.setdefault("vm", vm.name)
                        serial_context.setdefault("target", vm.host)
                        result.error(
                            serial_error.step,
                            serial_error.message,
                            **serial_context,
                        )
        if failure is not None:
            return result.failure(failure)
        return result.success(f"Automation completed on {vm.name}")

    def _configure_storage_fixture(
        self, vm: VMConfig, options: AutomationOptions, result: ResultBuilder
    ) -> dict[str, object]:
        step = "automation.storage_fixture"
        with self.validation.ssh(
            vm.host,
            vm.username,
            self.settings.windows_ssh_password.get_secret_value(),
            remote_os="windows",
        ) as ssh:
            inspected = self.validation.run_windows_script(
                ssh,
                script_name="storage_fixture.ps1",
                config={"phase": "inspect"},
                step=step + ".inspect",
                timeout=120,
            )
            values = self.validation.parse_powershell_results(
                inspected.stdout,
                prefixes=("STORAGE_INVENTORY_JSON",),
            )
            try:
                inventory = StorageFixtureInventory.model_validate_json(
                    values["STORAGE_INVENTORY_JSON"]
                )
            except (KeyError, ValueError) as exc:
                raise WorkflowError(
                    step, "Invalid storage fixture inventory", details={"vm": vm.name}
                ) from exc
            plan = plan_storage_fixture(
                options.storage_fixture,
                inventory,
                secondary_snapshot=options.secondary_snapshot,
            )
            if plan["requires_decryption"]:
                system_disk = next(
                    disk for disk in inventory.disks if disk.number == inventory.system_disk_number
                )
                self._decrypt_storage_fixture_volume(
                    ssh,
                    vm,
                    result,
                    drive=inventory.system_drive + ":",
                    disk_device_path=system_disk.device_path,
                    require_system=True,
                )
                inspected = self.validation.run_windows_script(
                    ssh,
                    script_name="storage_fixture.ps1",
                    config={"phase": "inspect"},
                    step=step + ".inspect_decrypted",
                    timeout=120,
                )
                values = self.validation.parse_powershell_results(
                    inspected.stdout,
                    prefixes=("STORAGE_INVENTORY_JSON",),
                )
                inventory = StorageFixtureInventory.model_validate_json(
                    values["STORAGE_INVENTORY_JSON"]
                )
                if not inventory.system_volume_decrypted:
                    raise WorkflowError(step, "Independent volume encryption verification failed")
                plan = plan_storage_fixture(
                    options.storage_fixture,
                    inventory,
                    secondary_snapshot=options.secondary_snapshot,
                )
            result.ok(step + ".plan", "Storage fixture dry-run verified", vm=vm.name, plan=plan)
            applied = self.validation.run_windows_script(
                ssh,
                script_name="storage_fixture.ps1",
                config={"phase": "apply", "plan": plan},
                step=step + ".apply",
                timeout=300,
            )
            values = self.validation.parse_powershell_results(
                applied.stdout,
                prefixes=("STORAGE_FIXTURE_JSON",),
            )
            try:
                receipt = json.loads(values["STORAGE_FIXTURE_JSON"])
                created_inventory = StorageFixtureInventory.model_validate(receipt["inventory"])
                if not isinstance(receipt["witnesses"], list) or len(receipt["witnesses"]) != len(
                    plan["actions"]
                ):
                    raise ValueError("Missing storage witnesses")
            except (KeyError, TypeError, ValueError) as exc:
                raise WorkflowError(
                    step, "Invalid storage fixture receipt", details={"vm": vm.name}
                ) from exc
            verify_storage_fixture_creation(inventory, created_inventory, plan["actions"])
            verified = self.validation.run_windows_script(
                ssh,
                script_name="storage_fixture.ps1",
                config={"phase": "verify", "receipt": receipt},
                step=step + ".verify",
                timeout=120,
            )
            values = self.validation.parse_powershell_results(
                verified.stdout, prefixes=("STORAGE_FIXTURE_VERIFIED",)
            )
            if values.get("STORAGE_FIXTURE_VERIFIED") != "True":
                raise WorkflowError(
                    step, "Storage fixture creation was not verified", details={"vm": vm.name}
                )
            if options.storage_fixture.decrypt_secondary_volume:
                system_path = next(
                    disk.device_path
                    for disk in inventory.disks
                    if disk.number == inventory.system_disk_number
                )
                secondary_witnesses = [
                    item for item in receipt["witnesses"] if item["disk_device_path"] != system_path
                ]
                if len(secondary_witnesses) != 1:
                    raise WorkflowError(step, "No unambiguous secondary volume to decrypt")
                witness = secondary_witnesses[0]
                self._decrypt_storage_fixture_volume(
                    ssh,
                    vm,
                    result,
                    drive=str(witness["drive_letter"]) + ":",
                    disk_device_path=str(witness["disk_device_path"]),
                    partition_offset=int(witness["partition_offset"]),
                    volume_id=str(witness["volume_id"]),
                    require_system=False,
                )
                decrypted_verification = self.validation.run_windows_script(
                    ssh,
                    script_name="storage_fixture.ps1",
                    config={"phase": "verify", "receipt": receipt},
                    step=step + ".verify_decrypted",
                    timeout=120,
                )
                fields = self.validation.parse_powershell_results(
                    decrypted_verification.stdout, prefixes=("STORAGE_FIXTURE_VERIFIED",)
                )
                if fields.get("STORAGE_FIXTURE_VERIFIED") != "True":
                    raise WorkflowError(
                        step, "Storage preservation after decryption was not verified"
                    )
            if options.storage_fixture.redirect_documents:
                system_path = next(
                    disk.device_path
                    for disk in inventory.disks
                    if disk.number == inventory.system_disk_number
                )
                witnesses = [
                    item for item in receipt["witnesses"] if item["disk_device_path"] != system_path
                ]
                if len(witnesses) != 1:
                    raise WorkflowError(step, "No unambiguous secondary document fixture volume")
                prepared = self.validation.run_windows_script(
                    ssh,
                    script_name="storage_documents_fixture.ps1",
                    config={"phase": "apply", **witnesses[0]},
                    step=step + ".documents",
                    timeout=180,
                )
                fields = self.validation.parse_powershell_results(
                    prepared.stdout, prefixes=("STORAGE_DOCUMENTS_JSON",)
                )
                try:
                    documents = json.loads(fields["STORAGE_DOCUMENTS_JSON"])
                    if not isinstance(documents["files"], list) or not documents["files"]:
                        raise ValueError("Missing document witnesses")
                except (KeyError, TypeError, ValueError) as exc:
                    raise WorkflowError(step, "Invalid redirected Documents receipt") from exc
                receipt["user_documents"] = documents
                self._verify_storage_documents_fixture(ssh, vm, documents, result)
        result.ok(
            step,
            "Storage fixture created and its data witnesses verified",
            vm=vm.name,
            receipt=receipt,
        )
        return receipt

    def _verify_storage_documents_fixture(
        self, ssh: SSHClient, vm: VMConfig, receipt: dict[str, object], result: ResultBuilder
    ) -> None:
        step = "automation.storage_fixture.documents_preserved"
        response = self.validation.run_windows_script(
            ssh,
            script_name="storage_documents_fixture.ps1",
            config={"phase": "verify", "receipt": receipt},
            step=step,
            timeout=180,
        )
        values = self.validation.parse_powershell_results(
            response.stdout, prefixes=("STORAGE_DOCUMENTS_VERIFIED",)
        )
        if values.get("STORAGE_DOCUMENTS_VERIFIED") != "True":
            raise WorkflowError(step, "Redirected Documents preservation was not verified")
        result.ok(step, "Windows Documents redirection and file hashes verified", vm=vm.name)

    def _decrypt_storage_fixture_volume(
        self,
        ssh: SSHClient,
        vm: VMConfig,
        result: ResultBuilder,
        *,
        drive: str,
        disk_device_path: str,
        require_system: bool,
        partition_offset: int = 0,
        volume_id: str = "",
    ) -> None:
        config = {
            "drive": drive,
            "disk_device_path": disk_device_path,
            "require_system": require_system,
            "partition_offset": partition_offset,
            "volume_id": volume_id,
        }
        deadline = time.monotonic() + 1800
        progress_deadline = time.monotonic() + 600
        last_percentage = None
        begin = True
        while time.monotonic() < min(deadline, progress_deadline):
            response = self.validation.run_windows_script(
                ssh,
                script_name="prepare_storage_fixture_volume.ps1",
                config={**config, "begin": begin},
                step="automation.storage_fixture.decryption",
                timeout=min(90, max(1, min(deadline, progress_deadline) - time.monotonic())),
            )
            begin = False
            values = self.validation.parse_powershell_results(
                response.stdout, prefixes=("STORAGE_ENCRYPTION_JSON",)
            )
            try:
                state = json.loads(values["STORAGE_ENCRYPTION_JSON"])
                if (
                    state["drive"] != config["drive"]
                    or type(state["percentage"]) is not int
                    or not 0 <= state["percentage"] <= 100
                    or type(state["fully_decrypted"]) is not bool
                    or state["status"] not in {"FullyDecrypted", "DecryptionInProgress"}
                    or state["fully_decrypted"]
                    != (state["status"] == "FullyDecrypted" and state["percentage"] == 0)
                ):
                    raise ValueError("Invalid or non-decrypting encryption status")
            except (KeyError, TypeError, ValueError) as exc:
                raise WorkflowError(
                    "automation.storage_fixture.decryption", "Invalid encryption status"
                ) from exc
            if last_percentage is not None and state["percentage"] > last_percentage:
                raise WorkflowError(
                    "automation.storage_fixture.decryption",
                    "Windows fixture decryption progress regressed",
                    details={"vm": vm.name},
                )
            if last_percentage is None or state["percentage"] < last_percentage:
                progress_deadline = time.monotonic() + 600
            last_percentage = state["percentage"]
            result.ok(
                "automation.storage_fixture.decryption",
                "Windows fixture decryption status",
                vm=vm.name,
                drive=state["drive"],
                status=state["status"],
                percentage=state["percentage"],
                sequence=f"{state['status']}:{state['percentage']}",
            )
            if (
                state["fully_decrypted"] is True
                and state["status"] == "FullyDecrypted"
                and state["percentage"] == 0
            ):
                return
            time.sleep(min(5, max(0, min(deadline, progress_deadline) - time.monotonic())))
        raise WorkflowError(
            "automation.storage_fixture.decryption",
            "Windows fixture decryption exceeded its deadline",
            details={
                "vm": vm.name,
                "timeout_seconds": 1800,
                "inactivity_timeout_seconds": 600,
                "last_encryption_percentage": last_percentage,
            },
        )

    def _configure_windows_preference_fixture(
        self,
        vm: VMConfig,
        result: ResultBuilder,
        *,
        wallpaper_mode: Literal["custom", "windows-default"] = "custom",
    ) -> dict[str, str]:
        with self.validation.ssh(
            vm.host,
            vm.username,
            self.settings.windows_ssh_password.get_secret_value(),
            remote_os="windows",
        ) as ssh:
            response = self.validation.run_windows_script(
                ssh,
                script_name="configure_windows_preference_fixture.ps1",
                config={"wallpaper_mode": wallpaper_mode},
                step="automation.windows_preference_fixture",
                timeout=90,
            )
        values = self.validation.parse_powershell_results(
            response.stdout,
            prefixes=(
                "PREFERENCE_FIXTURE_READY",
                "WALLPAPER_SHA256",
                "ACCOUNT_IMAGE_SHA256",
            ),
        )
        if values.get("PREFERENCE_FIXTURE_READY") != "True":
            raise WorkflowError(
                "automation.windows_preference_fixture",
                "The Windows preference fixture was not verified",
                details={"vm": vm.name, "target": vm.host},
            )
        for name in ("WALLPAPER_SHA256", "ACCOUNT_IMAGE_SHA256"):
            value = values.get(name, "")
            if len(value) != 64 or any(character not in "0123456789abcdef" for character in value):
                raise WorkflowError(
                    "automation.windows_preference_fixture",
                    "The Windows preference fixture returned an invalid asset hash",
                    details={"vm": vm.name, "target": vm.host, "field": name},
                )
        result.ok(
            "automation.windows_preference_fixture",
            "Windows preference migration fixture prepared",
            vm=vm.name,
            target=vm.host,
        )
        return values

    def _capture_rollback_baseline(
        self,
        vm: VMConfig,
        result: ResultBuilder,
    ) -> dict[str, str]:
        with self.validation.ssh(
            vm.host,
            vm.username,
            self.settings.windows_ssh_password.get_secret_value(),
            remote_os="windows",
        ) as ssh:
            response = self.validation.run_windows_script(
                ssh,
                script_name="inspect_installation_rollback_state.ps1",
                config={"staging_volume_labels": list(STAGING_VOLUME_LABELS)},
                step="automation.rollback_baseline",
                timeout=90,
            )
        values = self.validation.parse_powershell_results(
            response.stdout,
            prefixes=(
                "SYSTEM_DISK_NUMBER",
                "SYSTEM_PARTITION_NUMBER",
                "SYSTEM_PARTITION_OFFSET",
                "SYSTEM_PARTITION_SIZE",
                "PARTITION_LAYOUT_JSON",
                "STORAGE_LAYOUT_JSON",
                "EXECUTION_PLAN_IDS_JSON",
                "INSTALLER_PARTITION_COUNT",
                "LIBERTIX_PROCESS_COUNT",
                "RECOVERY_TASK_COUNT",
                "RESULT",
            ),
        )
        required = (
            "SYSTEM_DISK_NUMBER",
            "SYSTEM_PARTITION_NUMBER",
            "SYSTEM_PARTITION_OFFSET",
            "SYSTEM_PARTITION_SIZE",
            "PARTITION_LAYOUT_JSON",
            "STORAGE_LAYOUT_JSON",
            "EXECUTION_PLAN_IDS_JSON",
        )
        if (
            values.get("RESULT") != "OK"
            or any(not values.get(name) for name in required)
            or values.get("INSTALLER_PARTITION_COUNT") != "0"
            or values.get("LIBERTIX_PROCESS_COUNT") != "0"
            or values.get("RECOVERY_TASK_COUNT") != "0"
        ):
            raise WorkflowError(
                "automation.rollback_baseline",
                "The clean Windows rollback baseline could not be proven",
                details={"vm": vm.name, "target": vm.host, **values},
            )
        result.ok(
            "automation.rollback_baseline",
            "The exact pre-installation Windows geometry and clean recovery state were captured",
            vm=vm.name,
            target=vm.host,
            **values,
        )
        return values

    def _start_serial_capture(
        self,
        vm: VMConfig,
        result: ResultBuilder,
    ) -> _SerialCaptureSession:
        serial_dir = self._capture_dir.parent / "serial"
        destination = serial_dir / f"{vm.name}-serial-console.log"
        stop_event = threading.Event()
        ready_event = threading.Event()
        session: _SerialCaptureSession

        def collect() -> None:
            try:
                with self._proxmox() as proxmox:
                    node = proxmox.locate_vm(vm.vmid)
                    if not proxmox.has_serial_console(node, vm.vmid):
                        session.report = SerialCaptureReport(
                            path=destination,
                            payload_bytes=0,
                            connections=0,
                            disconnects=0,
                            unavailable_reason="serial0 is not configured on the VM",
                        )
                        ready_event.set()
                        return
                    session.report = ProxmoxSerialCapture(proxmox).run(
                        node,
                        vm.vmid,
                        destination,
                        stop_event,
                        ready_event,
                    )
            except Exception as exc:
                session.error = exc
                ready_event.set()

        thread = threading.Thread(
            target=collect,
            name=f"libertix-serial-{vm.name}",
            daemon=True,
        )
        session = _SerialCaptureSession(
            destination=destination,
            stop_event=stop_event,
            ready_event=ready_event,
            thread=thread,
        )
        thread.start()
        if not ready_event.wait(self.settings.proxmox_timeout_seconds):
            stop_event.set()
            thread.join(timeout=3)
            raise WorkflowError(
                "automation.serial_capture",
                "Timed out while opening the Proxmox serial console",
                details={"vm": vm.name, "target": vm.host, "vmid": vm.vmid},
            )
        if session.error is not None:
            if isinstance(session.error, WorkflowError):
                raise session.error
            raise WorkflowError(
                "automation.serial_capture",
                "The Proxmox serial console could not be started",
                details={
                    "vm": vm.name,
                    "target": vm.host,
                    "vmid": vm.vmid,
                    "error_type": type(session.error).__name__,
                },
            ) from session.error
        if session.report is not None and session.report.unavailable_reason is not None:
            result.ok(
                "automation.serial_capture_unavailable",
                "Proxmox configuration has no serial0; serial capture was not started",
                vm=vm.name,
                target=vm.host,
                vmid=vm.vmid,
                capture_available=False,
            )
            return session
        result.ok(
            "automation.serial_capture_started",
            "Deterministic Proxmox serial-console capture started",
            vm=vm.name,
            target=vm.host,
            vmid=vm.vmid,
            path=str(destination),
        )
        return session

    def _stop_serial_capture(
        self,
        vm: VMConfig,
        session: _SerialCaptureSession,
        result: ResultBuilder,
    ) -> None:
        session.stop_event.set()
        session.thread.join(timeout=5)
        if session.thread.is_alive():
            raise WorkflowError(
                "automation.serial_capture",
                "The Proxmox serial-console capture did not stop cleanly",
                details={"vm": vm.name, "target": vm.host, "vmid": vm.vmid},
            )
        if session.error is not None:
            if isinstance(session.error, WorkflowError):
                raise session.error
            raise WorkflowError(
                "automation.serial_capture",
                "The Proxmox serial-console capture failed",
                details={
                    "vm": vm.name,
                    "target": vm.host,
                    "vmid": vm.vmid,
                    "error_type": type(session.error).__name__,
                },
            ) from session.error
        report = session.report
        if report is not None and report.unavailable_reason is not None:
            result.ok(
                "automation.serial_capture_unavailable",
                "Proxmox serial-console capture is unavailable for this VM",
                vm=vm.name,
                target=vm.host,
                vmid=vm.vmid,
                path=str(report.path),
                reason=report.unavailable_reason,
                capture_available=False,
            )
            return
        if report is None or report.payload_bytes == 0:
            raise WorkflowError(
                "automation.serial_capture",
                "The Proxmox serial console contained no guest output",
                details={
                    "vm": vm.name,
                    "target": vm.host,
                    "vmid": vm.vmid,
                    "path": str(session.destination),
                },
            )
        result.ok(
            "automation.serial_capture_complete",
            "Proxmox serial-console evidence saved",
            vm=vm.name,
            target=vm.host,
            vmid=vm.vmid,
            path=str(report.path),
            payload_bytes=report.payload_bytes,
            connections=report.connections,
            disconnects=report.disconnects,
        )

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

    def _inject_stale_firmware_entry(
        self,
        vm: VMConfig,
        executable: PureWindowsPath,
        result: ResultBuilder,
    ) -> None:
        if vm.firmware != "uefi":
            raise WorkflowError(
                "automation.stale_firmware_fixture",
                "The stale firmware-entry fixture is valid only for UEFI VMs",
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
                script_name="inject_stale_firmware_entry.ps1",
                config={"release_root": str(executable.parent)},
                step="automation.stale_firmware_fixture",
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
                "automation.stale_firmware_fixture",
                "The VM did not confirm the stale UEFI entry",
                details={"vm": vm.name, "host": vm.host},
            )
        result.ok(
            "automation.stale_firmware_fixture",
            "A stale UEFI Libertix entry was injected before installation",
            vm=vm.name,
            target=vm.host,
            boot_variable=values["STALE_BOOT_VARIABLE"],
            stale_partition_guid=values["STALE_PARTITION_GUID"],
        )

    def _launch_elevated(
        self,
        vm: VMConfig,
        executable: PureWindowsPath,
        options: AutomationOptions,
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
            force_offline_ntfs_resize=options.force_offline_ntfs_resize,
            unattended_config={
                "schemaVersion": 1,
                "distribution": options.distribution.id,
                "linuxSizeGiB": options.linux_size_gib,
                "installationTarget": options.installation_target,
                "linuxUsername": options.linux_username,
                "linuxPassword": options.linux_password,
                "computerName": f"{vm.name.lower()}-linux",
                "shareWindowsFilesInLinux": options.share_windows_files_in_linux,
                "shareLinuxFilesInWindows": options.share_linux_files_in_windows,
                "migrateWindowsPreferences": options.migrate_windows_preferences,
            },
        )
        return {
            "pid": int(values["PID"]),
            "session_id": int(values["SESSION_ID"]),
            "window_handle": int(values["WINDOW_HANDLE"]),
            "window_title": values["WINDOW_TITLE"],
            "task_name": values.get("TASK_NAME", task_name),
            "unattended_status_path": values.get("UNATTENDED_STATUS_PATH"),
            "unattended_acknowledgement_path": values.get("UNATTENDED_ACKNOWLEDGEMENT_PATH"),
        }
