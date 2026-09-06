#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path


def fail(message: str) -> None:
    raise RuntimeError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def gsettings_get(schema: str, key: str) -> str:
    result = subprocess.run(
        ["gsettings", "get", schema, key],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        fail(f"GSettings value is unavailable: {schema}.{key}")
    return result.stdout.strip()


def expect_gsetting(schema: str, key: str, expected: str) -> None:
    observed = gsettings_get(schema, key)
    if observed != expected:
        fail(f"GSettings mismatch for {schema}.{key}: expected {expected}, got {observed}")


def verify_user_asset(path: Path, expected_hash: str) -> None:
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid():
        fail("a migrated image is not a regular file owned by the installed user")
    if sha256(path) != expected_hash:
        fail("a migrated image has the wrong hash")
    verify_image_decodes(path)


def verify_image_decodes(path: Path) -> None:
    import gi

    gi.require_version("GdkPixbuf", "2.0")
    from gi.repository import GdkPixbuf

    # Use the desktop image decoder, not just the header or the transport hash.
    image = GdkPixbuf.Pixbuf.new_from_file(str(path))
    if image.get_width() != 1280 or image.get_height() != 720:
        fail("a migrated fixture image has unexpected dimensions")
    pixels = image.get_pixels()
    channels = image.get_n_channels()
    stride = image.get_rowstride()
    if (
        pixels[100 * stride + 100 * channels + 2] < 150
        or pixels[160 * stride + 1040 * channels] < 200
    ):
        fail("a migrated fixture image did not decode with the expected colors")


def verify_wallpaper(home: Path, prefix: str, expected_hash: str) -> None:
    for directory in (home / "Pictures", home / "Pictures" / "Libertix"):
        metadata = directory.lstat()
        if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid():
            fail("a migrated wallpaper directory is not owned by the installed user")
    wallpapers = list((home / "Pictures" / "Libertix").glob("windows-wallpaper.*"))
    if len(wallpapers) != 1:
        fail("the migrated wallpaper is absent or ambiguous")
    verify_user_asset(wallpapers[0], expected_hash)
    uri = "'" + wallpapers[0].as_uri() + "'"
    expect_gsetting(f"{prefix}.desktop.background", "picture-uri", uri)
    if prefix == "org.gnome":
        expect_gsetting(f"{prefix}.desktop.background", "picture-uri-dark", uri)


def run_checks(args: argparse.Namespace) -> None:
    home = Path.home()
    prefix = "org.cinnamon" if args.distribution == "mint" else "org.gnome"
    verify_wallpaper(home, prefix, args.wallpaper_sha256)
    face = home / ".face"
    verify_user_asset(face, args.account_image_sha256)
    account_icon = Path("/var/lib/AccountsService/icons") / args.username
    if not account_icon.is_file() or sha256(account_icon) != args.account_image_sha256:
        fail("the AccountsService image is missing or has the wrong hash")

    expect_gsetting(f"{prefix}.desktop.screensaver", "lock-enabled", "true")
    expect_gsetting(f"{prefix}.desktop.session", "idle-delay", "uint32 420")
    expect_gsetting(f"{prefix}.desktop.peripherals.mouse", "left-handed", "false")
    expect_gsetting(f"{prefix}.desktop.peripherals.touchpad", "natural-scroll", "true")
    expect_gsetting(f"{prefix}.desktop.peripherals.touchpad", "tap-to-click", "true")
    expect_gsetting(f"{prefix}.desktop.peripherals.keyboard", "delay", "uint32 500")
    expect_gsetting(f"{prefix}.desktop.peripherals.keyboard", "repeat-interval", "uint32 33")

    power_schema = f"{prefix}.settings-daemon.plugins.power"
    expect_gsetting(power_schema, "sleep-inactive-ac-timeout", "1800")
    expect_gsetting(power_schema, "sleep-inactive-battery-timeout", "600")
    expect_gsetting(power_schema, "lid-close-ac-action", "'nothing'")
    expect_gsetting(power_schema, "lid-close-battery-action", "'suspend'")
    if args.distribution == "mint":
        expect_gsetting("org.cinnamon.desktop.interface", "gtk-theme", "'Mint-Y-Dark'")
        expect_gsetting(power_schema, "sleep-display-ac", "900")
        expect_gsetting(power_schema, "sleep-display-battery", "300")
        expect_gsetting(power_schema, "lock-on-suspend", "true")
    else:
        expect_gsetting("org.gnome.desktop.interface", "color-scheme", "'prefer-dark'")
        expect_gsetting("org.gnome.desktop.screensaver", "ubuntu-lock-on-suspend", "true")

    plan = json.loads(Path("/etc/libertix/installation-plan.json").read_text(encoding="utf-8"))
    migration = plan["features"]["windowsPreferenceMigration"]
    if migration.get("enabled") is not True:
        fail("the installed plan does not record preference migration consent")
    expected_wifi_count = migration.get("wifiProfileCount")
    if not isinstance(expected_wifi_count, int) or expected_wifi_count < 0:
        fail("the installed plan Wi-Fi profile count is invalid")
    keyfiles = [
        path
        for path in Path("/etc/NetworkManager/system-connections").glob("libertix-*.nmconnection")
        if re.fullmatch(r"libertix-[0-9a-f]{20}\.nmconnection", path.name)
    ]
    if len(keyfiles) != expected_wifi_count:
        fail("the installed NetworkManager profile count does not match the plan")
    for keyfile in keyfiles:
        if stat.S_IMODE(keyfile.stat().st_mode) != 0o600 or keyfile.stat().st_uid != 0:
            fail("a migrated NetworkManager profile is not root-owned mode 0600")

    forbidden = [
        Path("/tmp/windows-preferences.secret.json"),
        Path("/run/libertix/windows-preferences.secret.json"),
        Path("/run/libertix-private/windows-preferences.secret.json"),
    ]
    if any(path.exists() for path in forbidden):
        fail("the temporary preference bundle survived installation")
    plan_text = Path("/etc/libertix/installation-plan.json").read_text(encoding="utf-8")
    if "keyMaterial" in plan_text or '"secret"' in plan_text:
        fail("the installation plan contains a Wi-Fi secret field")

    print(f"MIGRATED_WIFI_PROFILE_COUNT={len(keyfiles)}")
    print("PREFERENCE_MIGRATION_RESULT=OK")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--distribution", choices=("mint", "zorin"), required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--wallpaper-sha256", required=True)
    parser.add_argument("--account-image-sha256", required=True)
    parser.add_argument("--inside-session", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.inside_session and not os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
        command = [
            "dbus-run-session",
            "--",
            sys.executable,
            str(Path(__file__).resolve()),
            *sys.argv[1:],
            "--inside-session",
        ]
        return subprocess.run(command, check=False).returncode
    run_checks(args)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, KeyError, RuntimeError, ValueError, json.JSONDecodeError) as error:
        print(f"PREFERENCE_MIGRATION_RESULT=ERROR: {error}", file=sys.stderr)
        raise SystemExit(2) from error
