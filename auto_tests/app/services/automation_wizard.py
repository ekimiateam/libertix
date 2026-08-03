"""VNC interaction for the Libertix wizard."""

from __future__ import annotations

import logging
import re
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Literal

from vncdotool import api

from app.clients.vnc import VNCClient
from app.config import VMConfig
from app.errors import WorkflowError
from app.services.automation_types import AutomationOptions, Point, WizardProfile
from app.services.common import ResultBuilder

logger = logging.getLogger(__name__)


class WizardAutomationMixin:
    """Drive and validate wizard pages through the configured VNC desktop."""

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
                    "Arrêt volontaire après lancement visible de l'interface "
                    f"{profile.launch_only_label}",
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
        self._click(client, vm, Point(512, 403), 2.0)
        self._capture_from_client(client, vm, "01-distro", result)
        self._navigate_to_account(
            client,
            vm,
            welcome_point=Point(512, 403),
            distro_point=Point(145, 395),
            next_point=Point(919, 628),
            sharing_point=Point(899, 588),
            username=options.linux_username,
            result=result,
        )

        self._fill_account_fields(
            client,
            vm,
            username_point=Point(512, 220),
            password_point=Point(512, 333),
            confirmation_point=Point(512, 445),
            username=options.linux_username,
            password=options.linux_password,
        )
        time.sleep(0.5)
        account_capture, account_capture_latest = self._capture_wizard_pair(
            client, vm, "04-account-filled", result
        )
        self._assert_wizard_state(
            account_capture,
            vm,
            latest_capture=account_capture_latest,
            expected_screen="account",
            expected_username=options.linux_username,
            result=result,
        )

        self._click(client, vm, Point(919, 628), 2.0)
        warning_capture, warning_capture_latest = self._capture_wizard_pair(
            client, vm, "05-warning", result
        )
        self._assert_wizard_state(
            warning_capture,
            vm,
            latest_capture=warning_capture_latest,
            expected_screen="warning",
            expected_username=options.linux_username,
            result=result,
        )

        self._click(client, vm, Point(221, 541), 0.5)
        self._click(client, vm, Point(919, 628), 10.0)
        self._capture_from_client(client, vm, "06-apply-started", result)

    def _click_wizard_uefi(
        self, client: object, vm: VMConfig, options: AutomationOptions, result: ResultBuilder
    ) -> None:
        # Coordinates match the manually validated VM502 / 1280x800 UEFI wizard path,
        # converted back to the same 1024x768 reference system used by _click().
        self._click(client, vm, Point(512, 403), 2.0)
        self._capture_from_client(client, vm, "01-distro", result)
        self._navigate_to_account(
            client,
            vm,
            welcome_point=Point(512, 403),
            distro_point=Point(220, 389),
            next_point=Point(838, 614),
            sharing_point=Point(822, 579),
            username=options.linux_username,
            result=result,
        )

        self._fill_account_fields(
            client,
            vm,
            username_point=Point(508, 223),
            password_point=Point(508, 330),
            confirmation_point=Point(508, 438),
            username=options.linux_username,
            password=options.linux_password,
        )
        time.sleep(0.5)
        account_capture, account_capture_latest = self._capture_wizard_pair(
            client, vm, "04-account-filled", result
        )
        self._assert_wizard_state(
            account_capture,
            vm,
            latest_capture=account_capture_latest,
            expected_screen="account",
            expected_username=options.linux_username,
            result=result,
        )

        self._click(client, vm, Point(838, 614), 2.0)
        warning_capture, warning_capture_latest = self._capture_wizard_pair(
            client, vm, "05-warning", result
        )
        self._assert_wizard_state(
            warning_capture,
            vm,
            latest_capture=warning_capture_latest,
            expected_screen="warning",
            expected_username=options.linux_username,
            result=result,
        )

        self._click(client, vm, Point(278, 530), 0.5)
        self._click(client, vm, Point(838, 614), 10.0)
        self._capture_from_client(client, vm, "06-apply-started", result)

    def _navigate_to_account(
        self,
        client: object,
        vm: VMConfig,
        *,
        welcome_point: Point,
        distro_point: Point,
        next_point: Point,
        sharing_point: Point,
        username: str,
        result: ResultBuilder,
    ) -> None:
        deadline = time.monotonic() + 300
        last_screen: str | None = None
        attempt = 0
        while time.monotonic() < deadline:
            attempt += 1
            capture, latest_capture = self._capture_wizard_pair(
                client, vm, f"02-navigation-{attempt:02d}", result
            )
            try:
                verdict = self.vision_llm.analyze_wizard_state(
                    capture,
                    vm.name,
                    vm.os,
                    expected_screen="account",
                    expected_username=username,
                    second_image_path=latest_capture,
                )
            except WorkflowError as exc:
                if exc.step != "llm.wizard_state":
                    raise
                result.ok(
                    "automation.wizard_vision_retry",
                    "Verdict LLM temporairement invalide; nouvelle capture sans clic",
                    target=vm.vnc,
                    vm=vm.name,
                    attempt=attempt,
                    error=exc.message,
                )
                time.sleep(3)
                continue
            context = {
                "target": vm.vnc,
                "vm": vm.name,
                "capture": str(capture),
                "latest_capture": str(latest_capture),
                "detected_screen": verdict.detected_screen,
                "expected_screen_visible": verdict.expected_screen_visible,
                "no_blocking_error": verdict.no_blocking_error,
                "summary": verdict.summary,
                "visible_text": verdict.visible_text,
            }
            visible_lower = verdict.visible_text.lower()
            # Empty account fields legitimately show "password required" before
            # automation fills them. Validation becomes strict immediately after fill.
            if verdict.detected_screen == "account":
                return
            if (
                verdict.detected_screen == "compatibility"
                and "preflight_ok=true" not in verdict.visible_text.lower()
            ):
                result.ok(
                    "automation.compatibility_wait",
                    "Préflight de compatibilité encore en cours",
                    **context,
                )
                time.sleep(2)
                continue
            compatibility_without_error = (
                verdict.detected_screen == "compatibility"
                and "compat_e_" not in verdict.visible_text.lower()
            )
            known_wizard_page_without_error = verdict.detected_screen in {
                "welcome",
                "distro",
                "resize",
                "sharing",
            } and not any(
                marker in visible_lower
                for marker in (
                    "une erreur s'est produite",
                    "erreur pendant",
                    "compat_e_",
                    "installation failed",
                )
            )
            if (
                not verdict.no_blocking_error
                and not compatibility_without_error
                and not known_wizard_page_without_error
            ):
                raise WorkflowError(
                    "automation.wizard_navigation",
                    "Erreur visible pendant la navigation de l'assistant",
                    details=context,
                )
            result.ok(
                "automation.wizard_navigation",
                "Page de l'assistant identifiée avant navigation",
                **context,
            )
            if verdict.detected_screen != last_screen:
                # The vision service can be slow when three VMs are analyzed in
                # parallel. Measure a stall from the latest real wizard
                # transition instead of from the beginning of the whole path.
                deadline = time.monotonic() + 300
                last_screen = verdict.detected_screen
            if verdict.detected_screen == "welcome":
                self._click(client, vm, welcome_point, 1.0)
            elif verdict.detected_screen == "compatibility":
                self._click(client, vm, next_point, 1.0)
            elif verdict.detected_screen == "distro":
                self._click(client, vm, distro_point, 0.3)
                self._click(client, vm, next_point, 1.0)
            elif verdict.detected_screen == "resize":
                self._click(client, vm, next_point, 1.0)
            elif verdict.detected_screen == "sharing":
                self._click(client, vm, sharing_point, 1.0)
            elif verdict.detected_screen in {"warning", "apply"}:
                raise WorkflowError(
                    "automation.wizard_navigation",
                    "L'assistant a dépassé l'écran compte de manière inattendue",
                    details=context,
                )
            elif (
                verdict.detected_screen == "other"
                and "contrôle de compte d'utilisateur" in verdict.visible_text.lower()
                and "sécurité windows" in verdict.visible_text.lower()
            ):
                client.keyPress("esc")
                time.sleep(3)
                result.ok(
                    "automation.dismiss_windows_security_uac",
                    "UAC retardé de Sécurité Windows fermé sans autoriser de modification",
                    target=vm.vnc,
                    vm=vm.name,
                )
            elif (
                verdict.detected_screen == "other"
                and "protection contre les virus et menaces" in verdict.visible_text.lower()
            ):
                client.keyDown("alt")
                client.keyPress("f4")
                client.keyUp("alt")
                time.sleep(3)
                result.ok(
                    "automation.dismiss_windows_security_window",
                    "Fenêtre Windows Security fermée pour rendre Libertix au premier plan",
                    target=vm.vnc,
                    vm=vm.name,
                )
            else:
                time.sleep(3)

        raise WorkflowError(
            "automation.wizard_navigation",
            "Timeout en attendant l'écran de création du compte",
            details={"vm": vm.name, "target": vm.vnc},
        )

    def _assert_wizard_state(
        self,
        capture: Path,
        vm: VMConfig,
        *,
        latest_capture: Path | None = None,
        expected_screen: Literal["account", "warning"],
        expected_username: str,
        result: ResultBuilder,
    ) -> None:
        verdict = self.vision_llm.analyze_wizard_state(
            capture,
            vm.name,
            vm.os,
            expected_screen=expected_screen,
            expected_username=expected_username,
            second_image_path=latest_capture,
        )
        context = {
            "target": vm.vnc,
            "vm": vm.name,
            "capture": str(capture),
            "latest_capture": str(latest_capture or capture),
            "expected_screen": expected_screen,
            **verdict.model_dump(),
        }
        visible_text = verdict.visible_text or ""
        username_pattern = rf"(?<![A-Za-z0-9_-]){re.escape(expected_username)}(?![A-Za-z0-9_-])"
        username_visible_from_text = bool(re.search(username_pattern, visible_text))
        masked_fields = re.findall(r"(?:[\u2022\u25cf\u00b7*]\s*){3,}", visible_text)
        password_fields_filled_from_text = len(masked_fields) >= 2
        username_confirmed = verdict.username_visible or username_visible_from_text
        passwords_confirmed = verdict.password_fields_filled or password_fields_filled_from_text
        context.update(
            {
                "username_visible_from_text": username_visible_from_text,
                "password_fields_filled_from_text": password_fields_filled_from_text,
                "username_confirmed": username_confirmed,
                "password_fields_confirmed": passwords_confirmed,
            }
        )
        # The following transition to the warning page is the authoritative WPF
        # validation that both password fields are non-empty and identical. OCR
        # frequently omits mask glyphs, so requiring them here creates false
        # negatives without adding safety before the non-destructive Next click.
        account_valid = expected_screen != "account" or username_confirmed
        if (
            verdict.detected_screen != expected_screen
            or not verdict.expected_screen_visible
            or not verdict.no_blocking_error
            or not account_valid
        ):
            raise WorkflowError(
                "automation.wizard_state",
                "État critique de l'assistant non confirmé; Apply est bloqué",
                details=context,
            )
        result.ok(
            "automation.wizard_state",
            "État critique de l'assistant confirmé avant de continuer",
            **context,
        )

    def _capture_wizard_pair(
        self,
        client: object,
        vm: VMConfig,
        label: str,
        result: ResultBuilder,
    ) -> tuple[Path, Path]:
        first = self._capture_from_client(client, vm, f"{label}-01", result)
        time.sleep(1)
        second = self._capture_from_client(client, vm, f"{label}-02", result)
        return first, second

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
        return self._capture_dir / f"{vm.name}-auto-{stamp}-{safe_label}.png"

    def _click(self, client: object, vm: VMConfig, point: Point, delay: float) -> None:
        x = round(point.x * vm.screen_width / self.REFERENCE_WIDTH)
        y = round(point.y * vm.screen_height / self.REFERENCE_HEIGHT)
        client.mouseMove(x, y)
        client.mousePress(1)
        time.sleep(delay)

    @staticmethod
    def _click_absolute(client: object, vm: VMConfig, point: Point, delay: float) -> None:
        if not (0 <= point.x < vm.screen_width and 0 <= point.y < vm.screen_height):
            raise WorkflowError(
                "automation.click",
                "Coordonnées VNC hors écran",
                details={"vm": vm.name, "x": point.x, "y": point.y},
            )
        client.mouseMove(point.x, point.y)
        client.mousePress(1)
        time.sleep(delay)

    def _fill_field(self, client: object, vm: VMConfig, point: Point, text: str) -> None:
        self._click(client, vm, point, 0.35)
        self._select_all(client)
        time.sleep(0.15)
        self._type_text(client, text)
        time.sleep(0.35)

    def _fill_account_fields(
        self,
        client: object,
        vm: VMConfig,
        *,
        username_point: Point,
        password_point: Point,
        confirmation_point: Point,
        username: str,
        password: str,
    ) -> None:
        self._fill_field(client, vm, username_point, username)
        self._fill_field(client, vm, password_point, password)
        self._fill_field(client, vm, confirmation_point, password)
        # WPF can recreate the first PasswordBox when its initial validation
        # error clears. A second selected write makes both password controls
        # deterministic without relying on clipboard or OCR.
        self._fill_field(client, vm, password_point, password)
        self._fill_field(client, vm, confirmation_point, password)

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
