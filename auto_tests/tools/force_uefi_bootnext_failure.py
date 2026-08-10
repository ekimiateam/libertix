"""Force a controlled BootNext miss during the UEFI recovery integration test."""

from __future__ import annotations

import argparse
import uuid
from pathlib import Path

from app.clients.ssh import SSHClient
from app.config import get_settings


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vm", default="vm2")
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    settings = get_settings()
    vm = next(item for item in settings.vms if item.name == args.vm)
    if vm.firmware != "uefi":
        parser.error("--vm must select a configured UEFI VM")
    script = Path(__file__).parents[1] / "app" / "scripts" / "force_uefi_bootnext_failure.ps1"
    run_id = uuid.uuid4().hex
    remote_script = f"C:/Windows/Temp/force-uefi-bootnext-failure-{run_id}.ps1"
    remote_windows_script = remote_script.replace("/", "\\")

    with SSHClient(
        vm.host,
        vm.username,
        settings.windows_ssh_password.get_secret_value(),
        known_hosts_path=settings.ssh_known_hosts,
        port=settings.ssh_port,
        connect_timeout=settings.ssh_timeout_seconds,
        remote_os="windows",
    ) as ssh:
        try:
            ssh.upload_text(
                remote_script,
                script.read_text(encoding="utf-8"),
                step="test.force_bootnext.upload",
            )
            result = ssh.run(
                "powershell -NoProfile -ExecutionPolicy Bypass "
                f'-File "{remote_windows_script}" -TimeoutSeconds {args.timeout}',
                step="test.force_bootnext",
                timeout=args.timeout + 60,
                sensitive=True,
                check=False,
            )
        finally:
            ssh.run(
                f'cmd.exe /d /c "del /f /q {remote_windows_script} 2>nul & '
                f'if exist {remote_windows_script} exit /b 1"',
                step="test.force_bootnext.cleanup",
                timeout=30,
                check=True,
                sensitive=True,
            )

    args.output.write_text(
        f"exit_code={result.exit_code}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}\n",
        encoding="utf-8",
    )
    return result.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
