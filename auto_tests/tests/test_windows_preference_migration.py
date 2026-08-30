from __future__ import annotations

import base64
import hashlib
import importlib.util
import json
import os
import stat
import subprocess
import sys
from pathlib import Path
from types import ModuleType

import pytest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "assets/live/libertix-apply-windows-preferences.py"


def load_helper() -> ModuleType:
    spec = importlib.util.spec_from_file_location("libertix_windows_preferences", HELPER)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def helper() -> ModuleType:
    return load_helper()


def desktop_preferences() -> dict[str, object]:
    return {
        "darkMode": True,
        "autoLockAfterInactivity": True,
        "autoLockTimeoutSeconds": 420,
        "lockOnWakeAc": True,
        "lockOnWakeBattery": True,
        "screenTimeoutAcSeconds": 900,
        "screenTimeoutBatterySeconds": 300,
        "sleepTimeoutAcSeconds": 1800,
        "sleepTimeoutBatterySeconds": 600,
        "lidCloseActionAc": "nothing",
        "lidCloseActionBattery": "suspend",
        "primaryMouseButton": "right",
        "mouseNaturalScroll": True,
        "touchpadNaturalScroll": False,
        "touchpadTapToClick": True,
        "keyboardRepeatDelayMilliseconds": 500,
        "keyboardRepeatIntervalMilliseconds": 33,
    }


def wifi_profiles() -> list[dict[str, object]]:
    return [
        {
            "id": "Cafe open",
            "ssid": "Cafe open",
            "security": "open",
            "hidden": False,
            "autoConnect": True,
        },
        {
            "id": "Cafe Enhanced Open",
            "ssid": "Cafe Enhanced Open",
            "security": "owe",
            "hidden": False,
            "autoConnect": True,
        },
        {
            "id": "Home WPA2",
            "ssid": "Home=Network;2",
            "security": "wpa-psk",
            "secret": "correct horse battery staple",
            "hidden": False,
            "autoConnect": True,
        },
        {
            "id": "Home WPA3",
            "ssid": "Home WPA3",
            "security": "sae",
            "secret": "sae-passphrase",
            "hidden": True,
            "autoConnect": False,
        },
    ]


def test_bundle_contract_accepts_complete_preferences_and_wifi(
    helper: ModuleType, tmp_path: Path
) -> None:
    bundle_path = tmp_path / "windows-preferences.secret.json"
    bundle_path.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "planId": "a" * 32,
                "preferences": desktop_preferences(),
                "wifiProfiles": wifi_profiles(),
            }
        ),
        encoding="utf-8",
    )

    bundle = helper.read_bundle(bundle_path, "a" * 32, 4)

    assert bundle["preferences"]["lidCloseActionBattery"] == "suspend"
    assert [profile["security"] for profile in bundle["wifiProfiles"]] == [
        "open",
        "owe",
        "wpa-psk",
        "sae",
    ]


def test_bundle_contract_rejects_a_wifi_count_mismatch(helper: ModuleType, tmp_path: Path) -> None:
    bundle_path = tmp_path / "windows-preferences.secret.json"
    bundle_path.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "planId": "a" * 32,
                "preferences": desktop_preferences(),
                "wifiProfiles": wifi_profiles(),
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(helper.PreferenceMigrationError, match="count does not match"):
        helper.read_bundle(bundle_path, "a" * 32, 2)


def test_assets_require_the_declared_sha256(helper: ModuleType) -> None:
    content = b"\x89PNG\r\n\x1a\nfixture"
    value = {
        "fileName": "wallpaper.png",
        "sha256": hashlib.sha256(content).hexdigest(),
        "contentBase64": base64.b64encode(content).decode("ascii"),
    }

    assert helper.decode_asset(value, "wallpaper", 1024) == (".png", content)
    value["sha256"] = "0" * 64
    with pytest.raises(helper.PreferenceMigrationError, match="hash verification failed"):
        helper.decode_asset(value, "wallpaper", 1024)


def test_networkmanager_keyfiles_cover_open_owe_wpa2_and_wpa3_without_logging_secrets(
    helper: ModuleType, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    destination = tmp_path / "system-connections"

    assert (
        helper.install_wifi_profiles(
            wifi_profiles(),
            destination,
            os.geteuid(),
            os.getegid(),
        )
        == 4
    )

    files = sorted(destination.glob("libertix-*.nmconnection"))
    assert len(files) == 4
    contents = [path.read_text(encoding="utf-8") for path in files]
    assert sum("[wifi-security]" not in content for content in contents) == 1
    assert any("key-mgmt=owe" in content for content in contents)
    assert any("key-mgmt=wpa-psk" in content for content in contents)
    assert any("key-mgmt=sae" in content for content in contents)
    assert any("hidden=true" in content for content in contents)
    assert any("autoconnect=false" in content for content in contents)
    assert all(stat.S_IMODE(path.stat().st_mode) == 0o600 for path in files)
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err == ""


def test_networkmanager_library_loads_every_generated_keyfile(
    helper: ModuleType, tmp_path: Path
) -> None:
    gi = pytest.importorskip("gi")
    gi.require_version("NM", "1.0")
    from gi.repository import GLib, NM  # noqa: I001, PLC0415

    destination = tmp_path / "system-connections"
    helper.install_wifi_profiles(
        wifi_profiles(),
        destination,
        os.geteuid(),
        os.getegid(),
    )

    loaded: dict[str, tuple[str | None, str | None]] = {}
    for path in destination.glob("*.nmconnection"):
        keyfile = GLib.KeyFile()
        keyfile.load_from_file(str(path), GLib.KeyFileFlags.NONE)
        connection = NM.keyfile_read(
            keyfile,
            str(destination),
            NM.KeyfileHandlerFlags.NONE,
            None,
            None,
        )
        assert connection.verify() is True
        wireless = connection.get_setting_wireless()
        ssid = bytes(wireless.get_ssid().get_data()).decode("utf-8")
        security = connection.get_setting_wireless_security()
        loaded[ssid] = (
            security.get_key_mgmt() if security is not None else None,
            security.get_psk() if security is not None else None,
        )

    assert loaded == {
        "Cafe open": (None, None),
        "Cafe Enhanced Open": ("owe", None),
        "Home=Network;2": ("wpa-psk", "correct horse battery staple"),
        "Home WPA3": ("sae", "sae-passphrase"),
    }


@pytest.mark.parametrize("security", ["wep", "wpa-eap", "802.1x", "vpn", "proxy"])
def test_unsupported_network_contracts_are_rejected(helper: ModuleType, security: str) -> None:
    profile = wifi_profiles()[1] | {"security": security}

    with pytest.raises(helper.PreferenceMigrationError, match="security is unsupported"):
        helper.validate_wifi_profile(profile, 0)


def test_desktop_mapping_applies_every_supported_contract(
    helper: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    preference_path = tmp_path / "preferences.json"
    preference_path.write_text(json.dumps(desktop_preferences()), encoding="utf-8")
    themes = tmp_path / "themes"
    (themes / "Mint-Y-Dark").mkdir(parents=True)
    applied: list[tuple[str, str, object]] = []

    def record(schema: str, key: str, value: object) -> bool:
        applied.append((schema, key, value))
        return True

    monkeypatch.setattr(helper, "set_gsetting", record)

    count = helper.apply_desktop_preferences(
        preference_path,
        "file:///home/test/Pictures/Libertix/windows-wallpaper.png",
        themes,
    )

    assert count == len(applied)
    assert (
        "org.gnome.desktop.background",
        "picture-uri-dark",
        "file:///home/test/Pictures/Libertix/windows-wallpaper.png",
    ) in applied
    assert ("org.gnome.desktop.interface", "color-scheme", "prefer-dark") in applied
    assert ("org.cinnamon.desktop.interface", "gtk-theme", "Mint-Y-Dark") in applied
    assert ("org.gnome.desktop.session", "idle-delay", 420) in applied
    assert ("org.cinnamon.desktop.screensaver", "lock-enabled", True) in applied
    assert ("org.gnome.desktop.screensaver", "lock-delay", 0) in applied
    assert ("org.cinnamon.settings-daemon.plugins.power", "sleep-display-ac", 900) in applied
    assert ("org.gnome.settings-daemon.plugins.power", "sleep-display-battery", 300) in applied
    assert (
        "org.cinnamon.settings-daemon.plugins.power",
        "sleep-inactive-ac-timeout",
        1800,
    ) in applied
    assert (
        "org.gnome.settings-daemon.plugins.power",
        "sleep-inactive-battery-timeout",
        600,
    ) in applied
    assert (
        "org.cinnamon.settings-daemon.plugins.power",
        "lid-close-ac-action",
        "nothing",
    ) in applied
    assert (
        "org.gnome.settings-daemon.plugins.power",
        "lid-close-battery-action",
        "suspend",
    ) in applied
    assert ("org.gnome.desktop.peripherals.mouse", "left-handed", True) in applied
    assert ("org.gnome.desktop.peripherals.mouse", "natural-scroll", True) in applied
    assert (
        "org.cinnamon.desktop.peripherals.touchpad",
        "natural-scroll",
        False,
    ) in applied
    assert ("org.cinnamon.desktop.peripherals.touchpad", "tap-to-click", True) in applied
    assert ("org.cinnamon.desktop.peripherals.keyboard", "delay", 500) in applied
    assert ("org.gnome.desktop.peripherals.keyboard", "repeat-interval", 33) in applied


def test_lock_on_wake_is_not_flattened_when_ac_and_battery_differ(
    helper: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    preferences = desktop_preferences() | {"lockOnWakeBattery": False}
    preference_path = tmp_path / "preferences.json"
    preference_path.write_text(json.dumps(preferences), encoding="utf-8")
    applied: list[tuple[str, str, object]] = []
    monkeypatch.setattr(
        helper,
        "set_gsetting",
        lambda schema, key, value: applied.append((schema, key, value)) or True,
    )

    helper.apply_desktop_preferences(preference_path, None, tmp_path / "themes")

    assert not any(key in {"ubuntu-lock-on-suspend", "lock-on-suspend"} for _, key, _ in applied)


def test_apply_desktop_command_keeps_a_successful_zero_exit(
    tmp_path: Path,
) -> None:
    preference_path = tmp_path / "preferences.json"
    preference_path.write_text(json.dumps(desktop_preferences()), encoding="utf-8")
    environment = dict(os.environ)
    environment["GSETTINGS_BACKEND"] = "memory"

    result = subprocess.run(
        [sys.executable, str(HELPER), "apply-desktop", str(preference_path)],
        text=True,
        capture_output=True,
        check=False,
        env=environment,
    )

    assert result.returncode == 0, result.stderr
    assert "Windows desktop preferences applied" in result.stdout
    assert "Traceback" not in result.stderr


def test_secret_bundle_is_verified_retired_and_never_installed_persistently() -> None:
    windows_plan = (ROOT / "Pages/ApplyChanges.Plan.cs").read_text(encoding="utf-8-sig")
    uefi_publisher = (ROOT / "Scripts/uefi/Libertix.Uefi.Execution.ps1").read_text(
        encoding="utf-8-sig"
    )
    live_context = (ROOT / "assets/live/libertix-live-context.sh").read_text(encoding="utf-8-sig")
    installer = (ROOT / "assets/live/libertix-install-main.sh").read_text(encoding="utf-8-sig")
    target = (ROOT / "assets/live/libertix-target-common.sh").read_text(encoding="utf-8-sig")
    rollback = (ROOT / "assets/live/libertix-rollback-common.sh").read_text(encoding="utf-8-sig")

    assert "WindowsPreferenceMigrationContract.ComputeSha256(temporary)" in windows_plan
    assert "File.Delete(_windowsPreferenceMigrationBundlePath);" in windows_plan
    assert "Get-FileHash -LiteralPath $preferenceBundleSource -Algorithm SHA256" in uefi_publisher
    assert "[IO.File]::Delete($preferenceBundleSource)" in uefi_publisher
    assert "Published Windows preference migration bundle re-verified." in uefi_publisher
    assert "Published Windows preference migration bundle verification failed." in uefi_publisher
    assert "preferences.secret.json" in live_context
    assert 'chmod 0600 "$LOG_DIR/windows-preferences.secret.json"' in live_context
    assert 'sha256sum "$WINDOWS_PREFERENCE_BUNDLE_RUNTIME_PATH"' in installer
    assert "/mnt/target/tmp/windows-preferences.secret.json" in target
    assert "rm -f /mnt/target/tmp/libertix-configure-target.sh" in target
    assert "${LOG_DIR:-/run/libertix}/windows-preferences.secret.json" in rollback
    assert 'rm -f -- "$WINDOWS_PREFERENCE_BUNDLE_RUNTIME_PATH"' in rollback


def test_windows_collector_reads_machine_preferences_from_the_64_bit_registry_view() -> None:
    collector = (ROOT / "Helpers/WindowsPreferenceCollector.cs").read_text(encoding="utf-8-sig")

    assert collector.count("RegistryView.Registry64") >= 2
    assert "AccountPicture\\Users\\" in collector
    assert '@"SYSTEM\\CurrentControlSet\\Enum\\HID"' in collector
