#!/bin/bash

# UEFI-specific live-installation adapter.
#
# The main live installer owns the installation sequence. This module owns ESP
# discovery, signed bootloader installation, BootNext/BootOrder cleanup, UEFI
# rollback, and UEFI final verification. These policies intentionally remain
# outside the common orchestrator.


firmware_finalize_success_best_effort() {
    local mountpoint="/mnt/libertix-windows-success"
    local transaction_state="$mountpoint/LibertixTools/uefi-transaction.json"

    # The Windows transaction document describes the temporary FAT32 staging
    # geometry. Once final verification proves that this partition is the
    # installed ext4 system, retaining that stale geometry would falsely imply
    # that a later Windows-side rollback could still identify it safely.
    mkdir -p "$mountpoint"
    mountpoint -q "$mountpoint" && umount "$mountpoint" 2>/dev/null || true
    if ! mount -t ntfs-3g -o rw "$WINDOWS_PART" "$mountpoint" 2>/dev/null; then
        echo "WARNING: cannot mount Windows to retire the completed UEFI transaction state"
        return 0
    fi

    if [ -e "$transaction_state" ]; then
        if rm -f -- "$transaction_state"; then
            sync || true
            echo "Retired completed UEFI transaction state."
        else
            echo "WARNING: cannot retire the completed UEFI transaction state"
        fi
    fi
    umount "$mountpoint" 2>/dev/null || \
        echo "WARNING: cannot unmount Windows after retiring the UEFI transaction state"
    return 0
}


candidate_disks() {
    local disk

    {
        lsblk -dnpo NAME,TYPE 2>/dev/null \
            | awk '$2=="disk"{print $1}' \
            | while read -r disk; do
                case "$(basename "$disk")" in
                    loop*|ram*|sr*) continue ;;
                esac
                echo "$disk"
            done

        for disk in /sys/block/*; do
            [ -e "$disk" ] || continue
            disk="/dev/$(basename "$disk")"
            case "$(basename "$disk")" in
                loop*|ram*|sr*) continue ;;
            esac
            [ -b "$disk" ] || continue
            echo "$disk"
        done
    } | awk '!seen[$0]++' || true
}

write_windows_recovery_marker_best_effort() {
    local state="$1"
    local rc="${2:-0}"
    local mountpoint="/mnt/libertix-recovery-state"
    local relative marker

    [ -n "$RECOVERY_ROOT_WINDOWS" ] || return 0
    [ -n "$RECOVERY_RUN_ID" ] || return 0
    [ -n "$WINDOWS_PART" ] && [ -b "$WINDOWS_PART" ] || return 0
    case "$RECOVERY_ROOT_WINDOWS" in
        [Cc]:\\*) ;;
        *)
            echo "WARNING: refusing unexpected Windows recovery root: $RECOVERY_ROOT_WINDOWS"
            return 0
            ;;
    esac

    relative="$(windows_path_to_relative "$RECOVERY_ROOT_WINDOWS")"
    marker="$mountpoint/$relative/$state.env"
    mkdir -p "$mountpoint"
    mountpoint -q "$mountpoint" && umount "$mountpoint" 2>/dev/null || true
    if ! mount -t ntfs-3g -o rw "$WINDOWS_PART" "$mountpoint" 2>/dev/null; then
        echo "WARNING: cannot write Windows recovery marker $state"
        return 0
    fi

    mkdir -p "$(dirname "$marker")" 2>/dev/null || true
    {
        echo "LIBERTIX_UEFI_RECOVERY_RUN_ID=$RECOVERY_RUN_ID"
        echo "LIBERTIX_UEFI_RECOVERY_STATE=$state"
        echo "LIBERTIX_UEFI_RECOVERY_STAGE=$CURRENT_STAGE"
        echo "LIBERTIX_UEFI_RECOVERY_RC=$rc"
        echo "LIBERTIX_UEFI_RECOVERY_TIME=$(date -Is 2>/dev/null || date)"
    } > "$marker" 2>/dev/null || true
    sync || true
    umount "$mountpoint" 2>/dev/null || true
}

disk_matches_manifest() {
    local disk="$1" actual_size actual_style expected_style windows_candidate
    actual_size=$(blockdev --getsize64 "$disk" 2>/dev/null || echo 0)
    [ "$actual_size" = "$TARGET_DISK_SIZE_BYTES" ] || return 1
    actual_style=$(parted -sm "$disk" print 2>/dev/null | awk -F: 'NR==2{print tolower($6)}')
    expected_style=$(echo "$EXPECTED_PARTITION_STYLE" | tr '[:upper:]' '[:lower:]')
    [ "$expected_style" != "mbr" ] || expected_style="msdos"
    [ "$actual_style" = "$expected_style" ] || return 1
    windows_candidate=$(partition_at_offset "$disk" "$WINDOWS_PARTITION_OFFSET_BYTES" || true)
    [ -n "$windows_candidate" ] || return 1
    [ "$(blkid -s TYPE -o value "$windows_candidate" 2>/dev/null || true)" = "ntfs" ] || return 1
}


find_biggest_bitlocker_partition() {
    local disk="$1"
    local best=""
    local best_size=0
    local pdev pfs psize

    while read -r pdev; do
        [ -n "$pdev" ] || continue
        pfs=$(blkid -s TYPE -o value "$pdev" 2>/dev/null || echo "")
        echo "$pfs" | grep -qi "bitlocker" || continue
        psize=$(($(blockdev --getsize64 "$pdev" 2>/dev/null || echo 0) / 1024 / 1024))
        if [ "$psize" -gt 1000 ] && [ "$psize" -gt "$best_size" ]; then
            best="$pdev"
            best_size="$psize"
        fi
    done < <(partitions_of_disk "$disk")

    echo "$best"
}

find_live_partition_on_disk() {
    local disk="$1"
    local pdev label pfs psize legacy_label
    # Partitions created before the project was renamed still carry this label.
    legacy_label="LINUXGATE"

    while read -r pdev; do
        [ -n "$pdev" ] || continue
        label=$(blkid -s LABEL -o value "$pdev" 2>/dev/null || echo "")
        if [ "$label" = "LIBERTIX" ] \
            || [ "$label" = "LIBERTIX_INSTALLER" ] \
            || [ "$label" = "LIBERTIXEFI" ] \
            || [ "$label" = "$legacy_label" ]; then
            echo "$pdev"
            return 0
        fi
    done < <(partitions_of_disk "$disk")

    while read -r pdev; do
        [ -n "$pdev" ] || continue
        pfs=$(blkid -s TYPE -o value "$pdev" 2>/dev/null || echo "")
        [ "$pfs" = "vfat" ] || [ "$pfs" = "fat32" ] || continue
        psize=$(($(blockdev --getsize64 "$pdev" 2>/dev/null || echo 0) / 1024 / 1024))
        if [ "$psize" -ge 1500 ] && [ "$psize" -le 32768 ]; then
            echo "$pdev"
            return 0
        fi
    done < <(partitions_of_disk "$disk")

    return 1
}

recovery_geometry() {
    local disk="$1"
    local part_table line dev num start size end type part ptype plabel layout

    part_table="$(parted -sm "$disk" print 2>/dev/null | awk -F: 'NR==2{print $6}')"
    if [ "$part_table" = "msdos" ]; then
        parted -sm "$disk" unit s print 2>/dev/null | awk -F: '$1=="4"{print $1":"$2":"$3":"$5":"$6; exit}'
        return 0
    fi

    if command -v sfdisk >/dev/null 2>&1; then
        while IFS= read -r line; do
            case "$line" in
                "$disk"*":"*"type="*)
                    type="$(printf '%s\n' "$line" | sed -n 's/.*type=\([^, ]*\).*/\1/p' | tr '[:upper:]' '[:lower:]')"
                    [ "$type" = "de94bba4-06d1-4d40-a16a-bfd50179d6ac" ] || continue
                    dev="${line%% :*}"
                    num="$(partition_number "$dev")"
                    start="$(printf '%s\n' "$line" | sed -n 's/.*start=[[:space:]]*\([0-9]*\).*/\1/p')"
                    size="$(printf '%s\n' "$line" | sed -n 's/.*size=[[:space:]]*\([0-9]*\).*/\1/p')"
                    if [ -n "$num" ] && [ -n "$start" ] && [ -n "$size" ]; then
                        end="$((start + size - 1))"
                        echo "$num:${start}s:${end}s:${size}s:$type"
                        return 0
                    fi
                    ;;
            esac
        done < <(sfdisk -d "$disk" 2>/dev/null || true)
    fi

    while read -r part; do
        [ -n "$part" ] || continue
        ptype="$(lsblk -dnro PARTTYPE "$part" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
        plabel="$(lsblk -dnro PARTLABEL "$part" 2>/dev/null || true)"
        if [ "$ptype" = "de94bba4-06d1-4d40-a16a-bfd50179d6ac" ] || echo "$plabel" | grep -qi "recovery"; then
            num="$(partition_number "$part")"
            layout="$(parted -sm "$disk" unit s print 2>/dev/null | awk -F: -v n="$num" '$1==n{print $1":"$2":"$3":"$4; exit}')"
            [ -n "$layout" ] && echo "$layout:$ptype"
            return 0
        fi
    done < <(partitions_of_disk "$disk")
}



verify_fstab_or_die() {
    local target_root="$1" output rc
    local target_dev="$target_root/dev"

    [ -f "$target_root/etc/fstab" ] || die "final verify: target fstab missing"
    [ -d "$target_dev" ] || die "final verify: target /dev directory missing"

    # findmnt resolves mount targets from /. Run it in the installed system;
    # otherwise /boot/efi is incorrectly checked against the live environment.
    mount --rbind /dev "$target_dev" || die "final verify: unable to bind /dev for fstab validation"
    mount --make-rslave "$target_dev" || {
        umount -R "$target_dev" 2>/dev/null || true
        die "final verify: unable to isolate target /dev bind"
    }

    if output=$(chroot "$target_root" findmnt --verify --verbose --tab-file /etc/fstab 2>&1); then
        rc=0
    else
        rc=$?
    fi
    umount -R "$target_dev" || die "final verify: unable to unmount target /dev bind"

    printf '%s\n' "$output"
    [ "$rc" -eq 0 ] && return 0
    if printf '%s\n' "$output" | grep -Eq '(^|[[:space:]])0 parse errors, 0 errors,'; then
        echo "FINAL VERIFY: fstab has non-fatal compatibility warnings only"
        return 0
    fi
    die "final verify: fstab is invalid"
}

final_verify_or_die() {
    local target_verify="/mnt/libertix-final-verify"
    local windows_verify="/mnt/libertix-windows-final-verify"
    local fs uuid primary_slot_count part_table esp_part esp_verify

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

    mkdir -p "$target_verify"
    mount -o ro "$NEW_PART" "$target_verify"
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
    esp_verify="/mnt/libertix-esp-final-verify"
    mkdir -p "$esp_verify"
    mount -t vfat -o ro "$esp_part" "$esp_verify"
    [ -f "$esp_verify/EFI/Libertix/shimx64.efi" ] || die "final verify: Libertix shim missing"
    [ -f "$esp_verify/EFI/Libertix/grubx64.efi" ] || die "final verify: Libertix signed GRUB missing"
    [ -f "$esp_verify/EFI/Libertix/grub.cfg" ] || die "final verify: Libertix EFI grub.cfg missing"
    [ ! -e "$esp_verify/EFI/LibertixInstaller" ] || \
        die "final verify: temporary EFI/LibertixInstaller directory was not removed"
    umount "$esp_verify"

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
    cleanup_final_uefi_bootloader_best_effort || true
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

    candidate="$(partition_at_offset "$DISK" "$INSTALLER_PARTITION_OFFSET_BYTES" || true)"
    if [ -n "$candidate" ]; then
        NEW_PART="$candidate"
        NEW_PART_NUM="$(partition_number "$candidate")"
        echo "ROLLBACK: resolved transaction partition as $NEW_PART"
    fi
}

firmware_rollback_partition_is_owned() {
    local partition="$1"

    [ "$partition" != "$WINDOWS_PART" ] \
        && [ "$(parent_disk_from_part "$partition")" = "$DISK" ]
}

firmware_cleanup_partition_container_best_effort() {
    return 0
}

firmware_restore_boot_state_best_effort() {
    # On GPT, parted's "boot" flag is the ESP flag. Resolve the real ESP instead
    # of assuming partition 1, otherwise a rollback marks the wrong partition.
    local esp_part esp_num
    esp_part="$(find_esp_partition || true)"
    [ -n "$esp_part" ] && [ -b "$esp_part" ] || return 0
    [ "$(parent_disk_from_part "$esp_part")" = "$DISK" ] || return 0
    esp_num="$(partition_number "$esp_part")"
    [ -n "$esp_num" ] || return 0
    parted -s "$DISK" set "$esp_num" esp on 2>/dev/null || true
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
                [ "$(blkid -s LABEL -o value "$label_device" 2>/dev/null || true)" = "LIBERTIXEFI" ] && {
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

find_ntfs_partition_with_file() {
    local relative_path="$1"
    local candidate pdev pfs tmp

    while read -r candidate; do
        [ -n "$candidate" ] || continue
        [ -b "$candidate" ] || continue
        while read -r pdev; do
            [ -n "$pdev" ] || continue
            pfs=$(blkid -s TYPE -o value "$pdev" 2>/dev/null || echo "")
            [ "$pfs" = "ntfs" ] || continue

            tmp=$(mktemp -d)
            if mount -t ntfs-3g -o ro "$pdev" "$tmp" 2>/dev/null; then
                if [ -f "$tmp/$relative_path" ]; then
                    umount "$tmp"
                    rmdir "$tmp"
                    echo "$pdev"
                    return 0
                fi
                umount "$tmp" 2>/dev/null || true
            fi
            rmdir "$tmp" 2>/dev/null || true
        done < <(partitions_of_disk "$candidate")
    done < <(candidate_disks)
    return 1
}

find_fat_partition_with_file() {
    local relative_path="$1"
    local candidate pdev pfs tmp

    while read -r candidate; do
        [ -n "$candidate" ] || continue
        [ -b "$candidate" ] || continue
        while read -r pdev; do
            [ -n "$pdev" ] || continue
            pfs=$(blkid -s TYPE -o value "$pdev" 2>/dev/null || echo "")
            case "$pfs" in
                vfat|fat|msdos) ;;
                *) continue ;;
            esac

            tmp=$(mktemp -d)
            if mount -t vfat -o ro "$pdev" "$tmp" 2>/dev/null; then
                if [ -f "$tmp/$relative_path" ]; then
                    umount "$tmp"
                    rmdir "$tmp"
                    echo "$pdev"
                    return 0
                fi
                umount "$tmp" 2>/dev/null || true
            fi
            rmdir "$tmp" 2>/dev/null || true
        done < <(partitions_of_disk "$candidate")
    done < <(candidate_disks)
    return 1
}

find_esp_partition() {
    find_fat_partition_with_file "EFI/Microsoft/Boot/bootmgfw.efi"
}

cleanup_final_uefi_bootloader_best_effort() {
    local bootnum esp_part esp_mount

    [ "$INSTALL_SUCCESS" = false ] || return 0

    if command -v efibootmgr >/dev/null 2>&1; then
        efibootmgr 2>/dev/null \
            | awk '/^Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][* ] Libertix[[:space:]]/ {
                n=substr($1,5,4)
                gsub(/\*/, "", n)
                print n
            }' \
            | while read -r bootnum; do
                [ -n "$bootnum" ] || continue
                echo "ROLLBACK: deleting final UEFI entry Boot$bootnum"
                efibootmgr -b "$bootnum" -B || \
                    echo "ROLLBACK: warning: cannot delete final UEFI entry Boot$bootnum"
            done
    fi

    esp_part="$(find_esp_partition || true)"
    [ -n "$esp_part" ] && [ -b "$esp_part" ] || return 0

    esp_mount="/mnt/libertix-rollback-esp"
    mkdir -p "$esp_mount"
    if mount -t vfat -o rw,flush "$esp_part" "$esp_mount"; then
        if [ -d "$esp_mount/EFI/Libertix" ]; then
            echo "ROLLBACK: removing EFI/Libertix from ESP"
            rm -rf "$esp_mount/EFI/Libertix"
            sync || true
        fi
        umount "$esp_mount" 2>/dev/null || true
    else
        echo "ROLLBACK: warning: cannot mount ESP to remove EFI/Libertix"
    fi
}

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
        run_logged sfdisk --part-label "$DISK" "$NEW_PART_NUM" "LinuxMint" || \
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

copy_first_existing_file_or_die() {
    local dest="$1"
    shift
    local candidate

    for candidate in "$@"; do
        if [ -f "$candidate" ]; then
            install -m 0644 "$candidate" "$dest"
            return 0
        fi
    done

    die "missing signed EFI file for $dest"
}

set_libertix_bootentry_first_or_die() {
    local bootnum current_order rest new_order tab

    tab="$(printf '\t')"
    bootnum="$(
        efibootmgr 2>/dev/null | while IFS= read -r line; do
            case "$line" in
                Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]"* Libertix${tab}"*)
                    printf '%s\n' "${line#Boot}" | cut -c1-4
                    break
                    ;;
            esac
        done
    )"

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
    return 0
}

install_signed_uefi_bootloader_or_die() {
    local esp_part esp_num esp_mount efi_dir root_uuid loader_path

    esp_part="$(find_esp_partition || true)"
    [ -n "$esp_part" ] && [ -b "$esp_part" ] || die "UEFI ESP not found"

    esp_num="$(partition_number "$esp_part")"
    root_uuid="$(blkid -s UUID -o value "$NEW_PART" 2>/dev/null || true)"
    [ -n "$root_uuid" ] || die "Linux root UUID missing before EFI install"

    esp_mount="/mnt/target/boot/efi"
    mkdir -p "$esp_mount"
    mountpoint -q "$esp_mount" || run_logged mount -t vfat "$esp_part" "$esp_mount"

    efi_dir="$esp_mount/EFI/Libertix"
    mkdir -p "$efi_dir"

    # Prefer the installed Mint/Ubuntu Secure Boot chain. The Debian live shim
    # can boot the installer, but it does not trust Mint's installed kernel.
    copy_first_existing_file_or_die "$efi_dir/shimx64.efi" \
        /mnt/target/usr/lib/shim/shimx64.efi.dualsigned \
        /mnt/target/usr/lib/shim/shimx64.efi.signed.latest \
        /mnt/target/usr/lib/shim/shimx64.efi.signed \
        /mnt/target/usr/lib/shim/shimx64.efi
    copy_first_existing_file_or_die "$efi_dir/grubx64.efi" \
        /mnt/target/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed \
        /mnt/target/usr/lib/grub/x86_64-efi-signed/grubx64.efi
    copy_first_existing_file_or_die "$efi_dir/mmx64.efi" \
        /mnt/target/usr/lib/shim/mmx64.efi.signed.latest \
        /mnt/target/usr/lib/shim/mmx64.efi.signed \
        /mnt/target/usr/lib/shim/mmx64.efi

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

    loader_path='\EFI\Libertix\shimx64.efi'
    if ! set_libertix_bootentry_first_or_die; then
        run_logged efibootmgr -c -d "$DISK" -p "$esp_num" -L "Libertix" -l "$loader_path"
        set_libertix_bootentry_first_or_die || die "failed to put Libertix first in UEFI BootOrder"
    fi

    # Windows stages this directory only to enter the live installer. Leaving
    # it on the ESP after success creates a second, stale boot surface.
    if [ -e "$esp_mount/EFI/LibertixInstaller" ]; then
        echo "Removing temporary EFI/LibertixInstaller directory"
        run_logged rm -rf "$esp_mount/EFI/LibertixInstaller"
        sync
    fi
    [ ! -e "$esp_mount/EFI/LibertixInstaller" ] || \
        die "temporary EFI/LibertixInstaller directory still exists after cleanup"
    umount "$esp_mount"
}


cleanup_temporary_uefi_bootentries() {
    local bootnum

    command -v efibootmgr >/dev/null 2>&1 || return 0

    efibootmgr 2>/dev/null \
        | awk '/^Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][* ] Libertix UEFI Installer/ {
            n=substr($1,5,4)
            gsub(/\*/, "", n)
            print n
        }' \
        | while read -r bootnum; do
            [ -n "$bootnum" ] || continue
            echo "Deleting temporary UEFI installer entry Boot$bootnum"
            efibootmgr -b "$bootnum" -B || \
                echo "WARNING: cannot delete temporary UEFI installer entry Boot$bootnum"
        done

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

    bcd_part=$(find_fat_partition_with_file "EFI/Microsoft/Boot/BCD" || true)
    if [ -n "$bcd_part" ]; then
        bcd_mnt="/mnt/libertix-bcd"
        echo "Cleaning temporary UEFI BCD live boot entry from $bcd_part"
        mkdir -p "$bcd_mnt"
        if mount -t vfat -o rw,flush "$bcd_part" "$bcd_mnt"; then
            if [ -f "$bcd_mnt/EFI/Microsoft/Boot/BCD" ]; then
                delete_live_bcd_entry_or_die "$bcd_mnt/EFI/Microsoft/Boot/BCD" || \
                    echo "WARNING: UEFI BCD cleanup failed; continuing because bootsequence is one-shot"
                sync
            else
                echo "WARNING: Windows UEFI BCD store disappeared after mount; continuing"
            fi
            umount "$bcd_mnt" 2>/dev/null || true
        else
            echo "WARNING: cannot mount Windows ESP for BCD cleanup; continuing"
        fi
    else
        echo "WARNING: Windows UEFI BCD store not found; continuing"
    fi
}
