from __future__ import annotations

import copy
import json
import subprocess
from pathlib import Path

import pytest

from tests.test_installation_contracts import GIB, load_live_module, make_plan


def make_separate_allocation_plan(firmware: str = "uefi", style: str = "GPT") -> dict:
    plan = make_plan(firmware, 20)
    plan["schemaVersion"] = 5
    plan["allocation"] = {
        "number": 3,
        "uniqueId": plan["disk"]["uniqueId"],
        "partitionTableId": (
            "gpt:87654321-1234-1234-1234-123456789abc" if style == "GPT" else "mbr:87654321"
        ),
        "sizeBytes": 64 * GIB,
        "logicalSectorSizeBytes": 512,
        "partitionStyle": style,
        "sourceDrive": "D:",
        "sourcePartition": {"number": 2, "offsetBytes": GIB, "sizeBytes": 60 * GIB},
        "sourceVolumeId": "volume-data",
        "sourceNtfsUuid": "1234567890ABCDEF",
        "sourceBitLockerState": "FullyDecrypted",
    }
    plan["disk"]["installer"]["offsetBytes"] = 41 * GIB
    plan["disk"]["installer"]["finalOffsetBytes"] = 41 * GIB
    return plan


@pytest.fixture
def validator():
    return load_live_module("assets/live/libertix-installation-plan.py", "separate_allocation_plan")


@pytest.mark.parametrize("firmware", ["bios", "uefi"])
@pytest.mark.parametrize("style", ["MBR", "GPT"])
def test_distinct_allocation_does_not_change_windows_or_recovery(validator, firmware, style):
    plan = make_separate_allocation_plan(firmware, style)
    original = copy.deepcopy(plan)
    validator.validate_plan(plan, require_installer=True)
    assert plan == original
    assert plan["disk"]["windows"]["sizeBytes"] == 200 * GIB


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("number", 0),
        ("number", 2**31),
        ("sourceDrive", "C:"),
        ("sourceDrive", "d:"),
        ("partitionTableId", "gpt:12345678-1234-1234-1234-123456789abc"),
        ("partitionTableId", "gpt:00000000-0000-0000-0000-000000000000"),
        ("sourceVolumeId", ""),
        ("sourceNtfsUuid", None),
        ("sourceNtfsUuid", "0000000000000000"),
        ("sourceNtfsUuid", "12345678"),
        ("sourceNtfsUuid", "1234567890abcdef"),
        ("sourceBitLockerState", "suspended"),
        ("logicalSectorSizeBytes", 0),
        ("sizeBytes", 2**63),
        ("sourcePartition", {"number": 2, "offsetBytes": 63 * GIB, "sizeBytes": 60 * GIB}),
    ],
)
def test_ambiguous_or_invalid_allocation_is_rejected(validator, field, value):
    plan = make_separate_allocation_plan()
    plan["allocation"][field] = value
    with pytest.raises(validator.PlanValidationError):
        validator.validate_plan(plan)


def test_installer_extent_is_taken_from_selected_source_not_windows(validator):
    plan = make_separate_allocation_plan()
    plan["disk"]["installer"]["finalOffsetBytes"] = 181 * GIB
    with pytest.raises(validator.PlanValidationError, match="finalOffsetBytes"):
        validator.validate_plan(plan)


def test_secondary_offline_extent_uses_the_source_partition(validator):
    plan = make_separate_allocation_plan()
    plan["disk"]["installer"]["resizeMode"] = "live-offline"
    plan["disk"]["installer"]["offsetBytes"] = 53 * GIB
    validator.validate_plan(plan)


def test_mbr_logical_source_is_not_supported(validator):
    plan = make_separate_allocation_plan(style="MBR")
    plan["allocation"]["sourcePartition"]["number"] = 5
    with pytest.raises(validator.PlanValidationError, match="primary extent"):
        validator.validate_plan(plan)


def test_schema_four_cannot_silently_carry_secondary_allocation(validator):
    plan = make_separate_allocation_plan()
    plan["schemaVersion"] = 4
    with pytest.raises(validator.PlanValidationError):
        validator.validate_plan(plan)


def test_schema_five_requires_explicit_allocation(validator):
    plan = make_plan("uefi", 20)
    plan["schemaVersion"] = 5
    with pytest.raises(validator.PlanValidationError):
        validator.validate_plan(plan)


@pytest.mark.parametrize("firmware", ["bios", "uefi"])
@pytest.mark.parametrize("style", ["MBR", "GPT"])
def test_shell_projection_keeps_windows_and_allocation_identities_distinct(
    validator, firmware, style
):
    plan = make_separate_allocation_plan(firmware, style)
    validator.validate_plan(plan, require_installer=True)
    values = validator.shell_values(plan)
    assert values["SEPARATE_ALLOCATION_DISK"] == "true"
    assert values["TARGET_DISK_PARTITION_TABLE_ID"] == plan["disk"]["partitionTableId"]
    assert values["ALLOCATION_DISK_PARTITION_TABLE_ID"] == plan["allocation"]["partitionTableId"]
    assert values["ALLOCATION_DISK_SIZE_BYTES"] == str(64 * GIB)
    assert values["ALLOCATION_DISK_SECTOR_SIZE_BYTES"] == "512"
    assert values["ALLOCATION_PARTITION_STYLE"] == style
    assert values["ALLOCATION_SOURCE_OFFSET_BYTES"] == str(GIB)
    assert values["ALLOCATION_SOURCE_SIZE_BYTES"] == str(60 * GIB)
    assert values["ALLOCATION_SOURCE_NTFS_UUID"] == "1234567890ABCDEF"
    assert values["WINDOWS_PARTITION_SIZE_BYTES"] == str(200 * GIB)
    assert values["ALLOCATION_SOURCE_BITLOCKER_STATE"] == "FullyDecrypted"
    assert values["ISO_WINDOWS_PATH"] == plan["distribution"]["installerIsoWindowsPath"]


@pytest.mark.parametrize("firmware", ["bios", "uefi"])
def test_schema_four_projects_windows_as_the_default_allocation_source(validator, firmware):
    plan = make_plan(firmware, 20)
    validator.validate_plan(plan, require_installer=True)
    values = validator.shell_values(plan)
    assert values["SEPARATE_ALLOCATION_DISK"] == "false"
    assert values["ALLOCATION_DISK_PARTITION_TABLE_ID"] == values["TARGET_DISK_PARTITION_TABLE_ID"]
    assert values["ALLOCATION_SOURCE_OFFSET_BYTES"] == values["WINDOWS_PARTITION_OFFSET_BYTES"]
    assert values["ALLOCATION_SOURCE_SIZE_BYTES"] == values["WINDOWS_PARTITION_SIZE_BYTES"]
    assert values["ALLOCATION_SOURCE_BITLOCKER_STATE"] == values["WINDOWS_BITLOCKER_STATE"]


@pytest.mark.parametrize(
    "changed_field,accepted",
    [("none", True), ("size", False), ("sector", False), ("table", False), ("style", False)],
)
def test_live_disk_identity_requires_every_recorded_field(changed_field, accepted):
    library = Path(__file__).resolve().parents[2] / "assets/live/libertix-storage-common.sh"
    script = r"""
set -eu
source "$1"
fixture_size=68719476736
fixture_sector=512
fixture_table=gpt:87654321-1234-1234-1234-123456789abc
fixture_style=gpt
case "$2" in
    size) fixture_size=68719477248 ;;
    sector) fixture_sector=4096 ;;
    table) fixture_table=gpt:12345678-1234-1234-1234-123456789abc ;;
    style) fixture_style=msdos ;;
esac
blockdev() {
    case "$1" in
        --getsize64) echo "$fixture_size" ;;
        --getss) echo "$fixture_sector" ;;
        *) return 1 ;;
    esac
}
parted() { printf 'BYT;\n/dev/fixture:64GB:scsi:512:512:%s:model:;\n' "$fixture_style"; }
disk_partition_table_identity() { echo "$fixture_table"; }
disk_matches_recorded_identity /dev/fixture 68719476736 512 \
    gpt:87654321-1234-1234-1234-123456789abc GPT
"""
    result = subprocess.run(
        ["bash", "-c", script, "test", str(library), changed_field],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert (result.returncode == 0) == accepted, result.stderr


@pytest.mark.parametrize("matches", [0, 1, 2])
@pytest.mark.parametrize("role", ["allocation", "target"])
def test_live_allocation_resolution_refuses_missing_or_duplicate_disks(matches, role):
    library = Path(__file__).resolve().parents[2] / "assets/live/libertix-storage-common.sh"
    script = r"""
set -eu
source "$1"
match_count="$2"
role="$3"
ALLOCATION_DISK_PARTITION_TABLE_ID=gpt:87654321-1234-1234-1234-123456789abc
TARGET_DISK_PARTITION_TABLE_ID="$ALLOCATION_DISK_PARTITION_TABLE_ID"
candidate_disks() { printf '/dev/windows\n/dev/data\n/dev/usb\n'; }
# No physical block device is queried or changed by this fixture.
[() {
    if test "$#" -eq 3 && test "$1" = -b; then return 0; fi
    builtin [ "$@"
}
disk_partition_table_identity() {
    case "$match_count:$1" in
        1:/dev/data|2:/dev/data|2:/dev/usb) echo "$ALLOCATION_DISK_PARTITION_TABLE_ID" ;;
        *) return 1 ;;
    esac
}
# The USB clone has different geometry, so the complete match rejects it.
# Identity resolution must still fail before accepting the other disk.
allocation_disk_matches_manifest() { test "$1" = /dev/data; }
disk_matches_manifest() { test "$1" = /dev/data; }
if test "$role" = allocation; then
    resolve_allocation_disk_from_manifest
else
    resolve_target_disk_from_manifest
fi
"""
    result = subprocess.run(
        ["bash", "-c", script, "test", str(library), str(matches), role],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert (result.returncode == 0) == (matches == 1), result.stderr
    if matches == 1:
        assert result.stdout.strip() == "/dev/data"
    else:
        assert result.stdout == ""
        assert f"matched {matches} {role} disks" in result.stderr


@pytest.mark.parametrize("observed", ["1234567890ABCDEF", "8765432190ABCDEF", "", "error"])
def test_allocation_resolver_rejects_a_replaced_ntfs_filesystem(observed):
    library = Path(__file__).resolve().parents[2] / "assets/live/libertix-storage-common.sh"
    script = r"""
set -eu
source "$1"
observed="$2"
SEPARATE_ALLOCATION_DISK=true
ALLOCATION_DISK_SIZE_BYTES=68719476736
ALLOCATION_DISK_SECTOR_SIZE_BYTES=512
ALLOCATION_DISK_PARTITION_TABLE_ID=mbr:12345678
ALLOCATION_PARTITION_STYLE=MBR
ALLOCATION_SOURCE_OFFSET_BYTES=1048576
ALLOCATION_SOURCE_NTFS_UUID=1234567890ABCDEF
disk_matches_recorded_identity() { return 0; }
partition_at_offset() { echo /dev/data1; }
blkid() {
    if test "$2" = TYPE; then echo ntfs;
    elif test "$observed" = error; then return 1;
    else printf '%s\n' "$observed"; fi
}
allocation_disk_matches_manifest /dev/data
"""
    result = subprocess.run(
        ["bash", "-c", script, "test", str(library), observed],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert (result.returncode == 0) == (observed == "1234567890ABCDEF"), result.stderr


@pytest.mark.parametrize("separate", [False, True])
def test_live_loader_exports_allocation_in_its_calling_process(tmp_path, separate):
    root = Path(__file__).resolve().parents[2]
    plan = make_separate_allocation_plan() if separate else make_plan("uefi", 20)
    path = tmp_path / "plan.json"
    path.write_text(json.dumps(plan), encoding="utf-8")
    script = r"""
set -eu
source "$1"
load_libertix_installation_plan "$2" "$3"
printf '%s\n' "$SEPARATE_ALLOCATION_DISK" "$ALLOCATION_DISK_PARTITION_TABLE_ID" \
    "$TARGET_DISK_PARTITION_TABLE_ID" "$ALLOCATION_SOURCE_SIZE_BYTES"
"""
    result = subprocess.run(
        [
            "bash",
            "-c",
            script,
            "test",
            str(root / "assets/live/libertix-installation-plan.sh"),
            str(path),
            str(root / "assets/live/libertix-installation-plan.py"),
        ],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    allocation = plan.get("allocation", plan["disk"])
    assert result.stdout.splitlines() == [
        str(separate).lower(),
        allocation["partitionTableId"],
        plan["disk"]["partitionTableId"],
        str((60 if separate else 200) * GIB),
    ]


@pytest.mark.parametrize("separate", [False, True])
def test_bios_boot_flags_and_mbr_backup_use_the_windows_disk(separate):
    root = Path(__file__).resolve().parents[2]
    script = r"""
set -eu
source "$1"
source "$2"
DISK=/dev/allocation
if test "$3" = true; then WINDOWS_DISK=/dev/windows; fi
MBR_BACKUP=/fixture/backup.bin
sfdisk() { printf 'SFDISK=%s\n' "$*"; }
sync() { :; }
partprobe() { printf 'PARTPROBE=%s\n' "$*"; }
udevadm() { :; }
only_mbr_partition_has_boot_flag() { printf 'VERIFY_ACTIVE=%s:%s\n' "$1" "$2"; }
set_mbr_active_partition_verified 1 test
with_windows_mounted_for_mbr_backup() {
    if test "$1" = load; then return 3; fi
    printf 'PUBLISH_BACKUP=%s\n' "$2"
}
run_logged() { printf 'COMMAND=%s\n' "$*"; }
stat() { echo 512; }
prepare_bios_mbr_backup_or_die
"""
    result = subprocess.run(
        [
            "bash",
            "-c",
            script,
            "test",
            str(root / "assets/live/libertix-bios-adapter.sh"),
            str(root / "assets/live/libertix-live-context.sh"),
            str(separate).lower(),
        ],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    expected = "/dev/windows" if separate else "/dev/allocation"
    assert f"SFDISK=--lock --activate {expected} 1" in result.stdout
    assert f"PARTPROBE={expected}" in result.stdout
    assert f"VERIFY_ACTIVE={expected}:1" in result.stdout
    assert f"COMMAND=dd if={expected} of=/fixture/backup.bin" in result.stdout
    assert "PUBLISH_BACKUP=/fixture/backup.bin" in result.stdout
    installer = (root / "assets/live/libertix-install-main.sh").read_text()
    assert 'grub-install --target=i386-pc --recheck "$WINDOWS_DISK"' in installer


@pytest.mark.parametrize("separate", [False, True])
def test_uefi_entry_uses_windows_esp_disk_not_linux_allocation(tmp_path, separate):
    root = Path(__file__).resolve().parents[2]
    script = r"""
set -eu
source "$1"
DISK=/dev/data
if [ "$2" = true ]; then WINDOWS_DISK=/dev/windows; fi
entry_record="$3"
find_exact_uefi_bootnumbers() { if [ -f "$entry_record" ]; then echo 0001; fi; }
run_logged() { printf '%s\n' "$@" > "$entry_record"; }
die() { echo "$*" >&2; exit 1; }
ensure_windows_bootentry_for_current_esp_or_die 2 87654321-1234-1234-1234-123456789abc
"""
    record = tmp_path / "entry-command"
    result = subprocess.run(
        [
            "bash",
            "-c",
            script,
            "test",
            str(root / "assets/live/libertix-uefi-adapter.sh"),
            str(separate).lower(),
            str(record),
        ],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert record.read_text().splitlines() == [
        "efibootmgr",
        "-c",
        "-d",
        "/dev/windows" if separate else "/dev/data",
        "-p",
        "2",
        "-L",
        "Windows Boot Manager",
        "-l",
        r"\EFI\Microsoft\Boot\bootmgfw.efi",
    ]


@pytest.mark.parametrize("separate", [False, True])
def test_mbr_rollback_uses_windows_boot_disk_not_linux_allocation(separate):
    root = Path(__file__).resolve().parents[2]
    script = r"""
set -eu
source "$1"
DISK=/dev/data
if [ "$2" = true ]; then WINDOWS_DISK=/dev/windows; fi
BOOTLOADER_WRITE_STARTED=true
LIBERTIX_FIRMWARE_MODE=bios
MBR_BACKUP=/fixture/mbr.bin
load_bios_mbr_backup_for_rollback() { return 0; }
dd() { printf 'DD_ARG=%s\n' "$@"; }
sync() { :; }
restore_pre_grub_mbr_best_effort
"""
    result = subprocess.run(
        [
            "bash",
            "-c",
            script,
            "test",
            str(root / "assets/live/libertix-rollback-common.sh"),
            str(separate).lower(),
        ],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    expected = "/dev/windows" if separate else "/dev/data"
    assert f"DD_ARG=of={expected}\n" in result.stdout
    assert "DD_ARG=bs=446\n" in result.stdout
    assert "DD_ARG=conv=notrunc\n" in result.stdout
