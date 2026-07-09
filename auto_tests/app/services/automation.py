from __future__ import annotations

import logging
import time
from collections.abc import Callable, Sequence
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path, PureWindowsPath

from vncdotool import api

from app.clients.proxmox import ProxmoxClient
from app.clients.vision_llm import VisionLLMClient
from app.clients.vnc import VNCClient
from app.config import Settings, VMConfig
from app.errors import WorkflowError
from app.models import OperationResult, SourceMode, StepResult
from app.services.common import ResultBuilder
from app.services.reset import RESET_SNAPSHOT
from app.services.validation import ValidationService

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class AutomationOptions:
    apply: bool
    linux_username: str
    linux_password: str
    monitor_iso: bool


@dataclass(frozen=True)
class Point:
    x: int
    y: int


@dataclass(frozen=True)
class WizardProfile:
    name: str
    vm_name: str
    vm_host: str
    vmid: int
    launch_only_label: str
    disable_defender_for_automation: bool = False


class AutomationService:
    """Automate the Libertix wizard through the real VNC desktop.

    The old standalone VM500 script was useful for proving the path. This
    service is the API version: it works from configured VM metadata, reuses the
    existing build/deploy code, streams steps, and keeps destructive Apply behind
    an explicit option.
    """

    REFERENCE_WIDTH = 1024
    REFERENCE_HEIGHT = 768
    BIOS_PROFILE = WizardProfile(
        name="bios",
        vm_name="vm1",
        vm_host="192.168.1.240",
        vmid=500,
        launch_only_label="BIOS",
    )
    WIN10_UEFI_PROFILE = WizardProfile(
        name="uefi",
        vm_name="vm2",
        vm_host="192.168.1.241",
        vmid=501,
        launch_only_label="UEFI",
        disable_defender_for_automation=True,
    )
    WIN11_UEFI_PROFILE = WizardProfile(
        name="uefi",
        vm_name="vm3",
        vm_host="192.168.1.242",
        vmid=502,
        launch_only_label="UEFI",
    )
    UEFI_PROFILE = WIN11_UEFI_PROFILE
    PROFILES = (BIOS_PROFILE, WIN10_UEFI_PROFILE, WIN11_UEFI_PROFILE)

    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.validation = ValidationService(settings)
        self.vnc = VNCClient()
        self.vision_llm = VisionLLMClient(
            settings.llm_api_key.get_secret_value(),
            settings.llm_api_url,
            settings.llm_model,
            settings.llm_timeout_seconds,
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
        result = ResultBuilder("automation", on_step=on_step)
        try:
            selected_vms = self.validation._select_vms(vm_selectors)  # noqa: SLF001
            profiles = self._automation_profiles(selected_vms, vm_selectors)
            # Always restore the known clean snapshot before UI automation. The
            # wizard can modify the disk, so retries must not inherit old state.
            for vm in selected_vms:
                self._restore_clean_snapshot(result, profiles[vm.name])
            executable = self.validation._prepare_server(result, source=source)  # noqa: SLF001
            windows_path = self.validation._to_windows_share_path(executable)  # noqa: SLF001
            result.ok(
                "automation.release_path",
                "Exécutable Libertix prêt pour automatisation UI",
                path=str(windows_path),
            )
            options = AutomationOptions(
                apply=apply,
                linux_username=linux_username,
                linux_password=linux_password,
                monitor_iso=monitor_iso,
            )
            with ThreadPoolExecutor(max_workers=len(selected_vms)) as executor:
                futures = [
                    executor.submit(
                        self._run_vm_isolated,
                        vm,
                        windows_path,
                        options,
                        profiles[vm.name],
                        on_step,
                    )
                    for vm in selected_vms
                ]
                for future in futures:
                    vm_result = future.result()
                    result.steps.extend(vm_result.steps)
                    if vm_result.status == "problème":
                        return OperationResult(
                            status="problème",
                            operation="automation",
                            message=vm_result.message,
                            steps=result.steps,
                        )
            suffix = "avec Apply" if apply else "lancement interface uniquement"
            return result.success(
                f"Automatisation Libertix terminée sur {len(selected_vms)} VM(s) {suffix}"
            )
        except WorkflowError as exc:
            return result.failure(exc)
        except Exception as exc:
            logger.exception("Erreur interne inattendue pendant l'automatisation UI")
            return result.failure(
                WorkflowError(
                    "automation.internal",
                    "Erreur interne inattendue",
                    details={"type": type(exc).__name__},
                )
            )

    def _automation_profile_for_vm(self, vm: VMConfig) -> WizardProfile | None:
        for profile in self.PROFILES:
            if vm.name == profile.vm_name and vm.host == profile.vm_host:
                return profile
        return None

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
            "Auto-click Libertix refusé: cette option est validée uniquement "
            "sur VM500/vm1 BIOS, VM501/vm2 UEFI et VM502/vm3 UEFI. "
            "Utilise ?vm=vm1, ?vm=vm2, ?vm=vm3 ou un body vms explicite.",
            details={
                "requested_selectors": list(selectors or []),
                "selected_vms": [vm.name for vm in selected_vms],
                "unsupported_vms": [
                    {"name": vm.name, "host": vm.host, "os": vm.os} for vm in unsupported
                ],
                "allowed": [
                    {"vmid": profile.vmid, "name": profile.vm_name, "host": profile.vm_host}
                    for profile in self.PROFILES
                ],
            },
        )

    def _assert_autoclick_scope(
        self, selected_vms: Sequence[VMConfig], selectors: Sequence[str] | None
    ) -> None:
        self._automation_profiles(selected_vms, selectors)

    def _proxmox(self) -> ProxmoxClient:
        s = self.settings
        return ProxmoxClient(
            s.proxmox_url,
            s.proxmox_token_id,
            s.proxmox_token_secret.get_secret_value(),
            verify_tls=s.proxmox_verify_tls,
            timeout=s.proxmox_timeout_seconds,
            task_timeout=s.proxmox_task_timeout_seconds,
        )

    def _restore_clean_snapshot(self, result: ResultBuilder, profile: WizardProfile) -> None:
        vmid = profile.vmid
        with self._proxmox() as proxmox:
            node = proxmox.locate_vm(vmid)
            proxmox.assert_snapshot(node, vmid, RESET_SNAPSHOT)
            result.ok(
                "automation.rollback_preflight",
                "VM et snapshot vérifiés avant automation",
                target=str(vmid),
                node=node,
                snapshot=RESET_SNAPSHOT,
            )
            proxmox.rollback(node, vmid, RESET_SNAPSHOT)
            result.ok(
                "automation.reset_vm_done",
                f"Reset VM{vmid} terminé: snapshot clean2 restauré et tâche Proxmox validée",
                target=str(vmid),
                node=node,
                snapshot=RESET_SNAPSHOT,
            )

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
            self._prepare_vm_for_automation(vm, profile, result)
            local_executable = self.validation._deploy_to_documents(vm, executable)  # noqa: SLF001
            result.ok(
                "automation.deploy",
                "Release Libertix copiée localement avant automatisation",
                target=vm.host,
                vm=vm.name,
                executable=str(local_executable),
            )
            launch = self._launch_elevated(vm, local_executable)
            result.ok(
                "automation.launch_elevated",
                "Libertix lancé en administrateur via tâche planifiée interactive",
                target=vm.host,
                vm=vm.name,
                **launch,
            )
            self._click_wizard(vm, options, profile, result)
            return result.success(f"Automatisation terminée sur {vm.name}")
        except WorkflowError as exc:
            return result.failure(exc)

    def _prepare_vm_for_automation(
        self, vm: VMConfig, profile: WizardProfile, result: ResultBuilder
    ) -> None:
        if not profile.disable_defender_for_automation:
            return
        with self.validation._ssh(  # noqa: SLF001
            vm.host, vm.username, self.settings.windows_ssh_password.get_secret_value()
        ) as ssh:
            response = self.validation._run_windows_script(  # noqa: SLF001
                ssh,
                script_name="prepare_automation_vm.ps1",
                config={
                    "release_dir_name": self.settings.release_dir_name,
                    "disable_defender": True,
                },
                step="automation.prepare_vm",
                timeout=90,
            )
        values = self.validation._parse_powershell_results(  # noqa: SLF001
            response.stdout,
            prefixes=("DEFENDER_PREPARED", "DEFENDER_REALTIME", "DEFENDER_EXCLUSION"),
        )
        result.ok(
            "automation.prepare_vm",
            "VM préparée avant automation UI",
            target=vm.host,
            vm=vm.name,
            **values,
        )

    def _launch_elevated(self, vm: VMConfig, executable: PureWindowsPath) -> dict[str, object]:
        task_name = f"LibertixAutoInstall_{vm.name}"
        # The scheduled task launches into the interactive desktop session while
        # keeping the process elevated. SSH alone would start a non-visible UI.
        with self.validation._ssh(  # noqa: SLF001
            vm.host, vm.username, self.settings.windows_ssh_password.get_secret_value()
        ) as ssh:
            response = self.validation._run_windows_script(  # noqa: SLF001
                ssh,
                script_name="launch_libertix_elevated.ps1",
                config={"executable": str(executable), "task_name": task_name},
                step="automation.launch_elevated",
                timeout=90,
            )
        values = self.validation._parse_powershell_results(  # noqa: SLF001
            response.stdout, prefixes=("PID", "SESSION_ID", "TASK_NAME")
        )
        if not values.get("PID", "").isdigit() or not values.get("SESSION_ID", "").isdigit():
            raise WorkflowError(
                "automation.launch_elevated",
                "Processus Libertix administrateur non confirmé",
                details={"vm": vm.name, "host": vm.host, "stdout": response.stdout[-4000:]},
            )
        return {
            "pid": int(values["PID"]),
            "session_id": int(values["SESSION_ID"]),
            "task_name": values.get("TASK_NAME", task_name),
        }

    def _click_wizard(
        self,
        vm: VMConfig,
        options: AutomationOptions,
        profile: WizardProfile,
        result: ResultBuilder,
    ) -> None:
        client = None
        try:
            client = api.connect(VNCClient._vncdotool_address(vm.vnc))
            time.sleep(1)
            self._capture_from_client(client, vm, "00-welcome", result)

            if not options.apply:
                result.ok(
                    "automation.launch_only_stop",
                    f"Arrêt volontaire après lancement visible de l'interface {profile.launch_only_label}",
                    target=vm.vnc,
                    vm=vm.name,
                )
                return

            if profile.name == "uefi":
                self._click_wizard_uefi(client, vm, options, result)
            else:
                self._click_wizard_bios(client, vm, options, result)
        except WorkflowError:
            raise
        except Exception as exc:
            raise WorkflowError(
                "automation.vnc_click",
                "Automatisation VNC impossible",
                details={"vm": vm.name, "address": vm.vnc, "error": str(exc)},
            ) from exc
        finally:
            if client is not None:
                try:
                    client.disconnect()
                except Exception:
                    logger.warning(
                        "Fermeture VNC imparfaite",
                        extra={"step": "automation.vnc_close", "target": vm.vnc},
                    )

        if options.monitor_iso and profile.name == "bios":
            self._monitor_install_progress(vm, result)
        elif options.monitor_iso and profile.name == "uefi":
            self._monitor_uefi_until_reboot(vm, result)

    def _click_wizard_bios(
        self, client: object, vm: VMConfig, options: AutomationOptions, result: ResultBuilder
    ) -> None:
        # Coordinates are relative to REFERENCE_WIDTH/HEIGHT and scaled in
        # _click. They match the VM500 BIOS wizard path validated by VNC.
        self._click(client, vm, Point(512, 438), 2.0)
        self._capture_from_client(client, vm, "01-distro", result)

        self._click(client, vm, Point(145, 395), 0.5)
        self._click(client, vm, Point(919, 628), 2.0)
        self._capture_from_client(client, vm, "02-resize", result)

        self._click(client, vm, Point(919, 628), 2.0)
        self._capture_from_client(client, vm, "03-account", result)

        self._fill_field(client, vm, Point(512, 220), options.linux_username)
        self._fill_field(client, vm, Point(512, 333), options.linux_password)
        self._fill_field(client, vm, Point(512, 445), options.linux_password)
        time.sleep(0.5)
        self._capture_from_client(client, vm, "04-account-filled", result)

        self._click(client, vm, Point(919, 628), 2.0)
        self._capture_from_client(client, vm, "05-warning", result)

        self._click(client, vm, Point(221, 541), 0.5)
        self._click(client, vm, Point(919, 628), 10.0)
        self._capture_from_client(client, vm, "06-apply-started", result)

    def _click_wizard_uefi(
        self, client: object, vm: VMConfig, options: AutomationOptions, result: ResultBuilder
    ) -> None:
        # Coordinates match the manually validated VM502 / 1280x800 UEFI wizard path,
        # converted back to the same 1024x768 reference system used by _click().
        self._click(client, vm, Point(512, 432), 2.0)
        self._capture_from_client(client, vm, "01-distro", result)

        self._click(client, vm, Point(220, 389), 0.5)
        self._click(client, vm, Point(838, 614), 2.0)
        self._capture_from_client(client, vm, "02-resize", result)

        self._click(client, vm, Point(838, 614), 2.0)
        self._capture_from_client(client, vm, "03-account", result)

        self._fill_field(client, vm, Point(508, 223), options.linux_username)
        self._fill_field(client, vm, Point(508, 330), options.linux_password)
        self._fill_field(client, vm, Point(508, 438), options.linux_password)
        time.sleep(0.5)
        self._capture_from_client(client, vm, "04-account-filled", result)

        self._click(client, vm, Point(838, 614), 2.0)
        self._capture_from_client(client, vm, "05-warning", result)

        self._click(client, vm, Point(278, 530), 0.5)
        self._click(client, vm, Point(838, 614), 10.0)
        self._capture_from_client(client, vm, "06-apply-started", result)

    def _monitor_install_progress(self, vm: VMConfig, result: ResultBuilder) -> None:
        deadline = time.monotonic() + self.settings.automation_monitor_timeout_seconds
        attempt = 0
        last_context: dict[str, object] | None = None
        while time.monotonic() < deadline:
            attempt += 1
            time.sleep(self.settings.automation_monitor_interval_seconds)
            capture = self._capture_with_name(vm, f"monitor-{attempt:03d}")
            try:
                verdict = self.vision_llm.analyze_install_progress(capture, vm.name, vm.os)
            except WorkflowError as exc:
                exc.details.update({"vm": vm.name, "target": vm.vnc, "capture": str(capture)})
                result.failure(exc)
                last_context = exc.details
                continue
            context = {
                "target": vm.vnc,
                "vm": vm.name,
                "capture": str(capture),
                **verdict.model_dump(),
            }
            last_context = context
            result.ok(
                "automation.monitor_iso",
                "Capture de progression analysée par le LLM",
                **context,
            )
            if verdict.error_visible:
                raise WorkflowError(
                    "automation.monitor_iso",
                    "Erreur visible pendant le téléchargement ou l'installation",
                    details=context,
                )
            if verdict.blocking_problem_visible:
                raise WorkflowError(
                    "automation.monitor_iso",
                    "Erreur bloquante détectée sur l'écran Libertix",
                    details=context,
                )
            if verdict.iso_download_finished:
                result.ok(
                    "automation.iso_download_seen",
                    "Téléchargement ISO terminé, attente de la fin de préparation",
                    **context,
                )
            # The LLM can see "finished" text while a progress bar is still
            # active. Only click Reboot after there is no active progress left.
            if (
                verdict.installation_finished or verdict.reboot_prompt_visible
            ) and not verdict.active_install_progress_visible:
                result.ok(
                    "automation.preparation_finished",
                    "Préparation Windows terminée",
                    **context,
                )
                self._click_reboot_after_preparation(vm, result)
                return
            if verdict.installation_finished or verdict.reboot_prompt_visible:
                result.ok(
                    "automation.finish_ignored",
                    "Verdict de fin ignoré car une progression active reste visible",
                    **context,
                )
        raise WorkflowError(
            "automation.monitor_iso",
            "Timeout en attendant la fin du téléchargement ISO",
            details=last_context or {"vm": vm.name, "target": vm.vnc},
        )

    def _monitor_uefi_until_reboot(self, vm: VMConfig, result: ResultBuilder) -> None:
        deadline = time.monotonic() + self.settings.automation_monitor_timeout_seconds
        attempt = 0
        last_context: dict[str, object] | None = None
        while time.monotonic() < deadline:
            attempt += 1
            time.sleep(self.settings.automation_monitor_interval_seconds)
            capture = self._capture_with_name(vm, f"uefi-monitor-{attempt:03d}")
            try:
                verdict = self.vision_llm.analyze_install_progress(capture, vm.name, vm.os)
            except WorkflowError as exc:
                exc.details.update({"vm": vm.name, "target": vm.vnc, "capture": str(capture)})
                result.failure(exc)
                last_context = exc.details
                continue
            context = {
                "target": vm.vnc,
                "vm": vm.name,
                "capture": str(capture),
                **verdict.model_dump(),
            }
            last_context = context
            result.ok(
                "automation.monitor_uefi",
                "Capture de progression UEFI analysée par le LLM",
                **context,
            )
            if verdict.error_visible or verdict.blocking_problem_visible:
                raise WorkflowError(
                    "automation.monitor_uefi",
                    "Erreur visible pendant la préparation UEFI",
                    details=context,
                )
            if self._uefi_reboot_or_live_started(verdict.summary, verdict.visible_text):
                result.ok(
                    "automation.uefi_reboot_seen",
                    "Reboot Windows vers le live UEFI confirmé visuellement",
                    **context,
                )
                return
        raise WorkflowError(
            "automation.monitor_uefi",
            "Timeout en attendant le reboot Windows vers le live UEFI",
            details=last_context or {"vm": vm.name, "target": vm.vnc},
        )

    @staticmethod
    def _uefi_reboot_or_live_started(summary: str, visible_text: str) -> bool:
        """Detect that Windows has left the wizard and the live boot path started.

        The UEFI automation must match the BIOS contract: it confirms the app
        path up to the reboot into the installer, then stops. It must not wait
        for Mint installation success.
        """

        text = f"{summary}\n{visible_text}".lower()
        if any(
            blocker in text
            for blocker in (
                "no libertix installer",
                "aucune fenêtre d'installateur",
                "aucun installateur",
                "windows desktop wallpaper",
                "windows boot manager",
                "gestionnaire de démarrage windows",
                "windows n'a pas pu démarrer",
                "could not start",
                "couldn't load",
                "lock screen",
                "écran de verrouillage",
                "appliquer les modifications",
                "creating uefi installer partition",
                "downloading mint iso",
                "downloading uefi installer",
                "copying uefi installer",
                "copying iso contents",
                "mounting iso",
                "configuring uefi boot",
                "libertixtools",
                "c:\\mint.iso",
                "c:/mint.iso",
                "c:\\libertixtools",
                "c:/libertixtools",
            )
        ):
            return False

        return any(
            marker in text
            for marker in (
                "linux boot process",
                "kernel and initramfs",
                "libertix installer",
                "installation automatique",
                "f12: mode terminal",
                "gnu grub",
                "start boot option",
                "isolinux",
                "vmlinuz",
                "initrd",
                "squashfs",
                "bdsdxe",
                "starting boot",
            )
        )

    def _click_reboot_after_preparation(self, vm: VMConfig, result: ResultBuilder) -> None:
        client = None
        try:
            client = api.connect(VNCClient._vncdotool_address(vm.vnc))
            self._capture_from_client(client, vm, "reboot-ready", result)
            # Small delays keep the click sequence visible and avoid racing the
            # confirmation dialog after the LLM declares the wizard complete.
            time.sleep(2)
            self._click(client, vm, Point(919, 628), 1.0)
            self._capture_from_client(client, vm, "reboot-confirm", result)
            time.sleep(1)
            self._click(client, vm, Point(560, 446), 3.0)
            self._capture_from_client(client, vm, "reboot-accepted", result)
            result.ok(
                "automation.reboot_clicked",
                "Bouton de redémarrage validé après verdict LLM de fin",
                target=vm.vnc,
                vm=vm.name,
            )
        except Exception as exc:
            raise WorkflowError(
                "automation.reboot_click",
                "Impossible de cliquer le redémarrage final",
                details={"vm": vm.name, "target": vm.vnc, "error": str(exc)},
            ) from exc
        finally:
            if client is not None:
                try:
                    client.disconnect()
                except Exception:
                    logger.warning(
                        "Fermeture VNC imparfaite",
                        extra={"step": "automation.vnc_close", "target": vm.vnc},
                    )

    def _capture_from_client(
        self, client: object, vm: VMConfig, label: str, result: ResultBuilder
    ) -> Path:
        path = self._capture_path(vm, label)
        path.parent.mkdir(parents=True, exist_ok=True)
        client.captureScreen(str(path))
        if not path.is_file() or path.stat().st_size == 0:
            raise WorkflowError(
                "automation.capture",
                "Capture VNC absente ou vide",
                details={"vm": vm.name, "path": str(path)},
            )
        result.ok(
            "automation.capture",
            "Capture UI enregistrée",
            target=vm.vnc,
            vm=vm.name,
            label=label,
            path=str(path),
            size=path.stat().st_size,
        )
        return path

    def _capture_with_name(self, vm: VMConfig, label: str) -> Path:
        path = self._capture_path(vm, label)
        self.vnc.capture(vm.vnc, path)
        return path

    def _capture_path(self, vm: VMConfig, label: str) -> Path:
        stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%S%fZ")
        safe_label = "".join(ch if ch.isalnum() or ch in "-_" else "-" for ch in label)
        return Path(self.settings.capture_dir) / f"{vm.name}-auto-{stamp}-{safe_label}.png"

    def _click(self, client: object, vm: VMConfig, point: Point, delay: float) -> None:
        x = round(point.x * vm.screen_width / self.REFERENCE_WIDTH)
        y = round(point.y * vm.screen_height / self.REFERENCE_HEIGHT)
        client.mouseMove(x, y)
        client.mousePress(1)
        time.sleep(delay)

    def _fill_field(self, client: object, vm: VMConfig, point: Point, text: str) -> None:
        self._click(client, vm, point, 0.35)
        self._select_all(client)
        time.sleep(0.15)
        self._type_text(client, text)
        time.sleep(0.35)

    @staticmethod
    def _type_text(client: object, text: str) -> None:
        # Send keys one by one. Clipboard paste is not reliable across the VNC
        # stack and can silently fail on login/password fields.
        for char in text:
            client.keyPress(char)
            time.sleep(0.12)

    @staticmethod
    def _select_all(client: object) -> None:
        # The Windows VNC keyboard layout used in this lab maps Ctrl+A through
        # the physical Q key. Keeping it here avoids paste/clipboard paths.
        client.keyDown("ctrl")
        time.sleep(0.05)
        client.keyPress("q")
        time.sleep(0.05)
        client.keyUp("ctrl")
        time.sleep(0.05)
