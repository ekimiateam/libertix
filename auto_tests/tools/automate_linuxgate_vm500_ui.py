#!/usr/bin/env python3
from __future__ import annotations

import argparse
import time
from pathlib import Path

from vncdotool import api

from app.clients.ssh import SSHClient
from app.clients.vnc import VNCClient
from app.config import VMConfig, get_settings


CAPTURE_DIR = Path(__file__).resolve().parents[1] / "captures"


def select_win10_bios_vm() -> VMConfig:
    settings = get_settings()
    for vm in settings.vms:
        if "Windows 10 BIOS" in vm.os:
            return vm
    raise SystemExit("Windows 10 BIOS VM not found in .env")


def launch_elevated(vm: VMConfig) -> None:
    settings = get_settings()
    script = r'''
$ErrorActionPreference = 'Continue'
Stop-Process -Name LinuxGate -Force -ErrorAction SilentlyContinue
schtasks.exe /Delete /TN LinuxGateElevatedTest /F 2>$null | Out-Null
$exe = 'C:\Users\admin\Documents\LinuxGate-release\LinuxGate.exe'
$time = (Get-Date).AddMinutes(1).ToString('HH:mm')
$tr = '\"' + $exe + '\"'
schtasks.exe /Create /TN LinuxGateElevatedTest /TR $tr /SC ONCE /ST $time /RL HIGHEST /IT /F | Write-Output
schtasks.exe /Run /TN LinuxGateElevatedTest | Write-Output
Start-Sleep -Seconds 5
Get-Process LinuxGate -ErrorAction SilentlyContinue | ForEach-Object { "PROCESS=$($_.Id);SESSION=$($_.SessionId);PATH=$($_.Path)" }
'''
    remote = "C:/Windows/Temp/linuxgate-elevated-test.ps1"
    with SSHClient(
        vm.host,
        vm.username,
        settings.windows_ssh_password.get_secret_value(),
        port=settings.ssh_port,
        connect_timeout=settings.ssh_timeout_seconds,
    ) as ssh:
        ssh.upload_text(remote, script, step="manual.vm500.launch_elevated.upload")
        result = ssh.run(
            f'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "{remote.replace("/", "\\")}"',
            step="manual.vm500.launch_elevated.run",
            timeout=90,
            check=False,
            sensitive=True,
        )
    if "PROCESS=" not in result.stdout:
        raise SystemExit(f"Elevated LinuxGate launch failed, rc={result.exit_code}")


def capture(client: object, name: str) -> Path:
    CAPTURE_DIR.mkdir(parents=True, exist_ok=True)
    path = CAPTURE_DIR / name
    client.captureScreen(str(path))
    print(f"CAPTURE={path} SIZE={path.stat().st_size}", flush=True)
    return path


def click(client: object, x: int, y: int, delay: float = 0.8) -> None:
    client.mouseMove(x, y)
    client.mousePress(1)
    time.sleep(delay)


def type_text(client: object, text: str) -> None:
    for ch in text:
        client.keyPress(ch)
        time.sleep(0.05)


def run_ui(vm: VMConfig, *, password: str, apply: bool, launch: bool) -> None:
    if launch:
        launch_elevated(vm)

    client = api.connect(VNCClient._vncdotool_address(vm.vnc))
    try:
        time.sleep(1)
        capture(client, "vm500-auto-00-welcome.png")

        click(client, 512, 438, 2.0)
        capture(client, "vm500-auto-01-distro.png")

        click(client, 145, 395, 0.5)
        click(client, 919, 628, 2.0)
        capture(client, "vm500-auto-02-resize.png")

        click(client, 919, 628, 2.0)
        capture(client, "vm500-auto-03-account.png")

        click(client, 512, 333, 0.3)
        type_text(client, password)
        client.keyPress("tab")
        time.sleep(0.2)
        type_text(client, password)
        time.sleep(0.5)
        capture(client, "vm500-auto-04-account-filled.png")

        click(client, 919, 628, 2.0)
        capture(client, "vm500-auto-05-warning.png")

        if not apply:
            print("STOPPED_BEFORE_DESTRUCTIVE_APPLY=1", flush=True)
            return

        click(client, 221, 541, 0.5)
        click(client, 919, 628, 10.0)
        capture(client, "vm500-auto-06-apply-started.png")
    finally:
        try:
            client.disconnect()
        except Exception:
            pass


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Automate the LinuxGate UI on the Windows 10 BIOS VM only."
    )
    parser.add_argument("--password", default="linux")
    parser.add_argument("--apply", action="store_true", help="Launch destructive ApplyChanges.")
    parser.add_argument(
        "--no-launch",
        action="store_true",
        help="Do not relaunch LinuxGate elevated before clicking.",
    )
    args = parser.parse_args()

    vm = select_win10_bios_vm()
    if vm.host != "192.168.1.240":
        raise SystemExit(f"Refusing unexpected Windows 10 BIOS host: {vm.host}")
    run_ui(vm, password=args.password, apply=args.apply, launch=not args.no_launch)


if __name__ == "__main__":
    main()
