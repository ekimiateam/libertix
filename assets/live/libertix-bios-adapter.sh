#!/bin/bash

# BIOS-specific live-installation adapter.
#
# The main live installer owns the installation sequence. This module owns the
# MBR/GRUB4DOS policy, BIOS rollback, BIOS final verification, and the legacy
# partition-layout rules that must not leak into the common orchestrator.


candidate_disks() {
    lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}' | while read -r disk; do
        case "$(basename "$disk")" in
            loop*|ram*|sr*) continue ;;
        esac
        echo "$disk"
    done
}

disk_matches_manifest() {
    local disk="$1" actual_size actual_style expected_style windows_candidate boot_candidate
    actual_size=$(blockdev --getsize64 "$disk" 2>/dev/null || echo 0)
    [ "$actual_size" = "$TARGET_DISK_SIZE_BYTES" ] || return 1
    actual_style=$(parted -sm "$disk" print 2>/dev/null | awk -F: 'NR==2{print tolower($6)}')
    expected_style=$(echo "$EXPECTED_PARTITION_STYLE" | tr '[:upper:]' '[:lower:]')
    [ "$expected_style" != "mbr" ] || expected_style="msdos"
    [ "$actual_style" = "$expected_style" ] || return 1
    windows_candidate=$(partition_at_offset "$disk" "$WINDOWS_PARTITION_OFFSET_BYTES" || true)
    [ -n "$windows_candidate" ] || return 1
    [ "$(blkid -s TYPE -o value "$windows_candidate" 2>/dev/null || true)" = "ntfs" ] || return 1
    boot_candidate=$(partition_at_offset "$disk" "$WINDOWS_BOOT_PARTITION_OFFSET_BYTES" || true)
    [ -n "$boot_candidate" ] || return 1
}

find_biggest_windows_partition() {
    local disk="$1"
    local best=""
    local best_size=0
    local pn pdev pfs psize
    for pn in 1 2 3 4 5; do
        pdev=$(partition_path "$disk" "$pn")
        [ -b "$pdev" ] || continue
        pfs=$(blkid -s TYPE -o value "$pdev" 2>/dev/null || echo "")
        [ "$pfs" = "ntfs" ] || continue
        psize=$(($(blockdev --getsize64 "$pdev" 2>/dev/null || echo 0) / 1024 / 1024))
        if [ "$psize" -gt 1000 ] && [ "$psize" -gt "$best_size" ]; then
            best="$pdev"
            best_size="$psize"
        fi
    done
    echo "$best"
}

find_live_partition_on_disk() {
    local disk="$1"
    local pn pdev label pfs psize legacy_label
    legacy_label="$(printf '%s%s' 'LINUX' 'GATE')"
    for pn in 1 2 3 4 5; do
        pdev=$(partition_path "$disk" "$pn")
        [ -b "$pdev" ] || continue
        label=$(blkid -s LABEL -o value "$pdev" 2>/dev/null || echo "")
        if [ "$label" = "LIBERTIX" ] || [ "$label" = "LIBERTIX_INSTALLER" ] || [ "$label" = "$legacy_label" ]; then
            echo "$pdev"
            return 0
        fi
    done
    for pn in 1 2 3 4 5; do
        pdev=$(partition_path "$disk" "$pn")
        [ -b "$pdev" ] || continue
        pfs=$(blkid -s TYPE -o value "$pdev" 2>/dev/null || echo "")
        [ "$pfs" = "vfat" ] || [ "$pfs" = "fat32" ] || continue
        psize=$(($(blockdev --getsize64 "$pdev" 2>/dev/null || echo 0) / 1024 / 1024))
        if [ "$psize" -ge 1500 ] && [ "$psize" -le 3072 ]; then
            echo "$pdev"
            return 0
        fi
    done
    return 1
}

recovery_geometry() {
    local disk="$1"
    parted -sm "$disk" unit s print 2>/dev/null | awk -F: '$1=="4"{print $1":"$2":"$3":"$5":"$6; exit}'
}

write_target_fstab_or_die() {
    local root_uuid

    root_uuid=$(blkid -s UUID -o value "$NEW_PART" 2>/dev/null || true)
    [ -n "$root_uuid" ] || die "root UUID missing before fstab write"
    echo "UUID=$root_uuid / ext4 defaults 0 1" > /mnt/target/etc/fstab
}

verify_fstab_or_die() {
    local target_root="$1" output rc
    local target_dev="$target_root/dev"

    [ -f "$target_root/etc/fstab" ] || die "final verify: target fstab missing"
    [ -d "$target_dev" ] || die "final verify: target /dev directory missing"

    # findmnt resolves mount targets from /. Run it in the installed system;
    # otherwise target paths are incorrectly checked against the live system.
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

final_verify_or_die() {
    local target_verify="/mnt/libertix-final-verify"
    local windows_verify="/mnt/libertix-windows-final-verify"
    local fs uuid count windows_boot_part_num

    mark "150-final-verify"
    echo "FINAL VERIFY: checking installed system before success"

    [ -n "$DISK" ] && [ -b "$DISK" ] || die "final verify: target disk missing"
    [ -n "$NEW_PART" ] && [ -b "$NEW_PART" ] || die "final verify: Linux partition missing"
    [ -n "$WINDOWS_PART" ] && [ -b "$WINDOWS_PART" ] || die "final verify: Windows partition missing"
    [ -n "$WINDOWS_BOOT_PART" ] && [ -b "$WINDOWS_BOOT_PART" ] || \
        die "final verify: Windows boot partition missing"

    assert_recovery_unchanged_or_die

    count="$(partition_count "$DISK")"
    [ "$count" -le 4 ] || die "final verify: MBR partition count is $count"

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

    mkdir -p "$target_verify"
    mount -o ro "$NEW_PART" "$target_verify"
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
    candidate="$(partition_at_offset "$DISK" "$INSTALLER_PARTITION_OFFSET_BYTES" || true)"
    if [ -n "$candidate" ]; then
        NEW_PART="$candidate"
        NEW_PART_NUM="$(partition_number "$candidate")"
        echo "ROLLBACK: resolved transaction partition as $NEW_PART"
    fi
}

firmware_rollback_partition_is_owned() {
    local partition="$1"

    [ "$(parent_disk_from_part "$partition")" = "$DISK" ] \
        && [ "$(partition_start_bytes "$DISK" "$partition" || true)" = "$INSTALLER_PARTITION_OFFSET_BYTES" ]
}

firmware_restore_boot_state_best_effort() {
    local windows_boot_partition windows_boot_number

    windows_boot_partition=$(partition_at_offset "$DISK" "$WINDOWS_BOOT_PARTITION_OFFSET_BYTES" || true)
    if [ -z "$windows_boot_partition" ] || [ ! -b "$windows_boot_partition" ]; then
        echo "ROLLBACK: Windows boot partition could not be resolved from the manifest"
        return 1
    fi

    windows_boot_number=$(partition_number "$windows_boot_partition")
    parted -s "$DISK" set "$windows_boot_number" boot on 2>/dev/null || true
}

firmware_write_failure_marker_best_effort() {
    return 0
}




wait_for_prereqs() {
    mark "005-wait-prereqs"
    local i label_device
    for i in $(seq 1 60); do
        local disk_ready=0
        local config_ready=0
        local candidate found_config

        for candidate in /dev/sd? /dev/nvme?n? /dev/mmcblk?; do
            [ -b "$candidate" ] && { disk_ready=1; break; }
        done

        for candidate in \
            /run/live/medium/config.txt \
            /lib/live/mount/medium/config.txt \
            /lib/live/mount/rootfs/filesystem.squashfs/config.txt \
            /cdrom/config.txt; do
            [ -f "$candidate" ] && { config_ready=1; break; }
        done

        if [ "$config_ready" -eq 0 ]; then
            found_config=$(find /run/live /lib/live /cdrom -maxdepth 6 -iname config.txt -print -quit 2>/dev/null || true)
            [ -n "$found_config" ] && config_ready=1
        fi

        if [ "$config_ready" -eq 0 ]; then
            while read -r label_device; do
                [ -n "$label_device" ] || continue
                case "$(blkid -s LABEL -o value "$label_device" 2>/dev/null || true)" in
                    LIBERTIX|LIBERTIX_INSTALLER) config_ready=1; break ;;
                esac
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
    local candidate pn pdev pfs tmp

    for candidate in /dev/sd? /dev/nvme?n? /dev/mmcblk?; do
        [ -b "$candidate" ] || continue
        for pn in 1 2 3 4 5; do
            pdev=$(partition_path "$candidate" "$pn")
            [ -b "$pdev" ] || continue
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
        done
    done
    return 1
}

find_windows_os_partition_any() {
    local best=""
    local best_size=0
    local candidate pn pdev pfs psize tmp

    for candidate in /dev/sd? /dev/nvme?n? /dev/mmcblk?; do
        [ -b "$candidate" ] || continue
        for pn in 1 2 3 4 5; do
            pdev=$(partition_path "$candidate" "$pn")
            [ -b "$pdev" ] || continue
            pfs=$(blkid -s TYPE -o value "$pdev" 2>/dev/null || echo "")
            [ "$pfs" = "ntfs" ] || continue
            psize=$(($(blockdev --getsize64 "$pdev" 2>/dev/null || echo 0) / 1024 / 1024))
            [ "$psize" -gt 1000 ] || continue

            tmp=$(mktemp -d)
            if mount -t ntfs-3g -o ro "$pdev" "$tmp" 2>/dev/null; then
                if [ -d "$tmp/Windows" ] && [ "$psize" -gt "$best_size" ]; then
                    best="$pdev"
                    best_size="$psize"
                fi
                umount "$tmp" 2>/dev/null || true
            fi
            rmdir "$tmp" 2>/dev/null || true
        done
    done

    echo "$best"
}

cleanup_windows_live_boot_artifacts() {
    local bcd_part windows_part bcd_mnt windows_mnt

    mark "006-clean-windows-live-boot"

    # First remove the one-shot Windows Boot Manager entry. If the installer
    # fails later, the next reboot must fall back to Windows instead of looping.
    bcd_part=$(find_ntfs_partition_with_file "Boot/BCD" || true)
    [ -n "$bcd_part" ] || die "Windows BCD store not found"

    bcd_mnt="/mnt/libertix-bcd"
    echo "Cleaning temporary BCD live boot entry from $bcd_part"
    mount_ntfs_rw_or_die "$bcd_part" "$bcd_mnt"
    [ -f "$bcd_mnt/Boot/BCD" ] || die "Windows BCD store disappeared after mount"
    delete_live_bcd_entry_or_die "$bcd_mnt/Boot/BCD"
    sync
    umount "$bcd_mnt"

    # Then remove the GRUB4DOS files that Windows used only to start this live
    # installer. The final Linux bootloader is installed later by grub-install.
    if grep -q 'findiso=/libertix-live.iso' /proc/cmdline; then
        echo "Low-memory mode: deferring GRUB4DOS file cleanup until Windows starts."
        return 0
    fi
    windows_part=$(find_windows_os_partition_any || true)
    [ -n "$windows_part" ] || die "Windows OS partition not found"

    windows_mnt="/mnt/libertix-windows-cleanup"
    echo "Removing temporary GRUB4DOS files from $windows_part"
    mount_ntfs_rw_or_die "$windows_part" "$windows_mnt"
    rm -f "$windows_mnt/grldr" "$windows_mnt/grldr.mbr" "$windows_mnt/menu.lst"
    sync
    umount "$windows_mnt"
}
