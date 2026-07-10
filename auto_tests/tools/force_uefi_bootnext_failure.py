"""Force a controlled BootNext miss during the UEFI recovery integration test."""

from __future__ import annotations

import argparse
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
    script = Path(__file__).parents[1] / "app" / "scripts" / "force_uefi_bootnext_failure.ps1"
    remote_script = "C:/Windows/Temp/force-uefi-bootnext-failure.ps1"
    remote_windows_script = remote_script.replace("/", "\\")

    with SSHClient(
        vm.host,
        vm.username,
        settings.windows_ssh_password.get_secret_value(),
        port=settings.ssh_port,
        connect_timeout=settings.ssh_timeout_seconds,
    ) as ssh:
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
        ssh.run(
            f'del "{remote_windows_script}"',
            step="test.force_bootnext.cleanup",
            timeout=30,
            check=False,
            sensitive=True,
        )

    args.output.write_text(
        f"exit_code={result.exit_code}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}\n",
        encoding="utf-8",
    )
    return result.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
