import subprocess
from pathlib import Path

import pytest


@pytest.mark.parametrize("firmware", ["bios", "uefi"])
@pytest.mark.parametrize("separate", [False, True])
@pytest.mark.parametrize("encrypted", [False, True])
@pytest.mark.parametrize("changed_uuid", [False, True])
def test_offline_resize_uses_only_the_allocation_volume(
    firmware: str, separate: bool, encrypted: bool, changed_uuid: bool
) -> None:
    root = Path(__file__).resolve().parents[2]
    script = r"""
set -eu
source "$1"
source "$5"
LIBERTIX_FIRMWARE_MODE="$2"
separate="$3"
SEPARATE_ALLOCATION_DISK="$separate"
encrypted="$4"
changed_uuid="$6"
ALLOCATION_SOURCE_NTFS_UUID=1234567890ABCDEF
INSTALLER_RESIZE_MODE=live-offline
INSTALLER_ALIGNMENT_BYTES=$((1024*1024))
INSTALLER_STAGING_SIZE_BYTES=$((8*1024*1024*1024))
INSTALLER_FINAL_SIZE_BYTES=$((20*1024*1024*1024))
WINDOWS_PART=/dev/windows3
WINDOWS_PARTITION_OFFSET_BYTES=$((1024*1024))
WINDOWS_PARTITION_SIZE_BYTES=$((60*1024*1024*1024))
WINDOWS_BITLOCKER_STATE=FullyDecrypted
DISK=/dev/windows
source_part="$WINDOWS_PART"
if test "$separate" = true; then
    DISK=/dev/data
    ALLOCATION_SOURCE_PART=/dev/data1
    source_part="$ALLOCATION_SOURCE_PART"
    ALLOCATION_SOURCE_OFFSET_BYTES="$WINDOWS_PARTITION_OFFSET_BYTES"
    ALLOCATION_SOURCE_SIZE_BYTES="$WINDOWS_PARTITION_SIZE_BYTES"
    ALLOCATION_SOURCE_BITLOCKER_STATE=FullyDecrypted
fi
if test "$encrypted" = true; then
    if test "$separate" = true; then
        ALLOCATION_SOURCE_BITLOCKER_STATE=EncryptedOrProtected
    else
        WINDOWS_BITLOCKER_STATE=EncryptedOrProtected
    fi
fi
LIVE_PART=/dev/staging
NEW_PART="$LIVE_PART"
padding=0
if test "$LIBERTIX_FIRMWARE_MODE" = bios; then padding="$INSTALLER_ALIGNMENT_BYTES"; fi
current_size=$((WINDOWS_PARTITION_SIZE_BYTES - INSTALLER_STAGING_SIZE_BYTES - padding))
INSTALLER_FINAL_OFFSET_BYTES=$((
    WINDOWS_PARTITION_OFFSET_BYTES + WINDOWS_PARTITION_SIZE_BYTES - INSTALLER_FINAL_SIZE_BYTES
))
[() {
    if test "$#" -eq 3 && test "$1" = -b; then return 0; fi
    builtin [ "$@"
}
mark() { :; }
die() { echo "$*" >&2; exit 42; }
assert_no_target_disk_mounts() { :; }
assert_not_mounted_or_open() { echo "IDLE=$1"; }
assert_recovery_unchanged_or_die() { echo RECOVERY_CHECKED; }
blkid() {
    if test "$2" = TYPE; then echo ntfs;
    elif test "$changed_uuid" = true; then echo 8765432190ABCDEF;
    else echo 1234567890ABCDEF; fi
}
blockdev() {
    if test "$1" = --getss; then echo 512; else echo "$current_size"; fi
}
run_logged() { printf 'COMMAND=%s\n' "$*"; }
partition_number() { echo 9; }
resize_partition_size_sectors() {
    printf 'RESIZE_TABLE=%s:%s:%s\n' "$1" "$2" "$3"
    current_size=$(($3*512))
}
sync() { :; }
partprobe() { :; }
udevadm() { :; }
partition_start_bytes() {
    if test "$2" = "$source_part"; then echo "$WINDOWS_PARTITION_OFFSET_BYTES";
    else echo "$INSTALLER_FINAL_OFFSET_BYTES"; fi
}
firmware_relocate_installer_partition_or_die() {
    printf 'RELOCATE_STAGING=%s:%s\n' "$1" "$2"
}
prepare_offline_ntfs_resize_or_die
"""
    result = subprocess.run(
        [
            "bash",
            "-c",
            script,
            "test",
            str(root / "assets/live/libertix-offline-ntfs-resize.sh"),
            firmware,
            str(separate).lower(),
            str(encrypted).lower(),
            str(root / "assets/live/libertix-storage-common.sh"),
            str(changed_uuid).lower(),
        ],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    identity_failure = separate and changed_uuid
    assert (result.returncode == 0) == (not encrypted and not identity_failure), (
        result.stdout + result.stderr
    )
    if identity_failure:
        assert "source filesystem no longer matches" in result.stderr
        assert "COMMAND=" not in result.stdout
        assert "RESIZE_TABLE=" not in result.stdout
        return
    if encrypted:
        assert "BitLocker to be absent or fully decrypted" in result.stderr
        assert "COMMAND=" not in result.stdout
        assert "RESIZE_TABLE=" not in result.stdout
        return
    source = "/dev/data1" if separate else "/dev/windows3"
    disk = "/dev/data" if separate else "/dev/windows"
    size = 40 * 1024**3 - (1024**2 if firmware == "bios" else 0)
    assert f"COMMAND=ntfs-3g.probe --readwrite {source}" in result.stdout
    dry_run = f"COMMAND=ntfsresize --no-action --force --size {size} {source}"
    write = f"COMMAND=ntfsresize --force --size {size} {source}"
    resize_table = f"RESIZE_TABLE={disk}:9:{size // 512}"
    assert result.stdout.index(dry_run) < result.stdout.index(write)
    assert result.stdout.index(write) < result.stdout.index(resize_table)
    assert result.stdout.count("RECOVERY_CHECKED") == 3
    if separate:
        assert "/dev/windows" not in result.stdout
