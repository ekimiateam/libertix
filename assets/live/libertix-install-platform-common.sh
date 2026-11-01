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
        grep -qE '(^|[[:space:]])toram=filesystem\.squashfs([[:space:]]|$)' \
            <<< "$kernel_cmdline" || {
            echo "LIVE_E_LOW_MEMORY_BOOT: SquashFS module copy was requested but is absent from the kernel command line"
            return 1
        }
    else
        grep -qw toram <<< "$kernel_cmdline" || {
            echo "LIVE_E_TORAM_BOOT: normal mode requires toram before reformatting the installer partition"
            return 1
        }
    fi
}

assert_live_disk_identity_or_die() {
    local disk="$1" expected_size="$2" expected_sector="$3" expected_identity="$4" expected_style="$5"
    local disk_name disk_type sector_size holders
    disk_name=$(basename "$disk")
    disk_type=$(lsblk -dnro TYPE "$disk" 2>/dev/null || true)
    [ "$disk_type" = "disk" ] || die "LIVE_E_TARGET_TYPE: target $disk is type '$disk_type', not a physical disk"
    disk_matches_recorded_identity "$disk" "$expected_size" "$expected_sector" \
        "$expected_identity" "$expected_style" || die "LIVE_E_MANIFEST_MISMATCH: disk identity changed: $disk"
    sector_size=$(blockdev --getss "$disk" 2>/dev/null || echo 0)
    case "$sector_size" in 512|4096) ;; *) die "LIVE_E_SECTOR_SIZE: unsupported logical sector size $sector_size" ;; esac
    case "$disk_name" in dm-*|md*|loop*|ram*|sr*) die "LIVE_E_STORAGE_STACK: unsupported mapped or virtual target $disk" ;; esac
    holders=$(find "/sys/class/block/$disk_name/holders" -mindepth 1 -maxdepth 1 -printf '%f ' 2>/dev/null || true)
    [ -z "$holders" ] || die "LIVE_E_STORAGE_HOLDERS: target disk has active holders: $holders"
}

assert_live_allocation_source_or_die() {
    local source_part="${ALLOCATION_SOURCE_PART:-$WINDOWS_PART}"
    local source_offset="${ALLOCATION_SOURCE_OFFSET_BYTES:-$WINDOWS_PARTITION_OFFSET_BYTES}"
    local original_size="${ALLOCATION_SOURCE_SIZE_BYTES:-$WINDOWS_PARTITION_SIZE_BYTES}"
    local current_size source_end gap
    [ -n "$source_part" ] && [ -b "$source_part" ] || die "LIVE_E_SOURCE_PARTITION: allocation source is missing"
    [ "$(parent_disk_from_part "$source_part")" = "$DISK" ] || \
        die "LIVE_E_SOURCE_PARTITION: allocation source is on a different disk"
    allocation_source_filesystem_matches_manifest "$source_part" || \
        die "LIVE_E_SOURCE_FILESYSTEM: allocation source is not the recorded decrypted NTFS volume"
    [ "$(partition_start_bytes "$DISK" "$source_part" || true)" = "$source_offset" ] || \
        die "LIVE_E_SOURCE_GEOMETRY: allocation source start changed"
    current_size="$(blockdev --getsize64 "$source_part" 2>/dev/null || echo 0)"
    [ "$current_size" -gt 0 ] && [ "$current_size" -le "$original_size" ] || \
        die "LIVE_E_SOURCE_GEOMETRY: allocation source size is outside its original extent"
    source_end=$((source_offset + current_size))
    gap=$((INSTALLER_PARTITION_OFFSET_BYTES - source_end))
    [ "$gap" -ge 0 ] && [ "$gap" -le "$INSTALLER_ALIGNMENT_BYTES" ] || \
        die "LIVE_E_SOURCE_GEOMETRY: allocation source and staging extents do not join safely"
}

run_live_preflight() {
    mark "025-live-preflight"
    [ "$(uname -m)" = "x86_64" ] || die "LIVE_E_ARCH_UNSUPPORTED: live architecture is $(uname -m)"
    local memory_kb source windows_disk="${WINDOWS_DISK:-$DISK}"
    memory_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    local minimum_memory_kb=$((LIVE_MINIMUM_MEMORY_MIB * 1024))
    [ "${memory_kb:-0}" -ge "$minimum_memory_kb" ] || die "LIVE_E_RAM_TOO_LOW: less than $LIVE_MINIMUM_MEMORY_MIB MiB is visible to the live system"
    assert_live_disk_identity_or_die "$windows_disk" "$TARGET_DISK_SIZE_BYTES" \
        "$TARGET_LOGICAL_SECTOR_SIZE_BYTES" "$TARGET_DISK_PARTITION_TABLE_ID" "$EXPECTED_PARTITION_STYLE"
    if [ "${SEPARATE_ALLOCATION_DISK:-false}" = true ]; then
        [ "$DISK" != "$windows_disk" ] || die "LIVE_E_TARGET_TYPE: allocation disk must differ from Windows"
        assert_live_disk_identity_or_die "$DISK" "$ALLOCATION_DISK_SIZE_BYTES" \
            "$ALLOCATION_DISK_SECTOR_SIZE_BYTES" "$ALLOCATION_DISK_PARTITION_TABLE_ID" "$ALLOCATION_PARTITION_STYLE"
        [ "$(blockdev --getsize64 "$WINDOWS_PART" 2>/dev/null || echo 0)" = \
            "$WINDOWS_PARTITION_SIZE_BYTES" ] || die "LIVE_E_MANIFEST_MISMATCH: Windows size changed on the unallocated disk"
    fi
    [ -n "$WINDOWS_PART" ] && [ -b "$WINDOWS_PART" ] || die "LIVE_E_WINDOWS_PARTITION: Windows partition is missing"
    [ "$(blkid -s TYPE -o value "$WINDOWS_PART" 2>/dev/null || true)" = "ntfs" ] || die "LIVE_E_WINDOWS_FILESYSTEM: Windows partition is not NTFS"
    [ -n "$LIVE_PART" ] && [ -b "$LIVE_PART" ] || die "LIVE_E_INSTALLER_PARTITION: installer partition is missing"
    assert_live_allocation_source_or_die
    source=$(findmnt -rn -S "$LIVE_PART" -o TARGET 2>/dev/null || true)
    [ -z "$source" ] || die "LIVE_E_INSTALLER_BUSY: installer partition is still mounted at $source"
    assert_recovery_unchanged_or_die
    local boot_error
    boot_error=$(validate_live_boot_mode "$LOW_MEMORY_MODE" "$(cat /proc/cmdline)") || die "$boot_error"
    echo "LIVE_PREFLIGHT_OK=true"
}
