#!/usr/bin/env python3
"""Focus the Linux first-boot result using only X11 session contracts."""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import re
import subprocess
import time
import uuid
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
    required = ("DISPLAY", "XAUTHORITY")
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
            and isinstance(ui_state.get("fingerprint"), str)
        ):
            fingerprint = str(ui_state["fingerprint"])
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
        if (
            ui_state
            and ui_state.get("processId") == process_id
            and ui_state.get("fingerprint") == fingerprint
            and ui_state.get("visible") is True
            and ui_state.get("active") is True
        ):
            return True, fingerprint
        time.sleep(0.1)
    return False, fingerprint


def xprop(environment: dict[str, str], *arguments: str) -> str:
    process_environment = os.environ.copy()
    process_environment.update(environment)
    result = subprocess.run(
        ["xprop", *arguments],
        check=False,
        capture_output=True,
        text=True,
        env=process_environment,
        timeout=5,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "xprop failed")
    return result.stdout.strip()


def find_window(environment: dict[str, str], process_id: int) -> int | None:
    client_list = xprop(environment, "-root", "_NET_CLIENT_LIST")
    for hexadecimal in re.findall(r"0x[0-9a-fA-F]+", client_list):
        window = int(hexadecimal, 16)
        properties = xprop(environment, "-id", hexadecimal, "_NET_WM_PID", "WM_STATE")
        pid_match = re.search(r"_NET_WM_PID\([^)]*\) = (\d+)", properties)
        if pid_match and int(pid_match.group(1)) == process_id and "WM_STATE" in properties:
            return window
    return None


def active_window(environment: dict[str, str]) -> int | None:
    properties = xprop(environment, "-root", "_NET_ACTIVE_WINDOW")
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
    arguments = parser.parse_args()
    if arguments.pid <= 0 or arguments.timeout <= 0:
        parser.error("--pid and --timeout must be positive")

    environment = read_process_environment(arguments.pid)
    product_active, fingerprint = request_product_activation(
        arguments.pid,
        environment,
        arguments.timeout,
    )
    if product_active:
        print(f"PROCESS_ID={arguments.pid}")
        print("WINDOW_ID=product-gtk-dialog")
        print(f"FINGERPRINT={fingerprint}")
        print("ACTIVE_WINDOW_PROVEN=True")
        print("RESULT=OK")
        return 0

    deadline = time.monotonic() + arguments.timeout
    last_window: int | None = None
    while time.monotonic() < deadline:
        last_window = find_window(environment, arguments.pid)
        if last_window is not None:
            request_activation(environment, last_window)
            time.sleep(0.2)
            if active_window(environment) == last_window:
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
