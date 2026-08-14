#!/bin/bash

# Firmware-neutral block-device helpers shared by both live installers.
#
# Candidate enumeration and manifest identity are firmware-neutral. Firmware
# adapters keep only the partitioning and bootloader behavior that truly differs.

# Exclude small BitLocker metadata or recovery volumes when diagnosing the
# Windows system partition after a failed manifest match.
readonly MINIMUM_LIKELY_WINDOWS_PARTITION_MIB=1000

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

        # Early live boot can expose sysfs devices before lsblk reports them.
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

partition_number() {
    echo "$1" | grep -oE '[0-9]+$'
}

disk_partition_table_identity() {
    local disk="$1" style pt_uuid

    [ -b "$disk" ] || return 1
    style="$(parted -sm "$disk" print 2>/dev/null | awk -F: 'NR==2{print tolower($6)}')"
    pt_uuid="$(blkid -s PTUUID -o value "$disk" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    case "$style" in
        gpt)
            echo "$pt_uuid" | grep -Eq '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' || return 1
            printf 'gpt:%s\n' "$pt_uuid"
            ;;
        msdos)
            echo "$pt_uuid" | grep -Eq '^[0-9a-f]{8}$' || return 1
            printf 'mbr:%s\n' "$pt_uuid"
            ;;
        *) return 1 ;;
    esac
}

disk_matches_manifest() {
    local disk="$1"
    local actual_size actual_style actual_identity expected_style
    local windows_candidate boot_candidate

    actual_size="$(blockdev --getsize64 "$disk" 2>/dev/null || echo 0)"
    [ "$actual_size" = "$TARGET_DISK_SIZE_BYTES" ] || return 1
    actual_style="$(
        parted -sm "$disk" print 2>/dev/null | awk -F: 'NR==2{print tolower($6)}'
    )"
    expected_style="$(echo "$EXPECTED_PARTITION_STYLE" | tr '[:upper:]' '[:lower:]')"
    [ "$expected_style" != "mbr" ] || expected_style="msdos"
    [ "$actual_style" = "$expected_style" ] || return 1
    actual_identity="$(disk_partition_table_identity "$disk" || true)"
    [ "$actual_identity" = "$TARGET_DISK_PARTITION_TABLE_ID" ] || return 1
    windows_candidate="$(
        partition_at_offset "$disk" "$WINDOWS_PARTITION_OFFSET_BYTES" || true
    )"
    [ -n "$windows_candidate" ] || return 1
    [ "$(blkid -s TYPE -o value "$windows_candidate" 2>/dev/null || true)" = "ntfs" ] || \
        return 1
    boot_candidate="$(
        partition_at_offset "$disk" "$WINDOWS_BOOT_PARTITION_OFFSET_BYTES" || true
    )"
    [ -n "$boot_candidate" ] || return 1
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

installer_partition_target_bytes() {
    local requested_bytes="$1"
    local maximum_bytes="$2"
    local alignment_tolerance_bytes="${3:-${INSTALLER_ALIGNMENT_BYTES:-}}"
    local shortfall_bytes

    [ "$requested_bytes" -gt 0 ] 2>/dev/null || return 2
    [ "$maximum_bytes" -gt 0 ] 2>/dev/null || return 2
    [ "$alignment_tolerance_bytes" -ge 0 ] 2>/dev/null || return 2

    if [ "$maximum_bytes" -ge "$requested_bytes" ]; then
        echo "$requested_bytes"
        return 0
    fi

    # An MBR logical partition needs an aligned EBR gap inside the extended
    # partition. Windows reserves the requested allocation, but Linux may
    # expose one alignment unit less payload space before Recovery begins.
    shortfall_bytes=$((requested_bytes - maximum_bytes))
    [ "$shortfall_bytes" -le "$alignment_tolerance_bytes" ] || return 1
    echo "$maximum_bytes"
}

mbr_primary_slot_count_from_machine_output() {
    awk -F: '
        $1 ~ /^[0-9]+$/ && $1 >= 1 && $1 <= 4 {
            count++
        }
        END { print count + 0 }
    '
}

mbr_primary_slot_count() {
    local disk="$1"

    # MBR reserves numbers 1-4 for primary or extended slots; logical
    # partitions start at 5. This numeric invariant is stable even when
    # Parted's machine output omits the human-readable partition type.
    parted -sm "$disk" print 2>/dev/null | mbr_primary_slot_count_from_machine_output
}

mbr_empty_container_from_machine_output() {
    local installer_sector="$1"
    local recovery_sector="$2"

    awk -F: -v installer="$installer_sector" -v recovery="$recovery_sector" '
        $1 ~ /^[0-9]+$/ {
            number = $1 + 0
            if (number >= 5) {
                logical_partition_found = 1
            }
            if (number >= 1 && number <= 4) {
                start = $2
                end = $3
                sub(/s$/, "", start)
                sub(/s$/, "", end)
                start += 0
                end += 0
                if (start <= installer && installer <= end && end < recovery) {
                    candidate = number ":" start ":" end
                    candidate_count++
                }
            }
        }
        END {
            if (logical_partition_found) exit 2
            if (candidate_count > 1) exit 3
            if (candidate_count == 1) print candidate
        }
    '
}

mbr_owned_logical_layout_from_machine_output() {
    local installer_sector="$1"
    local recovery_sector="$2"

    awk -F: -v installer="$installer_sector" -v recovery="$recovery_sector" '
        $1 ~ /^[0-9]+$/ {
            number = $1 + 0
            start = $2
            end = $3
            sub(/s$/, "", start)
            sub(/s$/, "", end)
            start += 0
            end += 0

            if (number >= 5) {
                logical_count++
                if (start == installer && end < recovery) {
                    owned_logical_count++
                    logical_number = number
                    logical_start = start
                    logical_end = end
                }
            } else if (number >= 1 && number <= 4) {
                primary_start[number] = start
                primary_end[number] = end
            }
        }
        END {
            if (logical_count != 1 || owned_logical_count != 1) exit 2

            for (number in primary_start) {
                if (primary_start[number] < logical_start &&
                    primary_end[number] >= logical_end &&
                    primary_end[number] < recovery) {
                    container_number = number
                    container_start = primary_start[number]
                    container_end = primary_end[number]
                    container_count++
                }
            }

            if (container_count != 1) exit 3
            print logical_number ":" logical_start ":" logical_end ":" \
                container_number ":" container_start ":" container_end
        }
    '
}

normalize_mbr_partition_type() {
    tr '[:upper:]' '[:lower:]' | tr -d '[:space:]' | sed 's/^0x//; s/^0*//'
}

partitions_of_disk() {
    local disk="$1"

    lsblk -lnpo NAME,TYPE "$disk" 2>/dev/null | awk '$2=="part"{print $1}'
}

find_biggest_bitlocker_partition() {
    local disk="$1"
    local best=""
    local best_size=0
    local partition filesystem size_mib

    while read -r partition; do
        [ -n "$partition" ] || continue
        filesystem=$(blkid -s TYPE -o value "$partition" 2>/dev/null || echo "")
        echo "$filesystem" | grep -qi "bitlocker" || continue
        size_mib=$(($(blockdev --getsize64 "$partition" 2>/dev/null || echo 0) / 1024 / 1024))
        if [ "$size_mib" -gt "$MINIMUM_LIKELY_WINDOWS_PARTITION_MIB" ] \
            && [ "$size_mib" -gt "$best_size" ]; then
            best="$partition"
            best_size="$size_mib"
        fi
    done < <(partitions_of_disk "$disk")

    echo "$best"
}

partition_start_bytes() {
    local disk="$1"
    local partition="$2"
    local start_sector

    [ -b "$disk" ] || return 1
    start_sector=$(cat "/sys/class/block/$(basename "$partition")/start" 2>/dev/null) || return 1
    kernel_sector_to_bytes "$start_sector"
}

kernel_sector_to_bytes() {
    local start_sector="$1"

    [ "$start_sector" -ge 0 ] 2>/dev/null || return 2
    # Linux exports partition start offsets in fixed 512-byte sectors even on
    # 4Kn devices. Multiplying by the device logical sector size would move
    # every recorded offset by a factor of eight on those disks.
    echo "$((start_sector * 512))"
}

bytes_to_logical_sectors() {
    local bytes="$1"
    local logical_sector_size="$2"

    [ "$bytes" -ge 0 ] 2>/dev/null || return 2
    case "$logical_sector_size" in 512|4096) ;; *) return 2 ;; esac
    [ "$((bytes % logical_sector_size))" -eq 0 ] || return 1
    echo "$((bytes / logical_sector_size))"
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

manifest_partition_geometry() {
    local disk="$1"
    local expected_offset="$2"
    local partition number actual_offset size type

    partition="$(partition_at_offset "$disk" "$expected_offset" || true)"
    [ -n "$partition" ] && [ -b "$partition" ] || return 1
    number="$(partition_number "$partition")"
    actual_offset="$(partition_start_bytes "$disk" "$partition" || true)"
    size="$(blockdev --getsize64 "$partition" 2>/dev/null || echo 0)"
    type="$(lsblk -dnro PARTTYPE "$partition" 2>/dev/null || true)"
    [ "$actual_offset" = "$expected_offset" ] || return 1
    [ "$size" -gt 0 ] 2>/dev/null || return 1
    printf '%s:%s:%s:%s\n' "$number" "$actual_offset" "$size" "$type"
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
