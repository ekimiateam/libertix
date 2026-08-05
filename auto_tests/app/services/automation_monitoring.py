"""Visual monitoring after the Libertix Apply action."""

from __future__ import annotations

import logging
import re
import time
from typing import Literal

from vncdotool import api

from app.clients.vnc import VNCClient
from app.config import VMConfig
from app.errors import WorkflowError
from app.services.automation_types import Point
from app.services.common import ResultBuilder

logger = logging.getLogger(__name__)


class InstallationMonitoringMixin:
    """Observe preparation, reboot, live installation, and the installed system."""

    def _monitor_until_live_boot(
        self,
        vm: VMConfig,
        result: ResultBuilder,
        firmware: Literal["bios", "uefi"],
    ) -> Literal["boot-menu", "linux-desktop"]:
        """Monitor Windows preparation and the following live boot as one transaction."""

        deadline = time.monotonic() + self.settings.automation_monitor_timeout_seconds
        attempt = 0
        last_context: dict[str, object] | None = None
        reboot_clicked = False
        while time.monotonic() < deadline:
            attempt += 1
            time.sleep(self.settings.automation_monitor_interval_seconds)
            capture = self._capture_with_name(vm, f"{firmware}-monitor-{attempt:03d}")
            try:
                verdict = self.vision_llm.analyze_install_progress(capture, vm.name, vm.os)
            except WorkflowError as exc:
                exc.details.update({"vm": vm.name, "target": vm.vnc, "capture": str(capture)})
                raise
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
                raise WorkflowError(
                    "automation.monitor_installation",
                    f"Visible error during {firmware.upper()} installation",
                    details=context,
                )
            if (
                not reboot_clicked
                and (verdict.installation_finished or verdict.reboot_prompt_visible)
                and not verdict.active_install_progress_visible
            ):
                result.ok(
                    "automation.preparation_finished",
                    f"{firmware.upper()} preparation completed; validating reboot",
                    **context,
                )
                self._click_reboot_after_preparation(vm, result)
                reboot_clicked = True
                continue
            # Some vision models put GRUB OCR in the summary instead of
            # visible_text. Inspect both, but accept only the complete final
            # menu. This check precedes the model's generic finished flag so a
            # boot menu can never be mislabeled as a running Linux desktop.
            final_boot_evidence = f"{verdict.visible_text}\n{verdict.summary}"
            if self._reboot_or_live_started(final_boot_evidence):
                result.ok(
                    "automation.installed_boot_menu_seen",
                    f"Installed {firmware.upper()} boot menu confirmed visually",
                    **context,
                )
                return "boot-menu"
            if (
                reboot_clicked
                and verdict.installation_finished
                and not verdict.active_install_progress_visible
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

    @staticmethod
    def _rollback_in_progress(content: str) -> bool:
        """Keep monitoring while the installer is still restoring Windows."""

        text = content.casefold()
        return any(
            marker in text
            for marker in (
                "restoring windows",
                "restauration de windows",
                "restaurando windows",
                "windows を復元しています",
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
            "ロールバックが完了していません",
        )
        if any(marker in text for marker in incomplete_markers):
            return "incomplete"

        verified_markers = (
            "windows has been restored",
            "windows a été restauré",
            "windows a ete restaure",
            "windows ha sido restaurado",
            "windows を復元しました",
            "windows rollback completed and verified",
            "rollback windows terminé et vérifié",
            "rollback windows termine et verifie",
            "la restauración de windows terminó y fue verificada",
            "windows のロールバックと検証が完了しました",
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
    def _reboot_or_live_started(visible_text: str) -> bool:
        """Detect that Windows has left the wizard and the live boot path started.

        Both firmware paths must remain under observation after the reboot.
        Otherwise a bootloader failure can be mistaken for a successful run
        merely because the Windows preparation reached its restart prompt.
        """

        text = visible_text.lower()
        # The final themed GRUB menu is conclusive evidence that the live
        # installer completed and handed control to the installed system.  It
        # contains both operating systems plus the Libertix advanced submenu;
        # a standalone Windows Boot Manager screen must remain a blocker.
        final_menu_markers = (
            "linux mint gnu/linux",
            "shutdown",
            "advanced options",
        )
        windows_entry_visible = "windows boot manager" in text or bool(
            re.search(r"(?:^|\n)\s*windows\s*(?:\n|$)", text)
        )
        if all(marker in text for marker in final_menu_markers) and windows_entry_visible:
            return True

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

        return False

    def _click_reboot_after_preparation(self, vm: VMConfig, result: ResultBuilder) -> None:
        client = None
        try:
            client = api.connect(VNCClient._vncdotool_address(vm.vnc))
            self._capture_from_client(client, vm, "reboot-ready", result)
            # Small delays keep the click sequence visible and avoid racing the
            # confirmation dialog after the LLM declares the wizard complete.
            time.sleep(2)
            reboot_point = Point(1045, 643) if vm.screen_width >= 1200 else Point(919, 628)
            # The confirmation is a fixed-width WPF dialog rendered by
            # Libertix, not a native MessageBox. Click the center of its
            # localized affirmative button at each validated VM resolution.
            confirm_point = Point(756, 427) if vm.screen_width >= 1200 else Point(640, 427)
            self._click_absolute(client, vm, reboot_point, 1.0)
            self._capture_from_client(client, vm, "reboot-confirm", result)
            time.sleep(1)
            self._click_absolute(client, vm, confirm_point, 3.0)
            self._capture_from_client(client, vm, "reboot-accepted", result)
            result.ok(
                "automation.reboot_clicked",
                "Reboot command sent after final LLM verdict",
                target=vm.vnc,
                vm=vm.name,
            )
        except Exception as exc:
            raise WorkflowError(
                "automation.reboot_click",
                "Failed to click the final reboot control",
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
