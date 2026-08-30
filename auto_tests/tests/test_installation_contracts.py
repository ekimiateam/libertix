from __future__ import annotations

import base64
import importlib.util
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from types import ModuleType

import pytest
from jsonschema import Draft202012Validator, FormatChecker

ROOT = Path(__file__).resolve().parents[2]
GIB = 1024**3


def test_legacy_project_compiles_every_application_source_file() -> None:
    project = ET.parse(ROOT / "Libertix.csproj")
    namespace = {"msbuild": "http://schemas.microsoft.com/developer/msbuild/2003"}
    included = {
        element.attrib["Include"].replace("\\", "/")
        for element in project.findall(".//msbuild:Compile", namespace)
        if "Include" in element.attrib
    }
    ignored_roots = {
        "auto_tests",
        "BootGuardian",
        "Libertix.Tests",
        "Standalone",
        "bin",
        "obj",
        ".work",
    }
    application_sources = {
        path.relative_to(ROOT).as_posix()
        for path in ROOT.rglob("*.cs")
        if path.relative_to(ROOT).parts[0] not in ignored_roots
    }

    assert application_sources == included


def test_live_log_reader_consumes_appends_incrementally_and_resets_on_rotation(
    tmp_path: Path,
) -> None:
    progress = load_live_module(
        "assets/live/libertix_progress.py",
        "libertix_incremental_log_reader_contract",
    )
    log = tmp_path / "install.log"
    log.write_text("STAGE: 120-unsquashfs\n10%\n", encoding="utf-8")
    reader = progress.IncrementalLogReader(log, 3)

    reader.refresh()
    first_offset = reader.offset
    assert reader.subpercent("120-unsquashfs") == 10
    assert reader.tail(3) == "STAGE: 120-unsquashfs\n10%"

    with log.open("a", encoding="utf-8") as stream:
        stream.write("20%\r30%\n40%\n")
    reader.refresh()
    assert reader.offset > first_offset
    assert reader.subpercent("120-unsquashfs") == 40
    assert reader.tail(3) == "20%\n30%\n40%"

    replacement = tmp_path / "replacement.log"
    replacement.write_text("STAGE: 130-target-system-config\n5%\n", encoding="utf-8")
    replacement.replace(log)
    reader.refresh()
    assert reader.subpercent("120-unsquashfs") is None
    assert reader.subpercent("130-target-system-config") == 5
    assert reader.tail(3) == "STAGE: 130-target-system-config\n5%"


def load_live_module(relative_path: str, module_name: str) -> ModuleType:
    """Load a live helper exactly as the ISO executes it, without packaging it."""

    path = ROOT / relative_path
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load live helper: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(path.parent))
    try:
        spec.loader.exec_module(module)
    finally:
        sys.path.remove(str(path.parent))
    return module


def test_target_configuration_releases_windows_before_state_persistence() -> None:
    script = r"""
source "$1"
DISK=/dev/mock
mark() { printf 'mark:%s\n' "$1"; }
mount_target_runtime_filesystems() { printf 'runtime-mounted\n'; }
write_target_fstab_or_die() { printf 'fstab-written\n'; }
mount_target_windows_partitions_read_only() { printf 'windows-mounted\n'; }
install_target_configuration_payload() { printf 'payload-installed\n'; }
run_target_configuration() { printf 'target-configured\n'; }
partitions_of_disk() { printf '/dev/mock1\n'; }
partition_number() { printf '1\n'; }
mountpoint() { return 0; }
umount() { printf 'windows-unmounted:%s\n' "$1"; }
configure_target_system
"""
    result = subprocess.run(
        [
            "bash",
            "-euo",
            "pipefail",
            "-c",
            script,
            "bash",
            str(ROOT / "assets/live/libertix-target-common.sh"),
        ],
        check=True,
        capture_output=True,
        text=True,
    )

    assert result.stdout.splitlines() == [
        "mark:130-target-system-config",
        "runtime-mounted",
        "fstab-written",
        "windows-mounted",
        "payload-installed",
        "target-configured",
        "windows-unmounted:/mnt/target/mnt/win_1",
    ]


def test_final_verification_retries_a_transient_ext4_mount(tmp_path: Path) -> None:
    counter = tmp_path / "mount-attempts"
    counter.write_text("0", encoding="ascii")
    script = r"""
source "$1"
COUNTER="$2"
VERIFY_DIR="$3"
die() { printf 'die:%s\n' "$1"; return 1; }
unmount_if_mounted() { return 0; }
sync() { return 0; }
udevadm() { return 0; }
sleep() { return 0; }
mount() {
    local count
    count=$(cat "$COUNTER")
    count=$((count + 1))
    printf '%s' "$count" > "$COUNTER"
    if [ "$count" -eq 1 ]; then
        printf 'device is still settling\n' >&2
        return 32
    fi
    return 0
}
findmnt() { printf '/dev/mock\n'; }
readlink() { printf '%s\n' "${@: -1}"; }
mount_linux_root_read_only_or_die /dev/mock "$VERIFY_DIR"
printf 'attempts=%s\n' "$(cat "$COUNTER")"
"""
    result = subprocess.run(
        [
            "bash",
            "-euo",
            "pipefail",
            "-c",
            script,
            "bash",
            str(ROOT / "assets/live/libertix-install-runtime-common.sh"),
            str(counter),
            str(tmp_path / "verify"),
        ],
        check=True,
        capture_output=True,
        text=True,
    )

    assert "read-only ext4 mount failed rc=32 on attempt 1" in result.stdout
    assert "device is still settling" in result.stdout
    assert f"Linux root mounted read-only on {tmp_path / 'verify'}" in result.stdout
    assert result.stdout.rstrip().endswith("attempts=2")


@pytest.fixture(scope="module")
def plan_module() -> ModuleType:
    return load_live_module(
        "assets/live/libertix-installation-plan.py",
        "libertix_installation_plan_contract",
    )


@pytest.fixture(scope="module")
def state_module() -> ModuleType:
    return load_live_module(
        "assets/live/libertix-installation-state.py",
        "libertix_installation_state_contract",
    )


@pytest.fixture(scope="module")
def bcd_cleanup_module() -> ModuleType:
    return load_live_module(
        "assets/live/cleanup-bcd-main.py",
        "libertix_bcd_cleanup_contract",
    )


def make_plan(firmware: str, final_size_gib: int) -> dict[str, object]:
    """Build the smallest complete plan shared by BIOS and UEFI."""

    staging_size_gib = min(final_size_gib, 8)
    is_bios = firmware == "bios"
    return {
        "schemaVersion": 4,
        "planId": "a" * 32,
        "createdAtUtc": "2026-07-15T12:00:00Z",
        "firmware": firmware,
        "distribution": {
            "id": "mint",
            "name": "Linux Mint",
            "osReleaseId": "linuxmint",
            "grubDisplayName": "Linux Mint 22.3 Cinnamon",
            "grubIcon": "linuxmint",
            "secureBootMicrosoftAuthorities": ["2011"],
            "installerIsoFileName": "mint.iso",
            "installerIsoUrl": "https://example.test/mint.iso",
            "installerIsoWindowsPath": (
                "C:\\ProgramData\\Libertix\\Downloads\\" + "a" * 32 + "\\mint.iso"
            ),
            "installerIsoSha256": "b" * 64,
            "liveIsoUrl": "https://example.test/libertix.iso",
            "liveIsoSha256": "c" * 64,
        },
        "locale": {
            "languageCode": "fr",
            "systemLanguage": "fr_FR.UTF-8",
            "keyboardLayout": "fr",
            "keyboardVariant": "",
            "keyboardModel": "pc105",
            "timezone": "Europe/Paris",
        },
        "account": {
            "username": "oem",
            "passwordHashWindowsPath": ("C:\\ProgramData\\Libertix\\Recovery\\account-secret.env"),
            "computerName": "libertix-test",
        },
        "disk": {
            "number": 0,
            "uniqueId": "disk-0",
            "partitionTableId": (
                "mbr:1234abcd" if is_bios else "gpt:12345678-1234-1234-1234-123456789abc"
            ),
            "sizeBytes": 256 * GIB,
            "logicalSectorSizeBytes": 512,
            "partitionStyle": "MBR" if is_bios else "GPT",
            "systemDrive": "C:",
            "windows": {"number": 2, "offsetBytes": GIB, "sizeBytes": 200 * GIB},
            "boot": {"number": 1, "offsetBytes": 1024 * 1024, "sizeBytes": 100 * 1024**2},
            "recovery": {
                "number": 3,
                "offsetBytes": 240 * GIB,
                "sizeBytes": GIB,
            },
            "installer": {
                "number": 4,
                "offsetBytes": (201 - final_size_gib) * GIB,
                "finalOffsetBytes": (201 - final_size_gib) * GIB,
                "resizeMode": "windows-online",
                "finalSizeBytes": final_size_gib * GIB,
                "stagingSizeBytes": staging_size_gib * GIB,
            },
        },
        "features": {
            "shareWindowsFilesInLinux": True,
            "shareLinuxFilesInWindows": True,
            "windowsProfilesJsonBase64": "W10=",
            "windowsPreferenceMigration": {
                "enabled": False,
                "bundleFileName": None,
                "bundleSha256": None,
                "bundleSizeBytes": 0,
                "wifiProfileCount": 0,
            },
        },
        "runtime": {
            "windowsBitLockerState": "FullyDecrypted",
            "lowMemoryMode": False,
            "bootStrategy": "bios-grub4dos" if is_bios else "uefi-boot-next",
            "secureBootEnabled": not is_bios,
            "trustedMicrosoftUefiAuthorities": [] if is_bios else ["2011"],
            "recoveryRootWindows": "C:\\ProgramData\\Libertix\\Recovery",
            "recoveryRunId": "d" * 32,
        },
    }


def test_shell_plan_loader_accepts_the_partition_table_identity(tmp_path: Path) -> None:
    plan_path = tmp_path / "installation-plan.json"
    plan_path.write_text(json.dumps(make_plan("bios", 20)), encoding="utf-8")
    loader = ROOT / "assets/live/libertix-installation-plan.sh"
    parser = ROOT / "assets/live/libertix-installation-plan.py"

    result = subprocess.run(
        [
            "bash",
            "-c",
            'source "$1"; load_libertix_installation_plan "$2" "$3"; '
            'printf "%s\\n" "$TARGET_DISK_PARTITION_TABLE_ID"',
            "--",
            str(loader),
            str(plan_path),
            str(parser),
        ],
        check=True,
        capture_output=True,
        text=True,
    )

    assert result.stdout.strip() == "mbr:1234abcd"


@pytest.mark.parametrize("firmware", ["bios", "uefi"])
@pytest.mark.parametrize(
    ("final_size_gib", "staging_size_gib"),
    [(20, 8), (31, 8), (32, 8), (40, 8)],
)
def test_bios_and_uefi_use_the_same_size_policy(
    plan_module: ModuleType,
    firmware: str,
    final_size_gib: int,
    staging_size_gib: int,
) -> None:
    plan = make_plan(firmware, final_size_gib)

    validated = plan_module.validate_plan(plan, require_installer=True)
    exported = plan_module.shell_values(validated)

    assert exported["LINUX_SIZE_GB"] == str(final_size_gib)
    assert exported["LANGUAGE_CODE"] == "fr"
    assert exported["KEYBOARD_VARIANT"] == ""
    assert exported["WINDOWS_PARTITION_SIZE_BYTES"] == str(200 * GIB)
    assert exported["INSTALLER_FINAL_SIZE_BYTES"] == str(final_size_gib * GIB)
    assert exported["INSTALLER_STAGING_SIZE_BYTES"] == str(staging_size_gib * GIB)
    assert exported["DISTRIBUTION_SECURE_BOOT_MICROSOFT_AUTHORITIES"] == "2011"
    assert exported["TRUSTED_MICROSOFT_UEFI_AUTHORITIES"] == ("" if firmware == "bios" else "2011")
    assert exported["SECURE_BOOT_ENABLED"] == ("false" if firmware == "bios" else "true")


@pytest.mark.parametrize("firmware", ["bios", "uefi"])
def test_offline_resize_exports_staging_and_final_geometry(
    plan_module: ModuleType,
    firmware: str,
) -> None:
    plan = make_plan(firmware, 40)
    installer = plan["disk"]["installer"]  # type: ignore[index]
    installer["resizeMode"] = "live-offline"
    installer["offsetBytes"] = (201 - 8) * GIB

    validated = plan_module.validate_plan(plan, require_installer=True)
    exported = plan_module.shell_values(validated)

    assert exported["INSTALLER_RESIZE_MODE"] == "live-offline"
    assert exported["INSTALLER_PARTITION_OFFSET_BYTES"] == str((201 - 8) * GIB)
    assert exported["INSTALLER_FINAL_OFFSET_BYTES"] == str((201 - 40) * GIB)
    assert exported["WINDOWS_BITLOCKER_STATE"] == "FullyDecrypted"


def test_offline_resize_rejects_unexpected_staging_offset(plan_module: ModuleType) -> None:
    plan = make_plan("uefi", 40)
    installer = plan["disk"]["installer"]  # type: ignore[index]
    installer["resizeMode"] = "live-offline"
    installer["offsetBytes"] = (201 - 9) * GIB

    with pytest.raises(plan_module.PlanValidationError, match="selected Windows shrink geometry"):
        plan_module.validate_plan(plan, require_installer=True)


def test_plan_rejects_non_decrypted_bitlocker_state(plan_module: ModuleType) -> None:
    plan = make_plan("uefi", 40)
    plan["runtime"]["windowsBitLockerState"] = "FullyEncrypted"  # type: ignore[index]

    with pytest.raises(plan_module.PlanValidationError, match="windowsBitLockerState"):
        plan_module.validate_plan(plan, require_installer=True)


@pytest.mark.parametrize("state", ["FullyDecrypted", "NotEncryptable"])
def test_live_plan_accepts_only_safe_bitlocker_states(
    plan_module: ModuleType,
    state: str,
) -> None:
    plan = make_plan("bios", 40)
    plan["runtime"]["windowsBitLockerState"] = state  # type: ignore[index]

    validated = plan_module.validate_plan(plan, require_installer=True)

    assert validated["runtime"]["windowsBitLockerState"] == state


def test_plan_rejects_unknown_secure_boot_authority(plan_module: ModuleType) -> None:
    plan = make_plan("uefi", 40)
    plan["distribution"]["secureBootMicrosoftAuthorities"] = ["2040"]  # type: ignore[index]

    with pytest.raises(
        plan_module.PlanValidationError,
        match="secureBootMicrosoftAuthorities",
    ):
        plan_module.validate_plan(plan, require_installer=True)


def test_bios_plan_rejects_trusted_uefi_authority(plan_module: ModuleType) -> None:
    plan = make_plan("bios", 40)
    plan["runtime"]["trustedMicrosoftUefiAuthorities"] = ["2011"]  # type: ignore[index]

    with pytest.raises(plan_module.PlanValidationError, match="BIOS plan"):
        plan_module.validate_plan(plan, require_installer=True)


def test_live_plan_export_excludes_noninteractive_windows_profiles(
    plan_module: ModuleType,
) -> None:
    plan = make_plan("uefi", 40)
    plan["features"]["windowsProfilesJsonBase64"] = base64.b64encode(  # type: ignore[index]
        json.dumps(["Alice", "WsiAccount", "wsiaccount", "WDAGUtilityAccount"]).encode("utf-8")
    ).decode("ascii")

    validated = plan_module.validate_plan(plan, require_installer=True)
    exported = plan_module.shell_values(validated)
    projected = json.loads(
        base64.b64decode(exported["WINDOWS_PROFILES_JSON_BASE64"], validate=True).decode("utf-8")
    )

    assert projected == ["Alice"]


@pytest.mark.parametrize(
    ("field_path", "invalid_value"),
    [
        (("distribution", "installerIsoFileName"), "folder/mint.iso"),
        (("distribution", "installerIsoWindowsPath"), "C:mint.iso"),
        (
            ("distribution", "installerIsoWindowsPath"),
            "C:\\ProgramData\\Libertix\\Downloads\\" + "a" * 32 + "\\safe/../mint.iso",
        ),
        (("account", "passwordHashWindowsPath"), "..\\account-secret.env"),
        (
            ("account", "passwordHashWindowsPath"),
            "C:\\ProgramData\\Libertix\\Recovery\\safe/../../account-secret.env",
        ),
        (("account", "passwordHashWindowsPath"), "D:\\account-secret.env"),
        (("disk", "systemDrive"), "c:"),
        (("runtime", "recoveryRootWindows"), "relative\\Recovery"),
        (
            ("runtime", "recoveryRootWindows"),
            "C:\\ProgramData\\Libertix\\Recovery\\safe/../escaped",
        ),
        (("runtime", "recoveryRootWindows"), "D:\\Recovery"),
        (("features", "windowsProfilesJsonBase64"), ""),
        (("runtime", "recoveryRunId"), ""),
        (("locale", "languageCode"), "de"),
        (("locale", "keyboardLayout"), "fr;touch /tmp/unsafe"),
        (("locale", "keyboardVariant"), "intl;touch /tmp/unsafe"),
        (("account", "computerName"), "invalid hostname"),
        (("account", "computerName"), "Uppercase"),
        (("account", "computerName"), "trailing-"),
    ],
)
def test_shared_plan_rejects_ambiguous_or_unsafe_values(
    plan_module: ModuleType,
    field_path: tuple[str, str],
    invalid_value: str,
) -> None:
    plan = make_plan("uefi", 40)
    section, field = field_path
    plan[section][field] = invalid_value  # type: ignore[index]

    with pytest.raises(plan_module.PlanValidationError):
        plan_module.validate_plan(plan, require_installer=True)


def test_shared_plan_accepts_all_windows_paths_on_a_non_c_system_drive(
    plan_module: ModuleType,
) -> None:
    plan = make_plan("uefi", 40)
    plan["disk"]["systemDrive"] = "D:"  # type: ignore[index]
    plan["distribution"]["installerIsoWindowsPath"] = (  # type: ignore[index]
        "D:\\ProgramData\\Libertix\\Downloads\\" + "a" * 32 + "\\mint.iso"
    )
    plan["account"]["passwordHashWindowsPath"] = (  # type: ignore[index]
        "D:\\ProgramData\\Libertix\\Recovery\\account-secret.env"
    )
    plan["runtime"]["recoveryRootWindows"] = (  # type: ignore[index]
        "D:\\ProgramData\\Libertix\\Recovery"
    )

    plan_module.validate_plan(plan, require_installer=True)


def test_shared_plan_requires_the_account_secret_under_the_recovery_root(
    plan_module: ModuleType,
) -> None:
    plan = make_plan("uefi", 40)
    plan["account"]["passwordHashWindowsPath"] = (  # type: ignore[index]
        "C:\\ProgramData\\Libertix\\Other\\account-secret.env"
    )

    with pytest.raises(plan_module.PlanValidationError, match="under runtime.recoveryRootWindows"):
        plan_module.validate_plan(plan, require_installer=True)


def test_legacy_plan_without_keyboard_variant_uses_empty_variant(
    plan_module: ModuleType,
) -> None:
    plan = make_plan("uefi", 40)
    del plan["locale"]["keyboardVariant"]  # type: ignore[index]

    validated = plan_module.validate_plan(plan, require_installer=True)

    assert plan_module.shell_values(validated)["KEYBOARD_VARIANT"] == ""


def test_development_ssh_network_is_validated_and_exported(
    plan_module: ModuleType,
) -> None:
    plan = make_plan("uefi", 40)
    plan["development"] = {
        "enableSsh": True,
        "staticIpv4Address": "198.51.100.20",
        "staticIpv4PrefixLength": 23,
        "staticIpv4Gateway": "198.51.100.1",
        "dnsServers": ["9.9.9.9", "1.1.1.1"],
    }

    validated = plan_module.validate_plan(plan, require_installer=True)
    exported = plan_module.shell_values(validated)

    assert exported["DEVELOPMENT_SSH_ENABLED"] == "true"
    assert exported["DEVELOPMENT_STATIC_IPV4_ADDRESS"] == "198.51.100.20"
    assert exported["DEVELOPMENT_STATIC_IPV4_PREFIX_LENGTH"] == "23"
    assert exported["DEVELOPMENT_STATIC_IPV4_GATEWAY"] == "198.51.100.1"
    assert exported["DEVELOPMENT_DNS_SERVERS"] == "9.9.9.9;1.1.1.1"
    validate_schema_document("installation-plan.schema.json", plan)


def test_plan_without_development_access_exports_disabled_defaults(
    plan_module: ModuleType,
) -> None:
    exported = plan_module.shell_values(make_plan("bios", 20))

    assert exported["DEVELOPMENT_SSH_ENABLED"] == "false"
    assert exported["DEVELOPMENT_STATIC_IPV4_ADDRESS"] == ""


def test_live_plan_runtime_rejects_properties_outside_the_shared_schema(
    plan_module: ModuleType,
) -> None:
    plan = make_plan("uefi", 40)
    plan["unexpectedRuntimeField"] = True

    with pytest.raises(plan_module.PlanValidationError, match="schema validation failed"):
        plan_module.validate_plan(plan, require_installer=True)


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("enableSsh", False),
        ("staticIpv4Address", "198.51.100.0"),
        ("staticIpv4PrefixLength", 31),
        ("staticIpv4Gateway", "203.0.113.1"),
        ("dnsServers", ["1.1.1.1", "1.1.1.1"]),
        ("staticIpv4Address", "127.0.0.2"),
        ("staticIpv4Address", "169.254.10.2"),
        ("staticIpv4Address", "224.0.0.2"),
        ("staticIpv4Gateway", "127.0.0.1"),
    ],
)
def test_development_ssh_network_rejects_noncanonical_values(
    plan_module: ModuleType,
    field: str,
    value: object,
) -> None:
    plan = make_plan("uefi", 40)
    development = {
        "enableSsh": True,
        "staticIpv4Address": "198.51.100.20",
        "staticIpv4PrefixLength": 23,
        "staticIpv4Gateway": "198.51.100.1",
        "dnsServers": ["9.9.9.9", "1.1.1.1"],
    }
    development[field] = value
    plan["development"] = development

    with pytest.raises(plan_module.PlanValidationError):
        plan_module.validate_plan(plan, require_installer=True)


@pytest.mark.parametrize(
    ("final_size_bytes", "staging_size_bytes"),
    [
        (19 * GIB, 19 * GIB),
        (20 * GIB + 1, 20 * GIB),
        (31 * GIB, 8 * GIB),
        (32 * GIB, 32 * GIB),
        (40 * GIB, 9 * GIB),
    ],
)
def test_plan_rejects_noncanonical_staging_sizes(
    plan_module: ModuleType,
    final_size_bytes: int,
    staging_size_bytes: int,
) -> None:
    plan = make_plan("bios", 20)
    installer = plan["disk"]["installer"]  # type: ignore[index]
    installer["finalSizeBytes"] = final_size_bytes
    installer["stagingSizeBytes"] = staging_size_bytes

    with pytest.raises(plan_module.PlanValidationError):
        plan_module.validate_plan(plan, require_installer=True)


def test_plan_accepts_aligned_four_kn_partition_geometry(plan_module: ModuleType) -> None:
    plan = make_plan("uefi", 40)
    plan["disk"]["logicalSectorSizeBytes"] = 4096  # type: ignore[index]

    plan_module.validate_plan(plan, require_installer=True)
    validate_schema_document("installation-plan.schema.json", plan)


@pytest.mark.parametrize("logical_sector_size", [256, 1024, 8192])
def test_plan_rejects_unsupported_logical_sector_sizes(
    plan_module: ModuleType,
    logical_sector_size: int,
) -> None:
    plan = make_plan("uefi", 40)
    plan["disk"]["logicalSectorSizeBytes"] = logical_sector_size  # type: ignore[index]

    with pytest.raises(plan_module.PlanValidationError):
        plan_module.validate_plan(plan, require_installer=True)


def test_plan_rejects_partition_offsets_between_four_kn_sectors(
    plan_module: ModuleType,
) -> None:
    plan = make_plan("uefi", 40)
    disk = plan["disk"]  # type: ignore[assignment]
    disk["logicalSectorSizeBytes"] = 4096
    disk["windows"]["offsetBytes"] += 512

    with pytest.raises(plan_module.PlanValidationError, match="must align"):
        plan_module.validate_plan(plan, require_installer=True)


def test_plan_accepts_cloned_windows_geometry_with_preserved_gap(
    plan_module: ModuleType,
) -> None:
    plan = make_plan("uefi", 24)
    disk = plan["disk"]  # type: ignore[assignment]
    disk["windows"]["sizeBytes"] += 256 * 1024
    disk["installer"]["offsetBytes"] = (
        disk["windows"]["offsetBytes"]
        + disk["windows"]["sizeBytes"]
        - 256 * 1024
        - disk["installer"]["finalSizeBytes"]
    )

    plan_module.validate_plan(plan, require_installer=True)


def test_plan_rejects_installer_offset_not_derived_from_original_windows_geometry(
    plan_module: ModuleType,
) -> None:
    plan = make_plan("uefi", 24)
    plan["disk"]["installer"]["offsetBytes"] += 1024 * 1024  # type: ignore[index]

    with pytest.raises(plan_module.PlanValidationError, match="selected Windows shrink geometry"):
        plan_module.validate_plan(plan, require_installer=True)


def test_bios_plan_accepts_primary_partition_after_reserved_mbr_metadata(
    plan_module: ModuleType,
) -> None:
    plan = make_plan("bios", 24)
    plan["disk"]["installer"]["offsetBytes"] -= 1024 * 1024  # type: ignore[index]

    plan_module.validate_plan(plan, require_installer=True)


def test_uefi_plan_rejects_bios_primary_partition_offset(
    plan_module: ModuleType,
) -> None:
    plan = make_plan("uefi", 24)
    plan["disk"]["installer"]["offsetBytes"] -= 1024 * 1024  # type: ignore[index]

    with pytest.raises(plan_module.PlanValidationError, match="selected Windows shrink geometry"):
        plan_module.validate_plan(plan, require_installer=True)


def test_plan_rejects_recovery_before_original_windows_end(
    plan_module: ModuleType,
) -> None:
    plan = make_plan("uefi", 24)
    plan["disk"]["recovery"]["offsetBytes"] = 190 * GIB  # type: ignore[index]

    with pytest.raises(plan_module.PlanValidationError):
        plan_module.validate_plan(plan, require_installer=True)


def test_failure_and_rollback_preserve_the_completed_step_ledger(
    state_module: ModuleType,
) -> None:
    state = {
        "schemaVersion": 1,
        "planId": "a" * 32,
        "revision": 0,
        "status": "pending",
        "phase": "windows",
        "activeStep": None,
        "completedSteps": [],
        "compensatedSteps": [],
        "failure": None,
        "updatedAtUtc": "2026-07-15T12:00:00Z",
    }

    for step in (
        "windows.preflight-verified",
        "windows.artifacts-verified",
        "windows.recovery-armed",
        "windows.system-volume-shrunk",
    ):
        state_module.start_step(state, step)
        state_module.complete_step(state, step)
    state_module.start_step(state, "windows.installer-partition-created")
    state_module.fail(state, "TEST_FAILURE", "windows", "Injected failure")
    state_module.begin_rollback(state)

    with pytest.raises(state_module.StateTransitionError):
        state_module.compensate(state, "windows.installer-partition-created")

    state_module.compensate(state, "windows.system-volume-shrunk")
    state_module.compensate(state, "windows.recovery-armed")
    state_module.complete_rollback(state)

    assert state["status"] == "rolled-back"
    assert state["phase"] == "complete"
    assert state["completedSteps"] == [
        "windows.preflight-verified",
        "windows.artifacts-verified",
        "windows.recovery-armed",
        "windows.system-volume-shrunk",
    ]
    assert state["compensatedSteps"] == [
        "windows.system-volume-shrunk",
        "windows.recovery-armed",
    ]


def test_successful_live_state_can_begin_explicit_rollback(
    state_module: ModuleType,
) -> None:
    state = {
        "schemaVersion": 1,
        "planId": "a" * 32,
        "revision": 0,
        "status": "succeeded",
        "phase": "complete",
        "activeStep": None,
        "completedSteps": list(state_module.ORDERED_STEPS),
        "compensatedSteps": [],
        "failure": None,
        "updatedAtUtc": "2026-07-15T12:00:00Z",
    }

    state_module.begin_rollback(state)

    assert state["status"] == "rollback-running"
    assert state["phase"] == "rollback"


def test_live_state_rejects_out_of_order_and_incomplete_success(
    state_module: ModuleType,
) -> None:
    state = {
        "schemaVersion": 1,
        "planId": "a" * 32,
        "revision": 0,
        "status": "pending",
        "phase": "windows",
        "activeStep": None,
        "completedSteps": [],
        "compensatedSteps": [],
        "failure": None,
        "updatedAtUtc": "2026-07-15T12:00:00Z",
    }

    with pytest.raises(state_module.StateTransitionError, match="out of order"):
        state_module.start_step(state, "windows.recovery-armed")

    state_module.start_step(state, "windows.preflight-verified")
    state_module.complete_step(state, "windows.preflight-verified")
    with pytest.raises(state_module.StateTransitionError, match="final target verification"):
        state_module.complete_installation(state)


def test_live_state_rejects_forged_incomplete_terminal_states(
    state_module: ModuleType,
) -> None:
    base = {
        "schemaVersion": 1,
        "planId": "a" * 32,
        "revision": 1,
        "phase": "complete",
        "activeStep": None,
        "completedSteps": [
            "windows.preflight-verified",
            "windows.artifacts-verified",
            "windows.recovery-armed",
        ],
        "compensatedSteps": [],
        "failure": None,
        "updatedAtUtc": "2026-07-15T12:00:00Z",
    }

    with pytest.raises(state_module.StateTransitionError):
        state_module.validate_state({**base, "status": "succeeded"})

    rolled_back = {
        **base,
        "status": "rolled-back",
        "failure": {
            "code": "failure",
            "message": "failure",
            "component": "windows",
        },
    }
    with pytest.raises(state_module.StateTransitionError):
        state_module.validate_state(rolled_back)


def test_live_state_runtime_rejects_properties_outside_the_shared_schema(
    state_module: ModuleType,
) -> None:
    state = {
        "schemaVersion": 1,
        "planId": "a" * 32,
        "revision": 0,
        "status": "pending",
        "phase": "windows",
        "activeStep": None,
        "completedSteps": [],
        "compensatedSteps": [],
        "failure": None,
        "updatedAtUtc": "2026-07-15T12:00:00Z",
        "unexpectedRuntimeField": True,
    }

    with pytest.raises(state_module.StateTransitionError, match="schema validation failed"):
        state_module.validate_state(state)


def test_contract_implementations_share_the_same_policy_constants() -> None:
    policy_path = ROOT / "Scripts/config/Libertix.InstallationPolicy.json"
    policy = json.loads(policy_path.read_text(encoding="utf-8"))
    csharp = (ROOT / "Installation/InstallationSizePolicy.cs").read_text(encoding="utf-8-sig")
    powershell = (ROOT / "Scripts/modules/Libertix.InstallationPlan.psm1").read_text(
        encoding="utf-8-sig"
    )
    python = (ROOT / "assets/live/libertix-installation-plan.py").read_text(encoding="utf-8-sig")

    assert policy["storage"] == {
        "minimumFinalSizeGiB": 20,
        "targetWindowsFreeSpaceGiB": 10,
        "windowsFreeSpaceToleranceGiB": 2,
        "windowsFreeSpaceRetryWindowGiB": 2,
        "preflightShrinkSafetyGiB": 2,
        "maximumDirectFat32SizeGiB": 31,
        "stagingSizeGiB": 8,
        "partitionAlignmentBytes": 1024**2,
        "recommendedLinuxFractionOfFreeSpace": 0.4,
        "maximumRecommendedLinuxSizeGiB": 100,
    }
    assert policy["memory"] == {
        "windowsMinimumMiB": 2048,
        "lowMemoryThresholdMiB": 4096,
        "liveMinimumMiB": 1536,
    }
    assert policy["account"]["reservedUsernamesSource"] == (
        "https://sources.debian.org/src/user-setup/1.107/reserved-usernames"
    )
    assert len(policy["account"]["reservedUsernames"]) == 108
    assert {"root", "admin", "Debian-exim", "input", "kvm", "render"} <= set(
        policy["account"]["reservedUsernames"]
    )
    assert "InstallationPolicy.Current.Storage" in csharp
    resize = (ROOT / "Pages/ResizeDisk.xaml.cs").read_text(encoding="utf-8-sig")
    assert "InstallationSizePolicy.RecommendedLinuxFractionOfFreeSpace" in resize
    assert "InstallationSizePolicy.MaximumRecommendedLinuxSizeGiB" in resize
    assert "Get-LibertixInstallationPolicy" in powershell
    assert "INSTALLATION_POLICY.storage" in python
    for obsolete_literal in (
        "MinimumFinalSizeGiB = 20",
        "$script:MinimumFinalSizeGiB = 20",
        "MINIMUM_FINAL_SIZE_GIB = 20",
    ):
        assert obsolete_literal not in csharp + powershell + python


@pytest.mark.parametrize("username", ["root", "admin", "debian-exim"])
def test_live_plan_rejects_reserved_linux_usernames(
    plan_module: ModuleType,
    username: str,
) -> None:
    plan = make_plan("uefi", 40)
    plan["account"]["username"] = username  # type: ignore[index]

    with pytest.raises(plan_module.PlanValidationError, match="username is reserved"):
        plan_module.validate_plan(plan, require_installer=True)


@pytest.mark.parametrize(
    ("description", "path", "expected"),
    [
        ("Install Linux", r"\grldr.mbr", True),
        ("Install Linux", "/grldr.mbr", True),
        ("Libertix BIOS Installer " + "a" * 32, r"\grldr.mbr", True),
        ("Libertix BIOS Installer invalid", r"\grldr.mbr", False),
        ("Libertix UEFI Installer", r"\EFI\BOOT\BOOTX64.EFI", True),
        ("Libertix UEFI Installer " + "b" * 32, r"\EFI\BOOT\BOOTX64.EFI", True),
        (
            "Libertix UEFI Installer " + "c" * 32,
            r"\EFI\LibertixInstaller\BOOTX64.EFI",
            True,
        ),
        ("Libertix UEFI Installer " + "d" * 32, r"\EFI\ubuntu\shimx64.efi", False),
        ("Libertix UEFI Installer invalid", r"\EFI\BOOT\BOOTX64.EFI", False),
        ("Windows Boot Manager", r"\EFI\Microsoft\Boot\bootmgfw.efi", False),
        ("Firmware utility", r"\EFI\BOOT\BOOTX64.EFI", False),
        ("Install Linux", r"\EFI\BOOT\BOOTX64.EFI", False),
    ],
)
def test_bcd_cleanup_only_selects_owned_temporary_entries(
    bcd_cleanup_module: ModuleType,
    description: str,
    path: str,
    expected: bool,
) -> None:
    assert bcd_cleanup_module.is_libertix_temporary_entry(description, path) is expected


def test_firmware_wrappers_delegate_to_shared_implementations() -> None:
    runner_bios = (ROOT / "iso/live/libertix-runner.sh").read_text(encoding="utf-8-sig")
    runner_uefi = (ROOT / "iso-uefi/live/libertix-runner.sh").read_text(encoding="utf-8-sig")
    target_bios = (ROOT / "iso/target/configure-target.sh").read_text(encoding="utf-8-sig")
    target_uefi = (ROOT / "iso-uefi/target/configure-target.sh").read_text(encoding="utf-8-sig")

    assert "LIBERTIX_FIRMWARE_MODE=bios" in runner_bios
    assert "LIBERTIX_FIRMWARE_MODE=uefi" in runner_uefi
    assert "libertix-runner-main.sh" in runner_bios
    assert "libertix-runner-main.sh" in runner_uefi
    assert "LIBERTIX_FIRMWARE_MODE=bios" in target_bios
    assert "LIBERTIX_FIRMWARE_MODE=uefi" in target_uefi
    assert "configure-target-main.sh" in target_bios
    assert "configure-target-main.sh" in target_uefi


@pytest.mark.parametrize("firmware", ["iso", "iso-uefi"])
def test_grub_images_render_the_shared_menu_fragment(
    tmp_path: Path,
    firmware: str,
) -> None:
    renderer = load_live_module(
        "iso-tools/render-boot-config.py",
        f"libertix_boot_renderer_{firmware.replace('-', '_')}",
    )
    output = tmp_path / firmware / "grub.cfg"

    renderer.render(
        ROOT / "Scripts/config/Libertix.BootArguments.json",
        ROOT / firmware / "boot/grub.cfg",
        ROOT / "Scripts/config/Libertix.LiveGrubMenu.cfg.in",
        output,
    )

    rendered = output.read_text(encoding="utf-8")
    assert rendered.count('menuentry "Install selected Linux distribution (Automatic)"') == 1
    assert rendered.count('menuentry "Install (Verbose mode)"') == 1
    assert "@LIBERTIX_" not in rendered


def test_versioned_schemas_accept_documents_used_by_runtime_validators() -> None:
    plan = make_plan("uefi", 40)
    state = {
        "schemaVersion": 1,
        "planId": "a" * 32,
        "revision": 0,
        "status": "pending",
        "phase": "windows",
        "activeStep": None,
        "completedSteps": [],
        "compensatedSteps": [],
        "failure": None,
        "updatedAtUtc": "2026-07-15T12:00:00Z",
    }

    validate_schema_document("installation-plan.schema.json", plan)
    validate_schema_document("installation-state.schema.json", state)


def test_windows_plan_models_and_powershell_property_sets_match_schema() -> None:
    schema = json.loads(
        (ROOT / "schemas/installation-plan.schema.json").read_text(encoding="utf-8")
    )
    expected = {
        "root": set(schema["properties"]),
        "distribution": set(schema["$defs"]["distribution"]["properties"]),
        "locale": set(schema["$defs"]["locale"]["properties"]),
        "account": set(schema["$defs"]["account"]["properties"]),
        "disk": set(schema["$defs"]["disk"]["properties"]),
        "partition": set(schema["$defs"]["partitionIdentity"]["properties"]),
        "installer": set(schema["$defs"]["installerPartition"]["properties"]),
        "features": set(schema["$defs"]["features"]["properties"]),
        "windowsPreferenceMigration": set(
            schema["$defs"]["windowsPreferenceMigration"]["properties"]
        ),
        "runtime": set(schema["$defs"]["runtime"]["properties"]),
        "development": set(schema["$defs"]["development"]["properties"]),
    }

    powershell = (ROOT / "Scripts/modules/Libertix.InstallationPlan.psm1").read_text(
        encoding="utf-8-sig"
    )
    property_table = powershell.split("$script:InstallationPlanPropertySets = [ordered]@{", 1)[
        1
    ].split("\n}", 1)[0]
    powershell_sets = {
        name: set(re.findall(r'"([A-Za-z][A-Za-z0-9]*)"', values))
        for name, values in re.findall(r"(?ms)^\s+(\w+)\s*=\s*@\((.*?)\)(?=\s*$)", property_table)
    }
    assert powershell_sets == expected

    csharp = (ROOT / "Installation/InstallationPlan.cs").read_text(encoding="utf-8")
    class_to_schema = {
        "InstallationPlan": "root",
        "InstallationDistribution": "distribution",
        "InstallationLocale": "locale",
        "InstallationAccount": "account",
        "InstallationDisk": "disk",
        "PartitionIdentity": "partition",
        "InstallerPartitionPlan": "installer",
        "InstallationFeatures": "features",
        "InstallationRuntime": "runtime",
        "InstallationDevelopmentOptions": "development",
    }
    for class_name, schema_name in class_to_schema.items():
        body = re.search(
            rf"(?ms)^\s*public sealed class {class_name}\s*\{{(.*?)^\s*\}}",
            csharp,
        )
        assert body is not None, class_name
        properties = set(re.findall(r'JsonPropertyName\("([^"]+)"\)', body.group(1)))
        assert properties == expected[schema_name], class_name


def read_declaration_block(source: str, declaration: str, terminator: str) -> str:
    start = source.index(declaration)
    end = source.index(terminator, start)
    return source[start:end]


def read_shell_rollback_steps() -> list[str]:
    rollback = (ROOT / "assets/live/libertix-rollback-common.sh").read_text(encoding="utf-8")
    block = read_declaration_block(rollback, "for rollback_step in", "; do")
    return re.findall(r'"([a-z]+\.[a-z-]+)"', block)


def test_ordered_and_compensatable_steps_are_identical_in_every_runtime() -> None:
    """Guard the rollback contract that C#, PowerShell, Python and Bash each restate.

    A renamed, reordered or forgotten step in a single runtime would let one
    environment record a completed installation that another cannot compensate,
    so every copy is compared here rather than trusted individually.
    """

    constants = dict(
        re.findall(
            r'public const string (\w+) = "([a-z]+\.[a-z-]+)";',
            (ROOT / "Installation/InstallationExecutionState.cs").read_text(encoding="utf-8"),
        )
    )
    state_machine = (ROOT / "Installation/InstallationStateMachine.cs").read_text(encoding="utf-8")
    csharp_ordered = [
        constants[name]
        for name in re.findall(
            r"InstallationStep\.(\w+)",
            read_declaration_block(
                state_machine, "private static readonly string[] OrderedSteps", "};"
            ),
        )
    ]
    csharp_compensatable = {
        constants[name]
        for name in re.findall(
            r"InstallationStep\.(\w+)",
            read_declaration_block(
                state_machine,
                "private static readonly HashSet<string> CompensatableSteps",
                "StringComparer.Ordinal);",
            ),
        )
    }

    powershell = (ROOT / "Scripts/modules/Libertix.InstallationState.psm1").read_text(
        encoding="utf-8-sig"
    )
    powershell_ordered = re.findall(
        r'"([a-z]+\.[a-z-]+)"',
        read_declaration_block(powershell, "$script:OrderedSteps = @(", ")"),
    )
    powershell_compensatable = set(
        re.findall(
            r'"([a-z]+\.[a-z-]+)"',
            read_declaration_block(powershell, "$script:CompensatableSteps = @(", ")"),
        )
    )

    live_state = load_live_module(
        "assets/live/libertix-installation-state.py",
        "libertix_installation_step_parity",
    )

    assert csharp_ordered == list(live_state.ORDERED_STEPS)
    assert powershell_ordered == list(live_state.ORDERED_STEPS)
    assert csharp_compensatable == set(live_state.COMPENSATABLE_STEPS)
    assert powershell_compensatable == set(live_state.COMPENSATABLE_STEPS)

    # The live rollback engine compensates in reverse workflow order so a later
    # operation is always undone before the operation it depended on.
    shell_rollback_steps = read_shell_rollback_steps()
    expected_rollback_order = [
        step
        for step in reversed(live_state.ORDERED_STEPS)
        if step in live_state.COMPENSATABLE_STEPS
    ]
    assert shell_rollback_steps == expected_rollback_order


def test_persisted_runtime_names_match_across_language_boundaries() -> None:
    csharp = (ROOT / "Installation/RuntimeNames.cs").read_text(encoding="utf-8")
    names = dict(re.findall(r'public const string (\w+) = "([A-Za-z0-9_]+)";', csharp))
    assert names == {
        "InstallationLogDirectory": "LibertixInstallLogs",
        "WindowsLogDirectory": "Windows",
        "LinuxLogDirectory": "Linux",
        "BiosRecoveryDirectory": "LibertixInstallRecovery",
        "BiosRecoveryTask": "LibertixInstallRecovery",
        "BiosRecoveryPromptTask": "LibertixInstallRecoveryPrompt",
        "LinuxReadOnlyTask": "LibertixLinuxReadOnly",
    }
    policy = json.loads(
        (ROOT / "Scripts/config/Libertix.InstallationPolicy.json").read_text(encoding="utf-8")
    )
    labels = policy["volumeLabels"]
    assert labels == {
        "installationMedia": "LIBERTIXISO",
        "staging": "LIBERTIXSTG",
        "legacyStagingForRecovery": ["LIBERTIX", "LIBERTIXEFI"],
    }
    assert "InstallationPolicy.Current.VolumeLabels.InstallationMedia" in csharp
    assert "InstallationPolicy.Current.VolumeLabels.Staging" in csharp

    recovery = (ROOT / "Scripts/libertix-recovery-guard.ps1").read_text(encoding="utf-8-sig")
    bios_storage = (ROOT / "Scripts/libertix-bios-storage.ps1").read_text(encoding="utf-8-sig")
    windows_share = (ROOT / "Scripts/libertix-configure-windows-share.ps1").read_text(
        encoding="utf-8-sig"
    )
    uefi = (ROOT / "Scripts/libertix-uefi-install.ps1").read_text(encoding="utf-8-sig")
    live_context = (ROOT / "assets/live/libertix-live-context.sh").read_text(encoding="utf-8-sig")
    live_logs = (ROOT / "assets/live/libertix-copy-logs.sh").read_text(encoding="utf-8-sig")

    assert f'$TaskName = "{names["BiosRecoveryTask"]}"' in recovery
    assert f'$PromptTaskName = "{names["BiosRecoveryPromptTask"]}"' in recovery
    assert f'Join-Path $SystemDrive "{names["BiosRecoveryDirectory"]}"' in recovery
    assert (
        f'Join-Path $SystemDrive "{names["InstallationLogDirectory"]}\\'
        f'{names["WindowsLogDirectory"]}"'
    ) in recovery
    assert f'$script:LinuxReadOnlyTaskName = "{names["LinuxReadOnlyTask"]}"' in windows_share
    assert "$InstallerLabel = [string]$installationPolicy.volumeLabels.staging" in uefi
    assert (
        "$installerLabel = [string](Get-LibertixInstallationPolicy).volumeLabels.staging"
        in bios_storage
    )
    assert "$StagingVolumeLabel = [string]$InstallationPolicy.volumeLabels.staging" in recovery
    assert "$LIBERTIX_STAGING_VOLUME_LABEL" in live_context
    assert names["InstallationLogDirectory"] in live_logs
    assert f'/{names["LinuxLogDirectory"]}"' in live_logs


def test_windows_state_models_and_powershell_property_sets_match_schema() -> None:
    schema = json.loads(
        (ROOT / "schemas/installation-state.schema.json").read_text(encoding="utf-8")
    )
    expected = {
        "root": set(schema["properties"]),
        "progress": set(schema["$defs"]["progress"]["properties"]),
        "failure": set(schema["$defs"]["failure"]["properties"]),
    }

    powershell = (ROOT / "Scripts/modules/Libertix.InstallationState.psm1").read_text(
        encoding="utf-8-sig"
    )
    property_table = powershell.split("$script:InstallationStatePropertySets = [ordered]@{", 1)[
        1
    ].split("\n}", 1)[0]
    powershell_sets = {
        name: set(re.findall(r'"([A-Za-z][A-Za-z0-9]*)"', values))
        for name, values in re.findall(r"(?ms)^\s+(\w+)\s*=\s*@\((.*?)\)(?=\s*$)", property_table)
    }
    assert powershell_sets == expected

    csharp = (ROOT / "Installation/InstallationExecutionState.cs").read_text(encoding="utf-8")
    class_to_schema = {
        "InstallationExecutionState": "root",
        "InstallationProgress": "progress",
        "InstallationFailure": "failure",
    }
    for class_name, schema_name in class_to_schema.items():
        body = re.search(
            rf"(?ms)^\s*public sealed class {class_name}\s*\{{(.*?)^\s*\}}",
            csharp,
        )
        assert body is not None, class_name
        properties = set(re.findall(r'JsonPropertyName\("([^"]+)"\)', body.group(1)))
        assert properties == expected[schema_name], class_name


@pytest.mark.parametrize(
    "invalid_state",
    [
        {
            "status": "failed",
            "phase": "windows",
            "activeStep": None,
            "failure": None,
        },
        {
            "status": "succeeded",
            "phase": "complete",
            "activeStep": None,
            "failure": {
                "code": "stale",
                "message": "stale failure",
                "component": "windows",
            },
        },
        {
            "status": "rollback-running",
            "phase": "windows",
            "activeStep": None,
            "failure": {
                "code": "failure",
                "message": "failure",
                "component": "windows",
            },
        },
        {
            "status": "succeeded",
            "phase": "complete",
            "activeStep": None,
            "completedSteps": [],
            "compensatedSteps": [],
            "failure": None,
        },
        {
            "status": "rolled-back",
            "phase": "complete",
            "activeStep": None,
            "completedSteps": [
                "windows.preflight-verified",
                "windows.artifacts-verified",
                "windows.recovery-armed",
            ],
            "compensatedSteps": [],
            "failure": {
                "code": "failure",
                "message": "failure",
                "component": "windows",
            },
        },
    ],
)
def test_state_schema_rejects_contradictory_lifecycle_fields(
    invalid_state: dict[str, object],
) -> None:
    state = {
        "schemaVersion": 1,
        "planId": "a" * 32,
        "revision": 1,
        "status": "running",
        "phase": "windows",
        "activeStep": "windows.preflight-verified",
        "completedSteps": [],
        "compensatedSteps": [],
        "failure": None,
        "updatedAtUtc": "2026-07-15T12:00:00Z",
    }
    state.update(invalid_state)

    schema = json.loads(
        (ROOT / "schemas/installation-state.schema.json").read_text(encoding="utf-8")
    )
    validator = Draft202012Validator(schema, format_checker=FormatChecker())

    assert list(validator.iter_errors(state))


def validate_schema_document(schema_name: str, document: dict[str, object]) -> None:
    schema = json.loads((ROOT / "schemas" / schema_name).read_text(encoding="utf-8"))
    Draft202012Validator(schema, format_checker=FormatChecker()).validate(document)
