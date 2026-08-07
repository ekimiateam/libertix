"""Post-install validation of the installed Linux and Windows systems."""

from __future__ import annotations

import shlex
import time
import uuid
from dataclasses import dataclass
from typing import Literal

from app.clients.ssh import CommandResult, SSHClient
from app.config import VMConfig
from app.errors import WorkflowError
from app.services.automation_types import AutomationOptions
from app.services.common import ResultBuilder


@dataclass(frozen=True)
class RemoteCheck:
    name: str
    command: str
    timeout: float = 120
    sensitive: bool = False
    requires_sudo: bool = False


@dataclass(frozen=True)
class CrossOsArtifacts:
    windows_relative_path: str
    windows_sha256: str
    linux_relative_path: str
    linux_sha256: str


class PostInstallValidationMixin:
    """Validate both installed operating systems after the installer exits."""

    def _run_post_install_validation(
        self,
        vm: VMConfig,
        options: AutomationOptions,
        result: ResultBuilder,
        monitor_outcome: str,
    ) -> None:
        if monitor_outcome == "boot-menu":
            self._select_linux_from_grub(vm, result)

        result.ok(
            "automation.post_install_phase",
            "Waiting for installed Linux SSH",
            vm=vm.name,
            target=vm.host,
            phase="linux-ssh",
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
            phase="linux",
            grub_entry=None if monitor_outcome == "boot-menu" else "linux",
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
            self._run_windows_checks(windows_ssh, vm, options, artifacts, result)
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
        )
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
        )
        try:
            try:
                response = self.validation.run_windows_script(
                    final_windows_ssh,
                    script_name="post_install_windows_check.ps1",
                    config={
                        "check": "final_state",
                        "expected_firmware": vm.firmware,
                        "expected_ipv4": vm.host,
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

    def _select_linux_from_grub(self, vm: VMConfig, result: ResultBuilder) -> None:
        client = None
        try:
            client = self.vnc.connect(vm.vnc)
            client.mouseMove(5, 5)
            client.keyPress("home")
            client.keyPress("enter")
            result.ok(
                "automation.post_install_phase",
                "Selected the first installed Linux entry in GRUB",
                vm=vm.name,
                target=vm.vnc,
                phase="linux-boot",
            )
        except Exception as exc:
            raise WorkflowError(
                "automation.linux_boot",
                "Unable to select Linux from the installed GRUB menu",
                details={"vm": vm.name, "target": vm.vnc, "error": str(exc)},
            ) from exc
        finally:
            if client is not None:
                client.disconnect()

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
    ) -> SSHClient:
        deadline = time.monotonic() + self.settings.post_install_boot_timeout_seconds
        last_error: WorkflowError | None = None
        attempt = 0
        grub_selection_done = grub_entry is None
        while time.monotonic() < deadline:
            attempt += 1
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
            # The installed menu has no timeout by design. Only confirm a
            # choice after vision identifies the complete GRUB menu, avoiding
            # blind keystrokes in a booting OS or on a login screen.
            if not grub_selection_done and attempt % 3 == 0:
                grub_selection_done = self._select_grub_entry_if_visible(
                    vm, result, grub_entry, attempt
                )
            time.sleep(self.settings.post_install_poll_interval_seconds)

        details = {"vm": vm.name, "host": vm.host, "phase": phase}
        if last_error is not None:
            details["last_error"] = last_error.details
        raise WorkflowError(
            f"automation.{phase}_ssh_wait",
            f"Timed out waiting for {phase} SSH",
            details=details,
        )

    def _select_grub_entry_if_visible(
        self,
        vm: VMConfig,
        result: ResultBuilder,
        entry: Literal["linux", "windows"],
        attempt: int,
    ) -> bool:
        capture = self._capture_with_name(vm, f"post-install-{entry}-grub-{attempt:03d}")
        try:
            verdict = self.vision_llm.analyze_install_progress(capture, vm.name, vm.os)
        except WorkflowError:
            # SSH remains authoritative. A transient vision failure must not
            # abort the operating-system boot wait.
            return False

        evidence = f"{verdict.visible_text}\n{verdict.summary}"
        if not self._reboot_or_live_started(evidence):
            return False

        client = None
        try:
            client = self.vnc.connect(vm.vnc)
            client.mouseMove(5, 5)
            client.keyPress("home")
            if entry == "windows":
                client.keyPress("down")
            client.keyPress("enter")
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
            f"Selected {entry} from the installed GRUB menu",
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
                'test "$ID" = linuxmint',
            ),
            RemoteCheck("linux.kernel", "uname -a; test -r /proc/version"),
            RemoteCheck(
                "linux.hostname",
                'test -s /etc/hostname; test "$(hostname)" = "$(cat /etc/hostname)"; '
                'getent hosts "$(hostname)"',
            ),
            RemoteCheck(
                "linux.locale",
                '. /etc/default/locale; test -n "${LANG:-}"; '
                "expected=$(printf '%s' \"$LANG\" | tr '[:upper:]' '[:lower:]' | "
                "sed 's/utf-8/utf8/'); "
                "locale -a | tr '[:upper:]' '[:lower:]' | grep -Fx \"$expected\"",
            ),
            RemoteCheck(
                "linux.keyboard",
                '. /etc/default/keyboard; test -n "${XKBLAYOUT:-}"; '
                "test -x /usr/local/bin/libertix-apply-keyboard-once; "
                "test -s /etc/xdg/autostart/libertix-keyboard.desktop",
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
                'grep -Eq "menuentry [\'\\"]Windows( Boot Manager)?[\'\\"]" '
                "/boot/grub/grub.cfg; "
                "grep -Fq \"submenu 'Advanced options' --class efi\" /boot/grub/grub.cfg; "
                "grep -Fq \"menuentry 'Shutdown' --class shutdown\" /boot/grub/grub.cfg",
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
                "linux.windows_mount",
                windows_mount_test,
            ),
            RemoteCheck(
                "linux.sharing_policy",
                sharing_policy_test,
            ),
            RemoteCheck(
                "linux.windows_profile_shortcuts",
                profile_shortcut_test,
            ),
            RemoteCheck(
                "linux.desktop_stack",
                "test \"$(dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\\n' "
                "cinnamon lightdm | grep -c '^ii ')\" = 2; systemctl is-active lightdm",
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
        try:
            response = ssh.run(
                command,
                step=f"automation.test.{platform}",
                timeout=check.timeout,
                check=False,
                sensitive=sensitive,
                stdin_data=stdin_data,
            )
        except WorkflowError as exc:
            result.error(
                f"automation.test.{platform}",
                f"{check.name} failed before a result was returned",
                vm=vm.name,
                target=vm.host,
                test=check.name,
                **exc.details,
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
        check_names = [
            "finalization",
            "identity",
            "firmware",
            "system_volume",
            "system_resources",
            "partition_layout",
            "partition_geometry",
            "boot_partition",
            "boot_configuration",
            "recovery",
            "bitlocker",
            "temporary_artifacts",
            "network",
            "locale",
            "ssh_service",
            "core_services",
            "hibernation",
            "dism_check_health",
            "sfc_verify_only",
            "chkdsk_scan",
        ]
        if options.share_linux_files_in_windows:
            insert_at = check_names.index("dism_check_health")
            check_names[insert_at:insert_at] = [
                "ext4_driver",
                "ext4_readonly_mount",
                "linux_home",
                "linux_home_hash",
                "ext4_write_denied",
                "explorer_shortcut",
                "sharing_tasks",
            ]
        if options.share_windows_files_in_linux:
            check_names.insert(check_names.index("dism_check_health"), "cross_os_hash")
        if not (options.share_windows_files_in_linux and options.share_linux_files_in_windows):
            check_names.insert(check_names.index("dism_check_health"), "sharing_disabled")
        base_config = {
            "expected_firmware": vm.firmware,
            "expected_ipv4": vm.host,
            "linux_username": options.linux_username,
            "windows_relative_path": artifacts.windows_relative_path,
            "windows_sha256": artifacts.windows_sha256,
            "linux_relative_path": artifacts.linux_relative_path,
            "linux_sha256": artifacts.linux_sha256,
            "share_windows_files_in_linux": options.share_windows_files_in_linux,
            "share_linux_files_in_windows": options.share_linux_files_in_windows,
        }
        for name in check_names:
            try:
                response = self.validation.run_windows_script(
                    ssh,
                    script_name="post_install_windows_check.ps1",
                    config={**base_config, "check": name},
                    step="automation.test.windows",
                    timeout=1800 if name in {"sfc_verify_only", "chkdsk_scan"} else 300,
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
