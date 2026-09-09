#!/usr/bin/env python3
"""Prove result-window focus, using the product state on Wayland and X11 otherwise."""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import re
import subprocess
import time
import uuid
from datetime import UTC, datetime
from pathlib import Path

CLIENT_MESSAGE = 33
CURRENT_TIME = 0
SUBSTRUCTURE_NOTIFY_MASK = 1 << 19
SUBSTRUCTURE_REDIRECT_MASK = 1 << 20


class XClientMessageData(ctypes.Union):
    _fields_ = [
        ("b", ctypes.c_char * 20),
        ("s", ctypes.c_short * 10),
        ("l", ctypes.c_long * 5),
    ]


class XClientMessageEvent(ctypes.Structure):
    _fields_ = [
        ("type", ctypes.c_int),
        ("serial", ctypes.c_ulong),
        ("send_event", ctypes.c_int),
        ("display", ctypes.c_void_p),
        ("window", ctypes.c_ulong),
        ("message_type", ctypes.c_ulong),
        ("format", ctypes.c_int),
        ("data", XClientMessageData),
    ]


class XEvent(ctypes.Union):
    _fields_ = [
        ("type", ctypes.c_int),
        ("client_message", XClientMessageEvent),
        ("padding", ctypes.c_long * 24),
    ]


def read_process_environment(process_id: int) -> dict[str, str]:
    payload = Path(f"/proc/{process_id}/environ").read_bytes()
    values: dict[str, str] = {}
    for entry in payload.split(b"\0"):
        name, separator, value = entry.partition(b"=")
        if separator:
            values[name.decode("utf-8")] = value.decode("utf-8")
    required = () if values.get("XDG_SESSION_TYPE") == "wayland" else ("DISPLAY", "XAUTHORITY")
    missing = [name for name in required if not values.get(name)]
    if missing:
        raise RuntimeError("The graphical process environment lacks: " + ", ".join(missing))
    return values


def write_json_atomic(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.parent / f".{path.name}.{os.getpid()}.tmp"
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def read_json(path: Path) -> dict[str, object] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def request_product_activation(
    process_id: int,
    environment: dict[str, str],
    timeout: float,
    *,
    check_only: bool = False,
) -> tuple[bool, str]:
    home = environment.get("HOME")
    if not home:
        return False, ""
    state_root = Path(home) / ".local" / "state" / "libertix"
    ui_state_path = state_root / "first-boot-result-ui.json"
    activation_request_path = state_root / "first-boot-result-activate.json"
    deadline = time.monotonic() + timeout
    request_id = uuid.uuid4().hex
    fingerprint = ""
    while time.monotonic() < deadline:
        ui_state = read_json(ui_state_path)
        if (
            ui_state
            and ui_state.get("processId") == process_id
            and ui_state.get("visible") is True
            and re.fullmatch(r"[0-9a-f]{64}", str(ui_state.get("fingerprint", "")))
        ):
            fingerprint = str(ui_state["fingerprint"])
            if check_only:
                return product_state_is_active(ui_state, process_id, fingerprint), fingerprint
            write_json_atomic(
                activation_request_path,
                {
                    "schemaVersion": 1,
                    "requestId": request_id,
                    "fingerprint": fingerprint,
                },
            )
            break
        time.sleep(0.1)
    if not fingerprint:
        return False, ""

    while time.monotonic() < deadline:
        ui_state = read_json(ui_state_path)
        if product_state_is_active(ui_state, process_id, fingerprint):
            return True, fingerprint
        time.sleep(0.1)
    return False, fingerprint


def product_state_is_active(
    state: dict[str, object] | None, process_id: int, fingerprint: str
) -> bool:
    return product_state_is_visible(state, process_id, fingerprint) and state.get("active") is True


def product_state_is_visible(
    state: dict[str, object] | None, process_id: int, fingerprint: str
) -> bool:
    if not state:
        return False
    try:
        updated = datetime.fromisoformat(str(state.get("updatedAtUtc", "")))
        age = (datetime.now(UTC) - updated).total_seconds()
    except (ValueError, TypeError):
        return False
    return (
        0 <= age <= 5
        and state.get("processId") == process_id
        and state.get("fingerprint") == fingerprint
        and state.get("visible") is True
    )


def wait_product_window(process_id: int, environment: dict[str, str], timeout: float) -> bool:
    home = environment.get("HOME")
    if not home:
        return False
    path = Path(home) / ".local/state/libertix/first-boot-result-ui.json"
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = read_json(path)
        fingerprint = str(state.get("fingerprint", "")) if state else ""
        if re.fullmatch(r"[0-9a-f]{64}", fingerprint) and product_state_is_visible(
            state, process_id, fingerprint
        ):
            return True
        time.sleep(0.1)
    return False


def xprop(environment: dict[str, str], *arguments: str, deadline: float) -> str:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("The X11 focus deadline expired")
    process_environment = os.environ.copy()
    process_environment.update(environment)
    result = subprocess.run(
        ["xprop", *arguments],
        check=False,
        capture_output=True,
        text=True,
        env=process_environment,
        timeout=min(5, remaining),
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "xprop failed")
    return result.stdout.strip()


def find_window(environment: dict[str, str], process_id: int, deadline: float) -> int | None:
    client_list = xprop(environment, "-root", "_NET_CLIENT_LIST", deadline=deadline)
    for hexadecimal in re.findall(r"0x[0-9a-fA-F]+", client_list):
        window = int(hexadecimal, 16)
        properties = xprop(
            environment, "-id", hexadecimal, "_NET_WM_PID", "WM_STATE", deadline=deadline
        )
        pid_match = re.search(r"_NET_WM_PID\([^)]*\) = (\d+)", properties)
        if pid_match and int(pid_match.group(1)) == process_id and "WM_STATE" in properties:
            return window
    return None


def active_window(environment: dict[str, str], deadline: float) -> int | None:
    properties = xprop(environment, "-root", "_NET_ACTIVE_WINDOW", deadline=deadline)
    match = re.search(r"0x[0-9a-fA-F]+", properties)
    return int(match.group(0), 16) if match else None


def request_activation(environment: dict[str, str], window: int) -> None:
    library = ctypes.CDLL("libX11.so.6")
    library.XOpenDisplay.argtypes = [ctypes.c_char_p]
    library.XOpenDisplay.restype = ctypes.c_void_p
    library.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    library.XDefaultRootWindow.restype = ctypes.c_ulong
    library.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    library.XInternAtom.restype = ctypes.c_ulong
    library.XSendEvent.argtypes = [
        ctypes.c_void_p,
        ctypes.c_ulong,
        ctypes.c_int,
        ctypes.c_long,
        ctypes.POINTER(XEvent),
    ]
    library.XSendEvent.restype = ctypes.c_int
    library.XMapRaised.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    library.XSetInputFocus.argtypes = [
        ctypes.c_void_p,
        ctypes.c_ulong,
        ctypes.c_int,
        ctypes.c_ulong,
    ]
    library.XFlush.argtypes = [ctypes.c_void_p]
    library.XCloseDisplay.argtypes = [ctypes.c_void_p]

    old_display = os.environ.get("DISPLAY")
    old_xauthority = os.environ.get("XAUTHORITY")
    os.environ["DISPLAY"] = environment["DISPLAY"]
    os.environ["XAUTHORITY"] = environment["XAUTHORITY"]
    try:
        display = library.XOpenDisplay(environment["DISPLAY"].encode("utf-8"))
        if not display:
            raise RuntimeError("XOpenDisplay failed for the graphical session")
        try:
            root = library.XDefaultRootWindow(display)
            atom = library.XInternAtom(display, b"_NET_ACTIVE_WINDOW", 0)
            event = XEvent()
            event.client_message.type = CLIENT_MESSAGE
            event.client_message.display = display
            event.client_message.window = window
            event.client_message.message_type = atom
            event.client_message.format = 32
            event.client_message.data.l[0] = 2
            event.client_message.data.l[1] = CURRENT_TIME
            library.XMapRaised(display, window)
            library.XSendEvent(
                display,
                root,
                0,
                SUBSTRUCTURE_NOTIFY_MASK | SUBSTRUCTURE_REDIRECT_MASK,
                ctypes.byref(event),
            )
            library.XSetInputFocus(display, window, 1, CURRENT_TIME)
            library.XFlush(display)
        finally:
            library.XCloseDisplay(display)
    finally:
        if old_display is None:
            os.environ.pop("DISPLAY", None)
        else:
            os.environ["DISPLAY"] = old_display
        if old_xauthority is None:
            os.environ.pop("XAUTHORITY", None)
        else:
            os.environ["XAUTHORITY"] = old_xauthority


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--timeout", type=float, default=15)
    parser.add_argument("--ready-timeout", type=float, default=0)
    parser.add_argument("--check-only", action="store_true")
    arguments = parser.parse_args()
    if arguments.pid <= 0 or arguments.timeout <= 0 or arguments.ready_timeout < 0:
        parser.error("--pid and --timeout must be positive; --ready-timeout must be nonnegative")

    environment = read_process_environment(arguments.pid)
    wayland = environment.get("XDG_SESSION_TYPE") == "wayland"
    if arguments.ready_timeout and not arguments.check_only:
        # The product may wait for session localization before creating its dialog.
        # A running autostart process alone is not evidence that a window exists.
        ready = wait_product_window(arguments.pid, environment, arguments.ready_timeout)
        if wayland and not ready:
            raise RuntimeError(
                "The Linux result window did not publish fresh visibility evidence "
                f"within {arguments.ready_timeout} seconds; process_id={arguments.pid}."
            )
    deadline = time.monotonic() + arguments.timeout
    product_active, fingerprint = request_product_activation(
        arguments.pid,
        environment,
        arguments.timeout if wayland else arguments.timeout / 2,
        check_only=arguments.check_only,
    )
    if product_active:
        print(f"PROCESS_ID={arguments.pid}")
        print("WINDOW_ID=product-gtk-dialog")
        print(f"FINGERPRINT={fingerprint}")
        print("ACTIVE_WINDOW_PROVEN=True")
        print("RESULT=OK")
        return 0

    if wayland and fingerprint:
        # Wayland may reject background activation without a user-input token.
        # The controller must switch windows, then prove focus before sending Enter.
        print(f"PROCESS_ID={arguments.pid}")
        print(f"FINGERPRINT={fingerprint}")
        print("ACTIVE_WINDOW_PROVEN=False")
        print("RESULT=NEEDS_USER_ACTIVATION")
        return 0

    last_window: int | None = None
    while time.monotonic() < deadline:
        last_window = find_window(environment, arguments.pid, deadline)
        if last_window is not None:
            request_activation(environment, last_window)
            time.sleep(0.2)
            if active_window(environment, deadline) == last_window:
                print(f"PROCESS_ID={arguments.pid}")
                print(f"WINDOW_ID=0x{last_window:x}")
                print("ACTIVE_WINDOW_PROVEN=True")
                print("RESULT=OK")
                return 0
        time.sleep(0.1)
    raise RuntimeError(
        "The Linux first-boot result window could not be proven active; "
        f"process_id={arguments.pid} last_window={last_window}."
    )


if __name__ == "__main__":
    raise SystemExit(main())
