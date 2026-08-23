"""Visual monitoring after the Libertix Apply action."""

from __future__ import annotations

import logging
import re
import time
from pathlib import Path
from typing import Literal

from PIL import Image

from app.config import VMConfig
from app.distributions import DistributionProfile, load_distribution_profile
from app.errors import WorkflowError
from app.services.common import ResultBuilder

logger = logging.getLogger(__name__)

FINAL_BOOT_MENU_LABELS = (
    ("shutdown", "advanced options"),
    ("éteindre", "options avancées"),
    ("apagar", "opciones avanzadas"),
)
REBOOT_RECHECK_INTERVAL_SECONDS = 2.0
REBOOT_DIALOG_DELAY_SECONDS = 0.75
REBOOT_ACCEPT_DELAY_SECONDS = 1.0
UNCHANGED_CAPTURE_ANALYSIS_INTERVAL = 4


class InstallationMonitoringMixin:
    """Observe preparation, reboot, live installation, and the installed system."""

    def _monitor_until_live_boot(
        self,
        vm: VMConfig,
        result: ResultBuilder,
        firmware: Literal["bios", "uefi"],
        distribution: DistributionProfile | None = None,
        *,
        reboot_requested: bool = False,
    ) -> Literal["boot-menu", "linux-desktop"]:
        """Monitor Windows preparation and the following live boot as one transaction."""

        distribution = distribution or load_distribution_profile("mint")
        deadline = time.monotonic() + self.settings.automation_monitor_timeout_seconds
        attempt = 0
        last_context: dict[str, object] | None = None
        reboot_attempts = 1 if reboot_requested else 0
        previous_signature: tuple[int, ...] | None = None
        unchanged_captures = 0
        last_visual_change_at = time.monotonic()
        live_failure_reboot_probe_sent = False
        monitor_delay_seconds = self.settings.automation_monitor_interval_seconds
        while time.monotonic() < deadline:
            attempt += 1
            time.sleep(monitor_delay_seconds)
            monitor_delay_seconds = self.settings.automation_monitor_interval_seconds
            if live_failure_reboot_probe_sent:
                failure = self._read_archived_live_failure(vm)
                if failure is not None:
                    raise WorkflowError(
                        "automation.live_installer_failure",
                        failure["message"],
                        details={
                            "vm": vm.name,
                            "target": vm.host,
                            "stage": failure["stage"],
                            "exit_code": failure["exit_code"],
                            "rollback": failure["rollback"],
                            "run_id": failure["run_id"],
                        },
                    )
            try:
                capture = self._capture_with_name(vm, f"{firmware}-monitor-{attempt:03d}")
            except WorkflowError as exc:
                if reboot_attempts <= 0 or exc.step != "vnc.capture":
                    raise
                last_context = {
                    "vm": vm.name,
                    "target": vm.vnc,
                    "attempt": attempt,
                    "capture_error": exc.message,
                    **exc.details,
                }
                result.ok(
                    "automation.display_temporarily_unavailable",
                    f"{firmware.upper()} display is temporarily unavailable during reboot",
                    **last_context,
                )
                continue
            if self._installed_grub_theme_visible(capture):
                result.ok(
                    "automation.installed_boot_menu_seen",
                    f"Installed {firmware.upper()} boot menu confirmed by local theme detection",
                    target=vm.vnc,
                    vm=vm.name,
                    capture=str(capture),
                    proof_source="local-theme-colors",
                )
                return "boot-menu"
            signature = self._capture_signature(capture)
            if signature is not None and signature == previous_signature:
                unchanged_captures += 1
                stalled_seconds = time.monotonic() - last_visual_change_at
                if stalled_seconds >= self.settings.automation_stall_timeout_seconds:
                    raise WorkflowError(
                        "automation.progress_stalled",
                        f"No visible progress during the {firmware.upper()} installation",
                        details={
                            "vm": vm.name,
                            "target": vm.vnc,
                            "phase": f"{firmware}-installation",
                            "capture": str(capture),
                            "stalled_seconds": round(stalled_seconds, 3),
                            "stall_timeout_seconds": (
                                self.settings.automation_stall_timeout_seconds
                            ),
                            "unchanged_captures": unchanged_captures,
                        },
                    )
                if unchanged_captures % UNCHANGED_CAPTURE_ANALYSIS_INTERVAL != 0:
                    result.ok(
                        "automation.monitor_unchanged",
                        f"{firmware.upper()} capture is unchanged; AI analysis skipped",
                        target=vm.vnc,
                        vm=vm.name,
                        capture=str(capture),
                        unchanged_count=unchanged_captures,
                    )
                    continue
            else:
                previous_signature = signature
                unchanged_captures = 0
                last_visual_change_at = time.monotonic()
            try:
                verdict = self.vision_llm.analyze_install_progress(capture, vm.name, vm.os)
            except WorkflowError as exc:
                raise WorkflowError(
                    "automation.monitor_vision_required",
                    f"{firmware.upper()} installation monitoring requires the configured "
                    "vision provider",
                    details={
                        **exc.details,
                        "target": vm.vnc,
                        "vm": vm.name,
                        "capture": str(capture),
                        "provider_step": exc.step,
                        "provider_message": exc.message,
                    },
                ) from exc
            context = {
                "target": vm.vnc,
                "vm": vm.name,
                "capture": str(capture),
                **verdict.model_dump(),
            }
            last_context = context
            result.ok(
                "automation.monitor_installation",
                f"{firmware.upper()} progress capture analyzed by the LLM",
                **context,
            )
            rollback_text = f"{verdict.visible_text}\n{verdict.summary}"
            if self._rollback_in_progress(rollback_text):
                result.ok(
                    "automation.rollback_in_progress",
                    f"{firmware.upper()} rollback detected; monitoring until final verdict",
                    **context,
                )
                continue
            rollback_outcome = self._rollback_terminal_outcome(rollback_text)
            if rollback_outcome is not None:
                context["rollback_outcome"] = rollback_outcome
                message = (
                    f"{firmware.upper()} installation failed after verified rollback"
                    if rollback_outcome == "verified"
                    else f"{firmware.upper()} installation failed with incomplete rollback"
                )
                raise WorkflowError(
                    "automation.monitor_installation",
                    message,
                    details=context,
                )
            if (
                self._display_transition_without_error(rollback_text)
                and not verdict.blocking_problem_visible
            ):
                result.ok(
                    "automation.display_transition",
                    f"{firmware.upper()} display transition detected; monitoring continues",
                    **context,
                )
                continue
            if verdict.error_visible or verdict.blocking_problem_visible:
                if reboot_attempts > 0 and not live_failure_reboot_probe_sent:
                    self._request_live_failure_reboot_probe(vm, capture, result)
                    live_failure_reboot_probe_sent = True
                    continue
                raise WorkflowError(
                    "automation.monitor_installation",
                    f"Visible error during {firmware.upper()} installation",
                    details=context,
                )
            if (
                (verdict.installation_finished or verdict.reboot_prompt_visible)
                and verdict.reboot_prompt_visible
                and not verdict.active_install_progress_visible
            ):
                if reboot_attempts >= 3:
                    raise WorkflowError(
                        "automation.reboot_request",
                        "The Windows restart prompt remained visible after three attempts",
                        details=context,
                    )
                result.ok(
                    (
                        "automation.preparation_finished"
                        if reboot_attempts == 0
                        else "automation.reboot_retry"
                    ),
                    (
                        f"{firmware.upper()} preparation completed; validating reboot"
                        if reboot_attempts == 0
                        else f"{firmware.upper()} restart prompt remained visible; retrying"
                    ),
                    **context,
                )
                self._request_reboot_after_preparation(vm, result)
                reboot_attempts += 1
                previous_signature = None
                unchanged_captures = 0
                last_visual_change_at = time.monotonic()
                monitor_delay_seconds = min(
                    self.settings.automation_monitor_interval_seconds,
                    REBOOT_RECHECK_INTERVAL_SECONDS,
                )
                continue
            # Some vision models put GRUB OCR in the summary instead of
            # visible_text. Inspect both, but accept only the complete final
            # menu. This check precedes the model's generic finished flag so a
            # boot menu can never be mislabeled as a running Linux desktop.
            final_boot_evidence = f"{verdict.visible_text}\n{verdict.summary}"
            if self._reboot_or_live_started(final_boot_evidence, distribution):
                result.ok(
                    "automation.installed_boot_menu_seen",
                    f"Installed {firmware.upper()} boot menu confirmed visually",
                    **context,
                )
                return "boot-menu"
            if (
                reboot_attempts > 0
                and verdict.installation_finished
                and not verdict.active_install_progress_visible
                and self._installed_linux_desktop_seen(final_boot_evidence, distribution)
            ):
                result.ok(
                    "automation.installation_finished",
                    f"{firmware.upper()} installation completed and Linux desktop started",
                    **context,
                )
                return "linux-desktop"
        raise WorkflowError(
            "automation.monitor_installation",
            f"Timed out waiting for Windows to reboot into the {firmware.upper()} live",
            details=last_context or {"vm": vm.name, "target": vm.vnc},
        )

    def _request_live_failure_reboot_probe(
        self,
        vm: VMConfig,
        capture: Path,
        result: ResultBuilder,
    ) -> None:
        client = None
        try:
            client = self.vnc.connect(vm.vnc)
            self._press_key(client, "r", 0)
            result.ok(
                "automation.live_failure_reboot_probe",
                "A deterministic failure-only reboot probe was sent to the live UI",
                vm=vm.name,
                target=vm.vnc,
                capture=str(capture),
            )
        except Exception as exc:
            raise WorkflowError(
                "automation.live_failure_reboot_probe",
                "Failed to send the failure-only reboot probe to the live UI",
                details={"vm": vm.name, "target": vm.vnc, "error": str(exc)},
            ) from exc
        finally:
            if client is not None:
                client.disconnect()

    def _read_archived_live_failure(self, vm: VMConfig) -> dict[str, str] | None:
        try:
            with self.validation.ssh(
                vm.host,
                vm.username,
                self.settings.windows_ssh_password.get_secret_value(),
                remote_os="windows",
            ) as ssh:
                response = self.validation.run_windows_script(
                    ssh,
                    script_name="inspect_live_failure.ps1",
                    config={},
                    step="automation.live_failure_evidence",
                    timeout=60,
                )
        except WorkflowError:
            return None

        values = self.validation.parse_powershell_results(
            response.stdout,
            prefixes=(
                "LIVE_FAILURE_PRESENT",
                "LIVE_FAILURE_MESSAGE",
                "LIVE_FAILURE_STAGE",
                "LIVE_FAILURE_EXIT_CODE",
                "LIVE_FAILURE_ROLLBACK",
                "LIVE_FAILURE_RUN_ID",
            ),
        )
        if values.get("LIVE_FAILURE_PRESENT") != "True":
            return None
        return {
            "message": values.get("LIVE_FAILURE_MESSAGE", "Live installer failed"),
            "stage": values.get("LIVE_FAILURE_STAGE", "unknown"),
            "exit_code": values.get("LIVE_FAILURE_EXIT_CODE", "unknown"),
            "rollback": values.get("LIVE_FAILURE_ROLLBACK", "unknown"),
            "run_id": values.get("LIVE_FAILURE_RUN_ID", "unknown"),
        }

    @staticmethod
    def _capture_signature(capture: Path) -> tuple[int, ...] | None:
        try:
            with Image.open(capture) as screenshot:
                grayscale = screenshot.convert("L").resize(
                    (32, 24),
                    Image.Resampling.BILINEAR,
                )
                flattened_data = getattr(grayscale, "get_flattened_data", None)
                pixel_values = (
                    flattened_data() if flattened_data is not None else grayscale.getdata()
                )
                return tuple(value // 16 for value in pixel_values)
        except (OSError, ValueError):
            return None

    @staticmethod
    def _rollback_in_progress(content: str) -> bool:
        """Keep monitoring while the installer is still restoring Windows."""

        text = content.casefold()
        return any(
            marker in text
            for marker in (
                "restoring windows",
                "running automatic revert",
                "restauration de windows",
                "restaurando windows",
            )
        )

    @staticmethod
    def _rollback_terminal_outcome(content: str) -> Literal["verified", "incomplete"] | None:
        """Classify only explicit final rollback messages rendered by Libertix."""

        text = content.casefold()
        incomplete_markers = (
            "rollback incomplete",
            "rollback incomplet",
            "restauración incompleta",
        )
        if any(marker in text for marker in incomplete_markers):
            return "incomplete"

        verified_markers = (
            "windows has been restored",
            "windows a été restauré",
            "windows a ete restaure",
            "windows ha sido restaurado",
            "windows rollback completed and verified",
            "rollback windows terminé et vérifié",
            "rollback windows termine et verifie",
            "la restauración de windows terminó y fue verificada",
        )
        if any(marker in text for marker in verified_markers):
            return "verified"
        return None

    @staticmethod
    def _display_transition_without_error(content: str) -> bool:
        """Treat missing video during reboot as uncertainty, never as visible failure."""

        text = content.casefold()
        return any(
            marker in text
            for marker in (
                "display output is not active",
                "display is inactive",
                "screen is blank",
                "blank screen",
                "black screen",
                "no video output",
                "video output is not active",
            )
        )

    @staticmethod
    def _reboot_or_live_started(
        visible_text: str, distribution: DistributionProfile | None = None
    ) -> bool:
        """Detect that Windows has left the wizard and the live boot path started.

        Both firmware paths must remain under observation after the reboot.
        Otherwise a bootloader failure can be mistaken for a successful run
        merely because the Windows preparation reached its restart prompt.
        """

        distribution = distribution or load_distribution_profile("mint")
        text = visible_text.lower()
        # The final themed GRUB menu is conclusive evidence that the live
        # installer completed and handed control to the installed system.  It
        # contains both operating systems plus the Libertix advanced submenu;
        # a standalone Windows Boot Manager screen must remain a blocker.
        distribution_entry_visible = distribution.grub_display_name.casefold() in text
        localized_menu_labels_visible = any(
            shutdown in text and advanced in text for shutdown, advanced in FINAL_BOOT_MENU_LABELS
        )
        windows_entry_visible = "windows boot manager" in text or bool(
            re.search(r"(?:^|\n)\s*windows\s*(?:\n|$)", text)
        )
        return (
            distribution_entry_visible and localized_menu_labels_visible and windows_entry_visible
        )

    @staticmethod
    def _installed_linux_desktop_seen(
        content: str, distribution: DistributionProfile | None = None
    ) -> bool:
        """Require Linux-specific evidence before accepting a generic final verdict."""

        distribution = distribution or load_distribution_profile("mint")
        text = content.casefold()
        if any(
            marker in text
            for marker in (
                "redémarrer",
                "restart",
                "libertix 100%",
                "installation preparation completed",
                "préparation terminée",
            )
        ):
            return False
        linux_markers = (
            distribution.name.casefold(),
            distribution.os_release_id.casefold(),
        )
        desktop_markers = ("desktop", "bureau", "welcome", "bienvenue", "panel", "panneau")
        return any(marker in text for marker in linux_markers) and any(
            marker in text for marker in desktop_markers
        )

    def _request_reboot_after_preparation(self, vm: VMConfig, result: ResultBuilder) -> None:
        client = None
        try:
            client = self.vnc.connect(vm.vnc)
            self._capture_from_client(client, vm, "reboot-ready", result)
            self._press_key(client, "enter", REBOOT_DIALOG_DELAY_SECONDS)
            self._capture_from_client(client, vm, "reboot-confirm", result)
            self._press_key(client, "enter", REBOOT_ACCEPT_DELAY_SECONDS)
            try:
                self._capture_from_client(client, vm, "reboot-accepted", result)
            except Exception as exc:
                # A fast reboot can close VNC after the confirmation key was
                # accepted but while captureScreen is waiting for its reply.
                # The boot monitor still has to prove the following live boot.
                result.ok(
                    "automation.reboot_transition",
                    "VNC became unavailable after reboot confirmation; boot verification continues",
                    target=vm.vnc,
                    vm=vm.name,
                    error=str(exc),
                )
            result.ok(
                "automation.reboot_requested",
                "Reboot requested from the focused default controls after the reboot-ready stage",
                target=vm.vnc,
                vm=vm.name,
            )
        except Exception as exc:
            raise WorkflowError(
                "automation.reboot_request",
                "Failed to request reboot from the final controls",
                details={"vm": vm.name, "target": vm.vnc, "error": str(exc)},
            ) from exc
        finally:
            if client is not None:
                try:
                    client.disconnect()
                except Exception:
                    logger.warning(
                        "VNC connection did not close cleanly",
                        extra={"step": "automation.vnc_close", "target": vm.vnc},
                    )
