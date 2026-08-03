#!/bin/bash

# Firmware-neutral block-device helpers shared by both live installers.
#
# The caller provides candidate_disks() and disk_matches_manifest() because
# those policies intentionally differ between the BIOS and UEFI adapters. This
# module owns only stable Linux device naming and manifest-based resolution.

safe_run() {
    "$@" || echo "WARNING: $* failed"
}

partition_path() {
    local disk="$1"
    local number="$2"

    if [[ "$(basename "$disk")" == nvme* ]] || [[ "$(basename "$disk")" == mmcblk* ]]; then
        echo "${disk}p${number}"
    else
        echo "${disk}${number}"
    fi
}

partition_number() {
    echo "$1" | grep -oE '[0-9]+$'
}

parent_disk_from_part() {
    local partition="$1"

    if [[ "$partition" == *"nvme"* ]] || [[ "$partition" == *"mmcblk"* ]]; then
        echo "$partition" | sed 's/p[0-9]*$//'
    else
        echo "$partition" | sed 's/[0-9]*$//'
    fi
}

windows_path_to_relative() {
    local path="$1"

    path="${path//\\//}"
    path="${path#?:/}"
    path="${path#/}"
    echo "$path"
}

partition_count() {
    lsblk -nr -o NAME,TYPE "$1" | awk '$2=="part"{count++}END{print count+0}'
}

partitions_of_disk() {
    local disk="$1"

    lsblk -lnpo NAME,TYPE "$disk" 2>/dev/null | awk '$2=="part"{print $1}'
}

partition_start_bytes() {
    local disk="$1"
    local partition="$2"
    local start_sector logical_sector_size

    start_sector=$(cat "/sys/class/block/$(basename "$partition")/start" 2>/dev/null) || return 1
    logical_sector_size=$(blockdev --getss "$disk" 2>/dev/null) || return 1
    echo "$((start_sector * logical_sector_size))"
}

partition_at_offset() {
    local disk="$1"
    local expected_offset="$2"
    local partition actual_offset

    while read -r partition; do
        [ -n "$partition" ] || continue
        actual_offset=$(partition_start_bytes "$disk" "$partition" || true)
        if [ "$actual_offset" = "$expected_offset" ]; then
            echo "$partition"
            return 0
        fi
    done < <(partitions_of_disk "$disk")
    return 1
}

resolve_target_disk_from_manifest() {
    local candidate
    local matches=()

    while read -r candidate; do
        [ -b "$candidate" ] || continue
        if disk_matches_manifest "$candidate"; then
            matches+=("$candidate")
        fi
    done < <(candidate_disks)

    if [ "${#matches[@]}" -ne 1 ]; then
        echo "Manifest matched ${#matches[@]} target disks; exactly one is required" >&2
        return 1
    fi
    echo "${matches[0]}"
}
