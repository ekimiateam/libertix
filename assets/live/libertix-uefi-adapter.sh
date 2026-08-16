#!/bin/bash

# UEFI-specific live-installation adapter.
#
# The main live installer owns the installation sequence. This module owns ESP
# discovery, signed bootloader installation, BootNext/BootOrder cleanup, UEFI
# rollback, and UEFI final verification. These policies intentionally remain
# outside the common orchestrator.

readonly UEFI_BOOTENTRY_HELPER="/usr/local/lib/libertix/libertix-uefi-bootentries.py"
readonly WINDOWS_BOOT_DESCRIPTION="Windows Boot Manager"
readonly WINDOWS_BOOT_LOADER='\EFI\Microsoft\Boot\bootmgfw.efi'
readonly LIBERTIX_BOOT_DESCRIPTION="Libertix"
readonly LIBERTIX_BOOT_LOADER='\EFI\Libertix\shimx64.efi'


firmware_retire_completed_transaction_best_effort() {
    # The Windows startup verifier archives this transaction document inside
    # the permanent recovery session before removing C:\LibertixTools. Keeping
    # it here is what makes a user-requested rollback possible after first boot.
    return 0
}


write_windows_recovery_marker_best_effort() {
    local state="$1"
    local rc="${2:-0}"
    write_windows_recovery_marker_file_best_effort "UEFI" "$state" "$rc"
}

final_verify_or_die() {
    local target_verify="/mnt/libertix-final-verify"
    local windows_verify="/mnt/libertix-windows-final-verify"
    local fs uuid primary_slot_count part_table esp_part esp_num esp_guid esp_verify esp_uuid
    local dpkg_audit bootnumbers owner_bootnum current_order first_bootnum

    mark "150-final-verify"
    echo "FINAL VERIFY: checking installed system before success"

    [ -n "$DISK" ] && [ -b "$DISK" ] || die "final verify: target disk missing"
    [ -n "$NEW_PART" ] && [ -b "$NEW_PART" ] || die "final verify: Linux partition missing"
    [ -n "$WINDOWS_PART" ] && [ -b "$WINDOWS_PART" ] || die "final verify: Windows partition missing"

    assert_recovery_unchanged_or_die

    part_table="$(parted -sm "$DISK" print 2>/dev/null | awk -F: 'NR==2{print $6}')"
    if [ "$part_table" = "msdos" ]; then
        primary_slot_count="$(mbr_primary_slot_count "$DISK")"
        [ "$primary_slot_count" -le 4 ] || \
            die "final verify: MBR primary slot count is $primary_slot_count"
    fi

    fs="$(blkid -s TYPE -o value "$NEW_PART" 2>/dev/null || true)"
    [ "$fs" = "ext4" ] || die "final verify: $NEW_PART is not ext4"

    uuid="$(blkid -s UUID -o value "$NEW_PART" 2>/dev/null || true)"
    [ -n "$uuid" ] || die "final verify: Linux partition UUID missing"

    mount_linux_root_read_only_or_die "$NEW_PART" "$target_verify"
    [ -f "$target_verify/etc/os-release" ] || die "final verify: target os-release missing"
    [ -f "$target_verify/etc/fstab" ] || die "final verify: target fstab missing"
    grep -q "$uuid" "$target_verify/etc/fstab" || die "final verify: root UUID missing from fstab"
    if [ -d /sys/firmware/efi ]; then
        esp_part="$(find_esp_partition || true)"
        [ -n "$esp_part" ] && [ -b "$esp_part" ] || die "final verify: UEFI ESP missing"
        esp_uuid="$(blkid -s UUID -o value "$esp_part" 2>/dev/null || true)"
        [ -n "$esp_uuid" ] || die "final verify: ESP UUID missing"
        grep -q "$esp_uuid" "$target_verify/etc/fstab" || die "final verify: ESP UUID missing from fstab"
        grep -q '/boot/efi' "$target_verify/etc/fstab" || die "final verify: /boot/efi missing from fstab"
    fi
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

    esp_part="$(find_esp_partition || true)"
    [ -n "$esp_part" ] && [ -b "$esp_part" ] || die "final verify: UEFI ESP missing"
    esp_num="$(partition_number "$esp_part")"
    esp_guid="$(blkid -s PARTUUID -o value "$esp_part" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    esp_verify="/mnt/libertix-esp-final-verify"
    mkdir -p "$esp_verify"
    mount -t vfat -o ro "$esp_part" "$esp_verify"
    [ -f "$esp_verify/EFI/Libertix/shimx64.efi" ] || die "final verify: Libertix shim missing"
    [ -f "$esp_verify/EFI/Libertix/grubx64.efi" ] || die "final verify: Libertix signed GRUB missing"
    [ -f "$esp_verify/EFI/Libertix/grub.cfg" ] || die "final verify: Libertix EFI grub.cfg missing"
    [ -f "$esp_verify/EFI/Libertix/.libertix-owner" ] || \
        die "final verify: Libertix EFI ownership marker missing"
    [ "$(sed -n '1p' "$esp_verify/EFI/Libertix/.libertix-owner" | tr -d '\r\n')" = "$RECOVERY_RUN_ID" ] || \
        die "final verify: Libertix EFI ownership marker mismatch"
    owner_bootnum="$(sed -n '2p' "$esp_verify/EFI/Libertix/.libertix-owner" | tr -d '\r\n')"
    [ "$(sed -n '3p' "$esp_verify/EFI/Libertix/.libertix-owner" | tr -d '\r\n')" = "$esp_num" ] || \
        die "final verify: Libertix EFI ownership partition number mismatch"
    [ "$(sed -n '4p' "$esp_verify/EFI/Libertix/.libertix-owner" | tr -d '\r\n')" = "$esp_guid" ] || \
        die "final verify: Libertix EFI ownership partition identifier mismatch"
    [ "$(sed -n '5p' "$esp_verify/EFI/Libertix/.libertix-owner" | tr -d '\r\n')" = "$LIBERTIX_BOOT_LOADER" ] || \
        die "final verify: Libertix EFI ownership loader mismatch"
    [ ! -e "$esp_verify/EFI/LibertixInstaller" ] || \
        die "final verify: temporary EFI/LibertixInstaller directory was not removed"
    umount "$esp_verify"

    if ! bootnumbers="$(find_exact_uefi_bootnumbers \
        "$WINDOWS_BOOT_DESCRIPTION" "$WINDOWS_BOOT_LOADER" "$esp_num" "$esp_guid")"; then
        die "final verify: cannot inspect Windows firmware boot entries"
    fi
    [ -n "$bootnumbers" ] || die "final verify: Windows Boot Manager entry is absent for the current ESP"
    if ! bootnumbers="$(find_exact_uefi_bootnumbers \
        "$LIBERTIX_BOOT_DESCRIPTION" "$LIBERTIX_BOOT_LOADER" "$esp_num" "$esp_guid")"; then
        die "final verify: cannot inspect Libertix firmware boot entries"
    fi
    printf '%s\n' "$bootnumbers" | grep -Fxiq "$owner_bootnum" || \
        die "final verify: owned Libertix entry does not target the current ESP"
    current_order="$(efibootmgr 2>/dev/null | awk -F: '/^BootOrder:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
    first_bootnum="${current_order%%,*}"
    [ "${first_bootnum^^}" = "${owner_bootnum^^}" ] || \
        die "final verify: firmware did not keep the owned Libertix entry first"

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
    cleanup_final_uefi_bootloader_best_effort
}

uefi_partition_table_or_die() {
    local partition_table

    partition_table="$(
        parted -sm "$DISK" print 2>/dev/null |
            awk -F: 'NR == 2 { print tolower($6); exit }'
    )"
    case "$partition_table" in
        gpt|msdos) printf '%s\n' "$partition_table" ;;
        *) die "UEFI adapter cannot determine the partition table on $DISK" ;;
    esac
}

firmware_resolve_rollback_partition() {
    local candidate

    [ -z "$NEW_PART" ] || return 0
    if [ -n "$LIVE_PART" ] && [ -b "$LIVE_PART" ] \
        && [ "$(parent_disk_from_part "$LIVE_PART")" = "$DISK" ]; then
        NEW_PART="$LIVE_PART"
        NEW_PART_NUM="$(partition_number "$NEW_PART")"
        echo "ROLLBACK: using known live/Linux partition $NEW_PART"
        return 0
    fi

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

firmware_rollback_partition_is_owned() {
    local partition="$1"

    [ "$partition" != "$WINDOWS_PART" ] \
        && [ "$(parent_disk_from_part "$partition")" = "$DISK" ] \
        && {
            [ "$(partition_start_bytes "$DISK" "$partition" || true)" = \
                "$INSTALLER_PARTITION_OFFSET_BYTES" ] ||
            [ "$(partition_start_bytes "$DISK" "$partition" || true)" = \
                "$INSTALLER_FINAL_OFFSET_BYTES" ]
        }
}

firmware_relocate_installer_partition_or_die() {
    local final_offset="$1" final_size="$2"
    local logical_sector start_sector size_sectors old_number
    local linux_gpt_guid="0FC63DAF-8483-4772-8E79-3D69D8477DE4"

    [ "$(uefi_partition_table_or_die)" = "gpt" ] || \
        die "offline UEFI resize requires a GPT partition table"
    firmware_rollback_partition_is_owned "$NEW_PART" || \
        die "offline UEFI resize does not own the staging partition"
    assert_not_mounted_or_open "$NEW_PART"
    logical_sector="$(blockdev --getss "$DISK" 2>/dev/null || echo 0)"
    start_sector="$(bytes_to_logical_sectors "$final_offset" "$logical_sector")" || \
        die "final UEFI partition offset is not sector aligned"
    size_sectors="$(bytes_to_logical_sectors "$final_size" "$logical_sector")" || \
        die "final UEFI partition size is not sector aligned"
    old_number="$NEW_PART_NUM"

    echo "Relocating GPT staging partition $old_number to the final Linux extent"
    run_logged parted -s "$DISK" rm "$old_number"
    sync
    partprobe "$DISK" 2>/dev/null || true
    udevadm settle --timeout=10 2>/dev/null || true
    if parted -sm "$DISK" print 2>/dev/null |
        awk -F: -v number="$old_number" '$1 == number { found=1 } END { exit !found }'; then
        die "GPT staging partition remains after removal"
    fi

    printf 'start=%s, size=%s, type=%s, name="LibertixLinux"\n' \
        "$start_sector" "$size_sectors" "$linux_gpt_guid" |
        sfdisk --lock --append --no-reread -N "$old_number" "$DISK" || \
        die "sfdisk could not create the final GPT Linux partition"
    sync
    partprobe "$DISK" 2>/dev/null || true
    udevadm settle --timeout=10 2>/dev/null || true

    NEW_PART=""
    for _ in $(seq 1 20); do
        NEW_PART="$(partition_at_offset "$DISK" "$final_offset" || true)"
        [ -n "$NEW_PART" ] && [ -b "$NEW_PART" ] && break
        sleep 0.25
    done
    [ -n "$NEW_PART" ] && [ -b "$NEW_PART" ] || \
        die "final GPT Linux partition could not be resolved"
    NEW_PART_NUM="$(partition_number "$NEW_PART")"
    [ "$(blockdev --getsize64 "$NEW_PART" 2>/dev/null || echo 0)" = "$final_size" ] || \
        die "final GPT Linux partition size verification failed"
}

firmware_cleanup_partition_container_best_effort() {
    return 0
}

firmware_restore_boot_state_best_effort() {
    # On GPT, parted's "boot" flag is the ESP flag. Resolve the real ESP instead
    # of assuming partition 1, otherwise a rollback marks the wrong partition.
    local esp_part esp_num
    esp_part="$(find_esp_partition || true)"
    [ -n "$esp_part" ] && [ -b "$esp_part" ] || return 1
    [ "$(parent_disk_from_part "$esp_part")" = "$DISK" ] || return 1
    esp_num="$(partition_number "$esp_part")"
    [ -n "$esp_num" ] || return 1
    parted -s "$DISK" set "$esp_num" esp on 2>/dev/null || return 1
    parted -sm "$DISK" print 2>/dev/null | awk -F: -v number="$esp_num" '
        $1 == number {
            count++
            if ($7 ~ /(^|,)(boot|esp)(,|;$)/) found=1
        }
        END { exit !(count == 1 && found == 1) }
    '
}

firmware_write_failure_marker_best_effort() {
    local rc="$1"
    write_windows_recovery_marker_best_effort "live-failed" "$rc"
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
            while read -r label_device; do
                [ -n "$label_device" ] || continue
                [ "$(blkid -s LABEL -o value "$label_device" 2>/dev/null || true)" = \
                    "$LIBERTIX_STAGING_VOLUME_LABEL" ] && {
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

find_esp_partition() (
    local esp filesystem mountpoint="" mounted=false

    cleanup_esp_probe_mount() {
        if [ "$mounted" = true ] && mountpoint -q "$mountpoint"; then
            umount "$mountpoint" 2>/dev/null || true
        fi
        [ -z "$mountpoint" ] || rmdir "$mountpoint" 2>/dev/null || true
    }
    trap cleanup_esp_probe_mount EXIT HUP INT TERM

    esp="$(partition_at_offset "$DISK" "$WINDOWS_BOOT_PARTITION_OFFSET_BYTES" || true)"
    [ -n "$esp" ] && [ -b "$esp" ] || return 1
    [ "$(parent_disk_from_part "$esp")" = "$DISK" ] || return 1
    filesystem="$(blkid -s TYPE -o value "$esp" 2>/dev/null || echo "")"
    case "$filesystem" in
        vfat|fat|msdos) ;;
        *) return 1 ;;
    esac

    mountpoint="$(mktemp -d)"
    if ! mount -t vfat -o ro "$esp" "$mountpoint" 2>/dev/null; then
        return 1
    fi
    mounted=true
    if [ ! -f "$mountpoint/EFI/Microsoft/Boot/bootmgfw.efi" ]; then
        return 1
    fi
    umount "$mountpoint" 2>/dev/null || return 1
    mounted=false
    rmdir "$mountpoint" 2>/dev/null || return 1
    mountpoint=""
    trap - EXIT HUP INT TERM
    echo "$esp"
)

cleanup_final_uefi_bootloader_best_effort() (
    local bootnum entry_line esp_part esp_mount owner_file owner_run_id

    cleanup_rollback_esp_mount() {
        if mountpoint -q "$esp_mount"; then
            umount "$esp_mount" 2>/dev/null || \
                echo "WARNING: rollback could not unmount the ESP at $esp_mount" >&2
        fi
        rmdir "$esp_mount" 2>/dev/null || true
    }

    [ "$INSTALL_SUCCESS" = false ] || return 0

    esp_part="$(find_esp_partition || true)"
    [ -n "$esp_part" ] && [ -b "$esp_part" ] || return 1

    esp_mount="/mnt/libertix-rollback-esp"
    mkdir -p "$esp_mount"
    trap cleanup_rollback_esp_mount EXIT
    mount -t vfat -o rw,flush "$esp_part" "$esp_mount" || return 1
    if [ -d "$esp_mount/EFI/Libertix" ]; then
        owner_file="$esp_mount/EFI/Libertix/.libertix-owner"
        [ -f "$owner_file" ] || return 1
        owner_run_id="$(sed -n '1p' "$owner_file" | tr -d '\r\n')"
        [ "$owner_run_id" = "$RECOVERY_RUN_ID" ] || return 1
        bootnum="$(sed -n '2p' "$owner_file" | tr -d '\r\n')"
        if [ -n "$bootnum" ]; then
            printf '%s\n' "$bootnum" | grep -Eq '^[0-9A-Fa-f]{4}$' || return 1
            command -v efibootmgr >/dev/null 2>&1 || return 1
            entry_line="$(efibootmgr -v 2>/dev/null | grep -Ei "^Boot${bootnum}[* ]" || true)"
            if [ -n "$entry_line" ]; then
                printf '%s\n' "$entry_line" | grep -Fqi ' Libertix' || return 1
                printf '%s\n' "$entry_line" | grep -Fqi 'File(\EFI\Libertix\shimx64.efi)' || return 1
                echo "ROLLBACK: deleting owned final UEFI entry Boot$bootnum"
                efibootmgr -b "$bootnum" -B || return 1
            fi
        fi
        echo "ROLLBACK: removing EFI/Libertix from ESP"
        rm -rf "$esp_mount/EFI/Libertix" || return 1
        sync || return 1
    fi
    [ ! -e "$esp_mount/EFI/Libertix" ] || return 1
    umount "$esp_mount" || return 1
    rmdir "$esp_mount" 2>/dev/null || return 1
    trap - EXIT
)

set_linux_partition_type_or_die() {
    local linux_gpt_guid="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
    local partition_table parttype expected

    [ -n "$NEW_PART_NUM" ] || die "Linux partition number missing"

    mark "060-set-linux-partition-type"
    partition_table="$(uefi_partition_table_or_die)"
    if [ "$partition_table" = "msdos" ]; then
        echo "Setting MBR partition $NEW_PART_NUM type to Linux (0x83)"
        run_logged sfdisk --part-type "$DISK" "$NEW_PART_NUM" 83 || \
            die "failed to set Linux MBR type on $NEW_PART"
    else
        echo "Setting GPT partition $NEW_PART_NUM type to Linux filesystem"
        run_logged sfdisk --part-type "$DISK" "$NEW_PART_NUM" "$linux_gpt_guid" || \
            die "failed to set Linux GPT type on $NEW_PART"
        run_logged sfdisk --part-label "$DISK" "$NEW_PART_NUM" "LibertixLinux" || \
            die "failed to set Linux GPT label on $NEW_PART"
    fi

    partprobe "$DISK" 2>/dev/null || true
    udevadm settle 2>/dev/null || true

    if [ "$partition_table" != "msdos" ]; then
        parttype="$(lsblk -dnro PARTTYPE "$NEW_PART" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
        expected="$(echo "$linux_gpt_guid" | tr '[:upper:]' '[:lower:]')"
        [ "$parttype" = "$expected" ] || \
            die "Linux GPT type verification failed on $NEW_PART: $parttype"
    fi
}

prepare_installer_partition_for_target_format_or_die() {
    return 0
}

verify_linux_partition_type_or_die() {
    local linux_gpt_guid="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
    local partition_table parttype expected

    partition_table="$(uefi_partition_table_or_die)"
    [ "$partition_table" != "msdos" ] || return 0

    partprobe "$DISK" 2>/dev/null || true
    udevadm settle 2>/dev/null || true

    parttype="$(lsblk -dnro PARTTYPE "$NEW_PART" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
    expected="$(echo "$linux_gpt_guid" | tr '[:upper:]' '[:lower:]')"
    [ "$parttype" = "$expected" ] || \
        die "Linux GPT type verification failed on $NEW_PART after bootloader install: $parttype"
}

write_target_fstab_or_die() {
    local root_uuid esp_part esp_uuid

    root_uuid="$(blkid -s UUID -o value "$NEW_PART" 2>/dev/null || true)"
    [ -n "$root_uuid" ] || die "root UUID missing before fstab write"

    echo "UUID=$root_uuid / ext4 defaults 0 1" > /mnt/target/etc/fstab

    if [ -d /sys/firmware/efi ]; then
        esp_part="$(find_esp_partition || true)"
        [ -n "$esp_part" ] && [ -b "$esp_part" ] || die "UEFI ESP missing before fstab write"
        esp_uuid="$(blkid -s UUID -o value "$esp_part" 2>/dev/null || true)"
        [ -n "$esp_uuid" ] || die "ESP UUID missing before fstab write"
        mkdir -p /mnt/target/boot/efi
        echo "UUID=$esp_uuid /boot/efi vfat umask=0077 0 1" >> /mnt/target/etc/fstab
    fi
}

find_exact_uefi_bootnumbers() {
    local description="$1" loader_path="$2" esp_num="$3" esp_guid="$4"
    [ -x "$UEFI_BOOTENTRY_HELPER" ] || return 2
    efibootmgr -v 2>/dev/null | python3 "$UEFI_BOOTENTRY_HELPER" \
        --description "$description" \
        --loader-path "$loader_path" \
        --partition-number "$esp_num" \
        --partition-guid "$esp_guid"
}

ensure_windows_bootentry_for_current_esp_or_die() {
    local esp_num="$1" esp_guid="$2" bootnumbers

    if ! bootnumbers="$(find_exact_uefi_bootnumbers \
        "$WINDOWS_BOOT_DESCRIPTION" "$WINDOWS_BOOT_LOADER" "$esp_num" "$esp_guid")"; then
        die "failed to inspect UEFI boot entries for the current Windows ESP"
    fi
    if [ -n "$bootnumbers" ]; then
        echo "Verified Windows Boot Manager entry for ESP $esp_guid: Boot$(printf '%s\n' "$bootnumbers" | head -n1)"
        return 0
    fi

    echo "Windows Boot Manager entry is absent for the current ESP; creating it"
    run_logged efibootmgr -c -d "$DISK" -p "$esp_num" \
        -L "$WINDOWS_BOOT_DESCRIPTION" -l "$WINDOWS_BOOT_LOADER"
    if ! bootnumbers="$(find_exact_uefi_bootnumbers \
        "$WINDOWS_BOOT_DESCRIPTION" "$WINDOWS_BOOT_LOADER" "$esp_num" "$esp_guid")"; then
        die "failed to verify the repaired Windows Boot Manager entry"
    fi
    [ -n "$bootnumbers" ] || \
        die "firmware did not retain the repaired Windows Boot Manager entry"
    echo "Created Windows Boot Manager entry for ESP $esp_guid: Boot$(printf '%s\n' "$bootnumbers" | head -n1)"
}

set_libertix_bootentry_first_or_die() {
    local esp_num="$1" esp_guid="$2" bootnumbers bootnum current_order rest new_order verified_order

    if ! bootnumbers="$(find_exact_uefi_bootnumbers \
        "$LIBERTIX_BOOT_DESCRIPTION" "$LIBERTIX_BOOT_LOADER" "$esp_num" "$esp_guid")"; then
        die "failed to inspect UEFI boot entries for the current Libertix ESP"
    fi
    bootnum="$(printf '%s\n' "$bootnumbers" | head -n1)"

    if [ -z "$bootnum" ]; then
        return 1
    fi

    current_order="$(efibootmgr 2>/dev/null | awk -F: '/^BootOrder:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
    rest="$(printf '%s\n' "$current_order" | tr ',' '\n' | awk -v n="$bootnum" 'toupper($0) != toupper(n) && $0 != ""' | paste -sd, -)"
    if [ -n "$rest" ]; then
        new_order="$bootnum,$rest"
    else
        new_order="$bootnum"
    fi

    run_logged efibootmgr -o "$new_order"
    verified_order="$(efibootmgr 2>/dev/null | awk -F: '/^BootOrder:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
    [ "${verified_order%%,*}" = "$bootnum" ] || \
        die "firmware did not retain the current ESP Libertix entry first in BootOrder"
    LIBERTIX_FINAL_BOOTNUM="$bootnum"
    return 0
}

install_signed_uefi_bootloader_or_die() {
    local esp_part esp_num esp_guid esp_mount efi_dir root_uuid

    esp_part="$(find_esp_partition || true)"
    [ -n "$esp_part" ] && [ -b "$esp_part" ] || die "UEFI ESP not found"

    esp_num="$(partition_number "$esp_part")"
    esp_guid="$(blkid -s PARTUUID -o value "$esp_part" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    printf '%s\n' "$esp_guid" | grep -Eq \
        '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' || \
        die "UEFI ESP GPT partition identifier is missing or invalid"
    root_uuid="$(blkid -s UUID -o value "$NEW_PART" 2>/dev/null || true)"
    [ -n "$root_uuid" ] || die "Linux root UUID missing before EFI install"

    esp_mount="/mnt/target/boot/efi"
    mkdir -p "$esp_mount"
    mountpoint -q "$esp_mount" || run_logged mount -t vfat "$esp_part" "$esp_mount"

    efi_dir="$esp_mount/EFI/Libertix"
    if [ -e "$efi_dir" ]; then
        [ -f "$efi_dir/.libertix-owner" ] || \
            die "EFI/Libertix exists without an ownership marker"
        [ "$(sed -n '1p' "$efi_dir/.libertix-owner" | tr -d '\r\n')" = "$RECOVERY_RUN_ID" ] || \
            die "EFI/Libertix belongs to another recovery run"
    fi
    mkdir -p "$efi_dir"
    printf '%s\n' "$RECOVERY_RUN_ID" > "$efi_dir/.libertix-owner"

    # The target-owned synchronizer inspects the actual Microsoft signature,
    # package ownership, and firmware trust before replacing any EFI binary.
    chroot /mnt/target /usr/local/sbin/libertix-sync-efi

    cat > "$efi_dir/grub.cfg" <<EOF
search --no-floppy --fs-uuid --set=root $root_uuid
set prefix=(\$root)/boot/grub
configfile /boot/grub/grub.cfg
EOF

    # Debian/Ubuntu signed GRUB normally reads the config beside the loaded EFI
    # binary, but mirroring it under EFI/debian helps if the compiled prefix is
    # distribution-specific.
    mkdir -p "$esp_mount/EFI/debian"
    cp -f "$efi_dir/grub.cfg" "$esp_mount/EFI/debian/grub.cfg"

    sync

    ensure_windows_bootentry_for_current_esp_or_die "$esp_num" "$esp_guid"
    LIBERTIX_FINAL_BOOTNUM=""
    if ! set_libertix_bootentry_first_or_die "$esp_num" "$esp_guid"; then
        run_logged efibootmgr -c -d "$DISK" -p "$esp_num" \
            -L "$LIBERTIX_BOOT_DESCRIPTION" -l "$LIBERTIX_BOOT_LOADER"
        set_libertix_bootentry_first_or_die "$esp_num" "$esp_guid" || \
            die "failed to put the current ESP Libertix entry first in UEFI BootOrder"
    fi
    [ -n "$LIBERTIX_FINAL_BOOTNUM" ] || die "final Libertix UEFI boot number is missing"
    printf '%s\n%s\n%s\n%s\n%s\n' \
        "$RECOVERY_RUN_ID" \
        "$LIBERTIX_FINAL_BOOTNUM" \
        "$esp_num" \
        "$esp_guid" \
        "$LIBERTIX_BOOT_LOADER" > "$efi_dir/.libertix-owner"

    # Windows stages this directory only to enter the live installer. Leaving
    # it on the ESP after success creates a second, stale boot surface.
    if [ -e "$esp_mount/EFI/LibertixInstaller" ]; then
        [ -f "$esp_mount/EFI/LibertixInstaller/.libertix-owner" ] || \
            die "temporary EFI/LibertixInstaller ownership marker is missing"
        [ "$(tr -d '\r\n' < "$esp_mount/EFI/LibertixInstaller/.libertix-owner")" = "$RECOVERY_RUN_ID" ] || \
            die "temporary EFI/LibertixInstaller belongs to another recovery run"
        echo "Removing temporary EFI/LibertixInstaller directory"
        run_logged rm -rf "$esp_mount/EFI/LibertixInstaller"
        sync
    fi
    [ ! -e "$esp_mount/EFI/LibertixInstaller" ] || \
        die "temporary EFI/LibertixInstaller directory still exists after cleanup"
    umount "$esp_mount"
}


cleanup_temporary_uefi_bootentries() {
    local bootnum expected_description temporary_entries

    command -v efibootmgr >/dev/null 2>&1 || \
        die "efibootmgr is required to remove the temporary UEFI entry"

    expected_description="Libertix UEFI Installer $RECOVERY_RUN_ID"
    temporary_entries="$(efibootmgr -v 2>/dev/null \
        | awk -v expected="$expected_description" '
            BEGIN {
                expected_path="file(\\efi\\libertixinstaller\\bootx64.efi)"
            }
            /^Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][* ] / {
                n=substr($1,5,4)
                gsub(/\*/, "", n)
                $1=""
                sub(/^ /, "")
                separator=substr($0, length(expected) + 1, 1)
                if (index($0, expected) == 1 && separator ~ /[[:space:]]/) {
                    if (index(tolower($0), expected_path) == 0) {
                        print "temporary UEFI entry has an unexpected loader path: Boot" n > "/dev/stderr"
                        invalid=1
                    } else {
                        print n
                    }
                }
            }
            END {
                if (invalid) exit 2
            }')" || die "cannot enumerate temporary UEFI boot entries"
    while read -r bootnum; do
        [ -n "$bootnum" ] || continue
        echo "Deleting temporary UEFI installer entry Boot$bootnum"
        efibootmgr -b "$bootnum" -B || \
            die "cannot delete temporary UEFI installer entry Boot$bootnum"
    done <<< "$temporary_entries"
    if efibootmgr -v 2>/dev/null | awk -v expected="$expected_description" '
        /^Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][* ] / {
            $1=""
            sub(/^ /, "")
            separator=substr($0, length(expected) + 1, 1)
            if (index($0, expected) == 1 && separator ~ /[[:space:]]/) found=1
        }
        END { exit(found ? 0 : 1) }
    '; then
        die "temporary UEFI installer entry remains after cleanup"
    fi

    # BootNext is one-shot and should already be consumed, but clearing it here
    # keeps a failed live boot from looping if the firmware preserved it.
    efibootmgr -N >/dev/null 2>&1 || true
}

cleanup_windows_live_boot_artifacts() {
    local bcd_part bcd_mnt

    mark "006-clean-windows-live-boot"

    # First remove the one-shot firmware/Windows boot entry. If the installer
    # fails later, the next reboot must fall back to Windows instead of looping.
    cleanup_temporary_uefi_bootentries

    bcd_part=$(find_esp_partition || true)
    [ -n "$bcd_part" ] && [ -b "$bcd_part" ] || \
        die "Windows UEFI boot partition is unavailable during BCD cleanup"
    bcd_mnt="/mnt/libertix-bcd"
    echo "Cleaning temporary UEFI BCD live boot entry from $bcd_part"
    mkdir -p "$bcd_mnt"
    mount -t vfat -o rw,flush "$bcd_part" "$bcd_mnt" || \
        die "cannot mount Windows ESP for BCD cleanup"
    [ -f "$bcd_mnt/EFI/Microsoft/Boot/BCD" ] || \
        die "Windows UEFI BCD store disappeared after mount"
    delete_live_bcd_entry_or_die "$bcd_mnt/EFI/Microsoft/Boot/BCD"
    sync
    umount "$bcd_mnt" || die "cannot unmount Windows ESP after BCD cleanup"
}
