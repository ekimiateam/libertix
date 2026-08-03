#!/bin/bash

# Shared rollback engine for BIOS and UEFI live installations.
#
# Firmware adapters supply five small hooks: preparing firmware rollback,
# resolving and validating the transaction partition, restoring boot state,
# and publishing an optional failure marker. The destructive geometry changes
# remain centralized here so both firmware paths follow the same safeguards.

cleanup_live_mounts_best_effort() {
    local mount_directory

    cd / 2>/dev/null || true
    sync || true
    umount /mnt/iso 2>/dev/null || true
    umount /mnt/target/dev/pts 2>/dev/null || true
    umount /mnt/target/dev 2>/dev/null || true
    umount /mnt/target/proc 2>/dev/null || true
    umount /mnt/target/sys 2>/dev/null || true
    umount /mnt/target/boot/efi 2>/dev/null || true
    for mount_directory in /mnt/target/mnt/win_*; do
        [ -d "$mount_directory" ] && umount "$mount_directory" 2>/dev/null || true
    done
    umount /mnt/target 2>/dev/null || true
    umount /mnt/windows 2>/dev/null || true
    umount /mnt/libertix-final-verify 2>/dev/null || true
    umount /mnt/libertix-windows-final-verify 2>/dev/null || true
    umount /mnt/libertix-esp-final-verify 2>/dev/null || true
}

resolve_rollback_storage_best_effort() {
    if [ -z "$DISK" ] || [ ! -b "$DISK" ]; then
        DISK=$(resolve_target_disk_from_manifest || true)
        [ -n "$DISK" ] && DISKNAME="$(basename "$DISK")"
    fi
    if [ -z "$WINDOWS_PART" ] && [ -n "$DISK" ] && [ -b "$DISK" ]; then
        WINDOWS_PART="$(partition_at_offset "$DISK" "$WINDOWS_PARTITION_OFFSET_BYTES" || true)"
        [ -n "$WINDOWS_PART" ] && echo "ROLLBACK: resolved Windows partition as $WINDOWS_PART"
    fi

    [ -n "$DISK" ] && [ -b "$DISK" ] || {
        echo "ROLLBACK: skipped because target disk is unknown"
        return 1
    }
    [ -n "$WINDOWS_PART" ] && [ -b "$WINDOWS_PART" ] || {
        echo "ROLLBACK: skipped because Windows partition is unknown"
        return 1
    }
}

restore_pre_grub_mbr_best_effort() {
    [ "$BOOTLOADER_WRITE_STARTED" = true ] || return 0
    [ -f "$MBR_BACKUP" ] || return 0

    echo "ROLLBACK: restoring pre-GRUB MBR boot code from $MBR_BACKUP"
    dd if="$MBR_BACKUP" of="$DISK" bs=446 count=1 conv=notrunc
    sync || true
}

delete_transaction_partition_best_effort() {
    local deleted=false

    firmware_resolve_rollback_partition
    if [ -n "$NEW_PART" ] && [ -b "$NEW_PART" ]; then
        NEW_PART_NUM="${NEW_PART_NUM:-$(partition_number "$NEW_PART")}"
        if firmware_rollback_partition_is_owned "$NEW_PART"; then
            if findmnt -rn -S "$NEW_PART" | grep -q .; then
                echo "ROLLBACK: cannot delete $NEW_PART because it is still mounted"
            elif fuser -m "$NEW_PART" >/tmp/libertix-rollback-fuser.txt 2>&1; then
                echo "ROLLBACK: cannot delete $NEW_PART because it still has users"
                cat /tmp/libertix-rollback-fuser.txt || true
            else
                echo "ROLLBACK: deleting temporary Linux partition $NEW_PART"
                if parted -s "$DISK" rm "$NEW_PART_NUM"; then
                    deleted=true
                    sync || true
                    partprobe "$DISK" 2>/dev/null || true
                    udevadm settle 2>/dev/null || true
                else
                    echo "ROLLBACK: deleting $NEW_PART failed"
                fi
            fi
        else
            echo "ROLLBACK: refusing to delete unexpected partition $NEW_PART"
        fi
    fi

    if [ -n "$NEW_PART_NUM" ] \
        && parted -sm "$DISK" print 2>/dev/null \
            | awk -F: -v n="$NEW_PART_NUM" '$1==n{found=1} END{exit !found}'; then
        if [ "$deleted" != true ]; then
            echo "ROLLBACK: skipping Windows resize because transaction partition $NEW_PART_NUM is still present"
            debug_disk_state || true
            return 1
        fi
    fi
}

rollback_recovery_start_sector() {
    local logical_sector geometry start

    if [ "${RECOVERY_PARTITION_OFFSET_BYTES:-0}" -gt 0 ] 2>/dev/null; then
        logical_sector=$(blockdev --getss "$1" 2>/dev/null || echo 512)
        echo "$((RECOVERY_PARTITION_OFFSET_BYTES / logical_sector))"
        return 0
    fi

    geometry="$(recovery_geometry "$1")"
    [ -n "$geometry" ] || return 0
    start="$(printf '%s\n' "$geometry" | awk -F: '{print $2; exit}')"
    start="${start%s}"
    [ -n "$start" ] && printf '%s\n' "$start"
}

restore_windows_partition_best_effort() {
    local windows_number recovery_start resize_end

    windows_number="$(partition_number "$WINDOWS_PART")"
    recovery_start="$(rollback_recovery_start_sector "$DISK" || true)"
    if [ -n "$recovery_start" ]; then
        resize_end="$((recovery_start - 1))s"
    else
        resize_end="100%"
    fi

    echo "ROLLBACK: resizing Windows partition $WINDOWS_PART to $resize_end"
    parted -s "$DISK" unit s resizepart "$windows_number" "$resize_end" || {
        echo "ROLLBACK: partition resize failed"
        return 1
    }

    partprobe "$DISK" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    echo "ROLLBACK: growing NTFS filesystem"
    ntfsresize -f "$WINDOWS_PART" <<< "y" && ntfsfix -d "$WINDOWS_PART" || {
        echo "ROLLBACK: NTFS growth or verification failed"
        return 1
    }
}

rollback_windows_layout_best_effort() {
    local rollback_ok=false boot_restore_ok=true

    [ "$INSTALL_SUCCESS" = false ] || return 0
    [ "$ROLLBACK_ATTEMPTED" = false ] || return 0
    ROLLBACK_ATTEMPTED=true

    echo "=== ROLLBACK: best-effort Windows layout restore ==="
    resolve_rollback_storage_best_effort || return 1
    cleanup_live_mounts_best_effort
    swapoff -a 2>/dev/null || true

    restore_pre_grub_mbr_best_effort || boot_restore_ok=false
    firmware_prepare_rollback_best_effort || boot_restore_ok=false
    delete_transaction_partition_best_effort || return 1
    if restore_windows_partition_best_effort; then
        [ "$boot_restore_ok" = true ] && rollback_ok=true
    fi
    firmware_restore_boot_state_best_effort || rollback_ok=false

    if [ -n "$RECOVERY_GEOMETRY_BEFORE" ]; then
        echo "ROLLBACK: recovery before=$RECOVERY_GEOMETRY_BEFORE"
        echo "ROLLBACK: recovery after=$(recovery_geometry "$DISK")"
    fi
    debug_disk_state || true

    if [ "$rollback_ok" = true ]; then
        echo "ROLLBACK: completed best-effort Windows layout restore"
        return 0
    fi
    return 1
}

fail_and_exit() {
    local rc="$1"
    local message="$2"

    trap - ERR
    set +e
    echo "ERROR: $message"
    debug_disk_state || true
    if rollback_windows_layout_best_effort; then
        append_install_result false "$rc" "completed"
    else
        append_install_result false "$rc" "skipped-or-failed"
    fi
    firmware_write_failure_marker_best_effort "$rc"
    exit "$rc"
}
