#!/usr/bin/env python3
"""Show the durable Libertix first-boot verification result once per update."""

from __future__ import annotations

import hashlib
import importlib
import json
import os
import pwd
import shutil
import subprocess
import time
from datetime import UTC, datetime
from pathlib import Path

PLAN_PATH = Path("/etc/libertix/installation-plan.json")
STATUS_PATH = Path("/var/lib/libertix/first-boot-verification.json")
WAIT_SECONDS = 600
SESSION_SETTLE_SECONDS = 10
SESSION_LOCALIZATION_WAIT_SECONDS = 60


def resolve_translation_catalogue_path() -> Path:
    adjacent = Path(__file__).with_name("Libertix.Translations.json")
    source_tree = Path(__file__).resolve().parents[2] / "Resources/Libertix.Translations.json"
    return adjacent if adjacent.is_file() else source_tree


TRANSLATION_CATALOGUE_PATH = resolve_translation_catalogue_path()


def load_translations(language: object) -> dict[str, str]:
    catalogue = json.loads(TRANSLATION_CATALOGUE_PATH.read_text(encoding="utf-8"))
    supported = catalogue["supportedLanguages"]
    selected = str(language) if str(language) in supported else "en"
    translations = catalogue["languages"][selected]["firstBoot"]
    fallback = catalogue["languages"]["en"]["firstBoot"]
    return {key: translations.get(key, value) for key, value in fallback.items()}


def read_json(path: Path) -> dict[str, object] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def write_json_atomic(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.parent / f".{path.name}.{os.getpid()}.tmp"
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def status_fingerprint(status: dict[str, object]) -> str:
    fields = {
        "planId": status.get("planId"),
        "status": status.get("status"),
        "updatedAtUtc": status.get("updatedAtUtc"),
        "error": status.get("error"),
    }
    return hashlib.sha256(json.dumps(fields, sort_keys=True).encode("utf-8")).hexdigest()


def show_gtk_dialog(
    title: str,
    message: str,
    failed: bool,
    state_root: Path | None = None,
    fingerprint: str | None = None,
    development_mode: bool = False,
) -> bool:
    try:
        gi = importlib.import_module("gi")
        gi.require_version("Gtk", "3.0")
        gtk = importlib.import_module("gi.repository.Gtk")
        glib = importlib.import_module("gi.repository.GLib")
    except (ImportError, ValueError):
        return False

    try:
        dialog = gtk.MessageDialog(
            transient_for=None,
            flags=gtk.DialogFlags.MODAL,
            message_type=gtk.MessageType.ERROR if failed else gtk.MessageType.INFO,
            buttons=gtk.ButtonsType.OK,
            text=title,
        )
        dialog.format_secondary_text(message)
        dialog.set_title(title)
        dialog.set_default_size(640, -1)
        dialog.set_keep_above(True)
        dialog.set_urgency_hint(True)
        dialog.set_position(gtk.WindowPosition.CENTER)
        dialog.stick()
        dialog.show_all()
        dialog.present()

        ui_state_path = state_root / "first-boot-result-ui.json" if state_root else None
        activation_request_path = (
            state_root / "first-boot-result-activate.json" if state_root else None
        )
        last_activation_request = ""

        def publish_ui_state() -> None:
            if ui_state_path is None:
                return
            write_json_atomic(
                ui_state_path,
                {
                    "schemaVersion": 1,
                    "processId": os.getpid(),
                    "fingerprint": fingerprint,
                    "visible": bool(dialog.get_visible()),
                    "active": bool(dialog.is_active()),
                    "title": title,
                    "updatedAtUtc": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
                },
            )

        def process_development_activation() -> bool:
            nonlocal last_activation_request
            if not development_mode or activation_request_path is None:
                publish_ui_state()
                return True
            request = read_json(activation_request_path)
            request_id = str(request.get("requestId", "")) if request else ""
            if (
                request
                and request.get("fingerprint") == fingerprint
                and request_id
                and request_id != last_activation_request
            ):
                last_activation_request = request_id
                dialog.present()
            publish_ui_state()
            return True

        publish_ui_state()
        glib.timeout_add(200, process_development_activation)

        def present_after_desktop_startup() -> bool:
            if dialog.get_visible():
                dialog.present()
            return False

        # Distribution welcome applications can open after this autostart entry
        # and otherwise cover the verification result. Re-present once after the
        # desktop has settled without repeatedly stealing focus from the user.
        glib.timeout_add_seconds(5, present_after_desktop_startup)
        dialog.run()
        if ui_state_path is not None:
            write_json_atomic(
                ui_state_path,
                {
                    "schemaVersion": 1,
                    "processId": os.getpid(),
                    "fingerprint": fingerprint,
                    "visible": False,
                    "active": False,
                    "title": title,
                    "updatedAtUtc": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
                },
            )
        dialog.destroy()
        while gtk.events_pending():
            gtk.main_iteration()
    except Exception:
        return False
    return True


def show_dialog(
    title: str,
    message: str,
    failed: bool,
    state_root: Path | None = None,
    fingerprint: str | None = None,
    development_mode: bool = False,
) -> bool:
    if state_root is None:
        gtk_shown = show_gtk_dialog(title, message, failed)
    else:
        gtk_shown = show_gtk_dialog(
            title,
            message,
            failed,
            state_root,
            fingerprint,
            development_mode,
        )
    if gtk_shown:
        return True

    commands: list[list[str]] = []
    if shutil.which("zenity"):
        commands.append(
            [
                "zenity",
                "--error" if failed else "--info",
                "--no-markup",
                "--width=640",
                "--title",
                title,
                "--text",
                message,
            ]
        )
    if shutil.which("yad"):
        commands.append(
            [
                "yad",
                "--error" if failed else "--info",
                "--width=640",
                "--title",
                title,
                "--text",
                message,
            ]
        )
    if shutil.which("kdialog"):
        commands.append(["kdialog", "--error" if failed else "--msgbox", message, "--title", title])
    if shutil.which("xmessage"):
        commands.append(["xmessage", "-center", "-title", title, message])
    if shutil.which("notify-send"):
        commands.append(
            [
                "notify-send",
                "--urgency=critical" if failed else "--urgency=normal",
                title,
                message,
            ]
        )
    for command in commands:
        result = subprocess.run(command, check=False)
        if result.returncode == 0:
            return True
    return False


def wait_for_session_localization(plan: dict[str, object]) -> str | None:
    locale = plan.get("locale")
    if not isinstance(locale, dict):
        return "The installation plan has no localization configuration."
    expected_language = locale.get("systemLanguage")
    expected_layout = locale.get("keyboardLayout")
    expected_variant = locale.get("keyboardVariant", "")
    if not all(
        isinstance(value, str) for value in (expected_language, expected_layout, expected_variant)
    ):
        return "The installation plan localization configuration is invalid."

    expected_source = expected_layout
    if expected_variant:
        expected_source += "+" + expected_variant
    marker_path = Path.home() / ".config" / "libertix" / "keyboard-initialized.json"
    deadline = time.monotonic() + SESSION_LOCALIZATION_WAIT_SECONDS
    marker = read_json(marker_path)
    while marker is None and time.monotonic() < deadline:
        time.sleep(1)
        marker = read_json(marker_path)
    if marker is None:
        return "The desktop keyboard initialization proof is missing."

    expected_values = {
        "status": "succeeded",
        "sessionLanguage": expected_language,
        "configuredLanguage": expected_language,
        "layout": expected_layout,
        "variant": expected_variant,
        "desktopSource": expected_source,
    }
    for name, expected_value in expected_values.items():
        if marker.get(name) != expected_value:
            return f"The desktop localization proof differs from the installation plan: {name}."
    return None


def main() -> int:
    if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        return 0
    plan = read_json(PLAN_PATH)
    if plan is None:
        return 0
    account = plan.get("account")
    if not isinstance(account, dict):
        return 0
    if account.get("username") != pwd.getpwuid(os.getuid()).pw_name:
        return 0

    deadline = time.monotonic() + WAIT_SECONDS
    status = read_json(STATUS_PATH)
    while status is None and time.monotonic() < deadline:
        time.sleep(2)
        status = read_json(STATUS_PATH)
    if status is None or status.get("status") not in ("succeeded", "failed"):
        return 0
    if status.get("planId") != plan.get("planId"):
        return 0

    state_root = Path.home() / ".local" / "state" / "libertix"
    acknowledgement_path = state_root / "first-boot-result-ack.json"
    fingerprint = status_fingerprint(status)
    acknowledgement = read_json(acknowledgement_path)
    if acknowledgement and acknowledgement.get("fingerprint") == fingerprint:
        return 0

    locale = plan.get("locale")
    language = locale.get("languageCode") if isinstance(locale, dict) else "en"
    text = load_translations(language)
    failed = status.get("status") == "failed"
    session_localization_error = None
    if not failed:
        session_localization_error = wait_for_session_localization(plan)
        failed = session_localization_error is not None
    title = text["failure_title"] if failed else text["success_title"]
    message = text["failure"] if failed else text["success"]
    if failed and status.get("error"):
        message += f"\n\n{status['error']}"
    if session_localization_error:
        message += f"\n\n{session_localization_error}"
    message += f"\n\n{text['log']}: {status.get('logPath', '')}"
    time.sleep(SESSION_SETTLE_SECONDS)
    if not show_dialog(
        title,
        message,
        failed,
        state_root,
        fingerprint,
        Path("/var/lib/libertix/development-ssh-ready").is_file(),
    ):
        return 0

    # A missing or mismatched session proof can be repaired by the desktop
    # initializer on a later login. Do not acknowledge that transient failure,
    # otherwise the later successful state would never be shown to the user.
    if session_localization_error:
        return 0

    write_json_atomic(
        acknowledgement_path,
        {
            "schemaVersion": 1,
            "fingerprint": fingerprint,
            "acknowledgedAtUtc": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
        },
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
