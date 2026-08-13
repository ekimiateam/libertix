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

TRANSLATIONS = {
    "en": {
        "success_title": "Libertix installation verified",
        "success": (
            "Linux started through the installed Libertix boot chain. The ext4 root, "
            "account, packages, services, GRUB, running kernel and Windows handoff "
            "evidence were verified successfully."
        ),
        "failure_title": "Libertix verification failed",
        "failure": "The installed system could not be fully verified.",
        "log": "Detailed log",
    },
    "fr": {
        "success_title": "Installation Libertix vérifiée",
        "success": (
            "Linux a démarré via la chaîne de démarrage Libertix installée. La racine "
            "ext4, le compte, les paquets, les services, GRUB, le noyau actif et la "
            "preuve transmise à Windows ont été vérifiés avec succès."
        ),
        "failure_title": "Échec de la vérification Libertix",
        "failure": "Le système installé n’a pas pu être entièrement vérifié.",
        "log": "Journal détaillé",
    },
    "es": {
        "success_title": "Instalación de Libertix verificada",
        "success": (
            "Linux se inició mediante la cadena de arranque Libertix instalada. Se "
            "verificaron correctamente la raíz ext4, la cuenta, los paquetes, los "
            "servicios, GRUB, el núcleo activo y la prueba enviada a Windows."
        ),
        "failure_title": "Falló la verificación de Libertix",
        "failure": "No se pudo verificar completamente el sistema instalado.",
        "log": "Registro detallado",
    },
    "ja": {
        "success_title": "Libertix インストールの検証完了",
        "success": (
            "インストール済みの Libertix ブートチェーンから Linux が起動しました。"
            "ext4 ルート、アカウント、パッケージ、サービス、GRUB、実行中のカーネル、"
            "Windows への証明を正常に検証しました。"
        ),
        "failure_title": "Libertix の検証に失敗しました",
        "failure": "インストール済みシステムを完全には検証できませんでした。",
        "log": "詳細ログ",
    },
}


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


def show_gtk_dialog(title: str, message: str, failed: bool) -> bool:
    try:
        gi = importlib.import_module("gi")
        gi.require_version("Gtk", "3.0")
        gtk = importlib.import_module("gi.repository.Gtk")
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
        dialog.run()
        dialog.destroy()
        while gtk.events_pending():
            gtk.main_iteration()
    except Exception:
        return False
    return True


def show_dialog(title: str, message: str, failed: bool) -> bool:
    if show_gtk_dialog(title, message, failed):
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
    text = TRANSLATIONS.get(str(language), TRANSLATIONS["en"])
    failed = status.get("status") == "failed"
    title = text["failure_title"] if failed else text["success_title"]
    message = text["failure"] if failed else text["success"]
    if failed and status.get("error"):
        message += f"\n\n{status['error']}"
    message += f"\n\n{text['log']}: {status.get('logPath', '')}"
    time.sleep(SESSION_SETTLE_SECONDS)
    if not show_dialog(title, message, failed):
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
