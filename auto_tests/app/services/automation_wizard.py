"""Deterministic unattended interaction with the Libertix wizard."""

from __future__ import annotations

import base64
import logging
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Literal

from app.clients.ssh import CommandResult, SSHClient, is_reconnectable_transport_error
from app.config import VMConfig
from app.errors import WorkflowError
from app.services.automation_types import (
    AutomationOptions,
)
from app.services.common import ResultBuilder
from tools.azerty_qwerty import azerty_to_qwerty

logger = logging.getLogger(__name__)

UNATTENDED_WARNING_DIALOG_MAX_ATTEMPTS = 3
UNATTENDED_CONTROL_SSH_MAX_ATTEMPTS = 12


class WizardAutomationMixin:
    """Observe unattended stages and perform the single visible warning acknowledgement."""

    def _run_unattended_wizard(
        self,
        vm: VMConfig,
        options: AutomationOptions,
        result: ResultBuilder,
        launch: dict[str, object],
    ) -> Literal["boot-menu", "linux-desktop"]:
        unattended_status_path = launch.get("unattended_status_path")
        unattended_acknowledgement_path = launch.get("unattended_acknowledgement_path")
        if not unattended_status_path or not unattended_acknowledgement_path:
            raise WorkflowError(
                "automation.unattended_protocol",
                "Installation automation requires the deterministic unattended stage protocol",
                details={"vm": vm.name, "target": vm.host},
            )
        self._observe_unattended_wizard(
            vm,
            result,
            int(launch["pid"]),
            str(unattended_status_path),
            str(unattended_acknowledgement_path),
        )
        return self._monitor_until_live_boot(
            vm,
            result,
            vm.firmware,
            options.distribution,
            reboot_requested=True,
        )

    def _observe_unattended_wizard(
        self,
        vm: VMConfig,
        result: ResultBuilder,
        process_id: int,
        status_path: str,
        acknowledgement_path: str,
    ) -> None:
        stages_before_warning = (
            "compatibility-running",
            "compatibility-passed",
            "configuration-distribution-applied",
            "configuration-disk-size-applied",
            "configuration-sharing-applied",
            "configuration-account-applied",
        )
        quoted_status = status_path.replace("'", "''")
        quoted_acknowledgement = acknowledgement_path.replace("'", "''")
        after_sequence = 0
        with self.validation.ssh(
            vm.host,
            vm.username,
            self.settings.windows_ssh_password.get_secret_value(),
            remote_os="windows",
        ) as ssh:
            for expected_stage in stages_before_warning:
                observed = self._wait_for_unattended_stage(
                    ssh,
                    vm,
                    quoted_status,
                    after_sequence,
                    (expected_stage,),
                )
                after_sequence = self._capture_and_acknowledge_unattended_stage(
                    ssh,
                    vm,
                    result,
                    quoted_acknowledgement,
                    observed,
                )

            warning_attempt = 0
            observed = self._wait_for_unattended_stage(
                ssh,
                vm,
                quoted_status,
                after_sequence,
                ("warning-ready",),
            )
            warning_client = None
            try:
                warning_client = self.vnc.connect(vm.vnc)
                while True:
                    warning_attempt += 1
                    if warning_attempt > UNATTENDED_WARNING_DIALOG_MAX_ATTEMPTS:
                        raise WorkflowError(
                            "automation.unattended_warning",
                            "The unattended warning dialog was not accepted after "
                            "three keyboard attempts",
                            details={"vm": vm.name, "target": vm.host, **observed},
                        )
                    capture = self._accept_unattended_warning_dialog(
                        ssh,
                        warning_client,
                        vm,
                        result,
                        process_id,
                        int(observed["sequence"]),
                        warning_attempt,
                    )
                    # Keep this VNC connection alive until the coordination files
                    # prove acceptance. Some VNC transports take long enough to
                    # disconnect that Libertix can otherwise expire first.
                    after_sequence = self._capture_and_acknowledge_unattended_stage(
                        ssh,
                        vm,
                        result,
                        quoted_acknowledgement,
                        observed,
                        capture=capture,
                    )

                    observed = self._wait_for_unattended_stage(
                        ssh,
                        vm,
                        quoted_status,
                        after_sequence,
                        ("warning-ready", "installation-started"),
                        timeout_seconds=15,
                    )
                    if observed["stage"] == "installation-started":
                        after_sequence = self._capture_and_acknowledge_unattended_stage(
                            ssh,
                            vm,
                            result,
                            quoted_acknowledgement,
                            observed,
                        )
                        break
            finally:
                if warning_client is not None:
                    try:
                        warning_client.disconnect()
                    except Exception:
                        logger.warning(
                            "VNC connection did not close cleanly",
                            extra={"step": "automation.vnc_close", "target": vm.vnc},
                        )

            observed = self._wait_for_unattended_stage(
                ssh,
                vm,
                quoted_status,
                after_sequence,
                ("reboot-ready",),
                timeout_seconds=self.settings.automation_monitor_timeout_seconds,
                observe_installation_progress=True,
                result=result,
            )
            self._capture_and_acknowledge_unattended_stage(
                ssh,
                vm,
                result,
                quoted_acknowledgement,
                observed,
            )

        self._request_reboot_after_preparation(vm, result)

    def _wait_for_unattended_stage(
        self,
        ssh: SSHClient,
        vm: VMConfig,
        quoted_status_path: str,
        after_sequence: int,
        accepted_stages: tuple[str, ...],
        *,
        timeout_seconds: float = 180,
        observe_installation_progress: bool = False,
        result: ResultBuilder | None = None,
    ) -> dict[str, object]:
        if observe_installation_progress and result is None:
            raise ValueError("A result builder is required while observing installation progress")

        deadline = time.monotonic() + timeout_seconds
        observed: dict[str, object] | None = None
        next_progress_observation = time.monotonic()
        progress_observation = 0
        vision_disabled = False
        while time.monotonic() < deadline:
            response = self._run_unattended_control_command(
                ssh,
                'powershell.exe -NoProfile -NonInteractive -Command "'
                f"$p='{quoted_status_path}'; "
                "if (Test-Path -LiteralPath $p -PathType Leaf) { "
                "$s=Get-Content -LiteralPath $p -Raw | ConvertFrom-Json; "
                "[Console]::Out.WriteLine(('SEQUENCE={0}' -f [int]$s.sequence)); "
                "[Console]::Out.WriteLine(('STAGE={0}' -f [string]$s.stage)); "
                "$m=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("
                "[string]$s.errorMessage)); "
                "[Console]::Out.WriteLine(('ERROR_CODE={0}' -f [string]$s.errorCode)); "
                "[Console]::Out.WriteLine(('ERROR_MESSAGE_BASE64={0}' -f $m)) }\"",
                step="automation.unattended_status",
                timeout=20,
                check=False,
            )
            values = self.validation.parse_powershell_results(
                response.stdout,
                prefixes=("SEQUENCE", "STAGE", "ERROR_CODE", "ERROR_MESSAGE_BASE64"),
            )
            sequence_text = values.get("SEQUENCE", "")
            if sequence_text.isdigit() and int(sequence_text) > after_sequence:
                observed = {
                    "sequence": int(sequence_text),
                    "stage": values.get("STAGE", ""),
                }
                if observed["stage"] == "failed":
                    encoded_message = values.get("ERROR_MESSAGE_BASE64", "")
                    try:
                        error_message = base64.b64decode(
                            encoded_message,
                            validate=True,
                        ).decode("utf-8")
                    except (ValueError, UnicodeDecodeError):
                        error_message = "Libertix reported an unreadable unattended failure."
                    raise WorkflowError(
                        "automation.unattended_failure",
                        error_message or "Libertix reported an unattended failure.",
                        details={
                            "vm": vm.name,
                            "target": vm.host,
                            "error_code": values.get("ERROR_CODE", "unattended-failure"),
                            **observed,
                        },
                    )
                break

            if observe_installation_progress and time.monotonic() >= next_progress_observation:
                progress_observation += 1
                capture = self._capture_with_name(
                    vm,
                    f"windows-preparation-progress-{progress_observation:03d}",
                )
                next_progress_observation = (
                    time.monotonic() + self.settings.automation_monitor_interval_seconds
                )
                if vision_disabled:
                    result.ok(
                        "automation.windows_preparation_without_vision",
                        "Windows preparation remains under deterministic stage observation",
                        vm=vm.name,
                        target=vm.vnc,
                        capture=str(capture),
                    )
                    continue
                try:
                    verdict = self.vision_llm.analyze_install_progress(
                        capture,
                        vm.name,
                        vm.os,
                    )
                except WorkflowError as exc:
                    http_status = exc.details.get("http_status")
                    if http_status in (401, 402, 403):
                        vision_disabled = True
                    result.ok(
                        "automation.windows_preparation_vision_unavailable",
                        "Windows preparation vision is unavailable; "
                        "deterministic stage observation continues",
                        vm=vm.name,
                        target=vm.vnc,
                        capture=str(capture),
                        http_status=http_status,
                        vision_disabled=vision_disabled,
                    )
                    continue

                context = {
                    "vm": vm.name,
                    "target": vm.vnc,
                    "capture": str(capture),
                    **verdict.model_dump(),
                }
                result.ok(
                    "automation.windows_preparation_progress",
                    "Windows preparation progress bar analyzed by the LLM",
                    **context,
                )
                rollback_text = f"{verdict.visible_text}\n{verdict.summary}"
                rollback_outcome = self._rollback_terminal_outcome(rollback_text)
                if rollback_outcome is not None:
                    context["rollback_outcome"] = rollback_outcome
                    raise WorkflowError(
                        "automation.windows_preparation_progress",
                        "Windows preparation ended after rollback",
                        details=context,
                    )
                if verdict.error_visible or verdict.blocking_problem_visible:
                    raise WorkflowError(
                        "automation.windows_preparation_progress",
                        "Visible error during Windows installation preparation",
                        details=context,
                    )
            time.sleep(0.2)

        expected_stage = " or ".join(accepted_stages)
        if observed is None:
            raise WorkflowError(
                "automation.unattended_status",
                "Timed out waiting for the next unattended wizard stage",
                details={
                    "vm": vm.name,
                    "target": vm.host,
                    "expected_stage": expected_stage,
                    "after_sequence": after_sequence,
                },
            )
        if observed["stage"] not in accepted_stages:
            raise WorkflowError(
                "automation.unattended_status",
                "The unattended wizard reported an unexpected stage",
                details={
                    "vm": vm.name,
                    "target": vm.host,
                    "expected_stage": expected_stage,
                    **observed,
                },
            )
        return observed

    def _capture_and_acknowledge_unattended_stage(
        self,
        ssh: SSHClient,
        vm: VMConfig,
        result: ResultBuilder,
        quoted_acknowledgement_path: str,
        observed: dict[str, object],
        *,
        capture: Path | None = None,
    ) -> int:
        sequence = int(observed["sequence"])
        stage = str(observed["stage"])
        capture = capture or self._capture_with_name(
            vm,
            f"wizard-{sequence:02d}-{stage}",
        )
        acknowledgement = self._run_unattended_control_command(
            ssh,
            'powershell.exe -NoProfile -NonInteractive -Command "'
            f"$p='{quoted_acknowledgement_path}'; "
            "$deadline=[DateTime]::UtcNow.AddSeconds(5); "
            "while ($true) { try { "
            f"[IO.File]::WriteAllText($p, '{sequence}', [Text.Encoding]::ASCII); "
            "break } catch [IO.IOException] { "
            "if ([DateTime]::UtcNow -ge $deadline) { throw }; "
            'Start-Sleep -Milliseconds 50 } }"',
            step="automation.unattended_acknowledgement",
            timeout=20,
        )
        result.ok(
            "automation.unattended_stage",
            f"Unattended wizard stage captured and acknowledged: {stage}",
            vm=vm.name,
            target=vm.vnc,
            stage=stage,
            sequence=sequence,
            capture=str(capture),
            acknowledgement_exit_code=acknowledgement.exit_code,
        )
        return sequence

    @staticmethod
    def _run_unattended_control_command(
        ssh: SSHClient,
        command: str,
        *,
        step: str,
        timeout: float,
        check: bool = True,
    ) -> CommandResult:
        """Retry only idempotent unattended coordination after a dead transport."""

        last_error: WorkflowError | None = None
        for attempt in range(1, UNATTENDED_CONTROL_SSH_MAX_ATTEMPTS + 1):
            try:
                if attempt > 1:
                    ssh.reconnect()
                return ssh.run(
                    command,
                    step=step,
                    timeout=timeout,
                    check=check,
                )
            except WorkflowError as exc:
                last_error = exc
                if (
                    not is_reconnectable_transport_error(exc)
                    or attempt == UNATTENDED_CONTROL_SSH_MAX_ATTEMPTS
                ):
                    raise
        assert last_error is not None
        raise last_error

    def _accept_unattended_warning_dialog(
        self,
        ssh: SSHClient,
        client: object,
        vm: VMConfig,
        result: ResultBuilder,
        process_id: int,
        sequence: int,
        attempt: int,
    ) -> Path:
        try:
            focus = self.validation.run_windows_script(
                ssh,
                script_name="focus_unattended_warning.ps1",
                config={"process_id": process_id},
                step="automation.unattended_warning_focus",
                timeout=20,
            )
            capture = self._capture_from_client(
                client,
                vm,
                f"wizard-{sequence:02d}-warning-ready-keyboard-{attempt}",
                result,
            )
            result.ok(
                "automation.unattended_warning_focus",
                "Libertix unattended warning received keyboard focus",
                vm=vm.name,
                target=vm.host,
                process_id=process_id,
                focus_exit_code=focus.exit_code,
                stdout=focus.stdout,
            )
            self._press_key(client, "tab", 0.25)
            self._press_key(client, "enter", 0.5)
            return capture
        except WorkflowError:
            raise
        except Exception as exc:
            raise WorkflowError(
                "automation.unattended_warning",
                "The unattended warning dialog keyboard action failed",
                details={
                    "vm": vm.name,
                    "target": vm.vnc,
                    "attempt": attempt,
                    "error": str(exc),
                },
            ) from exc

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
    def _type_text(client: object, text: str, keyboard_layout: str = "us") -> None:
        # Send keys one by one. Clipboard paste is not reliable across the VNC
        # stack and can silently fail on login/password fields.
        # Proxmox VNC sends US physical key positions. Pre-translating text for
        # a French guest session makes the characters produced by AZERTY
        # match the caller's logical value, including masked password fields.
        wire_text = azerty_to_qwerty(text) if keyboard_layout == "fr" else text
        for char in wire_text:
            # vncdotool treats a literal hyphen as a chord separator. Its
            # documented "minus" key name emits the actual punctuation key.
            client.keyPress("minus" if char == "-" else char)
            time.sleep(0.12)
