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
WARNING_TRANSITION_MAX_ATTEMPTS = 6
WARNING_TRANSITION_RETRY_SECONDS = 5
WARNING_ACKNOWLEDGEMENT_MAX_ATTEMPTS = 3
WARNING_ACKNOWLEDGEMENT_RETRY_SECONDS = 5
APPLY_TRANSITION_MAX_OBSERVATIONS = 4
APPLY_TRANSITION_RETRY_SECONDS = 3


def _is_retryable_wizard_vision_error(exc: WorkflowError) -> bool:
    """Return whether the critical-screen proof failed for a transient network reason."""

    return exc.step == "llm.wizard_state" and exc.details.get("http_status") in (
        None,
        429,
        500,
        502,
        503,
        504,
    )


class WizardAutomationMixin:
    """Drive and validate wizard pages through the configured VNC desktop."""

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

            self._click_wizard_path(client, vm, options, result)
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
            return self._monitor_until_live_boot(vm, result, profile.name, options.distribution)
        return None

    def _click_wizard_path(
        self,
        client: object,
        vm: VMConfig,
        options: AutomationOptions,
        result: ResultBuilder,
    ) -> None:
        self._press_key(client, "enter", 2.0)
        self._capture_from_client(client, vm, "01-distro", result)
        self._navigate_to_account(
            client,
            vm,
            distribution_index=options.distribution.catalog_index,
            share_windows_files_in_linux=options.share_windows_files_in_linux,
            share_linux_files_in_windows=options.share_linux_files_in_windows,
            username=options.linux_username,
            result=result,
        )

        self._fill_and_confirm_account_fields(
            client,
            vm,
            username=options.linux_username,
            password=options.linux_password,
            result=result,
        )

        # Navigation can complete after the button handler returns while WPF is
        # busy rendering three concurrent test VMs. Let the animation settle
        # before asking vision to prove that the warning page replaced account.
        self._press_key(client, "enter", 5.0)
        self._confirm_warning_page(
            client,
            vm,
            options.linux_username,
            result,
        )

        self._acknowledge_warning_page(
            client,
            vm,
            options.linux_username,
            result,
        )
        self._start_installation_from_warning(
            client,
            vm,
            options.linux_username,
            result,
        )

    def _navigate_to_account(
        self,
        client: object,
        vm: VMConfig,
        *,
        distribution_index: int,
        username: str,
        result: ResultBuilder,
        share_windows_files_in_linux: bool = True,
        share_linux_files_in_windows: bool = True,
    ) -> None:
        if distribution_index < 0:
            raise WorkflowError(
                "automation.distribution_catalog",
                "The selected distribution has an invalid catalog position",
            )
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
            if verdict.detected_screen in {"welcome", "compatibility"}:
                if verdict.detected_screen == "welcome":
                    # A scheduled task can display Libertix without making it
                    # the foreground window. Recover focus with the standard
                    # window-switching shortcut instead of screen coordinates.
                    self._press_chord(client, "alt", "tab", 0.5)
                self._press_key(client, "enter", 1.0)
            elif verdict.detected_screen == "distro":
                self._select_distribution_with_keyboard(client, distribution_index)
            elif verdict.detected_screen == "resize":
                self._press_chord(client, "ctrl", "end")
                self._press_key(client, "enter", 1.0)
            elif verdict.detected_screen == "sharing":
                self._configure_sharing_with_keyboard(
                    client,
                    share_windows_files_in_linux=share_windows_files_in_linux,
                    share_linux_files_in_windows=share_linux_files_in_windows,
                )
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
                self._close_windows_interference(
                    vm,
                    kind="security",
                    step="automation.dismiss_windows_security_window",
                    result=result,
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
                self._close_windows_interference(
                    vm,
                    kind="settings",
                    step="automation.dismiss_windows_settings",
                    result=result,
                )
            else:
                time.sleep(3)

        raise WorkflowError(
            "automation.wizard_navigation",
            "Timed out waiting for the account creation screen",
            details={"vm": vm.name, "target": vm.vnc},
        )

    def _confirm_warning_page(
        self,
        client: object,
        vm: VMConfig,
        username: str,
        result: ResultBuilder,
    ) -> None:
        for attempt in range(1, WARNING_TRANSITION_MAX_ATTEMPTS + 1):
            capture, latest_capture = self._capture_wizard_pair(
                client, vm, f"05-warning-{attempt:02d}", result
            )
            try:
                self._assert_wizard_state(
                    capture,
                    vm,
                    latest_capture=latest_capture,
                    expected_screen="warning",
                    expected_username=username,
                    result=result,
                )
                return
            except WorkflowError as exc:
                if (
                    _is_retryable_wizard_vision_error(exc)
                    and attempt < WARNING_TRANSITION_MAX_ATTEMPTS
                ):
                    result.ok(
                        "automation.warning_vision_wait",
                        "Warning-page visual proof is temporarily unavailable; retrying",
                        target=vm.vnc,
                        vm=vm.name,
                        attempt=attempt,
                        maximum_attempts=WARNING_TRANSITION_MAX_ATTEMPTS,
                        vision_error=exc.details,
                    )
                    time.sleep(WARNING_TRANSITION_RETRY_SECONDS)
                    continue
                diagnostic = " ".join(
                    str(exc.details.get(name, "")) for name in ("summary", "visible_text")
                ).lower()
                settings_is_obscuring = any(
                    marker in diagnostic
                    for marker in (
                        "windows settings",
                        "paramètres windows",
                        "parametres windows",
                        "system settings",
                    )
                )
                account_is_still_visible = (
                    exc.details.get("detected_screen") == "account"
                    and exc.details.get("username_confirmed") is True
                    and exc.details.get("password_fields_confirmed") is True
                )
                if account_is_still_visible and attempt < WARNING_TRANSITION_MAX_ATTEMPTS:
                    self._press_key(client, "enter", 5.0)
                    continue
                if exc.details.get("no_blocking_error") is not True:
                    raise
                if settings_is_obscuring:
                    if attempt == WARNING_TRANSITION_MAX_ATTEMPTS:
                        raise
                    self._close_windows_interference(
                        vm,
                        kind="settings",
                        step="automation.dismiss_windows_settings",
                        result=result,
                    )
                    continue
                if (
                    exc.details.get("detected_screen") == "other"
                    and attempt < WARNING_TRANSITION_MAX_ATTEMPTS
                ):
                    result.ok(
                        "automation.warning_transition_wait",
                        "Warning page is still rendering; visual confirmation will retry",
                        target=vm.vnc,
                        vm=vm.name,
                        attempt=attempt,
                        maximum_attempts=WARNING_TRANSITION_MAX_ATTEMPTS,
                    )
                    time.sleep(WARNING_TRANSITION_RETRY_SECONDS)
                    continue
                raise

        raise AssertionError("Warning-page confirmation loop ended unexpectedly")

    def _acknowledge_warning_page(
        self,
        client: object,
        vm: VMConfig,
        username: str,
        result: ResultBuilder,
    ) -> None:
        """Select and visually prove the destructive-action acknowledgement."""

        last_context: dict[str, object] = {}
        for observation in range(1, WARNING_ACKNOWLEDGEMENT_MAX_ATTEMPTS + 1):
            try:
                self._set_warning_acknowledgement(vm, result, attempt=observation)
            except WorkflowError as exc:
                diagnostic = "\n".join(
                    str(exc.details.get(name, "")) for name in ("stdout", "stderr")
                ).casefold()
                control_not_ready = (
                    "warning acknowledgement control did not become visible" in diagnostic
                )
                if control_not_ready and observation < WARNING_ACKNOWLEDGEMENT_MAX_ATTEMPTS:
                    result.ok(
                        "automation.warning_acknowledgement_wait",
                        "Warning accessibility tree is still rendering; selection will retry",
                        vm=vm.name,
                        target=vm.host,
                        attempt=observation,
                        maximum_attempts=WARNING_ACKNOWLEDGEMENT_MAX_ATTEMPTS,
                    )
                    time.sleep(WARNING_ACKNOWLEDGEMENT_RETRY_SECONDS)
                    continue
                raise
            capture, latest_capture = self._capture_wizard_pair(
                client, vm, f"05-warning-acknowledgement-{observation:02d}", result
            )
            try:
                verdict = self.vision_llm.analyze_wizard_state(
                    capture,
                    vm.name,
                    vm.os,
                    expected_screen="warning",
                    expected_username=username,
                    second_image_path=latest_capture,
                )
            except WorkflowError as exc:
                if (
                    _is_retryable_wizard_vision_error(exc)
                    and observation < WARNING_ACKNOWLEDGEMENT_MAX_ATTEMPTS
                ):
                    result.ok(
                        "automation.warning_acknowledgement_vision_wait",
                        "Checkbox visual proof is temporarily unavailable; retrying",
                        target=vm.vnc,
                        vm=vm.name,
                        attempt=observation,
                        maximum_attempts=WARNING_ACKNOWLEDGEMENT_MAX_ATTEMPTS,
                        vision_error=exc.details,
                    )
                    time.sleep(WARNING_ACKNOWLEDGEMENT_RETRY_SECONDS)
                    continue
                raise
            context = {
                "target": vm.vnc,
                "vm": vm.name,
                "capture": str(capture),
                "latest_capture": str(latest_capture),
                **verdict.model_dump(),
            }
            last_context = context
            if (
                verdict.detected_screen == "warning"
                and verdict.expected_screen_visible
                and verdict.no_blocking_error
                and verdict.warning_acknowledged
            ):
                result.ok(
                    "automation.warning_acknowledged",
                    "Warning acknowledgement visibly selected before Apply",
                    **context,
                )
                return
            if (
                verdict.detected_screen != "warning"
                or not verdict.expected_screen_visible
                or not verdict.no_blocking_error
            ):
                raise WorkflowError(
                    "automation.warning_acknowledgement",
                    "Warning page was lost while selecting its acknowledgement",
                    details=context,
                )
            result.ok(
                "automation.warning_acknowledgement_retry",
                (
                    "Warning checkbox was not visibly selected; "
                    "Space and accessibility selection will retry"
                ),
                attempt=observation,
                **context,
            )
            if observation < WARNING_ACKNOWLEDGEMENT_MAX_ATTEMPTS:
                # The accessibility worker leaves keyboard focus on the checkbox.
                # Space provides an independent fallback when UI Automation reports
                # On but the rendered control is still visibly unchecked. The next
                # iteration restores On idempotently before taking new screenshots.
                self._press_key(client, "space", 0.5)

        raise WorkflowError(
            "automation.warning_acknowledgement",
            "Warning checkbox could not be visibly selected after three attempts",
            details=last_context or {"vm": vm.name, "target": vm.vnc},
        )

    def _set_warning_acknowledgement(
        self,
        vm: VMConfig,
        result: ResultBuilder,
        *,
        attempt: int,
    ) -> None:
        """Set the warning checkbox to On without a coordinate or toggle action."""

        with self.validation.ssh(
            vm.host,
            vm.username,
            self.settings.windows_ssh_password.get_secret_value(),
            remote_os="windows",
        ) as ssh:
            response = self.validation.run_windows_script(
                ssh,
                script_name="set_warning_acknowledgement.ps1",
                config={},
                step="automation.set_warning_acknowledgement",
                timeout=150,
            )
        values = self.validation.parse_powershell_results(
            response.stdout,
            prefixes=(
                "ACKNOWLEDGED",
                "CONFIRM_ENABLED",
                "LIBERTIX_PROCESS_ID",
                "CHECKBOX_SEARCH_SCOPE",
                "BUTTON_SEARCH_SCOPE",
            ),
        )
        if values.get("ACKNOWLEDGED") != "True" or values.get("CONFIRM_ENABLED") != "True":
            raise WorkflowError(
                "automation.set_warning_acknowledgement",
                "Windows accessibility did not prove the warning acknowledgement",
                details={
                    "vm": vm.name,
                    "target": vm.host,
                    "attempt": attempt,
                    **values,
                },
            )
        result.ok(
            "automation.set_warning_acknowledgement",
            "Warning acknowledgement set and read back through Windows accessibility",
            vm=vm.name,
            target=vm.host,
            attempt=attempt,
            libertix_process_id=int(values["LIBERTIX_PROCESS_ID"]),
            checkbox_search_scope=values["CHECKBOX_SEARCH_SCOPE"],
            button_search_scope=values["BUTTON_SEARCH_SCOPE"],
        )

    def _start_installation_from_warning(
        self,
        client: object,
        vm: VMConfig,
        username: str,
        result: ResultBuilder,
    ) -> None:
        """Activate Apply by keyboard and prove that the warning page was left."""

        last_context: dict[str, object] = {}
        for attempt in range(1, 4):
            # The accessibility worker leaves focus on the checkbox. With cyclic
            # tab order, Shift+Tab selects the confirmation button regardless of
            # screen resolution, then Enter invokes it.
            self._press_chord(client, "shift", "tab")
            self._press_key(client, "enter", 3.0)
            for observation in range(1, APPLY_TRANSITION_MAX_OBSERVATIONS + 1):
                capture, latest_capture = self._capture_wizard_pair(
                    client,
                    vm,
                    f"06-apply-started-{attempt:02d}-{observation:02d}",
                    result,
                )
                try:
                    verdict = self.vision_llm.analyze_wizard_state(
                        capture,
                        vm.name,
                        vm.os,
                        expected_screen="warning",
                        expected_username=username,
                        second_image_path=latest_capture,
                    )
                except WorkflowError as exc:
                    if (
                        _is_retryable_wizard_vision_error(exc)
                        and observation < APPLY_TRANSITION_MAX_OBSERVATIONS
                    ):
                        result.ok(
                            "automation.apply_vision_wait",
                            "Apply-page visual proof is temporarily unavailable; retrying",
                            target=vm.vnc,
                            vm=vm.name,
                            attempt=attempt,
                            observation=observation,
                            maximum_observations=APPLY_TRANSITION_MAX_OBSERVATIONS,
                            vision_error=exc.details,
                        )
                        time.sleep(APPLY_TRANSITION_RETRY_SECONDS)
                        continue
                    raise
                context = {
                    "target": vm.vnc,
                    "vm": vm.name,
                    "capture": str(capture),
                    "latest_capture": str(latest_capture),
                    "attempt": attempt,
                    "observation": observation,
                    **verdict.model_dump(),
                }
                last_context = context
                if verdict.detected_screen == "apply" and verdict.no_blocking_error:
                    result.ok(
                        "automation.apply_started",
                        "Apply page visibly replaced the warning page",
                        **context,
                    )
                    return
                if verdict.detected_screen == "other" and verdict.no_blocking_error:
                    if observation < APPLY_TRANSITION_MAX_OBSERVATIONS:
                        time.sleep(APPLY_TRANSITION_RETRY_SECONDS)
                        continue
                    raise WorkflowError(
                        "automation.apply_started",
                        "The Apply page did not finish rendering within the observation window",
                        details=context,
                    )
                if (
                    verdict.detected_screen != "warning"
                    or not verdict.expected_screen_visible
                    or not verdict.no_blocking_error
                ):
                    raise WorkflowError(
                        "automation.apply_started",
                        "The destructive transition did not reach a valid Apply page",
                        details=context,
                    )
                break
            self._set_warning_acknowledgement(vm, result, attempt=attempt + 1)

        raise WorkflowError(
            "automation.apply_started",
            "The warning page remained visible after three verified keyboard attempts",
            details=last_context or {"vm": vm.name, "target": vm.vnc},
        )

    def _close_windows_interference(
        self,
        vm: VMConfig,
        *,
        kind: Literal["settings", "security"],
        step: str,
        result: ResultBuilder,
    ) -> None:
        with self.validation.ssh(
            vm.host,
            vm.username,
            self.settings.windows_ssh_password.get_secret_value(),
            remote_os="windows",
        ) as ssh:
            response = self.validation.run_windows_script(
                ssh,
                script_name="close_windows_interference.ps1",
                config={"kind": kind},
                step=step,
                timeout=30,
            )
        values = self.validation.parse_powershell_results(
            response.stdout,
            prefixes=(
                "INTERFERENCE_CLOSED",
                "INTERFERENCE_KIND",
                "CLOSED_PROCESS_COUNT",
                "LIBERTIX_PROCESS_COUNT",
            ),
        )
        if (
            values.get("INTERFERENCE_CLOSED") != "True"
            or values.get("INTERFERENCE_KIND") != kind
            or int(values.get("LIBERTIX_PROCESS_COUNT", "0")) < 1
        ):
            raise WorkflowError(
                step,
                "Windows interference was not closed safely",
                details={"vm": vm.name, "target": vm.host, "kind": kind},
            )
        closed_process_count = int(values.get("CLOSED_PROCESS_COUNT", "0"))
        if closed_process_count > 0:
            time.sleep(3)
            result.ok(
                step,
                "Windows interference closed by verified process identity",
                target=vm.vnc,
                vm=vm.name,
                kind=kind,
                closed_process_count=closed_process_count,
                libertix_process_count=int(values["LIBERTIX_PROCESS_COUNT"]),
            )
            return True

        # Vision can classify a transient toast as Settings because both use
        # the Windows shell style. Never click through the bottom-right overlay.
        time.sleep(10)
        result.ok(
            "automation.wait_windows_overlay",
            "No matching window process existed; waited for the transient overlay to expire",
            target=vm.vnc,
            vm=vm.name,
            kind=kind,
            libertix_process_count=int(values["LIBERTIX_PROCESS_COUNT"]),
        )
        return False

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

    @staticmethod
    def _press_key(client: object, key: str, delay: float = 0.2) -> None:
        client.keyPress(key)
        time.sleep(delay)

    @staticmethod
    def _press_chord(client: object, modifier: str, key: str, delay: float = 0.2) -> None:
        modifier_is_down = False
        try:
            client.keyDown(modifier)
            modifier_is_down = True
            time.sleep(0.05)
            client.keyPress(key)
            time.sleep(0.05)
        finally:
            if modifier_is_down:
                client.keyUp(modifier)
        time.sleep(delay)

    def _select_distribution_with_keyboard(self, client: object, catalog_index: int) -> None:
        self._press_chord(client, "ctrl", "home")
        for _ in range(catalog_index):
            self._press_chord(client, "ctrl", "right")
        self._press_key(client, "enter", 1.0)

    def _configure_sharing_with_keyboard(
        self,
        client: object,
        *,
        share_windows_files_in_linux: bool,
        share_linux_files_in_windows: bool,
    ) -> None:
        self._press_chord(client, "ctrl", "home")
        if not share_windows_files_in_linux:
            self._press_key(client, "space")
        self._press_key(client, "tab")
        if not share_linux_files_in_windows:
            self._press_key(client, "space")
        self._press_key(client, "enter", 1.0)

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

    def _replace_focused_field(self, client: object, vm: VMConfig, text: str) -> None:
        self._select_all(client)
        time.sleep(0.15)
        self._type_text(client, text, vm.vnc_keyboard_layout)
        time.sleep(0.35)

    def _fill_account_fields(
        self,
        client: object,
        vm: VMConfig,
        *,
        username: str,
        password: str,
    ) -> None:
        self._press_chord(client, "ctrl", "home")
        self._replace_focused_field(client, vm, username)
        self._press_key(client, "tab")
        self._replace_focused_field(client, vm, password)
        self._press_key(client, "tab")
        self._replace_focused_field(client, vm, password)
        # WPF can recreate the first PasswordBox when its initial validation
        # error clears. A second selected write makes both password controls
        # deterministic without relying on clipboard or OCR.
        self._press_chord(client, "shift", "tab")
        self._replace_focused_field(client, vm, password)
        self._press_key(client, "tab")
        self._replace_focused_field(client, vm, password)

    def _fill_and_confirm_account_fields(
        self,
        client: object,
        vm: VMConfig,
        *,
        username: str,
        password: str,
        result: ResultBuilder,
    ) -> None:
        for attempt in range(1, 4):
            self._fill_account_fields(
                client,
                vm,
                username=username,
                password=password,
            )
            time.sleep(0.5)
            capture, latest_capture = self._capture_wizard_pair(
                client,
                vm,
                f"04-account-filled-{attempt:02d}",
                result,
            )
            try:
                self._assert_wizard_state(
                    capture,
                    vm,
                    latest_capture=latest_capture,
                    expected_screen="account",
                    expected_username=username,
                    result=result,
                )
                return
            except WorkflowError as exc:
                if exc.details.get("detected_screen") != "account" or attempt == 3:
                    raise
                time.sleep(1)

        raise AssertionError("Account-field confirmation loop ended unexpectedly")

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
