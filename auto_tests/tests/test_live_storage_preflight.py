import subprocess
from pathlib import Path

import pytest


@pytest.mark.parametrize(
    "separate,fault,accepted",
    [
        (False, "none", True),
        (True, "none", True),
        (True, "windows-size", False),
        (True, "allocation-identity", False),
        (True, "windows-identity", False),
        (True, "same-disk", False),
        (True, "source-overlap", False),
        (True, "source-gap", False),
        (True, "source-uuid", False),
        (True, "source-uuid-missing", False),
        (False, "source-overlap", False),
    ],
)
def test_live_preflight_checks_both_disks_without_conflating_their_sizes(
    separate: bool, fault: str, accepted: bool
) -> None:
    root = Path(__file__).resolve().parents[2]
    script = r"""
set -eu
source "$1"
source "$4"
SEPARATE_ALLOCATION_DISK="$2"
fault="$3"
WINDOWS_DISK=/dev/windows
DISK=/dev/windows
if test "$SEPARATE_ALLOCATION_DISK" = true; then DISK=/dev/allocation; fi
if test "$fault" = same-disk; then DISK=/dev/windows; fi
WINDOWS_PART=/dev/windows3
ALLOCATION_SOURCE_PART="$WINDOWS_PART"
if test "$SEPARATE_ALLOCATION_DISK" = true; then ALLOCATION_SOURCE_PART=/dev/allocation1; fi
ALLOCATION_SOURCE_OFFSET_BYTES=1024
ALLOCATION_SOURCE_SIZE_BYTES=8192
ALLOCATION_SOURCE_NTFS_UUID=1234567890ABCDEF
if test "$fault" = source-uuid-missing; then unset ALLOCATION_SOURCE_NTFS_UUID; fi
INSTALLER_PARTITION_OFFSET_BYTES=5120
INSTALLER_ALIGNMENT_BYTES=1024
LIVE_PART=/dev/allocation2
WINDOWS_PARTITION_SIZE_BYTES=4000
TARGET_DISK_SIZE_BYTES=10000
TARGET_LOGICAL_SECTOR_SIZE_BYTES=512
TARGET_DISK_PARTITION_TABLE_ID=gpt:windows
EXPECTED_PARTITION_STYLE=GPT
ALLOCATION_DISK_SIZE_BYTES=20000
ALLOCATION_DISK_SECTOR_SIZE_BYTES=512
ALLOCATION_DISK_PARTITION_TABLE_ID=mbr:12345678
ALLOCATION_PARTITION_STYLE=MBR
LIVE_MINIMUM_MEMORY_MIB=1
LOW_MEMORY_MODE=false
[() {
    if test "$#" -eq 3 && test "$1" = -b; then return 0; fi
    builtin [ "$@"
}
mark() { :; }
die() { echo "$*" >&2; exit 42; }
lsblk() { echo disk; }
find() { :; }
findmnt() { :; }
blkid() {
    if test "$2" = TYPE; then echo ntfs;
    elif test "$fault" = source-uuid; then echo 8765432190ABCDEF;
    else echo 1234567890ABCDEF; fi
}
blockdev() {
    if test "$1" = --getss; then echo 512; return; fi
    if test "$2" = "$ALLOCATION_SOURCE_PART"; then
        case "$fault" in
            source-overlap) echo 5000 ;;
            source-gap) echo 2048 ;;
            *) echo 4096 ;;
        esac
        return
    fi
    if test "$fault" = windows-size; then echo 3000; else echo 4000; fi
}
parent_disk_from_part() { echo "$DISK"; }
partition_start_bytes() { echo "$ALLOCATION_SOURCE_OFFSET_BYTES"; }
disk_matches_recorded_identity() {
    printf 'IDENTITY=%s:%s:%s:%s:%s\n' "$@"
    case "$fault:$1" in
        allocation-identity:/dev/allocation|windows-identity:/dev/windows) return 1 ;;
    esac
}
assert_recovery_unchanged_or_die() { echo RECOVERY_CHECKED; }
validate_live_boot_mode() { :; }
run_live_preflight
"""
    result = subprocess.run(
        [
            "bash",
            "-c",
            script,
            "test",
            str(root / "assets/live/libertix-install-platform-common.sh"),
            str(separate).lower(),
            fault,
            str(root / "assets/live/libertix-storage-common.sh"),
        ],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert (result.returncode == 0) == accepted, result.stdout + result.stderr
    assert "IDENTITY=/dev/windows:10000:512:gpt:windows:GPT" in result.stdout
    if separate and fault not in {"windows-identity", "same-disk"}:
        assert "IDENTITY=/dev/allocation:20000:512:mbr:12345678:MBR" in result.stdout
    else:
        assert "IDENTITY=/dev/allocation" not in result.stdout
    assert ("LIVE_PREFLIGHT_OK=true" in result.stdout) == accepted
    assert ("RECOVERY_CHECKED" in result.stdout) == accepted
