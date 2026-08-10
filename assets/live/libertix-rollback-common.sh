#!/bin/bash

# Shared rollback engine for BIOS and UEFI live installations.
#
# Firmware adapters supply six small hooks: preparing firmware rollback,
# resolving and validating the transaction partition, cleaning a firmware-
# specific partition container, restoring boot state, and publishing an
# optional failure marker. The destructive geometry changes remain centralized
# here so both firmware paths follow the same safeguards.

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
        # The target setup module consumes DISKNAME after rollback refreshes it.
        # shellcheck disable=SC2034
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
    local deleted=false holders fuser_output=""

    firmware_resolve_rollback_partition
    if [ -n "$NEW_PART" ] && [ -b "$NEW_PART" ]; then
        NEW_PART_NUM="${NEW_PART_NUM:-$(partition_number "$NEW_PART")}"
        if firmware_rollback_partition_is_owned "$NEW_PART"; then
            for _ in $(seq 1 10); do
                holders="$(find "/sys/class/block/$(basename "$NEW_PART")/holders" \
                    -mindepth 1 -maxdepth 1 -printf '%f ' 2>/dev/null || true)"
                if ! findmnt -rn -S "$NEW_PART" | grep -q . \
                    && [ -z "$holders" ] \
                    && ! fuser_output=$(fuser "$NEW_PART" 2>&1); then
                    break
                fi
                sleep 1
            done

            holders="$(find "/sys/class/block/$(basename "$NEW_PART")/holders" \
                -mindepth 1 -maxdepth 1 -printf '%f ' 2>/dev/null || true)"
            if findmnt -rn -S "$NEW_PART" | grep -q .; then
                echo "ROLLBACK: cannot delete $NEW_PART because it is still mounted"
            elif [ -n "$holders" ]; then
                echo "ROLLBACK: cannot delete $NEW_PART because kernel holders remain: $holders"
            elif fuser_output=$(fuser "$NEW_PART" 2>&1); then
                echo "ROLLBACK: cannot delete $NEW_PART because direct device users remain"
                [ -z "$fuser_output" ] || printf '%s\n' "$fuser_output"
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

restore_windows_partition_best_effort() {
    local logical_sector original_end_bytes original_end_sector
    local recovery_start_sector windows_number

    windows_number="$(partition_number "$WINDOWS_PART")"
    logical_sector="$(blockdev --getss "$DISK" 2>/dev/null || echo 0)"
    [ "$logical_sector" -eq 512 ] || [ "$logical_sector" -eq 4096 ] || {
        echo "ROLLBACK: unsupported logical sector size: $logical_sector"
        return 1
    }
    [ "${WINDOWS_PARTITION_OFFSET_BYTES:-0}" -gt 0 ] 2>/dev/null || {
        echo "ROLLBACK: original Windows partition offset is unavailable"
        return 1
    }
    [ "${WINDOWS_PARTITION_SIZE_BYTES:-0}" -gt 0 ] 2>/dev/null || {
        echo "ROLLBACK: original Windows partition size is unavailable"
        return 1
    }

    original_end_bytes=$((WINDOWS_PARTITION_OFFSET_BYTES + WINDOWS_PARTITION_SIZE_BYTES))
    original_end_sector="$(bytes_to_logical_sectors \
        "$original_end_bytes" "$logical_sector")" || {
        echo "ROLLBACK: original Windows partition end is not sector-aligned"
        return 1
    }
    [ "$original_end_sector" -gt 0 ] || {
        echo "ROLLBACK: original Windows partition geometry is invalid"
        return 1
    }
    recovery_start_sector="$(bytes_to_logical_sectors \
        "$RECOVERY_PARTITION_OFFSET_BYTES" "$logical_sector")" || {
        echo "ROLLBACK: recovery partition offset is not sector-aligned"
        return 1
    }
    [ "$original_end_sector" -le "$recovery_start_sector" ] || {
        echo "ROLLBACK: original Windows partition would overlap Recovery"
        return 1
    }

    # Recovery must reproduce the captured geometry, not consume every sector
    # before Recovery. Cloned layouts may intentionally contain a pre-existing
    # gap, and growing C: into that gap would make rollback non-reversible.
    echo "ROLLBACK: restoring Windows partition $WINDOWS_PART to its original end"
    parted -s "$DISK" unit s resizepart \
        "$windows_number" "$((original_end_sector - 1))s" || {
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
    local rollback_ok=false boot_restore_ok=true state_rollback_ok=true

    [ "$INSTALL_SUCCESS" = false ] || return 0
    [ "$ROLLBACK_ATTEMPTED" = false ] || return 0
    ROLLBACK_ATTEMPTED=true
    begin_installation_state_rollback || state_rollback_ok=false

    echo "=== ROLLBACK: best-effort Windows layout restore ==="
    resolve_rollback_storage_best_effort || return 1
    cleanup_live_mounts_best_effort
    swapoff -a 2>/dev/null || true

    restore_pre_grub_mbr_best_effort || boot_restore_ok=false
    firmware_prepare_rollback_best_effort || boot_restore_ok=false
    delete_transaction_partition_best_effort || return 1
    firmware_cleanup_partition_container_best_effort || return 1
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
        for rollback_step in \
            "target.bootloader-installed" \
            "target.system-configured" \
            "live.distribution-extracted" \
            "live.target-filesystem-created" \
            "live.installer-partition-expanded" \
            "windows.temporary-boot-prepared" \
            "windows.live-media-prepared" \
            "windows.installer-partition-created" \
            "windows.system-volume-shrunk" \
            "windows.recovery-armed"; do
            compensate_installation_state_step "$rollback_step" || state_rollback_ok=false
        done
        if [ "$state_rollback_ok" = true ]; then
            complete_installation_state_rollback || state_rollback_ok=false
        fi
        if [ "$state_rollback_ok" = true ]; then
            echo "ROLLBACK: completed best-effort Windows layout restore"
            return 0
        fi
        echo "ROLLBACK: physical restore completed but durable rollback state is incomplete"
    fi
    return 1
}

fail_and_exit() {
    local rc="$1"
    local message="$2"

    trap - ERR
    set +e
    echo "ERROR: $message"
    # Release the ISO loop and NTFS mounts before persisting the failed state.
    # The durable state mirror must never race an existing read-only mount.
    cleanup_live_mounts_best_effort
    fail_installation_state_best_effort "$rc" "$message"
    debug_disk_state || true
    if rollback_windows_layout_best_effort; then
        append_install_result false "$rc" "completed"
    else
        append_install_result false "$rc" "skipped-or-failed"
    fi
    firmware_write_failure_marker_best_effort "$rc"
    exit "$rc"
}
