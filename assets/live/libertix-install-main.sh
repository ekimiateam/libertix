#!/bin/bash
# The orchestrator owns globals that sourced firmware and rollback modules read.
# shellcheck disable=SC2034
set -Eeuo pipefail

[ "$EUID" -ne 0 ] && { echo "Run as root"; exit 1; }

case "${LIBERTIX_FIRMWARE_MODE:-}" in
    bios|uefi) ;;
    *) echo "LIBERTIX_FIRMWARE_MODE must be bios or uefi" >&2; exit 2 ;;
esac

LOG_DIR="/run/libertix"
STAGE_FILE="$LOG_DIR/stage"
FAIL_FILE="$LOG_DIR/failure"
STAGE_CATALOG="/usr/local/lib/libertix/libertix-stages.tsv"
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
RUN_LOGGED_COMMAND=""
RUN_LOGGED_RC=""
MBR_BACKUP="$LOG_DIR/mbr-before-grub.bin"
RECOVERY_GEOMETRY_BEFORE=""
# Keep rollback-safe defaults available before the configuration file is parsed.
# ERR can fire during bootstrap and rollback must never fail because of `set -u`.
TARGET_DISK_SIZE_BYTES=""
WINDOWS_PARTITION_OFFSET_BYTES=""
WINDOWS_PARTITION_SIZE_BYTES=""
WINDOWS_BOOT_PARTITION_OFFSET_BYTES=""
INSTALLER_PARTITION_OFFSET_BYTES=""
INSTALLER_FINAL_OFFSET_BYTES=""
INSTALLER_FINAL_SIZE_BYTES=""
INSTALLER_STAGING_SIZE_BYTES=""
INSTALLER_RESIZE_MODE=""
WINDOWS_BITLOCKER_STATE=""
EXPECTED_PARTITION_STYLE=""
RECOVERY_PARTITION_OFFSET_BYTES=""
RECOVERY_PARTITION_SIZE_BYTES=""
RECOVERY_ROOT_WINDOWS=""
RECOVERY_RUN_ID=""
PASSWORD_HASH=""
WINDOWS_PREFERENCE_BUNDLE_RUNTIME_PATH=""
echo "$CURRENT_STAGE" > "$STAGE_FILE"

mark() {
    local next_stage="$1"

    if ! awk -F '\t' -v stage="$next_stage" \
        '$1 == stage { found=1; exit } END { exit !found }' \
        "$STAGE_CATALOG"; then
        die "unknown installation stage requested: $next_stage"
    fi
    CURRENT_STAGE="$next_stage"
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
    local shell_command="${BASH_COMMAND:-unknown}"
    local cmd="$shell_command"

    # ERR fires on run_logged's final return rather than on the wrapped
    # command. Preserve the real command so failure reports identify the
    # operation that failed instead of the implementation detail `return 1`.
    if [ -n "${RUN_LOGGED_COMMAND:-}" ] \
        && [ "${RUN_LOGGED_RC:-}" = "$rc" ] \
        && [[ "$shell_command" == return* ]]; then
        cmd="$RUN_LOGGED_COMMAND"
    fi
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

on_termination_signal() {
    local signal_name="$1"
    local rc="$2"

    trap - ERR EXIT INT TERM
    set +e +u
    echo "TERMINATION: signal=$signal_name stage=${CURRENT_STAGE:-bootstrap}; starting verified rollback"
    {
        echo "stage=${CURRENT_STAGE:-bootstrap}"
        echo "error=installation interrupted by $signal_name"
        echo "signal=$signal_name"
        echo "time=$(date -Is 2>/dev/null || date)"
    } > "$FAIL_FILE"
    if declare -F fail_and_exit >/dev/null 2>&1; then
        fail_and_exit "$rc" "installation interrupted by $signal_name"
    fi
    sync || true
    exit "$rc"
}

trap 'on_termination_signal TERM 143' TERM
trap 'on_termination_signal INT 130' INT

on_exit() {
    local rc="$?"

    trap - ERR EXIT INT TERM
    if [ "$rc" -eq 0 ]; then
        exit 0
    fi

    # Bash does not run ERR traps for every fatal expansion error, including an
    # unset variable under `set -u`. Keep this final guard outside nounset mode
    # so an unexpected shell exit still reaches the shared rollback engine.
    set +u
    if declare -F fail_and_exit >/dev/null 2>&1 \
        && [ "${INSTALL_SUCCESS:-false}" = false ] \
        && [ "${ROLLBACK_ATTEMPTED:-false}" = false ]; then
        fail_and_exit "$rc" "unhandled shell exit at stage ${CURRENT_STAGE:-bootstrap}"
    fi
    exit "$rc"
}

. /usr/local/lib/libertix/libertix-install-platform-common.sh
. /usr/local/lib/libertix/libertix-storage-common.sh
. /usr/local/lib/libertix/libertix-install-runtime-common.sh
. /usr/local/lib/libertix/libertix-offline-ntfs-resize.sh
. /usr/local/lib/libertix/libertix-distribution-common.sh
. /usr/local/lib/libertix/libertix-target-common.sh
. /usr/local/lib/libertix/libertix-rollback-common.sh
. /usr/local/lib/libertix/libertix-installation-plan.sh
. /usr/local/lib/libertix/libertix-live-context.sh
if [ "$LIBERTIX_FIRMWARE_MODE" = "bios" ]; then
    . /usr/local/lib/libertix/libertix-bios-adapter.sh
else
    . /usr/local/lib/libertix/libertix-uefi-adapter.sh
fi
trap on_exit EXIT

echo "Libertix build: $(cat /etc/libertix-build-id 2>/dev/null || echo unknown)"
wait_for_prereqs

# Load the validated plan that Windows persisted before booting the live system.
# No defaults are accepted here: every destructive decision must match the same
# disk identities, sizes, hashes, locale, and recovery transaction.
mark "010-read-config"
load_libertix_live_context "$LIBERTIX_FIRMWARE_MODE" || die "installation plan could not be loaded"

if [ "$WINDOWS_PREFERENCE_MIGRATION_ENABLED" = true ]; then
    WINDOWS_PREFERENCE_BUNDLE_RUNTIME_PATH="$LOG_DIR/$WINDOWS_PREFERENCE_BUNDLE_FILE_NAME"
    [ -f "$WINDOWS_PREFERENCE_BUNDLE_RUNTIME_PATH" ] || \
        die "Windows preference migration bundle is missing from the validated live context"
    [ "$(stat -c %s "$WINDOWS_PREFERENCE_BUNDLE_RUNTIME_PATH" 2>/dev/null || echo invalid)" = \
        "$WINDOWS_PREFERENCE_BUNDLE_SIZE_BYTES" ] || \
        die "Windows preference migration bundle size verification failed"
    [ "$(sha256sum "$WINDOWS_PREFERENCE_BUNDLE_RUNTIME_PATH" | awk '{print $1}')" = \
        "$WINDOWS_PREFERENCE_BUNDLE_SHA256" ] || \
        die "Windows preference migration bundle hash verification failed"
    chmod 0600 "$WINDOWS_PREFERENCE_BUNDLE_RUNTIME_PATH"
    export WINDOWS_PREFERENCE_BUNDLE_RUNTIME_PATH
fi

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
[ "$(blockdev --getsize64 "$LIVE_PART" 2>/dev/null || echo 0)" = \
    "$INSTALLER_STAGING_SIZE_BYTES" ] || \
    die "Installer partition size does not match the Windows manifest"

lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$DISK"

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

WINDOWS_BOOT_PART=$(partition_at_offset "$DISK" "$WINDOWS_BOOT_PARTITION_OFFSET_BYTES" || true)
[ -n "$WINDOWS_BOOT_PART" ] && [ -b "$WINDOWS_BOOT_PART" ] || \
    die "Windows boot partition does not match the Windows manifest"
[ "$(parent_disk_from_part "$WINDOWS_BOOT_PART")" = "$DISK" ] || \
    die "Windows boot partition is not on the target disk"
echo "Windows boot partition: $WINDOWS_BOOT_PART"

start_installation_state_step "live.preflight-verified"
run_live_preflight
complete_installation_state_step "live.preflight-verified"
cleanup_windows_live_boot_artifacts
mark "027-windows-live-boot-cleaned"
write_windows_recovery_marker_best_effort "live-started" 0

mark "030-check-installer-iso"
ISO_WINDOWS_REL=$(windows_path_to_relative "$ISO_WINDOWS_PATH")
ISO_SOURCE="/mnt/windows/$ISO_WINDOWS_REL"

mount_windows_ro_with_retry "$WINDOWS_PART" /mnt/windows
wait_for_iso_source_or_die "$ISO_SOURCE" "$ISO_WINDOWS_REL"
PASSWORD_HASH_WINDOWS_REL=$(windows_path_to_relative "$PASSWORD_HASH_WINDOWS_PATH")
PASSWORD_HASH_SOURCE="/mnt/windows/$PASSWORD_HASH_WINDOWS_REL"
[ -f "$PASSWORD_HASH_SOURCE" ] || die "protected account secret is missing from Windows"
IFS= read -r PASSWORD_HASH < "$PASSWORD_HASH_SOURCE" || true
case "$PASSWORD_HASH" in
    \$6\$*) ;;
    *) die "protected account secret does not contain a valid SHA-512 crypt hash" ;;
esac
[[ "$PASSWORD_HASH" != *$'\r'* && "$PASSWORD_HASH" != *$'\n'* && "$PASSWORD_HASH" != *$'\t'* ]] || \
    die "protected account secret contains an invalid control character"
export PASSWORD_HASH

retire_account_secret_or_die() {
    local mountpoint="/mnt/libertix-account-secret-retirement"
    local secret_path result=0

    mkdir -p "$mountpoint"
    findmnt -rn -S "$WINDOWS_PART" | grep -q . && \
        die "Windows partition is already mounted during account secret retirement"
    mount -t ntfs-3g -o rw "$WINDOWS_PART" "$mountpoint" || \
        die "Windows partition could not be mounted to retire the account secret"

    secret_path="$mountpoint/$PASSWORD_HASH_WINDOWS_REL"
    if [ -L "$secret_path" ] || { [ -e "$secret_path" ] && [ ! -f "$secret_path" ]; }; then
        result=1
    elif [ -f "$secret_path" ]; then
        rm -f -- "$secret_path" || result=1
    fi
    [ ! -e "$secret_path" ] || result=1
    sync "$(dirname "$secret_path")" 2>/dev/null || sync
    umount "$mountpoint" || result=1
    [ "$result" -eq 0 ] || die "protected account secret could not be retired"

    PASSWORD_HASH=""
    unset PASSWORD_HASH
    echo "Protected account secret retired after target verification."
}

# Keep Windows NTFS unmounted while changing the MBR table. Any mounted
# partition on the target disk can make BLKRRPART/partprobe keep the old view.
mark "035-umount-windows"
run_logged umount /mnt/windows

NEW_PART=""
NEW_PART_NUM=""

[ "$(parent_disk_from_part "$LIVE_PART")" = "$DISK" ] || \
    die "installer partition is not on the validated target disk"
echo "=== Reusing live partition $LIVE_PART as final Linux partition ==="
echo "The validated staging partition will become the final Linux partition."
mark "040-unmount-target-disk"
unmount_target_disk_partitions
assert_no_target_disk_mounts
NEW_PART="$LIVE_PART"
NEW_PART_NUM=$(partition_number "$NEW_PART")
assert_not_mounted_or_open "$NEW_PART"

# Windows may deliberately create only the FAT32 staging extent. Complete an
# approved offline NTFS resize first when required, then ensure that the
# resulting Linux partition reaches its final extent before mkfs.ext4.
current_partition_bytes=$(blockdev --getsize64 "$NEW_PART" 2>/dev/null || echo 0)
requested_partition_bytes=$((LINUX_SIZE_GB * 1024 * 1024 * 1024))
desired_partition_bytes="$requested_partition_bytes"
start_installation_state_step "live.installer-partition-expanded"
prepare_offline_ntfs_resize_or_die
mark "050-assert-live-detached"
assert_not_mounted_or_open "$NEW_PART"
current_partition_bytes=$(blockdev --getsize64 "$NEW_PART" 2>/dev/null || echo 0)
if [ "$current_partition_bytes" -lt "$requested_partition_bytes" ]; then
    logical_sector_bytes=$(blockdev --getss "$DISK" 2>/dev/null || echo 0)
    [ "$logical_sector_bytes" -gt 0 ] || die "cannot determine target disk logical sector size"
    partition_start_sector=$(bytes_to_logical_sectors \
        "$INSTALLER_PARTITION_OFFSET_BYTES" "$logical_sector_bytes") || \
        die "installer partition offset is not aligned to the logical sector size"
    recovery_start_sector=$(bytes_to_logical_sectors \
        "$RECOVERY_PARTITION_OFFSET_BYTES" "$logical_sector_bytes") || \
        die "recovery partition offset is not aligned to the logical sector size"
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

prepare_installer_partition_for_target_format_or_die
set_linux_partition_type_or_die
complete_installation_state_step "live.installer-partition-expanded"

start_installation_state_step "live.target-filesystem-created"
mark "070-wipefs-live-part"
run_logged wipefs -a "$NEW_PART" || die "Failed to clear old signatures on $NEW_PART"
mark "080-mkfs-ext4"
run_logged mkfs.ext4 -F "$NEW_PART"
mkdir -p /mnt/target /mnt/iso
mark "090-mount-target"
run_logged mount "$NEW_PART" /mnt/target
complete_installation_state_step "live.target-filesystem-created"

mark "100-remount-windows-ro"
start_installation_state_step "live.distribution-extracted"
mount_windows_ro_with_retry "$WINDOWS_PART" /mnt/windows
wait_for_iso_source_or_die "$ISO_SOURCE" "$ISO_WINDOWS_REL"
mark "105-verify-installer-iso"
echo "Verifying installer ISO integrity..."
verify_file_sha256 "$ISO_SOURCE" "$ISO_SHA256" || \
    die "installer ISO SHA-256 does not match the validated installation plan"

echo "Mounting installer ISO from Windows workspace..."
mark "110-loop-mount-installer-iso"
run_logged mount -o loop,ro "$ISO_SOURCE" /mnt/iso
distribution_rootfs="$(resolve_distribution_rootfs_or_die /mnt/iso)" || \
    die "installer ISO does not expose one unambiguous squashfs root filesystem"
assert_distribution_rootfs_compatible_or_die \
    "$distribution_rootfs" "$DISTRIBUTION_OS_RELEASE_ID" || \
    die "installer ISO payload is incompatible with the signed distribution plan"
echo "Extracting system..."
mark "120-unsquashfs"
if command -v stdbuf >/dev/null 2>&1; then
    run_logged stdbuf -oL -eL unsquashfs -f -d /mnt/target "$distribution_rootfs"
else
    run_logged unsquashfs -f -d /mnt/target "$distribution_rootfs"
fi
umount /mnt/iso
umount /mnt/windows
complete_installation_state_step "live.distribution-extracted"

start_installation_state_step "target.system-configured"
configure_target_system
complete_installation_state_step "target.system-configured"

start_installation_state_step "target.bootloader-installed"
mark "140-install-bootloader"
if [ "$LIBERTIX_FIRMWARE_MODE" = "bios" ]; then
    echo "Preparing a durable MBR backup before installing GRUB..."
    prepare_bios_mbr_backup_or_die || die "pre-GRUB MBR backup could not be persisted and verified"
    BOOTLOADER_WRITE_STARTED=true
    chroot /mnt/target grub-install --target=i386-pc --recheck "$DISK"
else
    BOOTLOADER_WRITE_STARTED=true
    echo "Installing signed UEFI bootloader..."
    install_signed_uefi_bootloader_or_die

    # In GPT, the boot flag means EFI System Partition. Keep it away from the
    # Linux root partition; the real ESP is mounted at /boot/efi above.
    verify_linux_partition_type_or_die
fi
complete_installation_state_step "target.bootloader-installed"

unmount_target_system || die "target filesystem could not be released before final verification"

if [ "$LIBERTIX_FIRMWARE_MODE" = "bios" ]; then
    # GRUB lives in the MBR and does not need the Linux partition marked active.
    # Keeping the Windows boot partition active preserves BCD and WinRE lookup.
    set_bios_boot_flags_or_die
fi
assert_recovery_unchanged_or_die
start_installation_state_step "target.installation-verified"
final_verify_or_die
complete_installation_state_step "target.installation-verified"
retire_account_secret_or_die
complete_installation_state

echo ""
echo "=== INSTALLATION COMPLETED ==="
INSTALL_SUCCESS=true
emit_install_result true 0 "not-needed"
write_windows_recovery_marker_best_effort "install-success" 0
firmware_retire_completed_transaction_best_effort
exit 0
