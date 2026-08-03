"""Visual monitoring after the Libertix Apply action."""

from __future__ import annotations

import logging
import time

from vncdotool import api

from app.clients.vnc import VNCClient
from app.config import VMConfig
from app.errors import WorkflowError
from app.services.automation_types import Point
from app.services.common import ResultBuilder

logger = logging.getLogger(__name__)


class InstallationMonitoringMixin:
    """Observe preparation, confirm reboot, and stop at the validated live stage."""

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
                raise
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
        reboot_clicked = False
        while time.monotonic() < deadline:
            attempt += 1
            time.sleep(self.settings.automation_monitor_interval_seconds)
            capture = self._capture_with_name(vm, f"uefi-monitor-{attempt:03d}")
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
            if (
                not reboot_clicked
                and (verdict.installation_finished or verdict.reboot_prompt_visible)
                and not verdict.active_install_progress_visible
            ):
                result.ok(
                    "automation.uefi_preparation_finished",
                    "Préparation UEFI terminée; validation du redémarrage",
                    **context,
                )
                self._click_reboot_after_preparation(vm, result)
                reboot_clicked = True
                continue
            if (
                reboot_clicked
                and verdict.installation_finished
                and not verdict.active_install_progress_visible
            ):
                result.ok(
                    "automation.uefi_installation_finished",
                    "Installation UEFI terminée et bureau Linux démarré",
                    **context,
                )
                return
            # Depending on the local vision model, the stable live-stage text
            # can be returned in either visible_text or the concise summary.
            # Inspect both fields so a real live boot is not missed merely
            # because the model placed its OCR evidence in the summary.
            live_evidence = f"{verdict.visible_text}\n{verdict.summary}"
            if self._uefi_reboot_or_live_started(live_evidence):
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
    def _uefi_reboot_or_live_started(visible_text: str) -> bool:
        """Detect that Windows has left the wizard and the live boot path started.

        The UEFI automation must match the BIOS contract: it confirms the app
        path up to the reboot into the installer, then stops. It must not wait
        for Mint installation success.
        """

        text = visible_text.lower()
        # The final themed GRUB menu is conclusive evidence that the live
        # installer completed and handed control to the installed system.  It
        # contains both operating systems plus the Libertix advanced submenu;
        # a standalone Windows Boot Manager screen must remain a blocker.
        if all(
            marker in text
            for marker in (
                "linux mint gnu/linux",
                "windows boot manager",
                "advanced options",
            )
        ):
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

        return any(
            marker in text
            for marker in (
                "libertix stage:",
                "code: 120-unsquashfs",
                "code: 130-target-system-config",
                "f12: mode terminal",
                "libertix_install_success=",
            )
        ) and any(
            marker in text
            for marker in (
                "installation automatique",
                "extraction de mint",
                "configuration du système installé",
                "configuration du systeme installe",
                "libertix stage:",
                "installer-success",
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
                "Commande de redémarrage envoyée après verdict LLM de fin",
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
