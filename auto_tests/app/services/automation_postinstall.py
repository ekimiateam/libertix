"""Post-install validation of the installed Linux and Windows systems."""

from __future__ import annotations

import json
import shlex
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from PIL import Image

from app.clients.ssh import CommandResult, SSHClient, is_reconnectable_transport_error
from app.config import VMConfig
from app.distributions import DistributionProfile
from app.errors import WorkflowError
from app.services.automation_types import AutomationOptions
from app.services.automation_windows_checks import (
    CrossOsArtifacts,
    build_windows_validation_plan,
    windows_validation_timeout_seconds,
)
from app.services.common import ResultBuilder

EXPECTED_GRUB_ROOT_ENTRY_COUNT = 4
REMOTE_CHECK_SSH_MAX_ATTEMPTS = 6
LINUX_SCRIPT_RECONNECT_DELAY_SECONDS = 3


@dataclass(frozen=True)
class RemoteCheck:
    name: str
    command: str
    timeout: float = 120
    sensitive: bool = False
    requires_sudo: bool = False


class PostInstallValidationMixin:
    """Validate both installed operating systems after the installer exits."""

    def _run_linux_command_resiliently(
        self,
        ssh: SSHClient,
        *,
        command: str,
        step: str,
        timeout: float,
    ) -> CommandResult:
        """Retry an idempotent Linux command after a proven transport failure."""

        last_error: WorkflowError | None = None
        for attempt in range(1, REMOTE_CHECK_SSH_MAX_ATTEMPTS + 1):
            try:
                if attempt > 1:
                    ssh.reconnect()
                return ssh.run(command, step=step, timeout=timeout)
            except WorkflowError as exc:
                last_error = exc
                if (
                    not is_reconnectable_transport_error(exc)
                    or attempt == REMOTE_CHECK_SSH_MAX_ATTEMPTS
                ):
                    raise

        assert last_error is not None
        raise last_error

    def _run_linux_script_resiliently(
        self,
        ssh: SSHClient,
        *,
        script_name: str,
        arguments: tuple[str, ...],
        step: str,
        timeout: float,
    ) -> CommandResult:
        """Upload and run a Linux helper again after a proven transport failure."""

        last_error: WorkflowError | None = None
        for attempt in range(1, REMOTE_CHECK_SSH_MAX_ATTEMPTS + 1):
            try:
                if attempt > 1:
                    ssh.reconnect()
                return self.validation.run_linux_script(
                    ssh,
                    script_name=script_name,
                    arguments=arguments,
                    step=step,
                    timeout=timeout,
                )
            except WorkflowError as exc:
                last_error = exc
                if (
                    not is_reconnectable_transport_error(exc)
                    or attempt == REMOTE_CHECK_SSH_MAX_ATTEMPTS
                ):
                    raise
                time.sleep(LINUX_SCRIPT_RECONNECT_DELAY_SECONDS)

        assert last_error is not None
        raise last_error

    def _run_windows_script_resiliently(
        self,
        ssh: SSHClient,
        *,
        script_name: str,
        config: dict[str, object],
        step: str,
        timeout: float,
    ) -> CommandResult:
        """Run a Windows helper again only after a proven transport failure."""

        last_error: WorkflowError | None = None
        for attempt in range(1, REMOTE_CHECK_SSH_MAX_ATTEMPTS + 1):
            try:
                if attempt > 1:
                    ssh.reconnect()
                return self.validation.run_windows_script(
                    ssh,
                    script_name=script_name,
                    config=config,
                    step=step,
                    timeout=timeout,
                )
            except WorkflowError as exc:
                last_error = exc
                if (
                    not is_reconnectable_transport_error(exc)
                    or attempt == REMOTE_CHECK_SSH_MAX_ATTEMPTS
                ):
                    raise

        assert last_error is not None
        raise last_error

    def _run_post_install_validation(
        self,
        vm: VMConfig,
        options: AutomationOptions,
        result: ResultBuilder,
        monitor_outcome: str,
    ) -> None:
        if monitor_outcome != "boot-menu":
            raise WorkflowError(
                "automation.windows_before_linux",
                "The installed GRUB menu was not captured before Linux first boot",
                details={"vm": vm.name, "monitor_outcome": monitor_outcome},
            )

        result.ok(
            "automation.post_install_phase",
            f"The requested first installed-system boot is {options.first_boot}",
            vm=vm.name,
            target=vm.host,
            phase=f"first-boot-{options.first_boot}",
        )
        if options.first_boot == "windows":
            result.ok(
                "automation.post_install_phase",
                "Waiting for Windows before the first installed Linux boot",
                vm=vm.name,
                target=vm.host,
                phase="windows-before-linux-ssh",
            )
            waiting_windows_ssh = self._wait_for_ssh(
                vm,
                result=result,
                username=vm.username,
                password=self.settings.windows_ssh_password.get_secret_value(),
                trust_on_first_use=False,
                probe="cmd.exe /d /c echo LIBERTIX_WINDOWS_READY",
                expected="LIBERTIX_WINDOWS_READY",
                phase="windows_before_linux",
                grub_entry="windows",
                distribution=options.distribution,
            )
            try:
                response = self._run_windows_script_resiliently(
                    waiting_windows_ssh,
                    script_name="post_install_windows_check.ps1",
                    config={
                        "check": "waiting_for_linux",
                        "expected_firmware": vm.firmware,
                    },
                    step="automation.test.windows",
                    timeout=240,
                )
                result.ok(
                    "automation.test.windows",
                    "windows.waiting_for_linux: OK",
                    vm=vm.name,
                    target=vm.host,
                    test="windows.waiting_for_linux",
                    exit_code=response.exit_code,
                    stdout=response.stdout,
                    stderr=response.stderr,
                )
                self._request_linux_boot_from_windows(waiting_windows_ssh, vm, result)
            finally:
                waiting_windows_ssh.__exit__(None, None, None)

        result.ok(
            "automation.post_install_phase",
            "Waiting for the first installed Linux SSH boot",
            vm=vm.name,
            target=vm.host,
            phase="linux-first-ssh",
        )
        linux_ssh = self._wait_for_ssh(
            vm,
            result=result,
            username=options.linux_username,
            password=options.linux_password,
            trust_on_first_use=True,
            probe=(
                "test -e /var/lib/libertix/development-ssh-ready && printf LIBERTIX_LINUX_READY"
            ),
            expected="LIBERTIX_LINUX_READY",
            phase="linux_first",
            grub_entry="linux",
            distribution=options.distribution,
        )
        try:
            result.ok(
                "automation.test.linux",
                "Linux SSH authentication succeeded",
                vm=vm.name,
                target=vm.host,
                test="linux.ssh",
                server_key_sha256=linux_ssh.server_key_sha256,
            )
            self._wait_for_first_boot_verification(linux_ssh, vm, result)
            self._prepare_linux_graphical_session(
                linux_ssh,
                vm,
                result,
                options.linux_username,
                options.linux_password,
            )
            self._run_remote_check(
                linux_ssh,
                vm,
                result,
                "linux",
                RemoteCheck(
                    "linux.post_install_result_ui",
                    'i=0; while [ "$i" -lt 60 ]; do '
                    "pgrep -af '/usr/local/lib/libertix/[l]ibertix-first-boot-result.py' "
                    ">/dev/null && exit 0; "
                    "i=$((i + 1)); sleep 1; done; exit 1",
                    timeout=75,
                ),
            )
            self._capture_and_dismiss_post_install_result(
                vm,
                result,
                "linux",
                linux_ssh,
            )
            self._run_linux_checks(linux_ssh, vm, options, result)
            artifacts = self._create_cross_os_artifacts(linux_ssh, vm, options, result)
            self._request_windows_boot(linux_ssh, vm, options, result)
        finally:
            linux_ssh.__exit__(None, None, None)

        result.ok(
            "automation.post_install_phase",
            "Waiting for Windows SSH",
            vm=vm.name,
            target=vm.host,
            phase="windows-ssh",
        )
        windows_ssh = self._wait_for_ssh(
            vm,
            result=result,
            username=vm.username,
            password=self.settings.windows_ssh_password.get_secret_value(),
            trust_on_first_use=False,
            probe="cmd.exe /d /c echo LIBERTIX_WINDOWS_READY",
            expected="LIBERTIX_WINDOWS_READY",
            phase="windows",
            grub_entry="windows",
            distribution=options.distribution,
        )
        try:
            result.ok(
                "automation.test.windows",
                "Windows SSH authentication succeeded",
                vm=vm.name,
                target=vm.host,
                test="windows.ssh",
                server_key_sha256=windows_ssh.server_key_sha256,
            )
            self._prepare_windows_graphical_session(windows_ssh, vm, result)
            try:
                self._run_windows_checks(windows_ssh, vm, options, artifacts, result)
                self._capture_and_dismiss_post_install_result(
                    vm,
                    result,
                    "windows",
                    windows_ssh,
                )
            finally:
                self._cleanup_windows_cross_os_artifact(windows_ssh, vm, options, artifacts, result)
            self._request_linux_boot_from_windows(windows_ssh, vm, result)
        finally:
            windows_ssh.__exit__(None, None, None)

        result.ok(
            "automation.post_install_phase",
            "Waiting for Linux SSH after the Windows boot cycle",
            vm=vm.name,
            target=vm.host,
            phase="linux-return-ssh",
        )
        returned_linux_ssh = self._wait_for_ssh(
            vm,
            result=result,
            username=options.linux_username,
            password=options.linux_password,
            trust_on_first_use=True,
            probe="test -e /var/lib/libertix/development-ssh-ready && printf LIBERTIX_LINUX_READY",
            expected="LIBERTIX_LINUX_READY",
            phase="linux_return",
            grub_entry="linux",
            distribution=options.distribution,
        )
        try:
            try:
                firmware_test = (
                    "test -d /sys/firmware/efi"
                    if vm.firmware == "uefi"
                    else "test ! -d /sys/firmware/efi"
                )
                self._run_remote_check(
                    returned_linux_ssh,
                    vm,
                    result,
                    "linux",
                    RemoteCheck(
                        "linux.return_after_windows",
                        f"{firmware_test}; test -s /boot/grub/grub.cfg; "
                        "grub-script-check /boot/grub/grub.cfg; "
                        'test "$(findmnt -n -o FSTYPE /)" = ext4',
                        requires_sudo=True,
                    ),
                    sudo_password=options.linux_password,
                )
            finally:
                self._cleanup_linux_cross_os_artifact(
                    returned_linux_ssh, vm, options, artifacts, result
                )
            self._request_windows_boot(
                returned_linux_ssh,
                vm,
                options,
                result,
                test_name="linux.final_windows_reboot",
            )
        finally:
            returned_linux_ssh.__exit__(None, None, None)

        result.ok(
            "automation.post_install_phase",
            "Waiting for the final Windows SSH state",
            vm=vm.name,
            target=vm.host,
            phase="windows-final-ssh",
        )
        final_windows_ssh = self._wait_for_ssh(
            vm,
            result=result,
            username=vm.username,
            password=self.settings.windows_ssh_password.get_secret_value(),
            trust_on_first_use=False,
            probe="cmd.exe /d /c echo LIBERTIX_WINDOWS_READY",
            expected="LIBERTIX_WINDOWS_READY",
            phase="windows_final",
            grub_entry="windows",
            distribution=options.distribution,
        )
        try:
            try:
                response = self._run_windows_script_resiliently(
                    final_windows_ssh,
                    script_name="post_install_windows_check.ps1",
                    config={
                        "check": "final_state",
                        "expected_firmware": vm.firmware,
                        "expected_ipv4": vm.host,
                        "installer_iso_file_name": options.distribution.installer_iso_file_name,
                    },
                    step="automation.test.windows",
                    timeout=300,
                )
                result.ok(
                    "automation.test.windows",
                    "windows.final_state: OK",
                    vm=vm.name,
                    target=vm.host,
                    test="windows.final_state",
                    server_key_sha256=final_windows_ssh.server_key_sha256,
                    exit_code=response.exit_code,
                    stdout=response.stdout,
                    stderr=response.stderr,
                )
            except WorkflowError as exc:
                result.error(
                    "automation.test.windows",
                    "windows.final_state: FAILED",
                    vm=vm.name,
                    target=vm.host,
                    test="windows.final_state",
                    **exc.details,
                )
        finally:
            final_windows_ssh.__exit__(None, None, None)

    def _wait_for_first_boot_verification(
        self,
        ssh: SSHClient,
        vm: VMConfig,
        result: ResultBuilder,
    ) -> None:
        state_path = "/var/lib/libertix/first-boot-verification.json"
        log_path = "/var/log/libertix/first-boot-resize.log"
        command = (
            'i=0; status=""; while [ "$i" -lt 120 ]; do '
            "status=$(python3 -c 'import json,sys; "
            'print(json.load(open(sys.argv[1], encoding="utf-8")).get("status", ""))\' '
            f"{shlex.quote(state_path)} 2>/dev/null || true); "
            'case "$status" in succeeded|failed) break;; esac; '
            "i=$((i + 1)); sleep 2; done; "
            "python3 -c 'import json,sys; "
            'p=json.load(open(sys.argv[1], encoding="utf-8")); '
            'failed=[{"name": c.get("name"), "message": c.get("message")} '
            'for c in p.get("checks", []) if not c.get("passed")]; '
            'print(json.dumps({"status": p.get("status"), "error": p.get("error"), '
            '"failedChecks": failed}, ensure_ascii=True)); '
            'raise SystemExit(0 if p.get("status") == "succeeded" else 1)\' '
            f"{shlex.quote(state_path)}"
        )
        response = ssh.run(
            f"sh -eu -c {shlex.quote(command)}",
            step="automation.test.linux",
            timeout=270,
            check=False,
        )
        try:
            payload = json.loads(response.stdout.strip())
        except (json.JSONDecodeError, TypeError) as exc:
            raise WorkflowError(
                "automation.test.linux",
                "Linux first-boot verification returned an unreadable terminal state",
                details={
                    "vm": vm.name,
                    "target": vm.host,
                    "test": "linux.first_boot_verification_ready",
                    "exit_code": response.exit_code,
                    "state_path": state_path,
                    "log_path": log_path,
                },
            ) from exc

        status = str(payload.get("status") or "unknown")
        error = str(payload.get("error") or "").strip()
        failed_checks = payload.get("failedChecks")
        context = {
            "vm": vm.name,
            "target": vm.host,
            "test": "linux.first_boot_verification_ready",
            "exit_code": response.exit_code,
            "status": status,
            "error": error,
            "failed_checks": failed_checks if isinstance(failed_checks, list) else [],
            "state_path": state_path,
            "log_path": log_path,
        }
        if response.exit_code != 0 or status != "succeeded":
            reason = error or f"terminal status is {status}"
            raise WorkflowError(
                "automation.test.linux",
                f"Linux first-boot verification failed: {reason}",
                details=context,
            )
        result.ok(
            "automation.test.linux",
            "linux.first_boot_verification_ready: OK",
            **context,
        )

    def _capture_and_dismiss_post_install_result(
        self,
        vm: VMConfig,
        result: ResultBuilder,
        platform: Literal["linux", "windows"],
        guest_ssh: SSHClient,
    ) -> None:
        if platform == "linux":
            process = self._run_linux_command_resiliently(
                guest_ssh,
                command=("pgrep -fo '/usr/local/lib/libertix/[l]ibertix-first-boot-result.py'"),
                step="automation.linux_post_install_result_process",
                timeout=15,
            )
            process_id = process.stdout.strip()
            if not process_id.isdigit() or int(process_id) <= 0:
                raise WorkflowError(
                    "automation.linux_post_install_result_process",
                    "The Linux post-install result process ID is invalid",
                    details={"vm": vm.name, "target": vm.host},
                )
            focus = self._run_linux_script_resiliently(
                guest_ssh,
                script_name="focus_linux_post_install_result.py",
                arguments=("--pid", process_id, "--timeout", "15"),
                step="automation.linux_post_install_result_focused",
                timeout=30,
            )
            values = self.validation.parse_powershell_results(
                focus.stdout,
                prefixes=("PROCESS_ID", "WINDOW_ID", "ACTIVE_WINDOW_PROVEN", "RESULT"),
            )
            if (
                values.get("PROCESS_ID") != process_id
                or values.get("ACTIVE_WINDOW_PROVEN") != "True"
                or values.get("RESULT") != "OK"
            ):
                raise WorkflowError(
                    "automation.linux_post_install_result_focused",
                    "The Linux post-install result window was not proven active",
                    details={"vm": vm.name, "target": vm.host, **values},
                )
        else:
            visibility = self._run_windows_script_resiliently(
                guest_ssh,
                script_name="post_install_windows_check.ps1",
                config={
                    "check": "post_install_result_ui",
                    "expected_firmware": vm.firmware,
                },
                step="automation.windows_post_install_result_visible",
                timeout=150,
            )
            values = self.validation.parse_powershell_results(
                visibility.stdout,
                prefixes=("POST_INSTALL_RESULT_UI_PROCESS_ID",),
            )
            process_id_text = values.get("POST_INSTALL_RESULT_UI_PROCESS_ID", "")
            if not process_id_text.isdigit() or int(process_id_text) <= 0:
                raise WorkflowError(
                    "automation.windows_post_install_result_visible",
                    "The Windows post-install result process ID is missing",
                    details={"vm": vm.name, "target": vm.host},
                )
            self._run_windows_script_resiliently(
                guest_ssh,
                script_name="focus_post_install_result.ps1",
                config={"process_id": int(process_id_text)},
                step="automation.windows_post_install_result_focused",
                timeout=60,
            )
        capture = self._capture_with_name(vm, f"post-install-{platform}-success")
        client = None
        try:
            client = self.vnc.connect(vm.vnc)
            client.keyPress("enter")
        finally:
            if client is not None:
                client.disconnect()
        if platform == "linux":
            dismissal = self._run_linux_command_resiliently(
                guest_ssh,
                command=(
                    'i=0; while [ "$i" -lt 30 ]; do '
                    "if ! pgrep -af '/usr/local/lib/libertix/[l]ibertix-first-boot-result.py' "
                    ">/dev/null && "
                    "python3 -c 'import json,pathlib; "
                    'p=pathlib.Path.home()/".local/state/libertix/first-boot-result-ack.json"; '
                    'v=json.loads(p.read_text(encoding="utf-8")); '
                    'assert v["schemaVersion"] == 1; assert len(v["fingerprint"]) == 64\' '
                    "; then exit 0; fi; i=$((i + 1)); sleep 1; done; exit 1"
                ),
                step="automation.linux_post_install_result_dismissed",
                timeout=45,
            )
        else:
            dismissal = self._run_windows_script_resiliently(
                guest_ssh,
                script_name="post_install_windows_check.ps1",
                config={
                    "check": "post_install_result_ui_dismissed",
                    "expected_firmware": vm.firmware,
                },
                step="automation.windows_post_install_result_dismissed",
                timeout=60,
            )
        result.ok(
            "automation.post_install_result_ui",
            f"{platform.capitalize()} post-install result captured after guest-side proof",
            vm=vm.name,
            target=vm.vnc,
            platform=platform,
            capture=str(capture),
            proof_source="guest-state-process-and-dismissal",
            dismissal_exit_code=dismissal.exit_code,
        )

    def _prepare_linux_graphical_session(
        self,
        linux_ssh: SSHClient,
        vm: VMConfig,
        result: ResultBuilder,
        username: str,
        password: str,
    ) -> None:
        quoted_username = shlex.quote(username)
        graphical_session_probe = (
            "for sid in $(loginctl list-sessions --no-legend | "
            f"awk -v expected={quoted_username} '$3 == expected {{print $1}}'); do "
            'type=$(loginctl show-session "$sid" -p Type --value); '
            'active=$(loginctl show-session "$sid" -p Active --value); '
            'case "$type:$active" in x11:yes|wayland:yes) '
            "printf LIBERTIX_DESKTOP_READY; exit 0;; esac; done; "
            "for sid in $(loginctl list-sessions --no-legend | awk '{print $1}'); do "
            'class=$(loginctl show-session "$sid" -p Class --value); '
            'type=$(loginctl show-session "$sid" -p Type --value); '
            'active=$(loginctl show-session "$sid" -p Active --value); '
            'case "$class:$type:$active" in greeter:x11:yes|greeter:wayland:yes) '
            "printf LIBERTIX_GREETER_READY; exit 0;; esac; done; exit 1"
        )
        for attempt in range(1, 4):
            response = linux_ssh.run(
                graphical_session_probe,
                step="automation.linux_graphical_session",
                timeout=30,
                check=False,
            )
            if response.exit_code == 0 and "LIBERTIX_DESKTOP_READY" in response.stdout:
                capture = self._capture_with_name(
                    vm,
                    f"post-install-linux-session-ready-{attempt:02d}",
                )
                result.ok(
                    "automation.linux_graphical_session",
                    "The active Linux graphical session was proven by loginctl",
                    vm=vm.name,
                    target=vm.vnc,
                    attempt=attempt,
                    capture=str(capture),
                )
                return

            if "LIBERTIX_GREETER_READY" not in response.stdout:
                result.ok(
                    "automation.linux_graphical_session_wait",
                    "No active Linux desktop or login greeter is proven yet",
                    vm=vm.name,
                    target=vm.vnc,
                    attempt=attempt,
                )
                time.sleep(10)
                continue

            client = None
            try:
                client = self.vnc.connect(vm.vnc)
                self._capture_from_client(
                    client,
                    vm,
                    f"post-install-linux-login-{attempt:02d}-ready",
                    result,
                )
                # LightDM already focuses the password entry for the selected
                # user. Pressing Enter here would submit the empty field and
                # discard the real password while authentication is pending.
                client.keyDown("ctrl")
                client.keyPress("q" if vm.vnc_keyboard_layout == "fr" else "a")
                client.keyUp("ctrl")
                client.keyPress("bsp")
                self._type_text(client, password, vm.vnc_keyboard_layout)
                self._capture_from_client(
                    client,
                    vm,
                    f"post-install-linux-login-{attempt:02d}-password-entered",
                    result,
                )
                client.keyPress("enter")
            finally:
                if client is not None:
                    client.disconnect()
            result.ok(
                "automation.linux_graphical_login",
                "Linux graphical credentials were submitted after loginctl found no active desktop",
                vm=vm.name,
                target=vm.vnc,
                attempt=attempt,
            )
            time.sleep(10)

        raise WorkflowError(
            "automation.linux_graphical_session",
            "The Linux graphical session did not become active after three attempts",
            details={"vm": vm.name, "target": vm.vnc},
        )

    def _prepare_windows_graphical_session(
        self,
        windows_ssh: SSHClient,
        vm: VMConfig,
        result: ResultBuilder,
    ) -> None:
        password = self.settings.windows_ssh_password.get_secret_value()
        for attempt in range(1, 4):
            inspection = self._run_windows_script_resiliently(
                windows_ssh,
                script_name="inspect_windows_graphical_session.ps1",
                config={},
                step="automation.windows_graphical_session",
                timeout=60,
            )
            values = self.validation.parse_powershell_results(
                inspection.stdout,
                prefixes=(
                    "EXPLORER_SESSION_READY",
                    "SETUP_EXPERIENCE_PRESENT",
                    "LOGIN_SCREEN_PRESENT",
                    "SESSION_ID",
                ),
            )
            capture = self._capture_with_name(vm, f"post-install-windows-login-{attempt:02d}")
            context = {
                "vm": vm.name,
                "target": vm.vnc,
                "capture": str(capture),
                "attempt": attempt,
                "session_id": values.get("SESSION_ID", "-1"),
            }
            if values.get("SETUP_EXPERIENCE_PRESENT") == "True":
                response = self._run_windows_script_resiliently(
                    windows_ssh,
                    script_name="dismiss_windows_setup_experience.ps1",
                    config={},
                    step="automation.windows_setup_experience",
                    timeout=60,
                )
                values = self.validation.parse_powershell_results(
                    response.stdout,
                    prefixes=(
                        "WINDOWS_SETUP_EXPERIENCE_DISMISSED",
                        "TERMINATED_PROCESS_COUNT",
                    ),
                )
                if values.get("WINDOWS_SETUP_EXPERIENCE_DISMISSED") != "True":
                    raise WorkflowError(
                        "automation.windows_setup_experience",
                        "The identified Windows setup experience was not dismissed",
                        details=context,
                    )
                result.ok(
                    "automation.windows_setup_experience",
                    "The identified Windows setup experience was dismissed",
                    terminated_process_count=int(values.get("TERMINATED_PROCESS_COUNT", "0")),
                    **context,
                )
                time.sleep(5)
                continue
            if values.get("EXPLORER_SESSION_READY") == "True":
                result.ok(
                    "automation.windows_graphical_session",
                    "Windows Explorer confirmed the interactive session",
                    **context,
                )
                return

            if values.get("LOGIN_SCREEN_PRESENT") != "True":
                result.ok(
                    "automation.windows_graphical_session_wait",
                    "Windows has not exposed an Explorer desktop or a proven login screen yet",
                    **context,
                )
                time.sleep(10)
                continue

            client = None
            try:
                client = self.vnc.connect(vm.vnc)
                client.keyPress("enter")
                time.sleep(1)
                self._type_text(client, password, vm.vnc_keyboard_layout)
                client.keyPress("enter")
            finally:
                if client is not None:
                    client.disconnect()
            result.ok(
                "automation.windows_graphical_login",
                "Windows credentials were submitted after LogonUI proved the login screen",
                **context,
            )
            time.sleep(10)
        raise WorkflowError(
            "automation.windows_graphical_session",
            "The Windows interactive session was not proven available",
            details={"vm": vm.name, "target": vm.vnc},
        )

    def _wait_for_ssh(
        self,
        vm: VMConfig,
        *,
        result: ResultBuilder,
        username: str,
        password: str,
        trust_on_first_use: bool,
        probe: str,
        expected: str,
        phase: str,
        grub_entry: Literal["linux", "windows"] | None = None,
        distribution: DistributionProfile | None = None,
    ) -> SSHClient:
        deadline = time.monotonic() + self.settings.post_install_boot_timeout_seconds
        last_error: WorkflowError | None = None
        attempt = 0
        if grub_entry is not None:
            self._select_grub_entry_when_theme_ready(
                vm,
                result,
                grub_entry,
                distribution=distribution,
            )
        while time.monotonic() < deadline:
            attempt += 1
            # A fresh local theme capture gates every retry. SSH remains the
            # authoritative proof that the requested operating system booted.
            if grub_entry is not None and attempt % 3 == 0:
                self._select_grub_entry_if_visible(
                    vm, result, grub_entry, attempt, distribution=distribution
                )
            client = SSHClient(
                vm.host,
                username,
                password,
                known_hosts_path=(
                    self._capture_dir / f"{vm.name}-linux-known-hosts"
                    if trust_on_first_use
                    else self.settings.ssh_known_hosts
                ),
                port=self.settings.ssh_port,
                connect_timeout=self.settings.ssh_timeout_seconds,
                trust_on_first_use=trust_on_first_use,
                remote_os="linux" if trust_on_first_use else "windows",
            )
            try:
                client.__enter__()
                response = client.run(
                    probe,
                    step=f"automation.{phase}_ssh_probe",
                    timeout=30,
                )
                if response.stdout.strip() == expected:
                    return client
            except WorkflowError as exc:
                last_error = exc
            client.__exit__(None, None, None)
            time.sleep(self.settings.post_install_poll_interval_seconds)

        details = {"vm": vm.name, "host": vm.host, "phase": phase}
        if last_error is not None:
            details["last_error"] = last_error.details
        raise WorkflowError(
            f"automation.{phase}_ssh_wait",
            f"Timed out waiting for {phase} SSH",
            details=details,
        )

    def _select_grub_entry_when_theme_ready(
        self,
        vm: VMConfig,
        result: ResultBuilder,
        entry: Literal["linux", "windows"],
        *,
        distribution: DistributionProfile | None,
    ) -> bool:
        del distribution
        deadline = time.monotonic() + self.settings.post_install_grub_detection_timeout_seconds
        capture_attempt = 0
        while time.monotonic() < deadline:
            capture_attempt += 1
            capture = self._capture_with_name(
                vm,
                f"post-install-{entry}-grub-ready-{capture_attempt:03d}",
            )
            if self._installed_grub_theme_visible(capture):
                return self._send_grub_entry(vm, result, entry)
            time.sleep(self.settings.post_install_grub_detection_interval_seconds)

        return False

    @staticmethod
    def _installed_grub_theme_visible(capture: Path) -> bool:
        try:
            with Image.open(capture) as screenshot:
                sample = screenshot.convert("RGB").resize(
                    (160, 100),
                    Image.Resampling.NEAREST,
                )
        except (OSError, ValueError):
            return False

        flattened_data = getattr(sample, "get_flattened_data", None)
        pixels = tuple(flattened_data() if flattened_data is not None else sample.getdata())
        total = len(pixels)
        if total == 0:
            return False

        def matches(
            pixel: tuple[int, int, int], target: tuple[int, int, int], tolerance: int
        ) -> bool:
            return all(
                abs(channel - expected) <= tolerance
                for channel, expected in zip(pixel, target, strict=True)
            )

        background_pixels = sum(matches(pixel, (34, 33, 52), 3) for pixel in pixels)
        selected_item_pixels = sum(matches(pixel, (66, 66, 82), 5) for pixel in pixels)
        return background_pixels / total >= 0.70 and selected_item_pixels / total >= 0.005

    def _select_grub_entry_if_visible(
        self,
        vm: VMConfig,
        result: ResultBuilder,
        entry: Literal["linux", "windows"],
        attempt: int,
        distribution: DistributionProfile | None = None,
    ) -> bool:
        del distribution
        capture = self._capture_with_name(vm, f"post-install-{entry}-grub-{attempt:03d}")
        if not self._installed_grub_theme_visible(capture):
            return False

        return self._send_grub_entry(vm, result, entry)

    def _send_grub_entry(
        self,
        vm: VMConfig,
        result: ResultBuilder,
        entry: Literal["linux", "windows"],
    ) -> bool:
        client = None
        try:
            client = self.vnc.connect(vm.vnc)
            client.keyPress("home")
            time.sleep(0.05)
            if entry == "windows":
                client.keyPress("down")
                time.sleep(0.05)
            client.keyDown("enter")
            try:
                time.sleep(0.15)
            finally:
                client.keyUp("enter")
            # Keep the VNC transport alive long enough to flush the final key
            # event. SSH, not this write, remains the authoritative success
            # signal and the menu will be retried if it stays visible.
            time.sleep(0.25)
        except Exception as exc:
            raise WorkflowError(
                "automation.grub_selection",
                f"Unable to select {entry} from the installed GRUB menu",
                details={"vm": vm.name, "target": vm.vnc, "error": str(exc)},
            ) from exc
        finally:
            if client is not None:
                client.disconnect()

        result.ok(
            "automation.post_install_phase",
            f"Sent the {entry} selection from the installed GRUB menu",
            vm=vm.name,
            target=vm.vnc,
            phase=f"{entry}-boot",
        )
        return True

    def _run_linux_checks(
        self,
        ssh: SSHClient,
        vm: VMConfig,
        options: AutomationOptions,
        result: ResultBuilder,
    ) -> None:
        username = shlex.quote(options.linux_username)
        expected_os_release_id = shlex.quote(options.distribution.os_release_id)
        expected_grub_entry = shlex.quote(
            "menuentry '"
            + options.distribution.grub_display_name
            + "' --class "
            + options.distribution.grub_icon
            + " --class "
        )
        windows_grub_entry_pattern = shlex.quote("""menuentry ['\"]Windows( Boot Manager)?['\"]""")
        firmware_test = (
            "test -d /sys/firmware/efi" if vm.firmware == "uefi" else "test ! -d /sys/firmware/efi"
        )
        prefix_length = self.settings.development_static_ipv4_prefix_length
        gateway = self.settings.development_static_ipv4_gateway
        dns_servers = self.settings.development_dns_servers
        expected_ip = shlex.quote(f"{vm.host}/{prefix_length}")
        expected_profile = shlex.quote(f"address1={vm.host}/{prefix_length},{gateway}")
        expected_gateway = shlex.quote(f"default via {gateway}")
        dns_checks = "; ".join(
            f"resolvectl dns | grep -Fq -- {shlex.quote(server)}" for server in dns_servers
        )
        boot_mode_test = (
            "findmnt /boot/efi; "
            'test "$(findmnt -n -o FSTYPE /boot/efi)" = vfat; '
            "find /boot/efi/EFI -type f -iname '*.efi' -print -quit | grep -q ."
            if vm.firmware == "uefi"
            else "test -s /boot/grub/i386-pc/core.img"
        )
        windows_mount_test = (
            "findmnt /mnt/windows; findmnt -n -o FSTYPE /mnt/windows | "
            "grep -Eq '^(fuseblk|ntfs3)$'; "
            "findmnt -n -o OPTIONS /mnt/windows | grep -qw rw"
            if options.share_windows_files_in_linux
            else "! findmnt /mnt/windows; "
            "! grep -Eq '^[^#].*[[:space:]]+/mnt/windows[[:space:]]+' /etc/fstab"
        )
        sharing_policy_test = (
            ("grep -Fx true" if options.share_linux_files_in_windows else "grep -Fx false")
            + " /etc/libertix/share-linux-in-windows; "
            + (
                "grep -Eq '^UUID=.*[[:space:]]+/mnt/windows[[:space:]]+' /etc/fstab"
                if options.share_windows_files_in_linux
                else "! grep -Eq '^[^#].*[[:space:]]+/mnt/windows[[:space:]]+' /etc/fstab"
            )
        )
        grub_regeneration_test = (
            "for generator in 10_linux 30_uefi-firmware 20_memtest86+ 20_memtest86; do "
            "source=/etc/grub.d/$generator; "
            "diverted=/usr/local/lib/libertix/grub-generators/$generator; "
            'test "$(dpkg-divert --listpackage "$source")" = LOCAL; '
            'test "$(dpkg-divert --truename "$source")" = "$diverted"; '
            "done; "
            'test "$(dpkg-divert --listpackage /usr/sbin/update-grub)" = LOCAL; '
            'test "$(dpkg-divert --truename /usr/sbin/update-grub)" '
            "= /usr/local/lib/libertix/update-grub.distrib; "
            "test -x /usr/sbin/update-grub; "
            "test -x /usr/local/lib/libertix/update-grub.distrib; "
            "before=$(sha256sum /boot/grub/grub.cfg | cut -d' ' -f1); "
            "if LIBERTIX_GRUB_MKCONFIG=/bin/false update-grub; then exit 1; fi; "
            "after=$(sha256sum /boot/grub/grub.cfg | cut -d' ' -f1); "
            'test "$before" = "$after"; '
            "update-grub; grub-script-check /boot/grub/grub.cfg; "
            f"test \"$(grep -Ec '^(menuentry|submenu) ' /boot/grub/grub.cfg)\" "
            f"= {EXPECTED_GRUB_ROOT_ENTRY_COUNT}; "
            f"grep -Eq -- {windows_grub_entry_pattern} /boot/grub/grub.cfg; "
            "grep -Fq -- '--class efi --id libertix-advanced' /boot/grub/grub.cfg; "
            "grep -Fq -- '--class shutdown --id libertix-shutdown' /boot/grub/grub.cfg; "
            f"grep -Fq -- {expected_grub_entry} /boot/grub/grub.cfg; "
            'grep -Fq -- "$(uname -r)" /boot/grub/grub.cfg'
            + (
                "; grep -Fq 'UEFI Firmware Settings' /boot/grub/grub.cfg; "
                "test -x /usr/local/sbin/libertix-sync-efi; "
                "test -s /etc/apt/apt.conf.d/99-libertix-boot-maintenance; "
                "systemctl is-enabled libertix-efi-sync.path; "
                "/usr/local/sbin/libertix-sync-efi --if-present; "
                "signatures=$(LC_ALL=C sbverify --list "
                "/boot/efi/EFI/Libertix/shimx64.efi 2>&1); "
                "printf '%s\\n' \"$signatures\" | grep -Eq "
                "'CN=Microsoft Corporation UEFI CA 2011|CN=Microsoft( Corporation)? UEFI CA 2023'"
                if vm.firmware == "uefi"
                else ""
            )
        )
        profile_shortcut_test = (
            "profiles=$(python3 -c 'import base64,json,sys; "
            'p=json.load(open(sys.argv[1], encoding="utf-8")); '
            'print("\\n".join(json.loads(base64.b64decode('
            'p["features"]["windowsProfilesJsonBase64"], validate=True))))\' '
            "/etc/libertix/installation-plan.json); "
            f"home=/home/{username}; bookmarks=$home/.config/gtk-3.0/bookmarks; "
            "printf '%s\\n' \"$profiles\" | while IFS= read -r profile; do "
            'test -n "$profile" || continue; shortcut=$home/User_$profile; '
            'test -L "$shortcut"; '
            'test "$(readlink "$shortcut")" = "/mnt/windows/Users/$profile"; '
            'grep -Fqx "file://$shortcut User_$profile" "$bookmarks"; done'
            if options.share_windows_files_in_linux
            else (
                f"! find /home/{username} -maxdepth 1 -type l -name 'User_*' "
                "-print -quit | grep -q ."
            )
        )
        checks = (
            RemoteCheck("linux.identity", f'test "$(id -un)" = {username}; id'),
            RemoteCheck(
                "linux.os_release",
                ". /etc/os-release; "
                'printf \'ID=%s VERSION_ID=%s\\n\' "$ID" "$VERSION_ID"; '
                f'test "$ID" = {expected_os_release_id}',
            ),
            RemoteCheck("linux.kernel", "uname -a; test -r /proc/version"),
            RemoteCheck(
                "linux.hostname",
                'test -s /etc/hostname; test "$(hostname)" = "$(cat /etc/hostname)"; '
                'getent hosts "$(hostname)"',
            ),
            RemoteCheck(
                "linux.locale",
                "set -eu; plan=/etc/libertix/installation-plan.json; "
                "expected_locale=$(python3 -c 'import json,sys; "
                'print(json.load(open(sys.argv[1], encoding="utf-8"))["locale"]'
                '["systemLanguage"])\' "$plan"); '
                "expected_language=$(python3 -c 'import json,sys; "
                'print(json.load(open(sys.argv[1], encoding="utf-8"))["locale"]'
                '["languageCode"])\' "$plan"); '
                ". /etc/default/locale; "
                'test "${LANG:-}" = "$expected_locale"; '
                'test "${LC_ALL:-}" = "$expected_locale"; '
                'test "${LANGUAGE:-}" = "$expected_language"; '
                "actual=$(locale -a | tr '[:upper:]' '[:lower:]' | "
                "sed 's/utf-8/utf8/g' | grep -E '\\.utf8$' | "
                "grep -v '^c\\.utf8$' | sort -u); "
                "expected=$(printf '%s\\n' \"$expected_locale\" en_US.UTF-8 | "
                "tr '[:upper:]' '[:lower:]' | sed 's/utf-8/utf8/g' | sort -u); "
                'test "$actual" = "$expected"; printf \'%s\\n\' "$actual"',
            ),
            RemoteCheck(
                "linux.keyboard",
                "set -eu; plan=/etc/libertix/installation-plan.json; "
                f"marker=/home/{username}/.config/libertix/keyboard-initialized.json; "
                "expected_layout=$(python3 -c 'import json,sys; "
                'print(json.load(open(sys.argv[1], encoding="utf-8"))["locale"]'
                '["keyboardLayout"])\' "$plan"); '
                "expected_variant=$(python3 -c 'import json,sys; "
                'print(json.load(open(sys.argv[1], encoding="utf-8"))["locale"]'
                '.get("keyboardVariant", ""))\' "$plan"); '
                "expected_model=$(python3 -c 'import json,sys; "
                'print(json.load(open(sys.argv[1], encoding="utf-8"))["locale"]'
                '["keyboardModel"])\' "$plan"); '
                ". /etc/default/keyboard; "
                'test "${XKBLAYOUT:-}" = "$expected_layout"; '
                'test "${XKBVARIANT:-}" = "$expected_variant"; '
                'test "${XKBMODEL:-}" = "$expected_model"; '
                "test -x /usr/local/bin/libertix-apply-keyboard-once; "
                'test -s /etc/xdg/autostart/libertix-keyboard.desktop; test -s "$marker"; '
                'python3 -c \'import json,sys; p=json.load(open(sys.argv[1], encoding="utf-8")); '
                'm=json.load(open(sys.argv[2], encoding="utf-8")); l=p["locale"]; '
                's=l["keyboardLayout"]+("+"+l.get("keyboardVariant", "") '
                'if l.get("keyboardVariant") else ""); '
                'assert m["status"] == "succeeded" and '
                'm["sessionLanguage"] == l["systemLanguage"] and '
                'm["desktopSource"] == s\' "$plan" "$marker"; '
                'source="$expected_layout"; '
                '[ -z "$expected_variant" ] || source="$source+$expected_variant"; '
                "expected_sources=\"[('xkb', '$source')]\"; "
                "uid=$(id -u); export XDG_RUNTIME_DIR=/run/user/$uid; "
                "export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus; found=false; "
                "for schema in org.gnome.desktop.input-sources "
                "org.cinnamon.desktop.input-sources; do "
                'gsettings list-schemas | grep -Fxq "$schema" || continue; found=true; '
                'test "$(gsettings get "$schema" sources)" = "$expected_sources"; done; '
                '[ "$found" = true ]',
            ),
            RemoteCheck(
                "linux.timezone",
                "test -L /etc/localtime; test -s /etc/timezone; "
                'test "$(timedatectl show -p Timezone --value)" = "$(cat /etc/timezone)"',
            ),
            RemoteCheck(
                "linux.firmware", f"{firmware_test}; test -r /sys/class/dmi/id/product_name"
            ),
            RemoteCheck(
                "linux.root_filesystem",
                "findmnt -n -o FSTYPE,OPTIONS /; "
                'test "$(findmnt -n -o FSTYPE /)" = ext4; '
                "findmnt -n -o OPTIONS / | grep -qw rw",
            ),
            RemoteCheck(
                "linux.root_uuid",
                'root_uuid="$(findmnt -n -o UUID /)"; test -n "$root_uuid"; '
                'grep -Eq "^UUID=$root_uuid[[:space:]]+/[[:space:]]+ext4([[:space:]]|$)" '
                "/etc/fstab",
            ),
            RemoteCheck("linux.fstab", "findmnt --verify --verbose --tab-file /etc/fstab"),
            RemoteCheck(
                "linux.user_home",
                f'test -d /home/{username}; test "$(stat -c %U /home/{username})" = {username}',
            ),
            RemoteCheck(
                "linux.sudo_group",
                f"id -nG {username}; id -nG {username} | tr ' ' '\\n' | grep -Fx sudo",
            ),
            RemoteCheck(
                "linux.ssh_service",
                "systemctl is-enabled ssh; systemctl is-active ssh",
            ),
            RemoteCheck(
                "linux.ssh_security",
                "sshd -T | grep -Fx 'permitrootlogin no'; "
                "sshd -T | grep -Fx 'passwordauthentication yes'; "
                f"sshd -T | grep -Eq '^allowusers .*\\b{username}\\b'",
                requires_sudo=True,
            ),
            RemoteCheck(
                "linux.development_profile",
                "test -e /var/lib/libertix/development-ssh-ready; "
                f"grep -Fx {username} /etc/libertix/development-ssh-user; "
                'test "$(stat -c %a /etc/NetworkManager/system-connections/'
                'libertix-development-static.nmconnection)" = 600; '
                "grep -Fq 'method=manual' /etc/NetworkManager/system-connections/"
                "libertix-development-static.nmconnection; "
                f"grep -Fq -- {expected_profile} "
                "/etc/NetworkManager/system-connections/"
                "libertix-development-static.nmconnection",
                requires_sudo=True,
            ),
            RemoteCheck(
                "linux.static_ipv4",
                "ip -4 -o addr show scope global; "
                "ip -4 -o addr show scope global | "
                f"awk '{{print $4}}' | grep -Fx {expected_ip}",
            ),
            RemoteCheck(
                "linux.gateway",
                f"ip -4 route; ip -4 route show default | grep -Fq -- {expected_gateway}",
            ),
            RemoteCheck(
                "linux.dns",
                f"resolvectl dns; {dns_checks}",
            ),
            RemoteCheck(
                "linux.grub",
                "test -s /boot/grub/grub.cfg; "
                "grub-script-check /boot/grub/grub.cfg; "
                f"test \"$(grep -Ec '^(menuentry|submenu) ' /boot/grub/grub.cfg)\" "
                f"= {EXPECTED_GRUB_ROOT_ENTRY_COUNT}; "
                f"grep -Eq -- {windows_grub_entry_pattern} /boot/grub/grub.cfg; "
                "grep -Fq -- '--class efi --id libertix-advanced' /boot/grub/grub.cfg; "
                "grep -Fq -- '--class shutdown --id libertix-shutdown' /boot/grub/grub.cfg; "
                f"grep -Fq -- {expected_grub_entry} /boot/grub/grub.cfg",
                requires_sudo=True,
            ),
            RemoteCheck(
                "linux.grub_regeneration",
                grub_regeneration_test,
                timeout=180,
                requires_sudo=True,
            ),
            RemoteCheck("linux.boot_mode_files", boot_mode_test, requires_sudo=True),
            RemoteCheck(
                "linux.boot_artifacts",
                "find /boot -maxdepth 1 -type f -name 'vmlinuz-*' "
                "-print -quit | grep -q .; "
                "find /boot -maxdepth 1 -type f -name 'initrd.img-*' "
                "-print -quit | grep -q .",
            ),
            RemoteCheck(
                "linux.running_kernel_artifacts",
                'kernel="$(uname -r)"; '
                'test -s "/boot/vmlinuz-$kernel"; '
                'test -s "/boot/initrd.img-$kernel"; '
                "for image in /boot/vmlinuz-*; do "
                'version="${image#/boot/vmlinuz-}"; '
                'test -s "/boot/initrd.img-$version"; done',
            ),
            RemoteCheck(
                "linux.initramfs_integrity",
                'kernel="$(uname -r)"; '
                'contents="$(lsinitramfs "/boot/initrd.img-$kernel")"; '
                "printf '%s\\n' \"$contents\" | grep -Eq '(^|/)init$'; "
                "! printf '%s\\n' \"$contents\" | "
                "grep -Eq '(^|/)conf/uuid$|default-boot-to-casper'",
                requires_sudo=True,
            ),
            RemoteCheck(
                "linux.windows_mount",
                windows_mount_test,
            ),
            RemoteCheck(
                "linux.sharing_policy",
                sharing_policy_test,
                requires_sudo=True,
            ),
            RemoteCheck(
                "linux.windows_profile_shortcuts",
                profile_shortcut_test,
            ),
            RemoteCheck(
                "linux.desktop_stack",
                'test -n "$(systemctl show -p Id --value display-manager.service)"; '
                "systemctl is-active display-manager.service; "
                "find /usr/share/xsessions /usr/share/wayland-sessions -maxdepth 1 "
                "-type f -name '*.desktop' -print -quit 2>/dev/null | grep -q .",
            ),
            RemoteCheck(
                "linux.first_boot_verification",
                "python3 -c 'import hashlib,json,sys; "
                's=json.load(open(sys.argv[1], encoding="utf-8")); '
                'p=json.load(open(sys.argv[2], encoding="utf-8")); '
                'a=json.load(open(sys.argv[3], encoding="utf-8")); '
                'assert s["schemaVersion"] == 1 and s["status"] == "succeeded"; '
                'assert s["planId"] == p["planId"] and not s.get("error"); '
                'assert s["distribution"]["id"] == sys.argv[4]; '
                'assert s["distribution"]["osReleaseId"] == sys.argv[5]; '
                'assert s["root"]["filesystem"] == "ext4"; '
                'assert s["system"]["username"] == sys.argv[6]; '
                'assert s["system"]["rootReadWrite"] is True; '
                'assert s["system"]["sudoMember"] is True; '
                'assert s["system"]["passwordActive"] is True; '
                'assert s["system"]["dpkgAuditClean"] is True; '
                'assert s["system"]["failedSystemdUnits"] == 0; '
                'l=p["locale"]; z=s["localization"]; '
                'source=l["keyboardLayout"]+("+"+l.get("keyboardVariant", "") '
                'if l.get("keyboardVariant") else ""); '
                'expected_locales=sorted({l["systemLanguage"].casefold().replace('
                '"utf-8","utf8"),"en_us.utf8"}); '
                'assert z["verified"] is True; '
                'assert z["languageCode"] == l["languageCode"]; '
                'assert z["systemLocale"] == l["systemLanguage"]; '
                'assert z["compiledUtf8Locales"] == expected_locales; '
                'assert z["keyboardLayout"] == l["keyboardLayout"]; '
                'assert z["keyboardVariant"] == l.get("keyboardVariant", ""); '
                'assert z["keyboardModel"] == l["keyboardModel"]; '
                'assert z["desktopSource"] == source; '
                'assert s["grub"]["bootChain"]["verified"] is True; '
                'assert s.get("windowsEvidencePath"); '
                "fields={k:s.get(k) for k in "
                '("planId","status","updatedAtUtc","error")}; '
                "fingerprint=hashlib.sha256("
                "json.dumps(fields, sort_keys=True).encode()).hexdigest(); "
                'assert a["fingerprint"] == fingerprint\' '
                "/var/lib/libertix/first-boot-verification.json "
                "/etc/libertix/installation-plan.json "
                f"/home/{username}/.local/state/libertix/first-boot-result-ack.json "
                f"{shlex.quote(options.distribution.id)} "
                f"{expected_os_release_id} {username}; "
                "test \"$(python3 -c 'import json; "
                'print(json.load(open("/var/lib/libertix/first-boot-verification.json", '
                'encoding="utf-8"))["logPath"])\')" = '
                '"/var/log/libertix/first-boot-resize.log"; '
                "test -s /var/log/libertix/first-boot-resize.log; "
                "test -s /etc/xdg/autostart/libertix-first-boot-result.desktop; "
                "test -x /usr/local/lib/libertix/libertix-first-boot-result.py",
                requires_sudo=True,
            ),
            RemoteCheck(
                "linux.first_boot_cleanup",
                "test ! -e /etc/systemd/system/first-boot-resize.service; "
                "test ! -e /usr/local/bin/first-boot-resize.sh; "
                "test -s /var/log/libertix/first-boot-resize.log",
                requires_sudo=True,
            ),
            RemoteCheck(
                "linux.system_resources",
                'test "$(df --output=avail -B1 / | tail -1)" -gt 1073741824; '
                'test "$(df --output=iavail / | tail -1)" -gt 10000; '
                "test \"$(awk '/MemTotal:/ {print $2}' /proc/meminfo)\" -gt 1048576",
            ),
            RemoteCheck(
                "linux.failed_units",
                "failed=$(systemctl --failed --no-legend --plain); "
                'printf \'%s\\n\' "$failed"; test -z "$failed"',
            ),
            RemoteCheck(
                "linux.time_sync",
                'i=0; while [ "$i" -lt 18 ]; do '
                "timeout 5s timedatectl show -p NTPSynchronized --value | "
                "grep -Fxq yes && exit 0; "
                "i=$((i + 1)); sleep 2; done; "
                "timeout 5s timedatectl status; exit 1",
                timeout=150,
            ),
            RemoteCheck(
                "linux.package_database",
                'test -z "$(dpkg --audit)"; dpkg --audit',
                requires_sudo=True,
            ),
            RemoteCheck(
                "linux.package_dependencies",
                "apt-get check",
                timeout=180,
                requires_sudo=True,
            ),
            RemoteCheck(
                "linux.name_resolution",
                "getent ahostsv4 ekimia.fr | head -1 | grep -q .",
            ),
        )
        for check in checks:
            self._run_remote_check(
                ssh,
                vm,
                result,
                "linux",
                check,
                sudo_password=options.linux_password,
            )

    def _create_cross_os_artifacts(
        self,
        ssh: SSHClient,
        vm: VMConfig,
        options: AutomationOptions,
        result: ResultBuilder,
    ) -> CrossOsArtifacts:
        run_id = uuid.uuid4().hex
        windows_relative = f"Users/Public/Documents/libertix-auto-test-{run_id}.bin"
        windows_linux_path = f"/mnt/windows/{windows_relative}"
        linux_relative = f"libertix-auto-test-{run_id}.bin"
        linux_path = f"/home/{options.linux_username}/{linux_relative}"
        windows_command = (
            f"umask 077; dd if=/dev/urandom of={shlex.quote(windows_linux_path)} "
            "bs=1M count=100 status=none; sync; "
            f'test "$(stat -c %s {shlex.quote(windows_linux_path)})" = 104857600; '
            f"sha256sum {shlex.quote(windows_linux_path)} | awk '{{print $1}}'"
        )
        linux_command = (
            f"umask 077; dd if=/dev/urandom of={shlex.quote(linux_path)} "
            "bs=1M count=1 status=none; sync; "
            f"sha256sum {shlex.quote(linux_path)} | awk '{{print $1}}'"
        )
        windows_hash = (
            self._run_artifact_check(
                ssh, vm, result, "sharing.linux_to_windows_100m", windows_command
            )
            if options.share_windows_files_in_linux
            else ""
        )
        linux_hash = (
            self._run_artifact_check(ssh, vm, result, "sharing.linux_home_marker", linux_command)
            if options.share_linux_files_in_windows
            else ""
        )
        return CrossOsArtifacts(
            windows_relative_path=windows_relative.replace("/", "\\"),
            windows_sha256=windows_hash,
            linux_relative_path=linux_relative,
            linux_sha256=linux_hash,
        )

    def _cleanup_windows_cross_os_artifact(
        self,
        ssh: SSHClient,
        vm: VMConfig,
        options: AutomationOptions,
        artifacts: CrossOsArtifacts,
        result: ResultBuilder,
    ) -> None:
        if not options.share_windows_files_in_linux:
            return
        path = rf"C:\{artifacts.windows_relative_path}"
        command = f'cmd.exe /d /c "del /f /q {path} 2>nul & if exist {path} exit /b 1"'
        self._run_cross_os_cleanup(
            ssh,
            vm,
            result,
            name="sharing.windows_artifact_cleanup",
            command=command,
        )

    def _cleanup_linux_cross_os_artifact(
        self,
        ssh: SSHClient,
        vm: VMConfig,
        options: AutomationOptions,
        artifacts: CrossOsArtifacts,
        result: ResultBuilder,
    ) -> None:
        if not options.share_linux_files_in_windows:
            return
        path = f"/home/{options.linux_username}/{artifacts.linux_relative_path}"
        quoted_path = shlex.quote(path)
        command = f"rm -f -- {quoted_path}; test ! -e {quoted_path}"
        self._run_cross_os_cleanup(
            ssh,
            vm,
            result,
            name="sharing.linux_artifact_cleanup",
            command=f"sh -eu -c {shlex.quote(command)}",
        )

    @staticmethod
    def _run_cross_os_cleanup(
        ssh: SSHClient,
        vm: VMConfig,
        result: ResultBuilder,
        *,
        name: str,
        command: str,
    ) -> None:
        try:
            response = ssh.run(
                command,
                step="automation.test.artifact_cleanup",
                timeout=60,
                check=False,
            )
        except WorkflowError as exc:
            result.error(
                "automation.test.artifact_cleanup",
                f"{name}: FAILED",
                vm=vm.name,
                target=vm.host,
                test=name,
                **exc.details,
            )
            return
        context = {
            "vm": vm.name,
            "target": vm.host,
            "test": name,
            "exit_code": response.exit_code,
            "stdout": response.stdout,
            "stderr": response.stderr,
        }
        if response.exit_code == 0:
            result.ok("automation.test.artifact_cleanup", f"{name}: OK", **context)
        else:
            result.error("automation.test.artifact_cleanup", f"{name}: FAILED", **context)

    def _run_artifact_check(
        self,
        ssh: SSHClient,
        vm: VMConfig,
        result: ResultBuilder,
        name: str,
        command: str,
    ) -> str:
        check = RemoteCheck(name, command, timeout=300)
        response = self._run_remote_check(ssh, vm, result, "linux", check)
        return response.stdout.strip().splitlines()[-1] if response and response.stdout else ""

    def _run_remote_check(
        self,
        ssh: SSHClient,
        vm: VMConfig,
        result: ResultBuilder,
        platform: str,
        check: RemoteCheck,
        sudo_password: str | None = None,
    ) -> CommandResult | None:
        # Every semicolon-separated assertion is part of the contract. Without
        # errexit, a later successful diagnostic could hide an earlier failure.
        command = f"sh -eu -c {shlex.quote(check.command)}"
        stdin_data = None
        sensitive = check.sensitive
        if check.requires_sudo:
            if sudo_password is None:
                raise ValueError(f"{check.name} requires a sudo password")
            command = f"sudo -S -p '' sh -eu -c {shlex.quote(check.command)}"
            stdin_data = sudo_password + "\n"
            sensitive = True
        last_error: WorkflowError | None = None
        response: CommandResult | None = None
        for attempt in range(1, REMOTE_CHECK_SSH_MAX_ATTEMPTS + 1):
            try:
                if attempt > 1:
                    ssh.reconnect()
                response = ssh.run(
                    command,
                    step=f"automation.test.{platform}",
                    timeout=check.timeout,
                    check=False,
                    sensitive=sensitive,
                    stdin_data=stdin_data,
                )
                break
            except WorkflowError as exc:
                last_error = exc
                if (
                    not is_reconnectable_transport_error(exc)
                    or attempt == REMOTE_CHECK_SSH_MAX_ATTEMPTS
                ):
                    break

        if response is None:
            assert last_error is not None
            result.error(
                f"automation.test.{platform}",
                f"{check.name} failed before a result was returned",
                vm=vm.name,
                target=vm.host,
                test=check.name,
                **last_error.details,
            )
            return None

        context = {
            "vm": vm.name,
            "target": vm.host,
            "test": check.name,
            "exit_code": response.exit_code,
            "stdout": response.stdout,
            "stderr": response.stderr,
            "command": "[SENSITIVE COMMAND HIDDEN]" if sensitive else check.command,
        }
        if response.exit_code == 0:
            result.ok(f"automation.test.{platform}", f"{check.name}: OK", **context)
        else:
            result.error(f"automation.test.{platform}", f"{check.name}: FAILED", **context)
        return response

    def _request_windows_boot(
        self,
        ssh: SSHClient,
        vm: VMConfig,
        options: AutomationOptions,
        result: ResultBuilder,
        *,
        test_name: str = "linux.windows_reboot",
    ) -> None:
        entry = "Windows" if vm.firmware == "bios" else "Windows Boot Manager"
        reboot_script = f"grub-reboot {shlex.quote(entry)} && systemctl reboot"
        command = f"sudo -S -p '' sh -c {shlex.quote(reboot_script)}"
        try:
            response = ssh.run(
                command,
                step="automation.windows_boot",
                timeout=30,
                check=False,
                sensitive=True,
                stdin_data=options.linux_password + "\n",
            )
        except WorkflowError as exc:
            result.error(
                "automation.test.linux",
                f"{test_name}: FAILED",
                vm=vm.name,
                target=vm.host,
                test=test_name,
                **exc.details,
            )
            return
        if response.exit_code not in {0, -1}:
            result.error(
                "automation.test.linux",
                f"{test_name}: FAILED",
                vm=vm.name,
                target=vm.host,
                test=test_name,
                exit_code=response.exit_code,
                stdout=response.stdout,
                stderr=response.stderr,
            )
            return
        result.ok(
            "automation.test.linux",
            f"{test_name}: OK",
            vm=vm.name,
            target=vm.host,
            test=test_name,
        )

    def _request_linux_boot_from_windows(
        self,
        ssh: SSHClient,
        vm: VMConfig,
        result: ResultBuilder,
    ) -> None:
        try:
            response = ssh.run(
                "shutdown.exe /r /t 0 /d p:0:0",
                step="automation.linux_return_boot",
                timeout=30,
                check=False,
            )
        except WorkflowError as exc:
            result.error(
                "automation.test.windows",
                "windows.linux_reboot: FAILED",
                vm=vm.name,
                target=vm.host,
                test="windows.linux_reboot",
                **exc.details,
            )
            return
        if response.exit_code not in {0, -1}:
            result.error(
                "automation.test.windows",
                "windows.linux_reboot: FAILED",
                vm=vm.name,
                target=vm.host,
                test="windows.linux_reboot",
                exit_code=response.exit_code,
                stdout=response.stdout,
                stderr=response.stderr,
            )
            return
        result.ok(
            "automation.test.windows",
            "windows.linux_reboot: OK",
            vm=vm.name,
            target=vm.host,
            test="windows.linux_reboot",
        )

    def _run_windows_checks(
        self,
        ssh: SSHClient,
        vm: VMConfig,
        options: AutomationOptions,
        artifacts: CrossOsArtifacts,
        result: ResultBuilder,
    ) -> None:
        plan = build_windows_validation_plan(vm, options, artifacts)
        for name in plan.check_names:
            try:
                response = self._run_windows_script_resiliently(
                    ssh,
                    script_name="post_install_windows_check.ps1",
                    config={**plan.base_config, "check": name},
                    step="automation.test.windows",
                    timeout=windows_validation_timeout_seconds(name),
                )
                result.ok(
                    "automation.test.windows",
                    f"windows.{name}: OK",
                    vm=vm.name,
                    target=vm.host,
                    test=f"windows.{name}",
                    exit_code=response.exit_code,
                    stdout=response.stdout,
                    stderr=response.stderr,
                )
            except WorkflowError as exc:
                result.error(
                    "automation.test.windows",
                    f"windows.{name}: FAILED",
                    vm=vm.name,
                    target=vm.host,
                    test=f"windows.{name}",
                    **exc.details,
                )
