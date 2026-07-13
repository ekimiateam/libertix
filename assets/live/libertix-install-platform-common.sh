#!/bin/bash

detect_grub_resolution() {
    local resolution="" mode_file
    if command -v xrandr >/dev/null 2>&1; then
        resolution="$(DISPLAY=:0 xrandr --current 2>/dev/null |
            awk '/\*/ {print $1; exit}' || true)"
    fi
    if [[ ! "$resolution" =~ ^[0-9]+x[0-9]+$ ]] && [ -r /sys/class/graphics/fb0/virtual_size ]; then
        resolution="$(tr ',' 'x' < /sys/class/graphics/fb0/virtual_size)"
    fi
    if [[ ! "$resolution" =~ ^[0-9]+x[0-9]+$ ]]; then
        for mode_file in /sys/class/drm/card*-*/modes; do
            [ -r "$mode_file" ] || continue
            resolution="$(head -n 1 "$mode_file")"
            [[ "$resolution" =~ ^[0-9]+x[0-9]+$ ]] && break
        done
    fi
    [[ "$resolution" =~ ^[0-9]+x[0-9]+$ ]] || resolution="1024x768"

    local width="${resolution%x*}" height="${resolution#*x}"
    if [ "$width" -lt 640 ] || [ "$height" -lt 480 ] ||
        [ "$width" -gt 7680 ] || [ "$height" -gt 4320 ]; then
        resolution="1024x768"
    fi
    printf '%s\n' "$resolution"
}

validate_live_boot_mode() {
    local low_memory_mode="$1" kernel_cmdline="$2"

    if [ "$low_memory_mode" = "true" ]; then
        grep -q 'findiso=/libertix-live.iso' <<< "$kernel_cmdline" || {
            echo "LIVE_E_LOW_MEMORY_BOOT: findiso mode was requested but is absent from the kernel command line"
            return 1
        }
    else
        grep -qw toram <<< "$kernel_cmdline" || {
            echo "LIVE_E_TORAM_BOOT: normal mode requires toram before reformatting the installer partition"
            return 1
        }
    fi
}

run_live_preflight() {
    mark "025-live-preflight"
    [ "$(uname -m)" = "x86_64" ] || die "LIVE_E_ARCH_UNSUPPORTED: live architecture is $(uname -m)"
    local memory_kb disk_name disk_type disk_size sector_size holders source
    memory_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    [ "${memory_kb:-0}" -ge 1572864 ] || die "LIVE_E_RAM_TOO_LOW: less than 1536 MiB is visible to the live system"
    disk_name=$(basename "$DISK")
    disk_type=$(lsblk -dnro TYPE "$DISK" 2>/dev/null || true)
    [ "$disk_type" = "disk" ] || die "LIVE_E_TARGET_TYPE: target $DISK is type '$disk_type', not a physical disk"
    disk_size=$(blockdev --getsize64 "$DISK" 2>/dev/null || echo 0)
    [ "$disk_size" = "$TARGET_DISK_SIZE_BYTES" ] || die "LIVE_E_MANIFEST_MISMATCH: disk size changed"
    sector_size=$(blockdev --getss "$DISK" 2>/dev/null || echo 0)
    case "$sector_size" in 512|4096) ;; *) die "LIVE_E_SECTOR_SIZE: unsupported logical sector size $sector_size" ;; esac
    case "$disk_name" in dm-*|md*|loop*|ram*|sr*) die "LIVE_E_STORAGE_STACK: unsupported mapped or virtual target $DISK" ;; esac
    holders=$(find "/sys/class/block/$disk_name/holders" -mindepth 1 -maxdepth 1 -printf '%f ' 2>/dev/null || true)
    [ -z "$holders" ] || die "LIVE_E_STORAGE_HOLDERS: target disk has active holders: $holders"
    [ -n "$WINDOWS_PART" ] && [ -b "$WINDOWS_PART" ] || die "LIVE_E_WINDOWS_PARTITION: Windows partition is missing"
    [ "$(blkid -s TYPE -o value "$WINDOWS_PART" 2>/dev/null || true)" = "ntfs" ] || die "LIVE_E_WINDOWS_FILESYSTEM: Windows partition is not NTFS"
    [ -n "$LIVE_PART" ] && [ -b "$LIVE_PART" ] || die "LIVE_E_INSTALLER_PARTITION: installer partition is missing"
    source=$(findmnt -rn -S "$LIVE_PART" -o TARGET 2>/dev/null || true)
    [ -z "$source" ] || die "LIVE_E_INSTALLER_BUSY: installer partition is still mounted at $source"
    assert_recovery_unchanged_or_die
    local boot_error
    boot_error=$(validate_live_boot_mode "$LOW_MEMORY_MODE" "$(cat /proc/cmdline)") || die "$boot_error"
    echo "LIVE_PREFLIGHT_OK=true"
}
