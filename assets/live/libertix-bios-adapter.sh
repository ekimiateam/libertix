#!/bin/bash

# BIOS-specific live-installation adapter.
#
# The main live installer owns the installation sequence. This module owns the
# MBR/GRUB4DOS policy, BIOS rollback, BIOS final verification, and the legacy
# partition-layout rules that must not leak into the common orchestrator.


firmware_retire_completed_transaction_best_effort() {
    return 0
}

write_windows_recovery_marker_best_effort() {
    local state="$1"
    local rc="${2:-0}"
    write_windows_recovery_marker_file_best_effort "BIOS" "$state" "$rc"
}


write_target_fstab_or_die() {
    local root_uuid

    root_uuid=$(blkid -s UUID -o value "$NEW_PART" 2>/dev/null || true)
    [ -n "$root_uuid" ] || die "root UUID missing before fstab write"
    echo "UUID=$root_uuid / ext4 defaults 0 1" > /mnt/target/etc/fstab
}

partition_has_boot_flag() {
    local disk="$1" partition_number="$2"
    parted -sm "$disk" print 2>/dev/null |
        awk -F: -v number="$partition_number" '
            $1 == number {
                matched = 1
                count = split($7, flags, ",")
                for (i = 1; i <= count; i++) {
                    sub(/;$/, "", flags[i])
                    if (flags[i] == "boot") has_boot = 1
                }
            }
            END { exit !(matched && has_boot) }
        '
}

only_mbr_partition_has_boot_flag() {
    local disk="$1"
    local expected_number="$2"

    parted -sm "$disk" print 2>/dev/null |
        awk -F: -v expected="$expected_number" '
            $1 ~ /^[0-9]+$/ {
                number = $1
                count = split($7, flags, ",")
                for (i = 1; i <= count; i++) {
                    sub(/;$/, "", flags[i])
                    if (flags[i] == "boot") {
                        if (number == expected) expected_is_active = 1
                        else unexpected_is_active = 1
                    }
                }
            }
            END { exit !(expected_is_active && !unexpected_is_active) }
        '
}

set_mbr_active_partition_verified() {
    local partition_number="$1"
    local purpose="$2"
    local rc

    echo "+ sfdisk --lock --activate $DISK $partition_number"
    if sfdisk --lock --activate "$DISK" "$partition_number"; then
        rc=0
    else
        rc=$?
    fi
    sync || true
    partprobe "$DISK" 2>/dev/null || true
    udevadm settle --timeout=10 2>/dev/null || true

    if ! only_mbr_partition_has_boot_flag "$DISK" "$partition_number"; then
        echo "$purpose: MBR boot flags do not match the requested state after rc=$rc"
        return 1
    fi
    if [ "$rc" -ne 0 ]; then
        echo "WARNING: sfdisk returned rc=$rc, but the requested MBR boot flags were verified"
    fi
    return 0
}

set_bios_boot_flags_or_die() {
    local windows_boot_partition_number

    windows_boot_partition_number="$(partition_number "$WINDOWS_BOOT_PART")"
    set_mbr_active_partition_verified \
        "$windows_boot_partition_number" "BIOS boot-flag update" || \
        die "the Windows boot partition could not be made the only active MBR partition"
}

final_verify_or_die() {
    local target_verify="/mnt/libertix-final-verify"
    local windows_verify="/mnt/libertix-windows-final-verify"
    local fs uuid primary_slot_count windows_boot_part_num dpkg_audit

    mark "150-final-verify"
    echo "FINAL VERIFY: checking installed system before success"

    [ -n "$DISK" ] && [ -b "$DISK" ] || die "final verify: target disk missing"
    [ -n "$NEW_PART" ] && [ -b "$NEW_PART" ] || die "final verify: Linux partition missing"
    [ -n "$WINDOWS_PART" ] && [ -b "$WINDOWS_PART" ] || die "final verify: Windows partition missing"
    [ -n "$WINDOWS_BOOT_PART" ] && [ -b "$WINDOWS_BOOT_PART" ] || \
        die "final verify: Windows boot partition missing"

    assert_recovery_unchanged_or_die

    primary_slot_count="$(mbr_primary_slot_count "$DISK")"
    [ "$primary_slot_count" -le 4 ] || \
        die "final verify: MBR primary slot count is $primary_slot_count"

    windows_boot_part_num="$(partition_number "$WINDOWS_BOOT_PART")"
    partition_has_boot_flag "$DISK" "$windows_boot_part_num" || \
        die "final verify: Windows boot partition is not active"
    if partition_has_boot_flag "$DISK" "$NEW_PART_NUM"; then
        die "final verify: Linux partition unexpectedly has the MBR boot flag"
    fi

    fs="$(blkid -s TYPE -o value "$NEW_PART" 2>/dev/null || true)"
    [ "$fs" = "ext4" ] || die "final verify: $NEW_PART is not ext4"

    uuid="$(blkid -s UUID -o value "$NEW_PART" 2>/dev/null || true)"
    [ -n "$uuid" ] || die "final verify: Linux partition UUID missing"

    mount_linux_root_read_only_or_die "$NEW_PART" "$target_verify"
    [ -f "$target_verify/etc/os-release" ] || die "final verify: target os-release missing"
    [ -f "$target_verify/etc/fstab" ] || die "final verify: target fstab missing"
    grep -q "$uuid" "$target_verify/etc/fstab" || die "final verify: root UUID missing from fstab"
    [ -f "$target_verify/boot/grub/grub.cfg" ] || die "final verify: grub.cfg missing"
    grep -q "menuentry" "$target_verify/boot/grub/grub.cfg" || die "final verify: grub menu missing"
    [ -d "$target_verify/home/$USERNAME" ] || die "final verify: user home missing"
    find "$target_verify/boot" -maxdepth 1 -type f -name 'vmlinuz-*' -print -quit | grep -q . || die "final verify: kernel missing"
    find "$target_verify/boot" -maxdepth 1 -type f -name 'initrd.img-*' -print -quit | grep -q . || die "final verify: initramfs missing"
    chroot "$target_verify" id "$USERNAME" | grep -q 'groups=.*sudo' || die "final verify: user is not in sudo group"
    chroot "$target_verify" passwd -S "$USERNAME" | grep -Eq "^[^ ]+ P " || die "final verify: user password is not set"
    chroot "$target_verify" visudo -cf /etc/sudoers >/dev/null || die "final verify: sudoers is invalid"
    chroot "$target_verify" grub-script-check /boot/grub/grub.cfg || die "final verify: grub.cfg syntax is invalid"
    dpkg_audit=$(chroot "$target_verify" dpkg --audit)
    [ -z "$dpkg_audit" ] || die "final verify: dpkg audit failed: $dpkg_audit"
    verify_fstab_or_die "$target_verify"
    umount "$target_verify"

    mkdir -p "$windows_verify"
    mount -t ntfs-3g -o ro "$WINDOWS_PART" "$windows_verify"
    [ -d "$windows_verify/Windows/System32" ] || die "final verify: Windows system directory missing"
    [ -f "$windows_verify/Windows/System32/config/SYSTEM" ] || die "final verify: Windows SYSTEM hive missing"
    [ ! -e "$windows_verify/grldr" ] || die "final verify: temporary grldr still present"
    [ ! -e "$windows_verify/grldr.mbr" ] || die "final verify: temporary grldr.mbr still present"
    [ ! -e "$windows_verify/menu.lst" ] || die "final verify: temporary menu.lst still present"
    umount "$windows_verify"

    echo "FINAL VERIFY: success"
}

firmware_prepare_rollback_best_effort() {
    return 0
}

firmware_resolve_rollback_partition() {
    local candidate

    [ -z "$NEW_PART" ] || return 0
    candidate="$(partition_at_offset "$DISK" "$INSTALLER_FINAL_OFFSET_BYTES" || true)"
    if [ -z "$candidate" ]; then
        candidate="$(partition_at_offset "$DISK" "$INSTALLER_PARTITION_OFFSET_BYTES" || true)"
    fi
    if [ -n "$candidate" ]; then
        NEW_PART="$candidate"
        NEW_PART_NUM="$(partition_number "$candidate")"
        echo "ROLLBACK: resolved transaction partition as $NEW_PART"
    fi
}

remove_mbr_partition_entry_verified() {
    local number="$1"
    local purpose="$2"
    local rc layout

    echo "+ parted -s $DISK rm $number"
    if parted -s "$DISK" rm "$number"; then
        rc=0
    else
        rc=$?
    fi
    sync || true
    partprobe "$DISK" 2>/dev/null || true
    udevadm settle 2>/dev/null || true

    layout="$(parted -sm "$DISK" unit s print 2>/dev/null)" || {
        echo "$purpose: cannot verify the MBR table after parted returned rc=$rc"
        return 1
    }
    if printf '%s\n' "$layout" | awk -F: -v number="$number" '
        $1 == number { found=1 }
        END { exit(found ? 0 : 1) }
    '; then
        echo "$purpose: partition $number remains after parted returned rc=$rc"
        return 1
    fi
    if [ "$rc" -ne 0 ]; then
        echo "WARNING: parted returned rc=$rc, but removal of MBR partition $number was verified"
    fi
    return 0
}

firmware_rollback_partition_is_owned() {
    local partition="$1"

    [ "$(parent_disk_from_part "$partition")" = "$DISK" ] \
        && {
            [ "$(partition_start_bytes "$DISK" "$partition" || true)" = \
                "$INSTALLER_PARTITION_OFFSET_BYTES" ] ||
            [ "$(partition_start_bytes "$DISK" "$partition" || true)" = \
                "$INSTALLER_FINAL_OFFSET_BYTES" ]
        }
}

firmware_relocate_installer_partition_or_die() {
    local final_offset="$1" final_size="$2"
    local layout logical_sector installer_sector recovery_sector owned_layout
    local target_number start_sector size_sectors extended_number

    bios_partition_table_or_die >/dev/null
    firmware_rollback_partition_is_owned "$NEW_PART" || \
        die "offline BIOS resize does not own the staging partition"
    assert_not_mounted_or_open "$NEW_PART"
    logical_sector="$(blockdev --getss "$DISK" 2>/dev/null || echo 0)"
    start_sector="$(bytes_to_logical_sectors "$final_offset" "$logical_sector")" || \
        die "final BIOS partition offset is not sector aligned"
    size_sectors="$(bytes_to_logical_sectors "$final_size" "$logical_sector")" || \
        die "final BIOS partition size is not sector aligned"
    target_number="$NEW_PART_NUM"

    if [ "$NEW_PART_NUM" -ge 5 ] 2>/dev/null; then
        layout="$(parted -sm "$DISK" unit s print 2>/dev/null)" || \
            die "cannot read MBR layout before offline relocation"
        installer_sector="$(bytes_to_logical_sectors \
            "$INSTALLER_PARTITION_OFFSET_BYTES" "$logical_sector")" || \
            die "staging offset is not sector aligned"
        recovery_sector="$(bytes_to_logical_sectors \
            "$RECOVERY_PARTITION_OFFSET_BYTES" "$logical_sector")" || \
            die "Recovery offset is not sector aligned"
        owned_layout="$(printf '%s\n' "$layout" |
            mbr_owned_logical_layout_from_machine_output \
                "$installer_sector" "$recovery_sector")" || \
            die "offline BIOS resize could not prove ownership of the logical staging layout"
        IFS=: read -r _ _ _ extended_number _ _ <<< "$owned_layout"
        target_number="$extended_number"
    fi

    echo "Relocating MBR staging partition $NEW_PART_NUM to final primary slot $target_number"
    remove_mbr_partition_entry_verified \
        "$NEW_PART_NUM" "offline MBR staging cleanup" || \
        die "offline BIOS staging partition could not be removed"
    NEW_PART=""
    NEW_PART_NUM=""
    if [ -n "${extended_number:-}" ]; then
        firmware_cleanup_partition_container_best_effort || \
            die "offline BIOS extended container could not be removed"
    fi

    printf 'start=%s, size=%s, type=83\n' "$start_sector" "$size_sectors" |
        sfdisk --lock --append --no-reread -N "$target_number" "$DISK" || \
        die "sfdisk could not create the final primary MBR Linux partition"
    sync
    partprobe "$DISK" 2>/dev/null || true
    udevadm settle --timeout=10 2>/dev/null || true

    for _ in $(seq 1 20); do
        NEW_PART="$(partition_at_offset "$DISK" "$final_offset" || true)"
        [ -n "$NEW_PART" ] && [ -b "$NEW_PART" ] && break
        sleep 0.25
    done
    [ -n "$NEW_PART" ] && [ -b "$NEW_PART" ] || \
        die "final primary MBR Linux partition could not be resolved"
    NEW_PART_NUM="$(partition_number "$NEW_PART")"
    [ "$NEW_PART_NUM" -ge 1 ] && [ "$NEW_PART_NUM" -le 4 ] || \
        die "offline BIOS relocation did not create a primary partition"
    [ "$(blockdev --getsize64 "$NEW_PART" 2>/dev/null || echo 0)" = "$final_size" ] || \
        die "final primary MBR Linux partition size verification failed"
}

firmware_cleanup_partition_container_best_effort() {
    local layout current_table logical_sector installer_sector recovery_sector
    local windows_number windows_end extended_row extended_rc extended_type
    local extended_number extended_start

    layout="$(parted -sm "$DISK" unit s print 2>/dev/null)" || return 1
    current_table="$(printf '%s\n' "$layout" | awk -F: 'NR==2{print $6; exit}')"
    [ "$current_table" = "msdos" ] || return 0

    logical_sector="$(blockdev --getss "$DISK" 2>/dev/null || true)"
    [ "${logical_sector:-0}" -gt 0 ] 2>/dev/null || return 1
    installer_sector="$(bytes_to_logical_sectors \
        "$INSTALLER_PARTITION_OFFSET_BYTES" "$logical_sector")" || return 1
    recovery_sector="$(bytes_to_logical_sectors \
        "$RECOVERY_PARTITION_OFFSET_BYTES" "$logical_sector")" || return 1

    if extended_row="$(
        printf '%s\n' "$layout" |
            mbr_empty_container_from_machine_output "$installer_sector" "$recovery_sector"
    )"; then
        extended_rc=0
    else
        extended_rc=$?
    fi
    if [ "$extended_rc" -eq 2 ]; then
        echo "ROLLBACK: refusing to remove the extended container because a logical partition remains"
        return 1
    fi
    if [ "$extended_rc" -ne 0 ]; then
        echo "ROLLBACK: refusing ambiguous extended-container cleanup"
        return 1
    fi
    if [ -z "$extended_row" ]; then
        # Some partitioning tools remove an empty container automatically.
        return 0
    fi

    IFS=: read -r extended_number extended_start _ <<< "$extended_row"
    extended_type="$(sfdisk --part-type "$DISK" "$extended_number" 2>/dev/null \
        | normalize_mbr_partition_type)"
    case "$extended_type" in
        5|f|85) ;;
        *)
            echo "ROLLBACK: refusing to remove partition $extended_number because type $extended_type is not extended"
            return 1
            ;;
    esac

    windows_number="$(partition_number "$WINDOWS_PART")"
    windows_end="$(
        printf '%s\n' "$layout" | awk -F: -v number="$windows_number" '
            $1 == number { end=$3; sub(/s$/, "", end); print end; exit }
        '
    )"
    [ -n "$windows_end" ] && [ "$windows_end" -lt "$extended_start" ] || {
        echo "ROLLBACK: extended container does not follow the Windows partition"
        return 1
    }

    # Windows creates an extended container when the temporary FAT32 volume
    # becomes logical partition 5. Once that owned logical partition is gone,
    # the empty container must also go or C: cannot grow back to Recovery.
    echo "ROLLBACK: deleting empty transaction-owned extended partition $extended_number"
    remove_mbr_partition_entry_verified \
        "$extended_number" "ROLLBACK: extended-container cleanup" || return 1
}

firmware_restore_boot_state_best_effort() {
    local windows_boot_partition windows_boot_number

    windows_boot_partition=$(partition_at_offset "$DISK" "$WINDOWS_BOOT_PARTITION_OFFSET_BYTES" || true)
    if [ -z "$windows_boot_partition" ] || [ ! -b "$windows_boot_partition" ]; then
        echo "ROLLBACK: Windows boot partition could not be resolved from the manifest"
        return 1
    fi

    windows_boot_number=$(partition_number "$windows_boot_partition")
    set_mbr_active_partition_verified \
        "$windows_boot_number" "ROLLBACK: Windows boot-flag restore"
}

firmware_write_failure_marker_best_effort() {
    local rc="$1"
    write_windows_recovery_marker_best_effort "live-failed" "$rc"
}

bios_partition_table_or_die() {
    local partition_table

    partition_table="$(
        parted -sm "$DISK" print 2>/dev/null |
            awk -F: 'NR == 2 { print tolower($6); exit }'
    )"
    [ "$partition_table" = "msdos" ] || \
        die "BIOS adapter expected an MBR partition table, got ${partition_table:-unknown}"
    printf '%s\n' "$partition_table"
}

prepare_installer_partition_for_target_format_or_die() {
    local layout logical_sector installer_sector recovery_sector owned_layout
    local logical_number logical_start logical_end
    local extended_number extended_start extended_type
    local original_size partition_size new_end new_size

    bios_partition_table_or_die >/dev/null
    [ "$SHARE_LINUX_FILES_IN_WINDOWS" = "true" ] || return 0
    [ "${NEW_PART_NUM:-0}" -ge 5 ] 2>/dev/null || return 0

    mark "055-normalize-mbr-linux-slot"
    layout="$(parted -sm "$DISK" unit s print 2>/dev/null)" || \
        die "cannot read MBR layout before Linux partition normalization"
    logical_sector="$(blockdev --getss "$DISK" 2>/dev/null || true)"
    [ "${logical_sector:-0}" -gt 0 ] 2>/dev/null || \
        die "cannot determine the MBR logical sector size"
    installer_sector="$(bytes_to_logical_sectors \
        "$INSTALLER_PARTITION_OFFSET_BYTES" "$logical_sector")" || \
        die "the MBR staging offset is not aligned to the logical sector size"
    recovery_sector="$(bytes_to_logical_sectors \
        "$RECOVERY_PARTITION_OFFSET_BYTES" "$logical_sector")" || \
        die "the MBR recovery offset is not aligned to the logical sector size"

    owned_layout="$(
        printf '%s\n' "$layout" |
            mbr_owned_logical_layout_from_machine_output "$installer_sector" "$recovery_sector"
    )" || die "the MBR logical staging layout is not uniquely owned by this transaction"
    IFS=: read -r \
        logical_number logical_start logical_end \
        extended_number extended_start _ <<< "$owned_layout"

    [ "$logical_number" = "$NEW_PART_NUM" ] || \
        die "the MBR logical staging number changed before normalization"
    [ "$(partition_start_bytes "$DISK" "$NEW_PART" || true)" = "$INSTALLER_PARTITION_OFFSET_BYTES" ] || \
        die "the MBR logical staging offset changed before normalization"
    extended_type="$(
        sfdisk --part-type "$DISK" "$extended_number" 2>/dev/null |
            normalize_mbr_partition_type
    )"
    case "$extended_type" in
        5|f|85) ;;
        *) die "the container around the MBR staging partition is not extended" ;;
    esac

    assert_not_mounted_or_open "$NEW_PART"
    assert_recovery_unchanged_or_die
    original_size="$(blockdev --getsize64 "$NEW_PART" 2>/dev/null || echo 0)"
    [ "$original_size" -gt 0 ] || die "cannot read the MBR logical staging size"

    # ext4-win-driver 0.2.2 reads only the four primary MBR entries and does
    # not traverse EBRs. When Windows created the owned staging volume as the
    # only logical partition, replace that logical/container pair with one
    # primary partition at the identical payload geometry. Recovery remains
    # untouched, and rollback can still resolve the partition by plan offset.
    echo "Converting transaction-owned MBR logical partition $logical_number to a primary Linux slot"
    NEW_PART=""
    NEW_PART_NUM=""
    remove_mbr_partition_entry_verified \
        "$logical_number" "MBR logical staging cleanup" || \
        die "the MBR logical staging partition could not be removed"
    remove_mbr_partition_entry_verified \
        "$extended_number" "MBR extended-container cleanup" || \
        die "the MBR extended staging container could not be removed"

    partition_size=$((logical_end - logical_start + 1))
    [ "$partition_size" -gt 0 ] || die "the primary Linux partition size is invalid"

    # Exact sector values avoid any geometry reinterpretation. The disk lock
    # also prevents udev from racing the short interval between removal of the
    # extended container and creation of the replacement primary entry.
    echo "+ sfdisk: create primary slot $extended_number at sector $logical_start size $partition_size"
    printf 'start=%s, size=%s, type=83\n' "$logical_start" "$partition_size" |
        sfdisk --lock --append --no-reread -N "$extended_number" "$DISK" ||
        die "sfdisk could not create the primary Linux partition"
    sync
    partprobe "$DISK" 2>/dev/null || true
    udevadm settle 2>/dev/null || true

    # BLKRRPART and udev updates are asynchronous on some virtual controllers.
    # Resolve the exact manifest offset rather than assuming a device number.
    for _ in $(seq 1 20); do
        NEW_PART="$(partition_at_offset "$DISK" "$INSTALLER_PARTITION_OFFSET_BYTES" || true)"
        [ -n "$NEW_PART" ] && [ -b "$NEW_PART" ] && break
        sleep 0.25
    done
    [ -n "$NEW_PART" ] && [ -b "$NEW_PART" ] || \
        die "the primary Linux partition could not be resolved after MBR normalization"
    NEW_PART_NUM="$(partition_number "$NEW_PART")"
    [ "$NEW_PART_NUM" -ge 1 ] && [ "$NEW_PART_NUM" -le 4 ] || \
        die "MBR normalization did not create a primary Linux partition"
    new_end="$(
        parted -sm "$DISK" unit s print 2>/dev/null |
            awk -F: -v number="$NEW_PART_NUM" '
                $1 == number { end=$3; sub(/s$/, "", end); print end; exit }
            '
    )"
    [ "$new_end" = "$logical_end" ] || \
        die "the primary Linux partition end changed during MBR normalization"
    new_size="$(blockdev --getsize64 "$NEW_PART" 2>/dev/null || echo 0)"
    [ "$new_size" = "$original_size" ] || \
        die "the primary Linux partition size changed during MBR normalization"
    assert_recovery_unchanged_or_die
    echo "Primary MBR Linux partition verified at $NEW_PART"
}




wait_for_prereqs() {
    mark "005-wait-prereqs"
    local i label_device
    for i in $(seq 1 60); do
        local disk_ready=0
        local config_ready=0
        local candidate found_config

        while read -r candidate; do
            [ -n "$candidate" ] || continue
            [ -b "$candidate" ] && { disk_ready=1; break; }
        done < <(candidate_disks)

        for candidate in \
            /run/live/medium/installation-plan.json \
            /lib/live/mount/medium/installation-plan.json \
            /cdrom/installation-plan.json; do
            [ -f "$candidate" ] && { config_ready=1; break; }
        done

        if [ "$config_ready" -eq 0 ]; then
            found_config=$(find /run/live /lib/live /cdrom -maxdepth 6 -name installation-plan.json -print -quit 2>/dev/null || true)
            [ -n "$found_config" ] && config_ready=1
        fi

        if [ "$config_ready" -eq 0 ]; then
            # load_libertix_staging_volume_label() only runs from stage
            # 010-read-config, after this stage returns, so the label is not
            # yet set here. Under `set -u` an unguarded reference aborts the
            # whole script rather than just failing this comparison.
            while read -r label_device; do
                [ -n "$label_device" ] || continue
                [ "$(blkid -s LABEL -o value "$label_device" 2>/dev/null || true)" = \
                    "${LIBERTIX_STAGING_VOLUME_LABEL:-}" ] && {
                    config_ready=1
                    break
                }
            done < <(blkid -o device 2>/dev/null || true)
        fi

        if [ "$disk_ready" -eq 1 ] && [ "$config_ready" -eq 1 ]; then
            udevadm settle 2>/dev/null || true
            return 0
        fi
        [ "$i" -eq 60 ] && echo "Prerequisite timeout: disk_ready=$disk_ready config_ready=$config_ready"
        sleep 1
    done
    die "live prerequisites not ready after 60s"
}

set_linux_partition_type_or_die() {
    [ -n "$NEW_PART_NUM" ] || die "Linux partition number missing"

    mark "060-set-linux-partition-type"
    bios_partition_table_or_die >/dev/null
    echo "Setting MBR partition $NEW_PART_NUM type to Linux (0x83)"
    run_logged sfdisk --part-type "$DISK" "$NEW_PART_NUM" 83 || \
        die "failed to set Linux MBR type on $NEW_PART"
    partprobe "$DISK" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
}

cleanup_windows_live_boot_artifacts() {
    local bcd_part windows_part bcd_mnt windows_mnt

    mark "006-clean-windows-live-boot"

    # First remove the one-shot Windows Boot Manager entry. If the installer
    # fails later, the next reboot must fall back to Windows instead of looping.
    bcd_part="$WINDOWS_BOOT_PART"
    [ -n "$bcd_part" ] && [ -b "$bcd_part" ] || \
        die "Windows boot partition is unavailable during BCD cleanup"

    bcd_mnt="/mnt/libertix-bcd"
    echo "Cleaning temporary BCD live boot entry from $bcd_part"
    mount_ntfs_rw_or_die "$bcd_part" "$bcd_mnt"
    [ -f "$bcd_mnt/Boot/BCD" ] || die "Windows BCD store disappeared after mount"
    delete_live_bcd_entry_or_die "$bcd_mnt/Boot/BCD"
    sync
    umount "$bcd_mnt"

    # Then remove the GRUB4DOS files that Windows used only to start this live
    # installer. The final Linux bootloader is installed later by grub-install.
    windows_part="$WINDOWS_PART"
    [ -n "$windows_part" ] && [ -b "$windows_part" ] || \
        die "Windows OS partition is unavailable during GRUB4DOS cleanup"

    windows_mnt="/mnt/libertix-windows-cleanup"
    echo "Removing temporary GRUB4DOS files from $windows_part"
    mount_ntfs_rw_or_die "$windows_part" "$windows_mnt"
    rm -f "$windows_mnt/grldr" "$windows_mnt/grldr.mbr" "$windows_mnt/menu.lst"
    sync
    umount "$windows_mnt"
}
