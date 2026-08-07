"""VNC interaction for the Libertix wizard."""

from __future__ import annotations

import logging
import re
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Literal

from app.clients.vision_models import contains_install_blocker
from app.config import VMConfig
from app.errors import WorkflowError
from app.services.automation_types import (
    AutomationOptions,
    Point,
    WizardLayout,
    WizardProfile,
)
from app.services.common import ResultBuilder
from tools.azerty_qwerty import azerty_to_qwerty

logger = logging.getLogger(__name__)

COMPATIBILITY_SUCCESS_MARKERS = (
    "machine compatible",
    "this computer is compatible",
    "el equipo es compatible",
    "互換性があります",
)


class WizardAutomationMixin:
    """Drive and validate wizard pages through the configured VNC desktop."""

    # VNC cannot discover WPF controls semantically. Keep the two validated
    # layouts centralized so UI changes update one explicit contract instead of
    # leaving unrelated pixel literals throughout the navigation workflow.
    BIOS_LAYOUT = WizardLayout(
        welcome_next=Point(512, 403),
        distribution=Point(145, 395),
        next_button=Point(919, 628),
        sharing_next=Point(899, 588),
        windows_to_linux_checkbox=Point(125, 310),
        linux_to_windows_checkbox=Point(125, 415),
        username=Point(512, 220),
        password=Point(512, 333),
        password_confirmation=Point(512, 445),
        warning_acknowledgement=Point(430, 575),
    )
    UEFI_LAYOUT = WizardLayout(
        welcome_next=Point(512, 403),
        distribution=Point(220, 389),
        next_button=Point(838, 614),
        sharing_next=Point(822, 579),
        windows_to_linux_checkbox=Point(125, 310),
        linux_to_windows_checkbox=Point(125, 415),
        username=Point(508, 223),
        password=Point(508, 330),
        password_confirmation=Point(508, 438),
        warning_acknowledgement=Point(430, 566),
    )

    def _click_wizard(
        self,
        vm: VMConfig,
        options: AutomationOptions,
        profile: WizardProfile,
        result: ResultBuilder,
    ) -> Literal["boot-menu", "linux-desktop"] | None:
        client = None
        try:
            client = self.vnc.connect(vm.vnc)
            time.sleep(1)
            self._capture_from_client(client, vm, "00-welcome", result)

            if not options.apply:
                result.ok(
                    "automation.launch_only_stop",
                    "Stopped intentionally after the interface became visible: "
                    f"{profile.launch_only_label}",
                    target=vm.vnc,
                    vm=vm.name,
                )
                return None

            layout = self.UEFI_LAYOUT if profile.name == "uefi" else self.BIOS_LAYOUT
            self._click_wizard_path(client, vm, options, result, layout)
        except WorkflowError:
            raise
        except Exception as exc:
            raise WorkflowError(
                "automation.vnc_click",
                "VNC automation failed",
                details={"vm": vm.name, "address": vm.vnc, "error": str(exc)},
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

        if options.monitor_iso:
            return self._monitor_until_live_boot(vm, result, profile.name)
        return None

    def _click_wizard_path(
        self,
        client: object,
        vm: VMConfig,
        options: AutomationOptions,
        result: ResultBuilder,
        layout: WizardLayout,
    ) -> None:
        self._click(client, vm, layout.welcome_next, 2.0)
        self._capture_from_client(client, vm, "01-distro", result)
        self._navigate_to_account(
            client,
            vm,
            welcome_point=layout.welcome_next,
            distro_point=layout.distribution,
            next_point=layout.next_button,
            sharing_point=layout.sharing_next,
            windows_to_linux_checkbox=layout.windows_to_linux_checkbox,
            linux_to_windows_checkbox=layout.linux_to_windows_checkbox,
            share_windows_files_in_linux=options.share_windows_files_in_linux,
            share_linux_files_in_windows=options.share_linux_files_in_windows,
            username=options.linux_username,
            result=result,
        )

        self._fill_account_fields(
            client,
            vm,
            username_point=layout.username,
            password_point=layout.password,
            confirmation_point=layout.password_confirmation,
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

        # Navigation can complete after the button handler returns while WPF is
        # busy rendering three concurrent test VMs. Let the animation settle
        # before asking vision to prove that the warning page replaced account.
        self._click(client, vm, layout.next_button, 5.0)
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

        self._click(client, vm, layout.warning_acknowledgement, 0.5)
        self._click(client, vm, layout.next_button, 10.0)
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
        windows_to_linux_checkbox: Point | None = None,
        linux_to_windows_checkbox: Point | None = None,
        share_windows_files_in_linux: bool = True,
        share_linux_files_in_windows: bool = True,
    ) -> None:
        windows_to_linux_checkbox = windows_to_linux_checkbox or Point(125, 310)
        linux_to_windows_checkbox = linux_to_windows_checkbox or Point(125, 415)
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
                    "Temporarily invalid LLM verdict; capturing again without clicking",
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
            analysis_lower = f"{verdict.summary}\n{verdict.visible_text}".lower()
            # Empty account fields legitimately show "password required" before
            # automation fills them. Validation becomes strict immediately after fill.
            if verdict.detected_screen == "account":
                return
            compatibility_error_visible = verdict.detected_screen == "compatibility" and (
                bool(re.search(r"\bCOMPAT_E_[A-Z0-9_]+\b", verdict.visible_text, re.IGNORECASE))
                or "preflight_ok=false" in visible_lower
            )
            if compatibility_error_visible:
                raise WorkflowError(
                    "automation.compatibility_preflight",
                    "Compatibility preflight failed",
                    details=context,
                )
            if verdict.detected_screen == "resize" and contains_install_blocker(
                verdict.visible_text
            ):
                raise WorkflowError(
                    "automation.resize_capacity",
                    "Libertix reports insufficient disk space",
                    details=context,
                )
            compatibility_complete = verdict.detected_screen == "compatibility" and any(
                marker in visible_lower for marker in COMPATIBILITY_SUCCESS_MARKERS
            )
            if verdict.detected_screen == "compatibility" and not compatibility_complete:
                result.ok(
                    "automation.compatibility_wait",
                    "Compatibility preflight is still running",
                    **context,
                )
                time.sleep(2)
                continue
            compatibility_without_error = (
                verdict.detected_screen == "compatibility" and not compatibility_error_visible
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
                    "Visible error while navigating the wizard",
                    details=context,
                )
            result.ok(
                "automation.wizard_navigation",
                "Wizard page identified before navigation",
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
                if not share_windows_files_in_linux:
                    self._click(client, vm, windows_to_linux_checkbox, 0.3)
                if not share_linux_files_in_windows:
                    self._click(client, vm, linux_to_windows_checkbox, 0.3)
                self._click(client, vm, sharing_point, 1.0)
            elif verdict.detected_screen in {"warning", "apply"}:
                raise WorkflowError(
                    "automation.wizard_navigation",
                    "The wizard unexpectedly advanced past the account screen",
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
                    "Delayed Windows Security UAC closed without authorizing a change",
                    target=vm.vnc,
                    vm=vm.name,
                )
            elif verdict.detected_screen == "other" and any(
                marker in analysis_lower
                for marker in (
                    "windows security",
                    "securite windows",
                    "sécurité windows",
                    "protection contre les virus et menaces",
                )
            ):
                client.keyDown("alt")
                client.keyPress("f4")
                client.keyUp("alt")
                time.sleep(3)
                result.ok(
                    "automation.dismiss_windows_security_window",
                    "Windows Security window closed to bring Libertix to the foreground",
                    target=vm.vnc,
                    vm=vm.name,
                )
            elif verdict.detected_screen == "other" and any(
                marker in analysis_lower
                for marker in (
                    "windows settings",
                    "paramètres windows",
                    "parametres windows",
                    "system settings",
                )
            ):
                client.keyDown("alt")
                client.keyPress("f4")
                client.keyUp("alt")
                time.sleep(3)
                result.ok(
                    "automation.dismiss_windows_settings",
                    "Windows Settings closed to bring Libertix to the foreground",
                    target=vm.vnc,
                    vm=vm.name,
                )
            else:
                time.sleep(3)

        raise WorkflowError(
            "automation.wizard_navigation",
            "Timed out waiting for the account creation screen",
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
                "Critical wizard state not confirmed; Apply is blocked",
                details=context,
            )
        result.ok(
            "automation.wizard_state",
            "Critical wizard state confirmed before continuing",
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
                "VNC capture is missing or empty",
                details={"vm": vm.name, "path": str(path)},
            )
        result.ok(
            "automation.capture",
            "UI capture saved",
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
                "VNC coordinates are outside the display",
                details={"vm": vm.name, "x": point.x, "y": point.y},
            )
        client.mouseMove(point.x, point.y)
        client.mousePress(1)
        time.sleep(delay)

    def _fill_field(self, client: object, vm: VMConfig, point: Point, text: str) -> None:
        self._click(client, vm, point, 0.35)
        self._select_all(client)
        time.sleep(0.15)
        self._type_text(client, text, vm.vnc_keyboard_layout)
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
    def _type_text(client: object, text: str, keyboard_layout: str = "us") -> None:
        # Send keys one by one. Clipboard paste is not reliable across the VNC
        # stack and can silently fail on login/password fields.
        # Proxmox VNC sends US physical key positions. Pre-translating text for
        # a French Windows session makes the characters produced by AZERTY
        # match the caller's logical value, including masked password fields.
        wire_text = azerty_to_qwerty(text) if keyboard_layout == "fr" else text
        for char in wire_text:
            # vncdotool treats a literal hyphen as a chord separator. Its
            # documented "minus" key name emits the actual punctuation key.
            client.keyPress("minus" if char == "-" else char)
            time.sleep(0.12)

    @staticmethod
    def _select_all(client: object) -> None:
        # The Windows VNC keyboard layout used in this lab maps Ctrl+A through
        # the physical Q key. Keeping it here avoids paste/clipboard paths.
        control_is_down = False
        try:
            client.keyDown("ctrl")
            control_is_down = True
            time.sleep(0.05)
            client.keyPress("q")
            time.sleep(0.05)
        finally:
            if control_is_down:
                client.keyUp("ctrl")
                time.sleep(0.05)
