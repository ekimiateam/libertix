from __future__ import annotations

import base64
import json
import time
from pathlib import Path

from app.errors import WorkflowError

STEP = "automation.secondary_windows_login"
LOGIN_TIMEOUT_SECONDS = 90


def _read_state(proxmox, node, vm):
    script = Path(__file__).resolve().parents[1] / "scripts/get_windows_lab_logon_state.ps1"
    encoded = base64.b64encode(script.read_text(encoding="utf-8").encode("utf-16le")).decode()
    result = proxmox.execute_guest_agent_command(
        node,
        vm.vmid,
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
        step=STEP,
        timeout=15,
    )
    if result.get("exitcode") != 0:
        raise WorkflowError(STEP, "Windows logon state could not be read")
    try:
        state = json.loads(result["out-data"])
        if not isinstance(state, dict) or not isinstance(state["explorers"], list):
            raise ValueError("Invalid state")
        return state
    except (KeyError, TypeError, ValueError) as error:
        raise WorkflowError(STEP, "Windows logon state is invalid") from error


def _desktop_ready(state, vm):
    explorers = state["explorers"]
    if not explorers:
        return False
    if not all(
        isinstance(entry, dict)
        and isinstance(entry.get("session"), int)
        and entry["session"] > 0
        and str(entry.get("user", "")).casefold() == vm.username.casefold()
        for entry in explorers
    ):
        raise WorkflowError(STEP, "The desktop belongs to another or unidentified user")
    return True


def _password_screen_identity(state, vm):
    logons = state.get("logonProcesses")
    expected_layout = {"fr": "0000040c", "us": "00000409"}[vm.vnc_keyboard_layout]
    if (
        state.get("automaticLogon") is not False
        or state.get("passwordProvider") is not True
        or str(state.get("lastUser", "")).casefold() != (".\\" + vm.username).casefold()
        or state.get("keyboard") != expected_layout
        or not isinstance(logons, list)
        or len(logons) != 1
        or not isinstance(logons[0], dict)
        or not isinstance(logons[0].get("id"), int)
        or logons[0]["id"] <= 0
        or not isinstance(logons[0].get("session"), int)
        or logons[0]["session"] <= 0
    ):
        raise WorkflowError(STEP, "The local password logon screen or keyboard cannot be verified")
    return logons[0]["id"], logons[0]["session"]


def _ensure_secondary_windows_session(service, proxmox, node, vm):
    if (
        not vm.secondary_disk_boot_order
        or vm.vmid not in service.settings.allowed_proxmox_vmids
        or not vm.automation_enabled
    ):
        raise WorkflowError(STEP, "Interactive login is limited to authorized secondary-disk tests")
    deadline = time.monotonic() + LOGIN_TIMEOUT_SECONDS
    state = None
    while time.monotonic() < deadline:
        try:
            state = _read_state(proxmox, node, vm)
        except WorkflowError:
            time.sleep(2)
            continue
        if _desktop_ready(state, vm):
            return
        if state.get("logonProcesses"):
            break
        time.sleep(2)
    if state is None or not state.get("logonProcesses"):
        raise WorkflowError(STEP, "Windows did not expose a logon screen before the deadline")
    identity = _password_screen_identity(state, vm)
    service.vnc.capture(vm.vnc, service._capture_dir / f"{vm.name}-secondary-logon-before.png")
    client = service.vnc.connect(vm.vnc)
    try:
        client.keyPress("ctrl-alt-delete")
        time.sleep(1)
        state = _read_state(proxmox, node, vm)
        if _desktop_ready(state, vm):
            return
        if _password_screen_identity(state, vm) != identity:
            raise WorkflowError(STEP, "The logon screen changed before password entry")
        # Never configure AutoAdminLogon or persist credentials in a registry value or file.
        # Only one password submission is allowed, after rechecking the local password provider.
        client.keyPress("ctrl-a")
        service._type_text(
            client, service.settings.windows_ssh_password.get_secret_value(), vm.vnc_keyboard_layout
        )
        client.keyPress("enter")
    finally:
        client.disconnect()
    deadline = time.monotonic() + LOGIN_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        try:
            state = _read_state(proxmox, node, vm)
        except WorkflowError:
            time.sleep(2)
            continue
        if _desktop_ready(state, vm):
            return
        time.sleep(2)
    service.vnc.capture(vm.vnc, service._capture_dir / f"{vm.name}-secondary-logon-failed.png")
    raise WorkflowError(STEP, "One login attempt did not open the expected Windows desktop")


def ensure_secondary_windows_session(service, proxmox, node, vm):
    try:
        _ensure_secondary_windows_session(service, proxmox, node, vm)
    except WorkflowError as error:
        error.details.update({"vm": vm.name, "vmid": vm.vmid})
        raise
