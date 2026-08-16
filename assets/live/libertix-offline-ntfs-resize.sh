#!/bin/bash

# Complete a Windows shrink that was intentionally limited to the live staging
# size. The live system runs from RAM, so both NTFS and the staging partition
# are detached before any geometry is changed.

resize_partition_size_sectors() {
    local disk="$1" partition_number="$2" size_sectors="$3"
    local rc

    [ "$size_sectors" -gt 0 ] 2>/dev/null || return 2
    echo "+ printf 'size=%s\\n' $size_sectors | sfdisk --lock --no-reread -N $partition_number $disk"
    if printf 'size=%s\n' "$size_sectors" \
        | sfdisk --lock --no-reread -N "$partition_number" "$disk"; then
        rc=0
    else
        rc=$?
    fi
    echo "rc=$rc: sfdisk resize partition $partition_number on $disk to $size_sectors sectors"
    [ "$rc" -eq 0 ] || return "$rc"
    sfdisk --verify "$disk"
}

prepare_offline_ntfs_resize_or_die() {
    [ "$INSTALLER_RESIZE_MODE" = "live-offline" ] || return 0

    local logical_sector alignment_bytes aligned_original_windows_end expected_staging_end
    local current_windows_size current_windows_end final_windows_end
    local final_windows_size final_size_sectors windows_number

    mark "045-offline-ntfs-preflight"
    echo "=== Completing Windows NTFS resize offline ==="
    assert_no_target_disk_mounts
    assert_not_mounted_or_open "$LIVE_PART"
    assert_not_mounted_or_open "$WINDOWS_PART"
    assert_recovery_unchanged_or_die
    case "$WINDOWS_BITLOCKER_STATE" in
        FullyDecrypted|NotEncryptable) ;;
        *) die "offline NTFS resize requires BitLocker to be absent or fully decrypted" ;;
    esac

    logical_sector="$(blockdev --getss "$DISK" 2>/dev/null || echo 0)"
    case "$logical_sector" in
        512|4096) ;;
        *) die "offline NTFS resize found unsupported logical sector size $logical_sector" ;;
    esac
    alignment_bytes="$INSTALLER_ALIGNMENT_BYTES"
    [ "$alignment_bytes" -gt 0 ] 2>/dev/null || \
        die "offline NTFS resize is missing the shared alignment policy"
    [ "$INSTALLER_FINAL_OFFSET_BYTES" -gt "$WINDOWS_PARTITION_OFFSET_BYTES" ] 2>/dev/null || \
        die "offline NTFS resize final offset is invalid"

    aligned_original_windows_end=$((
        WINDOWS_PARTITION_OFFSET_BYTES + WINDOWS_PARTITION_SIZE_BYTES
    ))
    aligned_original_windows_end=$((
        aligned_original_windows_end - aligned_original_windows_end % alignment_bytes
    ))
    expected_staging_end=$((aligned_original_windows_end - INSTALLER_STAGING_SIZE_BYTES))
    final_windows_end="$INSTALLER_FINAL_OFFSET_BYTES"
    if [ "$LIBERTIX_FIRMWARE_MODE" = "bios" ]; then
        # The MBR logical staging payload follows its extended-container EBR.
        expected_staging_end=$((expected_staging_end - alignment_bytes))
        final_windows_end=$((final_windows_end - alignment_bytes))
    fi
    final_windows_size=$((final_windows_end - WINDOWS_PARTITION_OFFSET_BYTES))
    [ "$final_windows_size" -gt 0 ] || die "offline NTFS resize target is not positive"
    [ $((final_windows_size % logical_sector)) -eq 0 ] || \
        die "offline NTFS resize target is not sector aligned"

    current_windows_size="$(blockdev --getsize64 "$WINDOWS_PART" 2>/dev/null || echo 0)"
    current_windows_end=$((WINDOWS_PARTITION_OFFSET_BYTES + current_windows_size))
    [ "$current_windows_end" -eq "$expected_staging_end" ] || \
        die "offline NTFS resize found unexpected Windows/staging geometry"
    [ "$final_windows_size" -lt "$current_windows_size" ] || \
        die "offline NTFS resize would not shrink the Windows partition"

    echo "Checking NTFS before offline resize..."
    run_logged ntfs-3g.probe --readwrite "$WINDOWS_PART" || \
        die "offline NTFS resize found an unsafe Windows filesystem"
    run_logged ntfsresize --check "$WINDOWS_PART" || \
        die "offline NTFS consistency check failed"
    run_logged ntfsresize --info "$WINDOWS_PART" || \
        die "offline NTFS geometry inspection failed"
    echo "Simulating NTFS resize to $final_windows_size bytes..."
    run_logged ntfsresize --no-action --force --size "$final_windows_size" "$WINDOWS_PART" || \
        die "offline NTFS resize simulation failed"

    mark "046-offline-ntfs-resize"
    echo "Resizing NTFS to fit the approved final Windows extent..."
    run_logged ntfsresize --force --size "$final_windows_size" "$WINDOWS_PART" || \
        die "offline NTFS filesystem resize failed"
    sync

    windows_number="$(partition_number "$WINDOWS_PART")"
    final_size_sectors=$((final_windows_size / logical_sector))
    echo "Shrinking Windows partition $windows_number to $final_size_sectors sectors..."
    resize_partition_size_sectors "$DISK" "$windows_number" "$final_size_sectors" || \
        die "offline Windows partition-table resize failed"
    sync
    partprobe "$DISK" 2>/dev/null || true
    udevadm settle --timeout=10 2>/dev/null || true

    [ "$(partition_start_bytes "$DISK" "$WINDOWS_PART" || true)" = \
        "$WINDOWS_PARTITION_OFFSET_BYTES" ] || \
        die "offline Windows partition start changed unexpectedly"
    current_windows_size="$(blockdev --getsize64 "$WINDOWS_PART" 2>/dev/null || echo 0)"
    [ "$current_windows_size" -eq "$final_windows_size" ] || \
        die "offline Windows partition verification failed: expected $final_windows_size, got $current_windows_size"
    assert_recovery_unchanged_or_die

    mark "047-relocate-installer-partition"
    firmware_relocate_installer_partition_or_die \
        "$INSTALLER_FINAL_OFFSET_BYTES" "$INSTALLER_FINAL_SIZE_BYTES"
    [ -n "$NEW_PART" ] && [ -b "$NEW_PART" ] || \
        die "relocated installer partition is unavailable"
    [ "$(partition_start_bytes "$DISK" "$NEW_PART" || true)" = \
        "$INSTALLER_FINAL_OFFSET_BYTES" ] || \
        die "relocated installer partition offset verification failed"
    assert_recovery_unchanged_or_die
    echo "Offline NTFS resize and installer partition relocation verified."
}
