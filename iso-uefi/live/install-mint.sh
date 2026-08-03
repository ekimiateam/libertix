#!/bin/bash
set -Eeuo pipefail

[ "$EUID" -ne 0 ] && { echo "Run as root"; exit 1; }

LOG_DIR="/run/libertix"
STAGE_FILE="$LOG_DIR/stage"
FAIL_FILE="$LOG_DIR/failure"
mkdir -p "$LOG_DIR"

CURRENT_STAGE="bootstrap"
DISK=""
LIVE_PART=""
WINDOWS_PART=""
NEW_PART=""
NEW_PART_NUM=""
INSTALL_SUCCESS=false
BOOTLOADER_WRITE_STARTED=false
MBR_BACKUP="$LOG_DIR/mbr-before-grub.bin"
ROLLBACK_ATTEMPTED=false
RECOVERY_GEOMETRY_BEFORE=""
# Keep rollback-safe defaults available before the configuration file is parsed.
# ERR can fire during bootstrap and rollback must never fail because of `set -u`.
TARGET_DISK_SIZE_BYTES=""
WINDOWS_PARTITION_OFFSET_BYTES=""
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
. /usr/local/lib/libertix/libertix-uefi-adapter.sh
















# Keep cleanup non-fatal: this is used from the error path, where preserving the
# rollback attempt is more important than failing on a stale mountpoint.

# Rollback is intentionally conservative. It only deletes the live/final Linux
# slot that was already identified during this run. The Windows recovery
# partition is never moved or removed here.
























echo "Libertix build: $(cat /etc/libertix-build-id 2>/dev/null || echo unknown)"
wait_for_prereqs

# Read config.txt. In low-memory mode the live root comes from an ISO on NTFS,
# while the generated configuration remains on the temporary FAT partition.
mark "010-read-config"
CONFIG_FILE=""
for mp in /run/live/medium /lib/live/mount/medium /cdrom; do
    [ -f "$mp/config.txt" ] && { CONFIG_FILE="$mp/config.txt"; break; }
done
if [ -z "$CONFIG_FILE" ]; then
    CONFIG_FILE=$(find /run/live /lib/live /cdrom -maxdepth 6 -iname config.txt -print -quit 2>/dev/null || true)
fi
if [ -z "$CONFIG_FILE" ]; then
    config_mount="/run/libertix-config-medium"
    mkdir -p "$config_mount"
    while read -r config_part; do
        [ -n "$config_part" ] || continue
        config_label=$(blkid -s LABEL -o value "$config_part" 2>/dev/null || true)
        [ "$config_label" = "LIBERTIXEFI" ] || continue
        if mount -t vfat -o ro "$config_part" "$config_mount" 2>/dev/null; then
            mounted_config=$(find "$config_mount" -maxdepth 1 -type f -iname config.txt -print -quit 2>/dev/null || true)
            if [ -n "$mounted_config" ]; then
                cp "$mounted_config" "$LOG_DIR/config.txt"
                CONFIG_FILE="$LOG_DIR/config.txt"
            fi
            umount "$config_mount" 2>/dev/null || true
        fi
        [ -n "$CONFIG_FILE" ] && break
    done < <(blkid -o device 2>/dev/null || true)
fi
[ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ] || die "config.txt not found on live medium"

LANGUAGE_CODE="en"
SYSTEM_LANG="en_US.UTF-8"
KEYBOARD_LAYOUT="us"
KEYBOARD_MODEL="pc105"
TIMEZONE="UTC"
USERNAME=""
PASSWORD_HASH=""
COMPUTER_NAME=""
ISO_FILENAME="mint.iso"
ISO_WINDOWS_PATH=""
LINUX_SIZE_GB="30"
TARGET_DISK_SIZE_BYTES=""
WINDOWS_PARTITION_OFFSET_BYTES=""
INSTALLER_PARTITION_OFFSET_BYTES=""
EXPECTED_PARTITION_STYLE=""
RECOVERY_PARTITION_OFFSET_BYTES=""
RECOVERY_PARTITION_SIZE_BYTES=""
LOW_MEMORY_MODE="false"
SHARE_WINDOWS_FILES_IN_LINUX="true"
SHARE_LINUX_FILES_IN_WINDOWS="true"
WINDOWS_PROFILES_JSON_BASE64="W10="

if [ -f "$CONFIG_FILE" ]; then
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        value=$(python3 - "$value" <<'PY'
import shlex
import sys

raw = sys.argv[1]
try:
    parsed = shlex.split("x=" + raw, posix=True)
    print(parsed[0].split("=", 1)[1] if parsed else "")
except Exception:
    print(raw.strip().strip('"').strip("'"))
PY
)
        case "$key" in
            LANGUAGE_CODE) LANGUAGE_CODE="$value" ;;
            SYSTEM_LANG) SYSTEM_LANG="$value" ;;
            KEYBOARD_LAYOUT) KEYBOARD_LAYOUT="$value" ;;
            KEYBOARD_MODEL) KEYBOARD_MODEL="$value" ;;
            TIMEZONE) TIMEZONE="$value" ;;
            USERNAME) USERNAME="$value" ;;
            PASSWORD_HASH) PASSWORD_HASH="$value" ;;
            COMPUTER_NAME) COMPUTER_NAME="$value" ;;
            ISO_FILENAME) ISO_FILENAME="$value" ;;
            ISO_WINDOWS_PATH) ISO_WINDOWS_PATH="$value" ;;
            LINUX_SIZE_GB) LINUX_SIZE_GB="$value" ;;
            TARGET_DISK_SIZE_BYTES) TARGET_DISK_SIZE_BYTES="$value" ;;
            WINDOWS_PARTITION_OFFSET_BYTES) WINDOWS_PARTITION_OFFSET_BYTES="$value" ;;
            INSTALLER_PARTITION_OFFSET_BYTES) INSTALLER_PARTITION_OFFSET_BYTES="$value" ;;
            EXPECTED_PARTITION_STYLE) EXPECTED_PARTITION_STYLE="$value" ;;
            RECOVERY_PARTITION_OFFSET_BYTES) RECOVERY_PARTITION_OFFSET_BYTES="$value" ;;
            RECOVERY_PARTITION_SIZE_BYTES) RECOVERY_PARTITION_SIZE_BYTES="$value" ;;
            RECOVERY_ROOT_WINDOWS) RECOVERY_ROOT_WINDOWS="$value" ;;
            RECOVERY_RUN_ID) RECOVERY_RUN_ID="$value" ;;
            LOW_MEMORY_MODE) LOW_MEMORY_MODE="$value" ;;
            SHARE_WINDOWS_FILES_IN_LINUX) SHARE_WINDOWS_FILES_IN_LINUX="$value" ;;
            SHARE_LINUX_FILES_IN_WINDOWS) SHARE_LINUX_FILES_IN_WINDOWS="$value" ;;
            WINDOWS_PROFILES_JSON_BASE64) WINDOWS_PROFILES_JSON_BASE64="$value" ;;
        esac
    done < "$CONFIG_FILE"
fi

[ -n "$USERNAME" ] || die "config.txt missing USERNAME"
case "$LANGUAGE_CODE" in en|fr|es|ja) ;; *) die "config.txt has invalid LANGUAGE_CODE" ;; esac
[[ "$PASSWORD_HASH" == \$6\$* ]] || die "config.txt missing valid PASSWORD_HASH"
[ -n "$COMPUTER_NAME" ] || die "config.txt missing COMPUTER_NAME"
[ -n "$LINUX_SIZE_GB" ] || die "config.txt missing LINUX_SIZE_GB"
[ "$TARGET_DISK_SIZE_BYTES" -gt 0 ] 2>/dev/null || die "config.txt missing valid TARGET_DISK_SIZE_BYTES"
[ "$WINDOWS_PARTITION_OFFSET_BYTES" -gt 0 ] 2>/dev/null || die "config.txt missing valid WINDOWS_PARTITION_OFFSET_BYTES"
[ "$INSTALLER_PARTITION_OFFSET_BYTES" -gt 0 ] 2>/dev/null || die "config.txt missing valid INSTALLER_PARTITION_OFFSET_BYTES"
case "$EXPECTED_PARTITION_STYLE" in GPT|MBR) ;; *) die "config.txt has invalid EXPECTED_PARTITION_STYLE" ;; esac
[ "$RECOVERY_PARTITION_OFFSET_BYTES" -gt 0 ] 2>/dev/null || die "config.txt missing valid RECOVERY_PARTITION_OFFSET_BYTES"
[ "$RECOVERY_PARTITION_SIZE_BYTES" -gt 0 ] 2>/dev/null || die "config.txt missing valid RECOVERY_PARTITION_SIZE_BYTES"
case "$LOW_MEMORY_MODE" in true|false) ;; *) die "config.txt has invalid LOW_MEMORY_MODE" ;; esac
case "$SHARE_WINDOWS_FILES_IN_LINUX" in true|false) ;; *) die "config.txt has invalid SHARE_WINDOWS_FILES_IN_LINUX" ;; esac
case "$SHARE_LINUX_FILES_IN_WINDOWS" in true|false) ;; *) die "config.txt has invalid SHARE_LINUX_FILES_IN_WINDOWS" ;; esac
[ -z "$ISO_WINDOWS_PATH" ] && ISO_WINDOWS_PATH="$ISO_FILENAME"

echo "Config: Lang=$SYSTEM_LANG Keyboard=$KEYBOARD_LAYOUT User=$USERNAME LinuxSize=${LINUX_SIZE_GB}GB"

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
DISKNAME=$(basename "$DISK")

LIVE_PART=$(partition_at_offset "$DISK" "$INSTALLER_PARTITION_OFFSET_BYTES" || true)
[ -n "$LIVE_PART" ] && [ -b "$LIVE_PART" ] || die "Installer partition does not match the Windows manifest"

lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$DISK"

PART_TABLE=$(parted -sm "$DISK" print 2>/dev/null | awk -F: 'NR==2{print $6}')
PART_COUNT=$(lsblk -nr -o NAME,TYPE "$DISK" | awk '$2=="part"{c++}END{print c+0}')
RECOVERY_GEOMETRY_BEFORE="$(recovery_geometry "$DISK")"
[ -n "$RECOVERY_GEOMETRY_BEFORE" ] && echo "Recovery partition geometry before install: $RECOVERY_GEOMETRY_BEFORE"

# Find Windows partition
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

run_live_preflight
cleanup_windows_live_boot_artifacts
mark "027-windows-live-boot-cleaned"
write_windows_recovery_marker_best_effort "live-started" 0

# Calculate how much more we need to shrink Windows
# LINUX_SIZE_GB includes the 2GB FAT32, so we need (LINUX_SIZE_GB - 2) more for ext4
LINUX_SIZE_MB=$((LINUX_SIZE_GB * 1024))
FAT32_SIZE_MB=2048

# Get current free space on disk
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

# Calculate how much more shrinking is needed
# We want: LINUX_SIZE_MB total for Linux (including FAT32)
# Current free space is what Windows already gave us
# Additional shrink needed = LINUX_SIZE_MB - CURRENT_FREE_MB
ADDITIONAL_SHRINK_MB=$((LINUX_SIZE_MB - CURRENT_FREE_MB))

if [ -n "$LIVE_PART" ] && [ "$(parent_disk_from_part "$LIVE_PART")" = "$DISK" ]; then
    echo "Live partition already exists at $LIVE_PART; skipping live-side Windows shrink."
    echo "Windows/Libertix created this partition at the final Linux size."
    ADDITIONAL_SHRINK_MB=0
fi

if [ "$ADDITIONAL_SHRINK_MB" -gt 1024 ]; then
    echo "=== Additional NTFS shrinking needed: ${ADDITIONAL_SHRINK_MB}MB ==="

    # Calculate new Windows size
    NEW_WINDOWS_SIZE_MB=$((WINDOWS_SIZE - ADDITIONAL_SHRINK_MB))

    if [ "$NEW_WINDOWS_SIZE_MB" -lt 20480 ]; then
        echo "WARNING: New Windows size would be less than 20GB, limiting shrink"
        NEW_WINDOWS_SIZE_MB=20480
        ADDITIONAL_SHRINK_MB=$((WINDOWS_SIZE - NEW_WINDOWS_SIZE_MB))
    fi

    echo "Shrinking Windows from ${WINDOWS_SIZE}MB to ${NEW_WINDOWS_SIZE_MB}MB..."

    # Make sure partition is not mounted
    umount "$WINDOWS_PART" 2>/dev/null || true

    # Check filesystem first
    echo "Checking NTFS filesystem..."
    ntfsfix "$WINDOWS_PART" || die "NTFS pre-resize check failed"

    # Resize NTFS filesystem (size in bytes for ntfsresize)
    NEW_SIZE_BYTES=$((NEW_WINDOWS_SIZE_MB * 1024 * 1024))
    echo "Resizing NTFS to ${NEW_WINDOWS_SIZE_MB}MB..."
    ntfsresize -f -s "${NEW_SIZE_BYTES}" "$WINDOWS_PART" <<< "y" || \
        die "ntfsresize failed; the partition table was not changed"

    # Resize partition table
    PART_NUM=$(echo "$WINDOWS_PART" | grep -oE '[0-9]+$')
    echo "Resizing partition table..."
    parted -s "$DISK" resizepart "$PART_NUM" "${NEW_WINDOWS_SIZE_MB}MB" 2>/dev/null || \
        die "parted failed after NTFS resize; rollback is required"

    sync
    partprobe "$DISK" 2>/dev/null || true
    sleep 2

    # Update Windows size
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
    echo "The partition table keeps four entries; only the filesystem changes from FAT32 to ext4."
    mark "040-unmount-target-disk"
    unmount_target_disk_partitions
    assert_no_target_disk_mounts
    NEW_PART="$LIVE_PART"
    NEW_PART_NUM=$(partition_number "$NEW_PART")
    if [ "$PART_TABLE" = "msdos" ]; then
        [ "$NEW_PART_NUM" = "3" ] || die "expected to reuse partition 3, got $NEW_PART_NUM"
    fi
    mark "050-assert-live-detached"
    assert_not_mounted_or_open "$NEW_PART"

    # Windows may deliberately create a small FAT32 staging partition when
    # the requested Linux size exceeds the historical Windows FAT32 limit.
    # C: has already been shrunk by the complete requested size, leaving the
    # remainder contiguous after this partition. Expand it before mkfs.ext4.
    current_partition_bytes=$(blockdev --getsize64 "$NEW_PART" 2>/dev/null || echo 0)
    desired_partition_bytes=$((LINUX_SIZE_GB * 1024 * 1024 * 1024))
    if [ "$current_partition_bytes" -lt "$desired_partition_bytes" ]; then
        logical_sector_bytes=$(blockdev --getss "$DISK" 2>/dev/null || echo 0)
        [ "$logical_sector_bytes" -gt 0 ] || die "cannot determine target disk logical sector size"
        partition_start_sector=$(cat "/sys/class/block/$(basename "$NEW_PART")/start" 2>/dev/null || echo 0)
        [ "$partition_start_sector" -gt 0 ] || die "cannot determine installer partition start sector"
        desired_partition_sectors=$((desired_partition_bytes / logical_sector_bytes))
        desired_end_sector=$((partition_start_sector + desired_partition_sectors - 1))
        recovery_start_sector=$((RECOVERY_PARTITION_OFFSET_BYTES / logical_sector_bytes))
        [ "$desired_end_sector" -lt "$recovery_start_sector" ] || \
            die "requested Linux partition would overlap the Windows recovery partition"

        echo "Expanding FAT32 staging partition from $current_partition_bytes to $desired_partition_bytes bytes before ext4 format"
        run_logged parted -s "$DISK" unit s resizepart "$NEW_PART_NUM" "${desired_end_sector}s"
        sync
        partprobe "$DISK" 2>/dev/null || true
        udevadm settle 2>/dev/null || true
        sleep 2

        expanded_partition_bytes=$(blockdev --getsize64 "$NEW_PART" 2>/dev/null || echo 0)
        [ "$expanded_partition_bytes" -eq "$desired_partition_bytes" ] || \
            die "installer partition expansion verification failed: expected $desired_partition_bytes, got $expanded_partition_bytes"
    fi
elif [ "$PART_TABLE" = "msdos" ] && [ "$PART_COUNT" -ge 4 ]; then
    echo "ERROR: MBR has $PART_COUNT partitions and no removable live partition was found"
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

# Extract ISO
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
echo "Installing signed UEFI bootloader..."
BOOTLOADER_WRITE_STARTED=true
install_signed_uefi_bootloader_or_die

# In GPT, the "boot" flag means EFI System Partition. Keep it away from the
# Linux root partition; the real ESP is mounted at /boot/efi above.
verify_linux_partition_type_or_die

unmount_target_system
assert_recovery_unchanged_or_die
final_verify_or_die

echo ""
echo "=== INSTALLATION COMPLETED ==="
INSTALL_SUCCESS=true
append_install_result true 0 "not-needed"
write_windows_recovery_marker_best_effort "install-success" 0
exit 0
