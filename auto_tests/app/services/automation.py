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
    linux_password: str
    monitor_iso: bool


@dataclass(frozen=True)
class Point:
    x: int
    y: int


class AutomationService:
    """Automate the Libertix wizard through the real VNC desktop.

    The old standalone VM500 script was useful for proving the path. This
    service is the API version: it works from configured VM metadata, reuses the
    existing build/deploy code, streams steps, and keeps destructive Apply behind
    an explicit option.
    """

    REFERENCE_WIDTH = 1024
    REFERENCE_HEIGHT = 768
    AUTOCHECK_ALLOWED_VM_NAME = "vm1"
    AUTOCHECK_ALLOWED_VM_HOST = "192.168.1.240"

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
        linux_password: str,
        monitor_iso: bool,
        source: SourceMode = "remote",
        on_step: Callable[[StepResult], None] | None = None,
    ) -> OperationResult:
        result = ResultBuilder("automation", on_step=on_step)
        try:
            selected_vms = self.validation._select_vms(vm_selectors)  # noqa: SLF001
            self._assert_autoclick_scope(selected_vms, vm_selectors)
            self._restore_clean_snapshot(result)
            executable = self.validation._prepare_server(result, source=source)  # noqa: SLF001
            windows_path = self.validation._to_windows_share_path(executable)  # noqa: SLF001
            result.ok(
                "automation.release_path",
                "Exécutable Libertix prêt pour automatisation UI",
                path=str(windows_path),
            )
            options = AutomationOptions(
                apply=apply,
                linux_password=linux_password,
                monitor_iso=monitor_iso,
            )
            with ThreadPoolExecutor(max_workers=len(selected_vms)) as executor:
                futures = [
                    executor.submit(self._run_vm_isolated, vm, windows_path, options, on_step)
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

    def _assert_autoclick_scope(
        self, selected_vms: Sequence[VMConfig], selectors: Sequence[str] | None
    ) -> None:
        """Keep the destructive UI automation restricted to the tested BIOS VM.

        Validation can target every configured VM, but the click coordinates and
        Libertix installation flow have only been validated on VM500 / vm1.
        Refusing implicit "all VMs" avoids accidentally clicking through UEFI
        VMs while their Libertix path is still considered untested.
        """

        allowed = [
            vm
            for vm in selected_vms
            if vm.name == self.AUTOCHECK_ALLOWED_VM_NAME
            and vm.host == self.AUTOCHECK_ALLOWED_VM_HOST
        ]
        if len(selected_vms) == 1 and allowed:
            return
        raise WorkflowError(
            "automation.scope",
            "Auto-click Libertix refusé: cette option est actuellement validée uniquement "
            "sur VM500 / vm1 / Windows 10 BIOS. Utilise ?vm=vm1. "
            "VM501 et VM502 seront supportées quand le parcours UEFI sera testé.",
            details={
                "requested_selectors": list(selectors or []),
                "selected_vms": [vm.name for vm in selected_vms],
                "allowed": {
                    "vmid": 500,
                    "name": self.AUTOCHECK_ALLOWED_VM_NAME,
                    "host": self.AUTOCHECK_ALLOWED_VM_HOST,
                },
            },
        )

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

    def _restore_clean_snapshot(self, result: ResultBuilder) -> None:
        vmid = 500
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
                "Reset VM500 terminé: snapshot clean2 restauré et tâche Proxmox validée",
                target=str(vmid),
                node=node,
                snapshot=RESET_SNAPSHOT,
            )

    def _run_vm_isolated(
        self,
        vm: VMConfig,
        executable: PureWindowsPath,
        options: AutomationOptions,
        on_step: Callable[[StepResult], None] | None,
    ) -> OperationResult:
        result = ResultBuilder("automation", on_step=on_step)
        try:
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
            self._click_wizard(vm, options, result)
            return result.success(f"Automatisation terminée sur {vm.name}")
        except WorkflowError as exc:
            return result.failure(exc)

    def _launch_elevated(self, vm: VMConfig, executable: PureWindowsPath) -> dict[str, object]:
        task_name = f"LibertixAutoInstall_{vm.name}"
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
        self, vm: VMConfig, options: AutomationOptions, result: ResultBuilder
    ) -> None:
        client = None
        try:
            client = api.connect(VNCClient._vncdotool_address(vm.vnc))
            time.sleep(1)
            self._capture_from_client(client, vm, "00-welcome", result)

            if not options.apply:
                result.ok(
                    "automation.launch_only_stop",
                    "Arrêt volontaire après lancement visible de l'interface",
                    target=vm.vnc,
                    vm=vm.name,
                )
                return

            self._click(client, vm, Point(512, 438), 2.0)
            self._capture_from_client(client, vm, "01-distro", result)

            self._click(client, vm, Point(145, 395), 0.5)
            self._click(client, vm, Point(919, 628), 2.0)
            self._capture_from_client(client, vm, "02-resize", result)

            self._click(client, vm, Point(919, 628), 2.0)
            self._capture_from_client(client, vm, "03-account", result)

            self._click(client, vm, Point(512, 333), 0.3)
            self._type_text(client, options.linux_password)
            client.keyPress("tab")
            time.sleep(0.2)
            self._type_text(client, options.linux_password)
            time.sleep(0.5)
            self._capture_from_client(client, vm, "04-account-filled", result)

            self._click(client, vm, Point(919, 628), 2.0)
            self._capture_from_client(client, vm, "05-warning", result)

            self._click(client, vm, Point(221, 541), 0.5)
            self._click(client, vm, Point(919, 628), 10.0)
            self._capture_from_client(client, vm, "06-apply-started", result)
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

        if options.monitor_iso:
            self._monitor_install_progress(vm, result)

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

    def _click_reboot_after_preparation(self, vm: VMConfig, result: ResultBuilder) -> None:
        client = None
        try:
            client = api.connect(VNCClient._vncdotool_address(vm.vnc))
            self._capture_from_client(client, vm, "reboot-ready", result)
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

    @staticmethod
    def _type_text(client: object, text: str) -> None:
        for char in text:
            client.keyPress(char)
            time.sleep(0.05)
