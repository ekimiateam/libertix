#!/bin/bash
set -Eeuo pipefail

[ "$EUID" -ne 0 ] && { echo "Run as root"; exit 1; }

case "${LIBERTIX_FIRMWARE_MODE:-}" in
    bios|uefi) ;;
    *) echo "LIBERTIX_FIRMWARE_MODE must be bios or uefi" >&2; exit 2 ;;
esac

LOG_DIR="/run/libertix"
STAGE_FILE="$LOG_DIR/stage"
FAIL_FILE="$LOG_DIR/failure"
mkdir -p "$LOG_DIR"

CURRENT_STAGE="bootstrap"
DISK=""
DISKNAME=""
LIVE_PART=""
WINDOWS_PART=""
WINDOWS_BOOT_PART=""
NEW_PART=""
NEW_PART_NUM=""
INSTALL_SUCCESS=false
ROLLBACK_ATTEMPTED=false
BOOTLOADER_WRITE_STARTED=false
MBR_BACKUP="$LOG_DIR/mbr-before-grub.bin"
RECOVERY_GEOMETRY_BEFORE=""
# Keep rollback-safe defaults available before the configuration file is parsed.
# ERR can fire during bootstrap and rollback must never fail because of `set -u`.
TARGET_DISK_SIZE_BYTES=""
WINDOWS_PARTITION_OFFSET_BYTES=""
WINDOWS_BOOT_PARTITION_OFFSET_BYTES=""
INSTALLER_PARTITION_OFFSET_BYTES=""
EXPECTED_PARTITION_STYLE=""
RECOVERY_PARTITION_OFFSET_BYTES=""
RECOVERY_PARTITION_SIZE_BYTES=""
RECOVERY_ROOT_WINDOWS=""
RECOVERY_RUN_ID=""
echo "$CURRENT_STAGE" > "$STAGE_FILE"

mark() {
    CURRENT_STAGE="$1"
    echo "$CURRENT_STAGE" > "$STAGE_FILE"
    echo "STAGE: $CURRENT_STAGE"
    echo "LIBERTIX STAGE: $CURRENT_STAGE" > /dev/kmsg 2>/dev/null || true
    touch "$LOG_DIR/${CURRENT_STAGE}.started" 2>/dev/null || true
}

die() {
    local msg="$*"
    echo "ERROR: stage=$CURRENT_STAGE: $msg"
    {
        echo "stage=$CURRENT_STAGE"
        echo "error=$msg"
        echo "time=$(date -Is 2>/dev/null || date)"
    } > "$FAIL_FILE"
    fail_and_exit 1 "$msg"
}

on_err() {
    local rc="$?"
    local line="${BASH_LINENO[0]:-unknown}"
    local cmd="${BASH_COMMAND:-unknown}"
    local msg="stage=$CURRENT_STAGE rc=$rc line=$line cmd=$cmd"
    echo "ERROR: $msg"
    {
        echo "stage=$CURRENT_STAGE"
        echo "rc=$rc"
        echo "line=$line"
        echo "cmd=$cmd"
        echo "time=$(date -Is 2>/dev/null || date)"
    } > "$FAIL_FILE"
    fail_and_exit "$rc" "$msg"
}
trap on_err ERR

. /usr/local/lib/libertix/libertix-install-platform-common.sh
. /usr/local/lib/libertix/libertix-storage-common.sh
. /usr/local/lib/libertix/libertix-install-runtime-common.sh
. /usr/local/lib/libertix/libertix-target-common.sh
. /usr/local/lib/libertix/libertix-rollback-common.sh
. /usr/local/lib/libertix/libertix-installation-plan.sh
. /usr/local/lib/libertix/libertix-live-context.sh
if [ "$LIBERTIX_FIRMWARE_MODE" = "bios" ]; then
    . /usr/local/lib/libertix/libertix-bios-adapter.sh
else
    . /usr/local/lib/libertix/libertix-uefi-adapter.sh
fi

echo "Libertix build: $(cat /etc/libertix-build-id 2>/dev/null || echo unknown)"
wait_for_prereqs

# Load the validated plan that Windows persisted before booting the live system.
# No defaults are accepted here: every destructive decision must match the same
# disk identities, sizes, hashes, locale, and recovery transaction.
mark "010-read-config"
load_libertix_live_context "$LIBERTIX_FIRMWARE_MODE" || die "installation plan could not be loaded"

echo "Plan: Id=$INSTALLATION_PLAN_ID Lang=$SYSTEM_LANG Keyboard=$KEYBOARD_LAYOUT Variant=$KEYBOARD_VARIANT User=$USERNAME LinuxSize=${LINUX_SIZE_GB}GB"

# Detect the exact disk recorded by Windows. The live medium source is useful
# evidence, but never sufficient by itself because toram/loop devices can hide
# the parent disk and removable media may contain similar labels.
mark "020-detect-disk"
TARGET_DISK=$(resolve_target_disk_from_manifest || true)
LIVE_PART=""

if [ -z "$TARGET_DISK" ]; then
    echo "ERROR: no target disk found"
    echo "--- candidate disks ---"
    candidate_disks || true
    echo "--- lsblk ---"
    lsblk -e7 -o NAME,MAJ:MIN,PKNAME,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS || true
fi

[ ! -b "$TARGET_DISK" ] && die "target disk not found: $TARGET_DISK"

DISK="$TARGET_DISK"
DISKNAME="$(basename "$DISK")"

LIVE_PART=$(partition_at_offset "$DISK" "$INSTALLER_PARTITION_OFFSET_BYTES" || true)
[ -n "$LIVE_PART" ] && [ -b "$LIVE_PART" ] || die "Installer partition does not match the Windows manifest"

lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$DISK"

PART_TABLE=$(parted -sm "$DISK" print 2>/dev/null | awk -F: 'NR==2{print $6}')
PART_COUNT=$(partition_count "$DISK")
MBR_PRIMARY_SLOT_COUNT=0
if [ "$PART_TABLE" = "msdos" ]; then
    MBR_PRIMARY_SLOT_COUNT=$(mbr_primary_slot_count "$DISK")
fi
RECOVERY_GEOMETRY_BEFORE="$(recovery_geometry "$DISK")"
[ -n "$RECOVERY_GEOMETRY_BEFORE" ] && echo "Recovery partition geometry before install: $RECOVERY_GEOMETRY_BEFORE"

WINDOWS_PART=$(partition_at_offset "$DISK" "$WINDOWS_PARTITION_OFFSET_BYTES" || true)
WINDOWS_SIZE=0
[ -n "$WINDOWS_PART" ] && WINDOWS_SIZE=$(($(blockdev --getsize64 "$WINDOWS_PART" 2>/dev/null || echo 0) / 1024 / 1024))

if [ -z "$WINDOWS_PART" ] || [ "$(blkid -s TYPE -o value "$WINDOWS_PART" 2>/dev/null || true)" != "ntfs" ]; then
    BITLOCKER_PART="$(find_biggest_bitlocker_partition "$DISK" || true)"
    if [ -n "$BITLOCKER_PART" ]; then
        die "Windows partition is BitLocker-encrypted: $BITLOCKER_PART"
    fi
    echo "--- no NTFS Windows partition detected on $DISK ---"
    lsblk -e7 -o NAME,MAJ:MIN,PKNAME,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS "$DISK" || true
    die "Windows partition does not match the Windows manifest"
fi
echo "Windows: $WINDOWS_PART (${WINDOWS_SIZE}MB)"
echo "$WINDOWS_PART" > "$LOG_DIR/windows-partition"

if [ "$LIBERTIX_FIRMWARE_MODE" = "bios" ]; then
    WINDOWS_BOOT_PART=$(partition_at_offset "$DISK" "$WINDOWS_BOOT_PARTITION_OFFSET_BYTES" || true)
    [ -n "$WINDOWS_BOOT_PART" ] && [ -b "$WINDOWS_BOOT_PART" ] || \
        die "Windows boot partition does not match the Windows manifest"
    [ "$(parent_disk_from_part "$WINDOWS_BOOT_PART")" = "$DISK" ] || \
        die "Windows boot partition is not on the target disk"
    echo "Windows boot partition: $WINDOWS_BOOT_PART"
fi

run_live_preflight
cleanup_windows_live_boot_artifacts
mark "027-windows-live-boot-cleaned"
if [ "$LIBERTIX_FIRMWARE_MODE" = "uefi" ]; then
    write_windows_recovery_marker_best_effort "live-started" 0
fi

# Windows already reserved the full requested Linux size; this is only the
# reference used to decide whether any additional live-side shrink is needed.
LINUX_SIZE_MB=$((LINUX_SIZE_GB * 1024))

CURRENT_FREE_MB=0
while IFS= read -r line; do
    if echo "$line" | grep -qi "Free Space"; then
        vals=($(echo "$line" | grep -oE '[0-9]+(\.[0-9]+)?MB' | sed 's/MB//'))
        [ "${#vals[@]}" -ge 3 ] && {
            sz=${vals[2]%%.*}
            [ "$sz" -gt "$CURRENT_FREE_MB" ] 2>/dev/null && CURRENT_FREE_MB=$sz
        }
    fi
done <<< "$(parted "$DISK" unit MB print free 2>/dev/null)"

echo "Current free space: ${CURRENT_FREE_MB}MB"
echo "Desired Linux size: ${LINUX_SIZE_MB}MB (${LINUX_SIZE_GB}GB)"

ADDITIONAL_SHRINK_MB=$((LINUX_SIZE_MB - CURRENT_FREE_MB))

if [ -n "$LIVE_PART" ] && [ "$(parent_disk_from_part "$LIVE_PART")" = "$DISK" ]; then
    echo "Live partition already exists at $LIVE_PART; skipping live-side Windows shrink."
    echo "Windows/Libertix created this partition at the final Linux size."
    ADDITIONAL_SHRINK_MB=0
fi

if [ "$ADDITIONAL_SHRINK_MB" -gt 1024 ]; then
    echo "=== Additional NTFS shrinking needed: ${ADDITIONAL_SHRINK_MB}MB ==="

    NEW_WINDOWS_SIZE_MB=$((WINDOWS_SIZE - ADDITIONAL_SHRINK_MB))

    if [ "$NEW_WINDOWS_SIZE_MB" -lt 20480 ]; then
        echo "WARNING: New Windows size would be less than 20GB, limiting shrink"
        NEW_WINDOWS_SIZE_MB=20480
        ADDITIONAL_SHRINK_MB=$((WINDOWS_SIZE - NEW_WINDOWS_SIZE_MB))
    fi

    echo "Shrinking Windows from ${WINDOWS_SIZE}MB to ${NEW_WINDOWS_SIZE_MB}MB..."

    umount "$WINDOWS_PART" 2>/dev/null || true

    # Shrink the NTFS filesystem before moving its partition boundary. Reversing
    # this order can cut live filesystem data from the block device.
    echo "Checking NTFS filesystem..."
    ntfsfix "$WINDOWS_PART" || die "NTFS pre-resize check failed"

    NEW_SIZE_BYTES=$((NEW_WINDOWS_SIZE_MB * 1024 * 1024))
    echo "Resizing NTFS to ${NEW_WINDOWS_SIZE_MB}MB..."
    ntfsresize -f -s "${NEW_SIZE_BYTES}" "$WINDOWS_PART" <<< "y" || \
        die "ntfsresize failed; the partition table was not changed"

    PART_NUM=$(echo "$WINDOWS_PART" | grep -oE '[0-9]+$')
    echo "Resizing partition table..."
    parted -s "$DISK" resizepart "$PART_NUM" "${NEW_WINDOWS_SIZE_MB}MB" 2>/dev/null || \
        die "parted failed after NTFS resize; rollback is required"

    sync
    partprobe "$DISK" 2>/dev/null || true
    sleep 2

    WINDOWS_SIZE=$(($(blockdev --getsize64 "$WINDOWS_PART" 2>/dev/null || echo 0) / 1024 / 1024))
    echo "Windows partition now: ${WINDOWS_SIZE}MB"
    [ "$WINDOWS_SIZE" -ge "$((NEW_WINDOWS_SIZE_MB - 8))" ] && \
        [ "$WINDOWS_SIZE" -le "$((NEW_WINDOWS_SIZE_MB + 8))" ] || \
        die "Windows partition size verification failed after resize"
else
    echo "No additional shrinking needed (current free space is sufficient)"
fi

mark "030-check-mint-iso"
ISO_WINDOWS_REL=$(windows_path_to_relative "$ISO_WINDOWS_PATH")
ISO_SOURCE="/mnt/windows/$ISO_WINDOWS_REL"

mount_windows_ro_with_retry "$WINDOWS_PART" /mnt/windows
wait_for_iso_source_or_die "$ISO_SOURCE" "$ISO_WINDOWS_REL"

# Keep Windows NTFS unmounted while changing the MBR table. Any mounted
# partition on the target disk can make BLKRRPART/partprobe keep the old view.
mark "035-umount-windows"
run_logged umount /mnt/windows

NEW_PART=""
NEW_PART_NUM=""

if [ -n "$LIVE_PART" ] && [ "$(parent_disk_from_part "$LIVE_PART")" = "$DISK" ]; then
    echo "=== Reusing live partition $LIVE_PART as final Linux partition ==="
    echo "The validated staging partition will become the final Linux partition."
    mark "040-unmount-target-disk"
    unmount_target_disk_partitions
    assert_no_target_disk_mounts
    NEW_PART="$LIVE_PART"
    NEW_PART_NUM=$(partition_number "$NEW_PART")
    mark "050-assert-live-detached"
    assert_not_mounted_or_open "$NEW_PART"

    # Windows may deliberately create a small FAT32 staging partition when
    # the requested Linux size exceeds the historical Windows FAT32 limit.
    # C: has already been shrunk by the complete requested size, leaving the
    # remainder contiguous after this partition. Expand it before mkfs.ext4.
    current_partition_bytes=$(blockdev --getsize64 "$NEW_PART" 2>/dev/null || echo 0)
    requested_partition_bytes=$((LINUX_SIZE_GB * 1024 * 1024 * 1024))
    desired_partition_bytes="$requested_partition_bytes"
    if [ "$current_partition_bytes" -lt "$requested_partition_bytes" ]; then
        logical_sector_bytes=$(blockdev --getss "$DISK" 2>/dev/null || echo 0)
        [ "$logical_sector_bytes" -gt 0 ] || die "cannot determine target disk logical sector size"
        partition_start_sector=$(cat "/sys/class/block/$(basename "$NEW_PART")/start" 2>/dev/null || echo 0)
        [ "$partition_start_sector" -gt 0 ] || die "cannot determine installer partition start sector"
        recovery_start_sector=$((RECOVERY_PARTITION_OFFSET_BYTES / logical_sector_bytes))
        maximum_partition_bytes=$(((recovery_start_sector - partition_start_sector) * logical_sector_bytes))
        desired_partition_bytes=$(installer_partition_target_bytes \
            "$requested_partition_bytes" "$maximum_partition_bytes") || \
            die "requested Linux partition would overlap the Windows recovery partition"

        if [ "$current_partition_bytes" -lt "$desired_partition_bytes" ]; then
            desired_partition_sectors=$((desired_partition_bytes / logical_sector_bytes))
            desired_end_sector=$((partition_start_sector + desired_partition_sectors - 1))
            echo "Expanding FAT32 staging partition from $current_partition_bytes to $desired_partition_bytes bytes before ext4 format"
            run_logged parted -s "$DISK" unit s resizepart "$NEW_PART_NUM" "${desired_end_sector}s"
            sync
            partprobe "$DISK" 2>/dev/null || true
            udevadm settle 2>/dev/null || true
            sleep 2
        fi

        expanded_partition_bytes=$(blockdev --getsize64 "$NEW_PART" 2>/dev/null || echo 0)
        [ "$expanded_partition_bytes" -eq "$desired_partition_bytes" ] || \
            die "installer partition expansion verification failed: expected $desired_partition_bytes, got $expanded_partition_bytes"
    fi
elif [ "$PART_TABLE" = "msdos" ] && [ "$MBR_PRIMARY_SLOT_COUNT" -ge 4 ]; then
    echo "ERROR: MBR has $MBR_PRIMARY_SLOT_COUNT primary slots and no removable live partition was found"
    echo "Refusing to delete or move the Windows recovery partition"
    print_disk_state "no live partition found"
    die "MBR full and no live partition found"
fi

if [ -z "$NEW_PART" ]; then
    # Find free space and create partition. This path is only used when the live
    # media is not on the target disk.
    unmount_target_disk_partitions
    assert_no_target_disk_mounts
    partprobe "$DISK" 2>/dev/null || true; sleep 1
    max_size=0; best_start=""; best_end=""
    while IFS= read -r line; do
        if echo "$line" | grep -qi "Free Space"; then
            vals=($(echo "$line" | grep -oE '[0-9]+(\.[0-9]+)?MB' | sed 's/MB//'))
            [ "${#vals[@]}" -ge 3 ] || continue
            sz=${vals[2]%%.*}
            [ "$sz" -gt "$max_size" ] 2>/dev/null && { max_size=$sz; best_start=${vals[0]%%.*}; best_end=${vals[1]%%.*}; }
        fi
    done <<< "$(parted "$DISK" unit MB print free 2>/dev/null)"

    [ "$max_size" -lt 5000 ] && die "<5GB free"

    echo "Creating Linux partition (${max_size}MB)"
    parted -s "$DISK" mkpart primary ext4 "${best_start}MB" "${best_end}MB"
    sync; partprobe "$DISK" 2>/dev/null || true; sleep 2

    for i in 1 2 3 4 5; do
        tp=$(partition_path "$DISK" "$i")
        [ -b "$tp" ] || continue
        fs=$(blkid -s TYPE -o value "$tp" 2>/dev/null || echo "")
        [ -z "$fs" ] && { NEW_PART="$tp"; break; }
    done
    [ -z "$NEW_PART" ] && NEW_PART=$(lsblk -nr -o NAME,TYPE "$DISK" | awk '$2=="part"{p="/dev/"$1}END{print p}')
    NEW_PART_NUM=$(echo "$NEW_PART" | grep -oE '[0-9]+$')
fi

prepare_installer_partition_for_target_format_or_die
set_linux_partition_type_or_die

mark "070-wipefs-live-part"
run_logged wipefs -a "$NEW_PART" || die "Failed to clear old signatures on $NEW_PART"
mark "080-mkfs-ext4"
run_logged mkfs.ext4 -F "$NEW_PART"
mkdir -p /mnt/target /mnt/iso
mark "090-mount-target"
run_logged mount "$NEW_PART" /mnt/target

mark "100-remount-windows-ro"
mount_windows_ro_with_retry "$WINDOWS_PART" /mnt/windows
wait_for_iso_source_or_die "$ISO_SOURCE" "$ISO_WINDOWS_REL"

echo "Mounting installer ISO from Windows workspace..."
mark "110-loop-mount-mint-iso"
run_logged mount -o loop,ro "$ISO_SOURCE" /mnt/iso
echo "Extracting system..."
mark "120-unsquashfs"
if command -v stdbuf >/dev/null 2>&1; then
    run_logged stdbuf -oL -eL unsquashfs -f -d /mnt/target /mnt/iso/casper/filesystem.squashfs
else
    run_logged unsquashfs -f -d /mnt/target /mnt/iso/casper/filesystem.squashfs
fi
umount /mnt/iso

configure_target_system

mark "140-install-bootloader"
BOOTLOADER_WRITE_STARTED=true
if [ "$LIBERTIX_FIRMWARE_MODE" = "bios" ]; then
    echo "Backing up the current MBR before installing GRUB..."
    dd if="$DISK" of="$MBR_BACKUP" bs=512 count=1
    chroot /mnt/target grub-install --target=i386-pc --recheck "$DISK"
else
    echo "Installing signed UEFI bootloader..."
    install_signed_uefi_bootloader_or_die

    # In GPT, the boot flag means EFI System Partition. Keep it away from the
    # Linux root partition; the real ESP is mounted at /boot/efi above.
    verify_linux_partition_type_or_die
fi

unmount_target_system

if [ "$LIBERTIX_FIRMWARE_MODE" = "bios" ]; then
    # GRUB lives in the MBR and does not need the Linux partition marked active.
    # Keeping the Windows boot partition active preserves BCD and WinRE lookup.
    WINDOWS_BOOT_PART_NUM="$(partition_number "$WINDOWS_BOOT_PART")"
    run_logged parted -s "$DISK" set "$NEW_PART_NUM" boot off
    run_logged parted -s "$DISK" set "$WINDOWS_BOOT_PART_NUM" boot on
    partprobe "$DISK" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
fi
assert_recovery_unchanged_or_die
final_verify_or_die
firmware_finalize_success_best_effort

echo ""
echo "=== INSTALLATION COMPLETED ==="
INSTALL_SUCCESS=true
append_install_result true 0 "not-needed"
if [ "$LIBERTIX_FIRMWARE_MODE" = "uefi" ]; then
    write_windows_recovery_marker_best_effort "install-success" 0
fi
exit 0
