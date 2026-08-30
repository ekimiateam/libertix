#!/usr/bin/env python3
"""Apply one validated Windows preference bundle to the installed target."""

from __future__ import annotations

import argparse
import base64
import configparser
import contextlib
import hashlib
import json
import os
import pwd
import re
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path
from typing import Any

BUNDLE_SCHEMA_VERSION = 1
MAXIMUM_BUNDLE_BYTES = 128 * 1024 * 1024
MAXIMUM_WIFI_PROFILES = 256
HEX_ID_PATTERN = re.compile(r"^[0-9a-f]{32}$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
SAFE_USERNAME_PATTERN = re.compile(r"^[a-z](?:[a-z0-9-]{0,30}[a-z0-9])?$")
SUPPORTED_ASSET_SUFFIXES = frozenset({".jpg", ".png", ".bmp", ".gif", ".webp", ".tif", ".tiff"})


class PreferenceMigrationError(ValueError):
    pass


def require_mapping(value: Any, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise PreferenceMigrationError(f"{name} must be an object")
    return value


def require_bool(value: Any, name: str) -> bool:
    if not isinstance(value, bool):
        raise PreferenceMigrationError(f"{name} must be a boolean")
    return value


def require_optional_bool(value: Any, name: str) -> bool | None:
    if value is None:
        return None
    return require_bool(value, name)


def require_optional_uint(value: Any, name: str) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < 0 or value > 0xFFFFFFFF:
        raise PreferenceMigrationError(f"{name} must be an unsigned 32-bit integer")
    return value


def read_bundle(path: Path, expected_plan_id: str, expected_wifi_count: int) -> dict[str, Any]:
    try:
        size = path.stat().st_size
        if size <= 0 or size > MAXIMUM_BUNDLE_BYTES:
            raise PreferenceMigrationError("preference bundle size is invalid")
        bundle = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PreferenceMigrationError("preference bundle cannot be read") from error

    root = require_mapping(bundle, "bundle")
    if set(root) != {"schemaVersion", "planId", "preferences", "wifiProfiles"}:
        raise PreferenceMigrationError("preference bundle contains unsupported fields")
    if root.get("schemaVersion") != BUNDLE_SCHEMA_VERSION:
        raise PreferenceMigrationError("preference bundle schemaVersion is unsupported")
    if root.get("planId") != expected_plan_id or not HEX_ID_PATTERN.fullmatch(expected_plan_id):
        raise PreferenceMigrationError("preference bundle planId does not match the installation")
    profiles = root.get("wifiProfiles")
    if not isinstance(profiles, list) or len(profiles) > MAXIMUM_WIFI_PROFILES:
        raise PreferenceMigrationError("preference bundle Wi-Fi profile list is invalid")
    if len(profiles) != expected_wifi_count:
        raise PreferenceMigrationError(
            "preference bundle Wi-Fi profile count does not match the plan"
        )
    require_mapping(root.get("preferences"), "preferences")
    return root


def decode_asset(value: Any, name: str, maximum_bytes: int) -> tuple[str, bytes] | None:
    if value is None:
        return None
    asset = require_mapping(value, name)
    if set(asset) != {"fileName", "sha256", "contentBase64"}:
        raise PreferenceMigrationError(f"{name} contains unsupported fields")
    file_name = asset.get("fileName")
    expected_hash = asset.get("sha256")
    encoded = asset.get("contentBase64")
    if not isinstance(file_name, str) or Path(file_name).name != file_name:
        raise PreferenceMigrationError(f"{name}.fileName is invalid")
    suffix = Path(file_name).suffix.lower()
    if suffix not in SUPPORTED_ASSET_SUFFIXES:
        raise PreferenceMigrationError(f"{name}.fileName has an unsupported image type")
    if not isinstance(expected_hash, str) or not SHA256_PATTERN.fullmatch(expected_hash):
        raise PreferenceMigrationError(f"{name}.sha256 is invalid")
    if not isinstance(encoded, str):
        raise PreferenceMigrationError(f"{name}.contentBase64 is invalid")
    try:
        content = base64.b64decode(encoded, validate=True)
    except ValueError as error:
        raise PreferenceMigrationError(f"{name}.contentBase64 is invalid") from error
    if not content or len(content) > maximum_bytes:
        raise PreferenceMigrationError(f"{name} size is invalid")
    if hashlib.sha256(content).hexdigest() != expected_hash:
        raise PreferenceMigrationError(f"{name} hash verification failed")
    return suffix, content


def atomic_write(path: Path, content: bytes, mode: int, uid: int = 0, gid: int = 0) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.chown(temporary, uid, gid)
        os.replace(temporary, path)
        directory_descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        with contextlib.suppress(FileNotFoundError):
            temporary.unlink()


def install_assets(preferences: dict[str, Any], username: str) -> tuple[Path | None, bool]:
    account = pwd.getpwnam(username)
    home = Path(account.pw_dir)
    if not home.is_absolute() or not home.is_dir():
        raise PreferenceMigrationError("the Linux user home directory is invalid")

    wallpaper = decode_asset(
        preferences.get("wallpaper"),
        "preferences.wallpaper",
        64 * 1024 * 1024,
    )
    wallpaper_path: Path | None = None
    if wallpaper is not None:
        suffix, content = wallpaper
        wallpaper_path = home / "Pictures" / "Libertix" / f"windows-wallpaper{suffix}"
        atomic_write(wallpaper_path, content, 0o644, account.pw_uid, account.pw_gid)

    account_image = decode_asset(
        preferences.get("accountImage"),
        "preferences.accountImage",
        16 * 1024 * 1024,
    )
    if account_image is None:
        return wallpaper_path, False

    _, content = account_image
    face_path = home / ".face"
    atomic_write(face_path, content, 0o644, account.pw_uid, account.pw_gid)
    icon_path = Path("/var/lib/AccountsService/icons") / username
    atomic_write(icon_path, content, 0o644)

    user_path = Path("/var/lib/AccountsService/users") / username
    configuration = configparser.ConfigParser(interpolation=None)
    configuration.optionxform = str
    if user_path.exists():
        try:
            configuration.read(user_path, encoding="utf-8")
        except (OSError, configparser.Error) as error:
            raise PreferenceMigrationError("the AccountsService user record is invalid") from error
    if not configuration.has_section("User"):
        configuration.add_section("User")
    configuration.set("User", "Icon", str(icon_path))
    from io import StringIO

    output = StringIO()
    configuration.write(output, space_around_delimiters=False)
    atomic_write(user_path, output.getvalue().encode("utf-8"), 0o600)
    return wallpaper_path, True


def validate_desktop_preferences(preferences: dict[str, Any]) -> dict[str, Any]:
    allowed = {
        "wallpaper",
        "darkMode",
        "accountImage",
        "autoLockAfterInactivity",
        "autoLockTimeoutSeconds",
        "lockOnWakeAc",
        "lockOnWakeBattery",
        "screenTimeoutAcSeconds",
        "screenTimeoutBatterySeconds",
        "sleepTimeoutAcSeconds",
        "sleepTimeoutBatterySeconds",
        "lidCloseActionAc",
        "lidCloseActionBattery",
        "primaryMouseButton",
        "mouseNaturalScroll",
        "touchpadNaturalScroll",
        "touchpadTapToClick",
        "keyboardRepeatDelayMilliseconds",
        "keyboardRepeatIntervalMilliseconds",
    }
    unexpected = set(preferences) - allowed
    if unexpected:
        raise PreferenceMigrationError("preferences contains unsupported fields")

    normalized = dict(preferences)
    normalized["darkMode"] = require_optional_bool(preferences.get("darkMode"), "darkMode")
    normalized["autoLockAfterInactivity"] = require_bool(
        preferences.get("autoLockAfterInactivity"),
        "autoLockAfterInactivity",
    )
    for name in (
        "lockOnWakeAc",
        "lockOnWakeBattery",
        "mouseNaturalScroll",
        "touchpadNaturalScroll",
        "touchpadTapToClick",
    ):
        normalized[name] = require_optional_bool(preferences.get(name), name)
    for name in (
        "autoLockTimeoutSeconds",
        "screenTimeoutAcSeconds",
        "screenTimeoutBatterySeconds",
        "sleepTimeoutAcSeconds",
        "sleepTimeoutBatterySeconds",
        "keyboardRepeatDelayMilliseconds",
        "keyboardRepeatIntervalMilliseconds",
    ):
        normalized[name] = require_optional_uint(preferences.get(name), name)
    for name in ("lidCloseActionAc", "lidCloseActionBattery"):
        value = preferences.get(name)
        if value is not None and value not in {"nothing", "suspend", "hibernate", "shutdown"}:
            raise PreferenceMigrationError(f"{name} is invalid")
        normalized[name] = value
    if preferences.get("primaryMouseButton") not in {"left", "right"}:
        raise PreferenceMigrationError("primaryMouseButton is invalid")
    return normalized


def gsettings_keys(schema: str) -> set[str]:
    result = subprocess.run(
        ["gsettings", "list-keys", schema],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode != 0:
        return set()
    return {line.strip() for line in result.stdout.splitlines() if line.strip()}


def variant(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    raise PreferenceMigrationError("unsupported GSettings value type")


def set_gsetting(schema: str, key: str, value: Any) -> bool:
    if key not in gsettings_keys(schema):
        return False
    result = subprocess.run(
        ["gsettings", "set", schema, key, variant(value)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise PreferenceMigrationError(f"GSettings rejected {schema}.{key}")
    return True


def set_for_desktops(suffix: str, key: str, value: Any) -> int:
    applied = 0
    for prefix in ("org.gnome", "org.cinnamon"):
        applied += int(set_gsetting(f"{prefix}.{suffix}", key, value))
    return applied


def apply_desktop_preferences(
    preferences_path: Path,
    wallpaper_uri: str | None,
    themes_root: Path = Path("/usr/share/themes"),
) -> int:
    try:
        preferences = validate_desktop_preferences(
            require_mapping(json.loads(preferences_path.read_text(encoding="utf-8")), "preferences")
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PreferenceMigrationError("desktop preference handoff is invalid") from error

    applied = 0
    if wallpaper_uri is not None:
        applied += set_for_desktops("desktop.background", "picture-uri", wallpaper_uri)
        applied += int(
            set_gsetting("org.gnome.desktop.background", "picture-uri-dark", wallpaper_uri)
        )

    dark_mode = preferences.get("darkMode")
    if dark_mode is not None:
        applied += int(
            set_gsetting(
                "org.gnome.desktop.interface",
                "color-scheme",
                "prefer-dark" if dark_mode else "default",
            )
        )
        cinnamon_theme = "Mint-Y-Dark" if dark_mode else "Mint-Y"
        if (themes_root / cinnamon_theme).is_dir():
            applied += int(
                set_gsetting("org.cinnamon.desktop.interface", "gtk-theme", cinnamon_theme)
            )
            applied += int(set_gsetting("org.cinnamon.theme", "name", cinnamon_theme))

    auto_lock = preferences["autoLockAfterInactivity"]
    applied += set_for_desktops("desktop.screensaver", "lock-enabled", auto_lock)
    applied += set_for_desktops("desktop.screensaver", "idle-activation-enabled", auto_lock)
    if auto_lock:
        timeout = preferences.get("autoLockTimeoutSeconds")
        if timeout is not None:
            applied += set_for_desktops("desktop.session", "idle-delay", timeout)
        applied += set_for_desktops("desktop.screensaver", "lock-delay", 0)

    lock_ac = preferences.get("lockOnWakeAc")
    lock_battery = preferences.get("lockOnWakeBattery")
    if lock_ac is not None and lock_ac == lock_battery:
        applied += int(
            set_gsetting("org.gnome.desktop.screensaver", "ubuntu-lock-on-suspend", lock_ac)
        )
        applied += int(
            set_gsetting(
                "org.cinnamon.settings-daemon.plugins.power",
                "lock-on-suspend",
                lock_ac,
            )
        )

    for source_name, key in (
        ("screenTimeoutAcSeconds", "sleep-display-ac"),
        ("screenTimeoutBatterySeconds", "sleep-display-battery"),
    ):
        value = preferences.get(source_name)
        if value is not None:
            applied += set_for_desktops("settings-daemon.plugins.power", key, value)

    for suffix, source_name in (
        ("ac", "sleepTimeoutAcSeconds"),
        ("battery", "sleepTimeoutBatterySeconds"),
    ):
        value = preferences.get(source_name)
        if value is not None:
            applied += set_for_desktops(
                "settings-daemon.plugins.power",
                f"sleep-inactive-{suffix}-timeout",
                value,
            )
            applied += set_for_desktops(
                "settings-daemon.plugins.power",
                f"sleep-inactive-{suffix}-type",
                "nothing" if value == 0 else "suspend",
            )

    for suffix, source_name in (
        ("ac", "lidCloseActionAc"),
        ("battery", "lidCloseActionBattery"),
    ):
        value = preferences.get(source_name)
        if value is not None:
            applied += set_for_desktops(
                "settings-daemon.plugins.power",
                f"lid-close-{suffix}-action",
                value,
            )

    applied += set_for_desktops(
        "desktop.peripherals.mouse",
        "left-handed",
        preferences["primaryMouseButton"] == "right",
    )
    for suffix, source_name, key in (
        ("mouse", "mouseNaturalScroll", "natural-scroll"),
        ("touchpad", "touchpadNaturalScroll", "natural-scroll"),
        ("touchpad", "touchpadTapToClick", "tap-to-click"),
    ):
        value = preferences.get(source_name)
        if value is not None:
            applied += set_for_desktops(f"desktop.peripherals.{suffix}", key, value)

    for source_name, key in (
        ("keyboardRepeatDelayMilliseconds", "delay"),
        ("keyboardRepeatIntervalMilliseconds", "repeat-interval"),
    ):
        value = preferences.get(source_name)
        if value is not None:
            applied += set_for_desktops("desktop.peripherals.keyboard", key, value)
    return applied


def keyfile_escape(value: str) -> str:
    escaped = (
        value.replace("\\", "\\\\").replace("\t", "\\t").replace("\r", "\\r").replace("\n", "\\n")
    )
    while escaped.startswith(" "):
        escaped = "\\s" + escaped[1:]
    while escaped.endswith(" "):
        escaped = escaped[:-1] + "\\s"
    return escaped


def validate_wifi_profile(value: Any, index: int) -> dict[str, Any]:
    profile = require_mapping(value, f"wifiProfiles[{index}]")
    allowed = {"id", "ssid", "security", "secret", "hidden", "autoConnect"}
    if set(profile) - allowed:
        raise PreferenceMigrationError(f"wifiProfiles[{index}] contains unsupported fields")
    identifier = profile.get("id")
    ssid = profile.get("ssid")
    security = profile.get("security")
    if (
        not isinstance(identifier, str)
        or not identifier
        or any(char in identifier for char in "\r\n\0")
    ):
        raise PreferenceMigrationError(f"wifiProfiles[{index}].id is invalid")
    if not isinstance(ssid, str) or not ssid or len(ssid.encode("utf-8")) > 32 or "\0" in ssid:
        raise PreferenceMigrationError(f"wifiProfiles[{index}].ssid is invalid")
    if security not in {"open", "owe", "wpa-psk", "sae"}:
        raise PreferenceMigrationError(f"wifiProfiles[{index}].security is unsupported")
    secret = profile.get("secret")
    if security in {"open", "owe"}:
        if secret is not None:
            raise PreferenceMigrationError(f"wifiProfiles[{index}] open network has a secret")
    elif (
        not isinstance(secret, str)
        or any(char in secret for char in "\r\n\0")
        or (
            security == "wpa-psk"
            and not (
                8 <= len(secret) <= 63
                or (len(secret) == 64 and all(char in "0123456789abcdefABCDEF" for char in secret))
            )
        )
        or (security == "sae" and not (1 <= len(secret) <= 63))
    ):
        raise PreferenceMigrationError(f"wifiProfiles[{index}].secret is invalid")
    require_bool(profile.get("hidden"), f"wifiProfiles[{index}].hidden")
    require_bool(profile.get("autoConnect"), f"wifiProfiles[{index}].autoConnect")
    return profile


def install_wifi_profiles(
    values: list[Any],
    destination: Path = Path("/etc/NetworkManager/system-connections"),
    uid: int = 0,
    gid: int = 0,
) -> int:
    destination.mkdir(parents=True, exist_ok=True)
    identities: set[tuple[str, str]] = set()
    for index, value in enumerate(values):
        profile = validate_wifi_profile(value, index)
        identity = (profile["ssid"], profile["security"])
        if identity in identities:
            raise PreferenceMigrationError("preference bundle contains duplicate Wi-Fi identities")
        identities.add(identity)

        connection_uuid = uuid.uuid5(
            uuid.NAMESPACE_URL,
            f"https://ekimia.fr/libertix/wifi/{profile['security']}/{profile['ssid']}",
        )
        ssid_bytes = profile["ssid"].encode("utf-8")
        lines = [
            "[connection]",
            f"id={keyfile_escape(profile['id'])}",
            f"uuid={connection_uuid}",
            "type=wifi",
            f"autoconnect={'true' if profile['autoConnect'] else 'false'}",
            "",
            "[wifi]",
            "mode=infrastructure",
            "ssid=" + ";".join(str(byte) for byte in ssid_bytes) + ";",
            f"hidden={'true' if profile['hidden'] else 'false'}",
            "",
        ]
        if profile["security"] == "owe":
            lines.extend(["[wifi-security]", "key-mgmt=owe", ""])
        elif profile["security"] != "open":
            lines.extend(
                [
                    "[wifi-security]",
                    f"key-mgmt={profile['security']}",
                    f"psk={keyfile_escape(profile['secret'])}",
                    "",
                ]
            )
        lines.extend(["[ipv4]", "method=auto", "", "[ipv6]", "method=auto", ""])
        file_name = hashlib.sha256(
            (profile["security"] + "\0" + profile["ssid"]).encode("utf-8")
        ).hexdigest()[:20]
        atomic_write(
            destination / f"libertix-{file_name}.nmconnection",
            "\n".join(lines).encode("utf-8"),
            0o600,
            uid,
            gid,
        )
    return len(values)


def apply_bundle(args: argparse.Namespace) -> int:
    if not SAFE_USERNAME_PATTERN.fullmatch(args.username):
        raise PreferenceMigrationError("Linux username is invalid")
    bundle = read_bundle(args.bundle, args.plan_id, args.wifi_profile_count)
    preferences = validate_desktop_preferences(bundle["preferences"])
    wallpaper_path, _ = install_assets(bundle["preferences"], args.username)
    wifi_count = install_wifi_profiles(bundle["wifiProfiles"])

    account = pwd.getpwnam(args.username)
    desktop_handoff = Path("/tmp/libertix-desktop-preferences.json")
    atomic_write(
        desktop_handoff,
        json.dumps(preferences, ensure_ascii=False, separators=(",", ":")).encode("utf-8"),
        0o600,
        account.pw_uid,
        account.pw_gid,
    )
    try:
        command = [
            "runuser",
            "-u",
            args.username,
            "--",
            "env",
            f"HOME={account.pw_dir}",
            "dbus-run-session",
            "--",
            sys.executable,
            str(Path(__file__).resolve()),
            "apply-desktop",
            str(desktop_handoff),
        ]
        if wallpaper_path is not None:
            command.extend(["--wallpaper-uri", wallpaper_path.as_uri()])
        result = subprocess.run(command, check=False)
        if result.returncode != 0:
            raise PreferenceMigrationError("desktop preferences could not be applied")
    finally:
        with contextlib.suppress(FileNotFoundError):
            desktop_handoff.unlink()
    print(f"Windows preference migration applied: wifi_profiles={wifi_count}")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    apply_parser = subparsers.add_parser("apply")
    apply_parser.add_argument("bundle", type=Path)
    apply_parser.add_argument("plan_id")
    apply_parser.add_argument("username")
    apply_parser.add_argument("wifi_profile_count", type=int)
    desktop_parser = subparsers.add_parser("apply-desktop")
    desktop_parser.add_argument("preferences", type=Path)
    desktop_parser.add_argument("--wallpaper-uri")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.command == "apply":
        return apply_bundle(args)
    applied = apply_desktop_preferences(args.preferences, args.wallpaper_uri)
    print(f"Windows desktop preferences applied: settings={applied}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (PreferenceMigrationError, KeyError) as error:
        print(f"Windows preference migration failed: {error}", file=sys.stderr)
        raise SystemExit(2) from error
