import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize("efi_mounted", ["true", "false"])
def test_rollback_unmounts_nested_efi_variables_before_target(efi_mounted):
    script = r"""
set -eu
source "$1"
efi_mounted="$2"
sys_mounted=true
target_mounted=true
sync() { :; }
rm() { :; }
umount() {
    case "$1" in
        /mnt/target/sys/firmware/efi/efivars) efi_mounted=false ;;
        /mnt/target/sys)
            test "$efi_mounted" = false || return 1
            sys_mounted=false ;;
        /mnt/target)
            test "$sys_mounted" = false || return 1
            target_mounted=false ;;
    esac
}
cleanup_live_mounts_best_effort
test "$target_mounted" = false
"""
    result = subprocess.run(
        [
            "bash",
            "-c",
            script,
            "test",
            str(ROOT / "assets/live/libertix-rollback-common.sh"),
            efi_mounted,
        ],
        text=True,
        capture_output=True,
        timeout=10,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.parametrize("fault", ["copy", "flush", "none"])
def test_live_mbr_restore_preserves_copy_and_flush_failures(fault):
    script = r"""
set -eu
source "$1"
fault="$2"
BOOTLOADER_WRITE_STARTED=true
LIBERTIX_FIRMWARE_MODE=bios
MBR_BACKUP=/fixture/mbr.bin
WINDOWS_DISK=/dev/fixture
load_bios_mbr_backup_for_rollback() { return 0; }
dd() { echo COPY; test "$fault" != copy; }
sync() { echo FLUSH; test "$fault" != flush; }
if restore_pre_grub_mbr_best_effort; then exit 0; else exit 1; fi
"""
    result = subprocess.run(
        [
            "bash",
            "-c",
            script,
            "test",
            str(ROOT / "assets/live/libertix-rollback-common.sh"),
            fault,
        ],
        text=True,
        capture_output=True,
        timeout=10,
        check=False,
    )
    assert (result.returncode == 0) == (fault == "none"), result.stdout + result.stderr


@pytest.mark.parametrize("firmware", ["bios", "uefi"])
@pytest.mark.parametrize(
    "offset_gib,size_bytes,accepted",
    [
        (44, 8 * 1024**3, True),
        (32, 20 * 1024**3, True),
        (32, 20 * 1024**3 - 1024**2, True),
        (32, 21 * 1024**3, False),
        (44, 9 * 1024**3, False),
        (32, 0, False),
        (32, 19 * 1024**3, False),
        (31, 20 * 1024**3, False),
    ],
)
def test_live_rollback_requires_the_recorded_partition_extent(
    firmware, offset_gib, size_bytes, accepted
):
    script = r"""
set -eu
source "$1"
source "$2"
DISK=/dev/fixture
WINDOWS_PART=/dev/fixture3
INSTALLER_PARTITION_OFFSET_BYTES=$((44*1024*1024*1024))
INSTALLER_STAGING_SIZE_BYTES=$((8*1024*1024*1024))
INSTALLER_FINAL_OFFSET_BYTES=$((32*1024*1024*1024))
INSTALLER_FINAL_SIZE_BYTES=$((20*1024*1024*1024))
INSTALLER_ALIGNMENT_BYTES=$((1024*1024))
fixture_offset="$3"
fixture_size="$4"
parent_disk_from_part() { echo /dev/fixture; }
partition_start_bytes() { echo "$fixture_offset"; }
blockdev() { echo "$fixture_size"; }
firmware_rollback_partition_is_owned /dev/fixture4
"""
    result = subprocess.run(
        [
            "bash",
            "-c",
            script,
            "test",
            str(ROOT / "assets/live/libertix-storage-common.sh"),
            str(ROOT / f"assets/live/libertix-{firmware}-adapter.sh"),
            str(offset_gib * 1024**3),
            str(size_bytes),
        ],
        text=True,
        capture_output=True,
        timeout=10,
        check=False,
    )
    assert (result.returncode == 0) == accepted, result.stdout + result.stderr


@pytest.mark.parametrize(
    "fault",
    [
        "begin",
        "resolve",
        "mbr",
        "esp",
        "delete",
        "container",
        "resize",
        "boot",
        "compensate",
        "complete",
        "none",
    ],
)
def test_live_rollback_never_reports_success_after_a_failed_physical_step(fault):
    script = r"""
set -eu
source "$1"
fault="$2"
INSTALL_SUCCESS=false
ROLLBACK_ATTEMPTED=false
BOOTLOADER_WRITE_STARTED=true
RECOVERY_GEOMETRY_BEFORE=
probe() { echo "CALL=$1"; test "$fault" != "$1"; }
begin_installation_state_rollback() { probe begin; }
resolve_rollback_storage_best_effort() { probe resolve; }
cleanup_live_mounts_best_effort() { :; }
swapoff() { :; }
restore_pre_grub_mbr_best_effort() { probe mbr; }
firmware_prepare_rollback_best_effort() { probe esp; }
delete_transaction_partition_best_effort() { probe delete; }
firmware_cleanup_partition_container_best_effort() { probe container; }
restore_windows_partition_best_effort() { probe resize; }
firmware_restore_boot_state_best_effort() { probe boot; }
debug_disk_state() { :; }
compensate_installation_state_step() { probe compensate; }
complete_installation_state_rollback() { probe complete; }
rollback_windows_layout_best_effort
"""
    result = subprocess.run(
        [
            "bash",
            "-c",
            script,
            "test",
            str(ROOT / "assets/live/libertix-rollback-common.sh"),
            fault,
        ],
        text=True,
        capture_output=True,
        timeout=10,
        check=False,
    )
    assert (result.returncode == 0) == (fault == "none"), result.stdout + result.stderr
    if fault != "none":
        assert "completed best-effort Windows layout restore" not in result.stdout
        if fault != "complete":
            assert "CALL=complete\n" not in result.stdout
        if fault not in {"begin", "compensate", "complete"}:
            assert "CALL=compensate" not in result.stdout
    if fault in {"begin", "compensate", "complete"}:
        assert "CALL=resize" in result.stdout
        assert (
            "physical restore completed but durable rollback state is incomplete" in result.stdout
        )
    if fault in {"resolve", "delete", "container"}:
        assert "CALL=resize" not in result.stdout
    if fault == "resolve":
        assert "CALL=delete" not in result.stdout


@pytest.mark.parametrize("fault", ["none", "missing-windows", "missing-allocation", "same-disk"])
def test_live_rollback_reresolves_both_disks_instead_of_trusting_cached_names(fault):
    script = r"""
set -eu
source "$1"
fault="$2"
SEPARATE_ALLOCATION_DISK=true
TARGET_DISK_SIZE_BYTES=10000
DISK=/dev/stale
WINDOWS_DISK=/dev/stale
WINDOWS_PART=/dev/stale3
WINDOWS_PARTITION_OFFSET_BYTES=1000
ALLOCATION_SOURCE_OFFSET_BYTES=2000
udevadm() { :; }
sleep() { :; }
[() {
    if test "$#" -eq 3 && test "$1" = -b; then test -n "$2"; return; fi
    builtin [ "$@"
}
resolve_target_disk_from_manifest() {
    echo RESOLVE_WINDOWS >&2
    test "$fault" != missing-windows || return 1
    echo /dev/windows
}
resolve_allocation_disk_from_manifest() {
    echo RESOLVE_ALLOCATION >&2
    test "$fault" != missing-allocation || return 1
    if test "$fault" = same-disk; then echo /dev/windows; else echo /dev/allocation; fi
}
partition_at_offset() {
    case "$1:$2" in
        /dev/windows:1000) echo /dev/windows3 ;;
        /dev/allocation:2000) echo /dev/allocation1 ;;
        *) return 1 ;;
    esac
}
resolve_rollback_storage_best_effort
printf 'RESOLVED=%s:%s:%s:%s\n' "$WINDOWS_DISK" "$DISK" "$WINDOWS_PART" "$ALLOCATION_SOURCE_PART"
"""
    result = subprocess.run(
        [
            "bash",
            "-c",
            script,
            "test",
            str(ROOT / "assets/live/libertix-rollback-common.sh"),
            fault,
        ],
        text=True,
        capture_output=True,
        timeout=10,
        check=False,
    )
    assert (result.returncode == 0) == (fault == "none"), result.stdout + result.stderr
    assert "RESOLVE_WINDOWS" in result.stderr
    assert "RESOLVE_ALLOCATION" in result.stderr
    assert "/dev/stale" not in result.stdout
    if fault == "none":
        assert (
            "RESOLVED=/dev/windows:/dev/allocation:/dev/windows3:/dev/allocation1" in result.stdout
        )
    else:
        assert "RESOLVED=" not in result.stdout


@pytest.mark.parametrize(
    "rows,accepted",
    [
        ("3:4096B:6143B:2048B:ntfs::;", True),
        (
            "1:1024B:4095B:3072B:fat32::;\n3:4096B:6143B:2048B:ntfs::;\n"
            "4:8192B:16383B:8192B:ntfs::;",
            True,
        ),
        ("3:4096B:6143B:2048B:ntfs::;\n4:7168B:8191B:1024B:fat32::;", False),
        ("3:4096B:8192B:4097B:ntfs::;", False),
        ("3:4097B:6143B:2047B:ntfs::;", False),
        ("3:4096B:6143B:2048B:ntfs::;\n3:4096B:6143B:2048B:ntfs::;", False),
        ("", False),
        ("3:invalid:6143B:2048B:ntfs::;", False),
    ],
)
def test_live_rollback_refuses_to_expand_over_an_unrelated_partition(rows, accepted):
    script = r"""
set -eu
source "$1"
rows="$2"
parted() { printf 'BYT;\n/dev/fixture:32768B:scsi:512:512:gpt:fixture:;\n%s\n' "$rows"; }
assert_source_restore_extent_is_free /dev/fixture 3 4096 4096
"""
    result = subprocess.run(
        ["bash", "-c", script, "test", str(ROOT / "assets/live/libertix-rollback-common.sh"), rows],
        text=True,
        capture_output=True,
        timeout=10,
        check=False,
    )
    assert (result.returncode == 0) == accepted, result.stdout + result.stderr


@pytest.mark.parametrize(
    "firmware,recovery_offset,recovery_size,accepted",
    [
        ("uefi", 256 * 1024**2, 512 * 1024**2, True),
        ("uefi", 220 * 1024**3, 1024**3, True),
        ("uefi", 190 * 1024**3, 1024**3, False),
        ("bios", 256 * 1024**2, 512 * 1024**2, False),
        ("bios", 220 * 1024**3, 1024**3, True),
    ],
)
@pytest.mark.parametrize("separate", [False, True])
@pytest.mark.parametrize("changed_uuid", [False, True])
def test_live_rollback_restores_only_the_recorded_windows_extent(
    firmware: str,
    recovery_offset: int,
    recovery_size: int,
    accepted: bool,
    separate: bool,
    changed_uuid: bool,
) -> None:
    script = r"""
set -eu
source "$1"
LIBERTIX_FIRMWARE_MODE="$2"
source "$6"
ALLOCATION_SOURCE_NTFS_UUID=1234567890ABCDEF
changed_uuid="$7"
blkid() {
    if test "$2" = TYPE; then echo ntfs;
    elif test "$changed_uuid" = true; then echo 8765432190ABCDEF;
    else echo 1234567890ABCDEF; fi
}
RECOVERY_PARTITION_OFFSET_BYTES="$3"
RECOVERY_PARTITION_SIZE_BYTES="$4"
WINDOWS_PARTITION_OFFSET_BYTES=$((1024*1024*1024))
WINDOWS_PARTITION_SIZE_BYTES=$((200*1024*1024*1024))
DISK=/dev/fixture-disk
WINDOWS_PART=/dev/fixture-windows
SEPARATE_ALLOCATION_DISK="$5"
if test "$SEPARATE_ALLOCATION_DISK" = true; then
    WINDOWS_DISK=/dev/windows
    ALLOCATION_SOURCE_PART=/dev/fixture-source
    ALLOCATION_SOURCE_OFFSET_BYTES="$WINDOWS_PARTITION_OFFSET_BYTES"
    ALLOCATION_SOURCE_SIZE_BYTES="$WINDOWS_PARTITION_SIZE_BYTES"
fi
partition_number() { echo 3; }
blockdev() {
    if [ "$1" = --getss ]; then echo 512; else echo "$WINDOWS_PARTITION_SIZE_BYTES"; fi
}
bytes_to_logical_sectors() { echo $(($1 / $2)); }
resize_partition_size_sectors() { printf 'RESIZE=%s:%s:%s\n' "$1" "$2" "$3"; }
partition_start_bytes() { echo "$WINDOWS_PARTITION_OFFSET_BYTES"; }
partprobe() { :; }
udevadm() { :; }
ntfsresize() { echo "NTFS_RESIZE=$*"; }
ntfsfix() { :; }
parted() {
    printf 'BYT;\n/dev/fixture-disk:300000000000B:scsi:512:512:gpt:fixture:;\n'
    printf '3:%sB:%sB:%sB:ntfs::;\n' "$WINDOWS_PARTITION_OFFSET_BYTES" \
        "$((WINDOWS_PARTITION_OFFSET_BYTES + WINDOWS_PARTITION_SIZE_BYTES - 1))" \
        "$WINDOWS_PARTITION_SIZE_BYTES"
}
restore_windows_partition_best_effort
"""
    result = subprocess.run(
        [
            "bash",
            "-c",
            script,
            "test",
            str(ROOT / "assets/live/libertix-rollback-common.sh"),
            firmware,
            str(recovery_offset),
            str(recovery_size),
            str(separate).lower(),
            str(ROOT / "assets/live/libertix-storage-common.sh"),
            str(changed_uuid).lower(),
        ],
        text=True,
        capture_output=True,
        timeout=10,
        check=False,
    )
    expected_success = (accepted or separate) and not (separate and changed_uuid)
    assert (result.returncode == 0) == expected_success, result.stdout + result.stderr
    if expected_success:
        assert f"RESIZE=/dev/fixture-disk:3:{200 * 1024**3 // 512}" in result.stdout
        assert "NTFS_RESIZE" in result.stdout
        expected_source = "/dev/fixture-source" if separate else "/dev/fixture-windows"
        assert f"NTFS_RESIZE=-f {expected_source}" in result.stdout
        if separate:
            assert "/dev/fixture-windows" not in result.stdout
    else:
        assert "RESIZE=" not in result.stdout
        assert "NTFS_RESIZE" not in result.stdout
