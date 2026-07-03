#!/bin/bash
set -Eeuo pipefail

[ "$EUID" -ne 0 ] && { echo "Run as root"; exit 1; }

LOG_DIR="/run/libertix"
STAGE_FILE="$LOG_DIR/stage"
FAIL_FILE="$LOG_DIR/failure"
mkdir -p "$LOG_DIR"

CURRENT_STAGE="bootstrap"
DISK=""
LIVE_PART=""
echo "$CURRENT_STAGE" > "$STAGE_FILE"

mark() {
    CURRENT_STAGE="$1"
    echo "$CURRENT_STAGE" > "$STAGE_FILE"
    echo "STAGE: $CURRENT_STAGE"
    echo "LIBERTIX STAGE: $CURRENT_STAGE" > /dev/kmsg 2>/dev/null || true
    touch "$LOG_DIR/${CURRENT_STAGE}.started" 2>/dev/null || true
}

die() {
    local msg="$*"
    echo "ERROR: stage=$CURRENT_STAGE: $msg"
    {
        echo "stage=$CURRENT_STAGE"
        echo "error=$msg"
        echo "time=$(date -Is 2>/dev/null || date)"
    } > "$FAIL_FILE"
    exit 1
}

on_err() {
    local rc="$?"
    local line="${BASH_LINENO[0]:-unknown}"
    local cmd="${BASH_COMMAND:-unknown}"
    echo "ERROR: stage=$CURRENT_STAGE rc=$rc line=$line cmd=$cmd"
    {
        echo "stage=$CURRENT_STAGE"
        echo "rc=$rc"
        echo "line=$line"
        echo "cmd=$cmd"
        echo "time=$(date -Is 2>/dev/null || date)"
    } > "$FAIL_FILE"
    exit "$rc"
}
trap on_err ERR

safe_run() { "$@" || echo "WARNING: $* failed"; }

partition_path() {
    local disk="$1"
    local num="$2"
    if [[ "$(basename "$disk")" == nvme* ]] || [[ "$(basename "$disk")" == mmcblk* ]]; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

partition_number() {
    echo "$1" | grep -oE '[0-9]+$'
}

parent_disk_from_part() {
    local part="$1"
    if [[ "$part" == *"nvme"* ]] || [[ "$part" == *"mmcblk"* ]]; then
        echo "$part" | sed 's/p[0-9]*$//'
    else
        echo "$part" | sed 's/[0-9]*$//'
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
    lsblk -nr -o NAME,TYPE "$1" | awk '$2=="part"{c++}END{print c+0}'
}

print_disk_state() {
    echo "--- Disk state: $1 ---"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT "$DISK" || true
    parted -s "$DISK" unit MiB print free || true
    echo "Mounted from live partition:"
    findmnt -rn -S "$LIVE_PART" || true
}

debug_partition_users() {
    local part="$1"
    local base mm holder
    base=$(basename "$part")
    mm=$(lsblk -dnro MAJ:MIN "$part" 2>/dev/null || true)

    echo "=== DEBUG users for $part ==="
    echo "--- findmnt source ---"
    findmnt -rn -S "$part" -o SOURCE,TARGET,FSTYPE,OPTIONS 2>/dev/null || true
    echo "--- /proc/*/mountinfo matching MAJ:MIN=$mm ---"
    if [ -n "$mm" ]; then
        awk -v mm="$mm" '$3 == mm { print FILENAME ":" $0 }' /proc/[0-9]*/mountinfo 2>/dev/null || true
    fi
    echo "--- fuser ---"
    fuser -vm "$part" 2>&1 || true
    echo "--- lsof ---"
    lsof "$part" 2>/dev/null || true
    echo "--- holders ---"
    if [ -d "/sys/class/block/$base/holders" ]; then
        ls -la "/sys/class/block/$base/holders" || true
        for holder in /sys/class/block/"$base"/holders/*; do
            [ -e "$holder" ] && echo "holder: $(basename "$holder")"
        done
    fi
    echo "--- inflight ---"
    cat "/sys/class/block/$base/inflight" 2>/dev/null || true
}

debug_disk_state() {
    echo "=== DEBUG disk state: $DISK ==="
    echo "--- /proc/cmdline ---"
    cat /proc/cmdline || true
    echo "--- lsblk full ---"
    lsblk -e7 -o NAME,MAJ:MIN,PKNAME,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS "$DISK" || true
    echo "--- parted sectors ---"
    parted -s "$DISK" unit s print free || true
    echo "--- /proc/partitions ---"
    cat /proc/partitions || true
    echo "--- findmnt ---"
    findmnt -rn -o SOURCE,TARGET,FSTYPE,OPTIONS || true
    echo "--- swaps ---"
    cat /proc/swaps || true
    echo "--- loop devices ---"
    losetup -a 2>/dev/null || true
    echo "--- dmsetup tree ---"
    dmsetup ls --tree 2>/dev/null || true
    echo "--- relevant processes ---"
    ps -ef | grep -E 'ntfs-3g|udisks|gvfs|blkid|parted|partprobe|mount|loop|systemd-udevd' | grep -v grep || true
    echo "--- dmesg tail ---"
    dmesg | tail -20 || true
}

run_logged() {
    echo "+ $*"
    set +e
    "$@"
    local rc=$?
    set -e
    echo "rc=$rc: $*"
    return "$rc"
}

unmount_target_disk_partitions() {
    echo "Unmounting mounted partitions from target disk $DISK..."
    local src target parent

    cd /
    while read -r src target; do
        [ -n "$src" ] && [ -n "$target" ] || continue
        [ -b "$src" ] || continue
        parent=$(parent_disk_from_part "$src")
        [ "$parent" = "$DISK" ] || continue
        echo "Unmounting $src from $target"
        if ! umount "$target"; then
            echo "ERROR: strict umount failed for $src at $target"
            debug_partition_users "$src"
            debug_disk_state
            die "strict umount failed for $src at $target"
        fi
    done < <(findmnt -rn -o SOURCE,TARGET | sort -r -k2)

    sync
}

assert_no_target_disk_mounts() {
    if findmnt -rn -o SOURCE,TARGET | awk -v disk="$(basename "$DISK")" '
        $1 ~ "^/dev/" disk "[0-9]+$" || $1 ~ "^/dev/" disk "p[0-9]+$" { found=1 }
        END { exit !found }
    '; then
        echo "ERROR: target disk still has mounted partitions:"
        findmnt -rn -o SOURCE,TARGET | awk -v disk="$(basename "$DISK")" '
            $1 ~ "^/dev/" disk "[0-9]+$" || $1 ~ "^/dev/" disk "p[0-9]+$" { print }
        '
        print_disk_state "mounted target partitions block reread"
        exit 1
    fi
}

assert_not_mounted_or_open() {
    local part="$1"
    [ -b "$part" ] || die "partition not found: $part"

    if findmnt -rn -S "$part" | grep -q .; then
        echo "ERROR: $part is still mounted"
        debug_partition_users "$part"
        return 1
    fi

    if fuser -m "$part" >/tmp/libertix-fuser.txt 2>&1; then
        echo "ERROR: $part still has users"
        cat /tmp/libertix-fuser.txt
        debug_partition_users "$part"
        return 1
    fi

    return 0
}

wait_for_prereqs() {
    mark "005-wait-prereqs"
    local i
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
            found_config=$(find /run/live /lib/live /cdrom -maxdepth 6 -name config.txt -print -quit 2>/dev/null || true)
            [ -n "$found_config" ] && config_ready=1
        fi

        if [ "$disk_ready" -eq 1 ] && [ "$config_ready" -eq 1 ]; then
            udevadm settle 2>/dev/null || true
            return 0
        fi
        sleep 1
    done
    die "live prerequisites not ready after 60s"
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

mount_ntfs_rw_or_die() {
    local part="$1"
    local mountpoint="$2"

    mkdir -p "$mountpoint"
    mountpoint -q "$mountpoint" && umount "$mountpoint"

    if mount -t ntfs-3g -o rw "$part" "$mountpoint" 2>/dev/null; then
        if touch "$mountpoint/.libertix-write-test" 2>/dev/null; then
            rm -f "$mountpoint/.libertix-write-test"
            return 0
        fi
        umount "$mountpoint" 2>/dev/null || true
    fi

    echo "NTFS write mount failed for $part; clearing unsafe flag with ntfsfix -d"
    run_logged ntfsfix -d "$part"
    run_logged mount -t ntfs-3g -o rw "$part" "$mountpoint"
    touch "$mountpoint/.libertix-write-test" || die "NTFS partition is not writable: $part"
    rm -f "$mountpoint/.libertix-write-test"
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

delete_live_bcd_entry_or_die() {
    local bcd_file="$1"

    python3 - "$bcd_file" <<'PY'
from __future__ import annotations

import shutil
import sys
from pathlib import Path

import hivex

BOOTMGR = "{9dea862c-5cdd-4e70-acc1-f32b344d4795}"
E_PATH = "12000002"
E_DESCRIPTION = "12000004"
E_DISPLAYORDER = "24000001"
E_BOOTSEQUENCE = "24000002"
E_TOOLS_DISPLAYORDER = "24000010"


def utf16z(text: str) -> bytes:
    return (text + "\0").encode("utf-16le")


def decode_utf16z(data: bytes | None) -> str:
    if not data:
        return ""
    return data.decode("utf-16le", errors="replace").rstrip("\0")


def decode_guid_list(data: bytes | None) -> list[str]:
    text = decode_utf16z(data)
    return [item for item in text.split("\0") if item]


def guid_list(guids: list[str]) -> bytes:
    return ("".join(guid + "\0" for guid in guids) + "\0").encode("utf-16le")


def child(hive: hivex.Hivex, node: int, name: str) -> int:
    found = hive.node_get_child(node, name)
    if not found:
        raise RuntimeError(f"missing BCD key: {name}")
    return found


def value_bytes(hive: hivex.Hivex, node: int | None, value_name: str = "Element") -> bytes | None:
    if not node:
        return None
    value = hive.node_get_value(node, value_name)
    if not value:
        return None
    _typ, data = hive.value_value(value)
    return data


def set_guid_list(hive: hivex.Hivex, elements: int, element_name: str, guids: list[str]) -> None:
    node = hive.node_get_child(elements, element_name)
    if guids:
        if not node:
            node = hive.node_add_child(elements, element_name)
        hive.node_set_value(node, {"key": "Element", "t": 7, "value": guid_list(guids)})
    elif node:
        hive.node_delete_child(node)


def main() -> int:
    bcd = Path(sys.argv[1])
    if not bcd.is_file():
        raise RuntimeError(f"BCD file not found: {bcd}")

    backup = bcd.with_name("BCD.bak-libertix-cleanup")
    if not backup.exists():
        shutil.copy2(bcd, backup)

    hive = hivex.Hivex(str(bcd), write=True)
    root = hive.root()
    objects = child(hive, root, "Objects")
    bootmgr = child(hive, objects, BOOTMGR)
    bootmgr_elements = child(hive, bootmgr, "Elements")

    targets: list[str] = []
    for obj in hive.node_children(objects):
        guid = hive.node_name(obj)
        elements = hive.node_get_child(obj, "Elements")
        if not elements:
            continue
        desc_node = hive.node_get_child(elements, E_DESCRIPTION)
        path_node = hive.node_get_child(elements, E_PATH)
        desc = decode_utf16z(value_bytes(hive, desc_node))
        path = decode_utf16z(value_bytes(hive, path_node))
        normalized_path = path.replace("/", "\\").casefold()
        if desc.casefold() == "install linux" or normalized_path in ("\\grldr.mbr", "\\\\grldr.mbr"):
            targets.append(guid)

    if not targets:
        print("BCD cleanup: no temporary live boot entry found")
        return 0

    target_set = {guid.casefold() for guid in targets}
    for element in (E_DISPLAYORDER, E_BOOTSEQUENCE, E_TOOLS_DISPLAYORDER):
        node = hive.node_get_child(bootmgr_elements, element)
        current = decode_guid_list(value_bytes(hive, node))
        filtered = [guid for guid in current if guid.casefold() not in target_set]
        if filtered != current:
            set_guid_list(hive, bootmgr_elements, element, filtered)

    for guid in targets:
        node = hive.node_get_child(objects, guid)
        if node:
            hive.node_delete_child(node)

    hive.commit(None)
    print("BCD cleanup: deleted " + ", ".join(targets))
    print(f"BCD cleanup: backup={backup}")
    return 0


raise SystemExit(main())
PY
}

cleanup_windows_live_boot_artifacts() {
    local bcd_part windows_part bcd_mnt windows_mnt

    mark "006-clean-windows-live-boot"

    bcd_part=$(find_ntfs_partition_with_file "Boot/BCD" || true)
    [ -n "$bcd_part" ] || die "Windows BCD store not found"

    bcd_mnt="/mnt/libertix-bcd"
    echo "Cleaning temporary BCD live boot entry from $bcd_part"
    mount_ntfs_rw_or_die "$bcd_part" "$bcd_mnt"
    [ -f "$bcd_mnt/Boot/BCD" ] || die "Windows BCD store disappeared after mount"
    delete_live_bcd_entry_or_die "$bcd_mnt/Boot/BCD"
    sync
    umount "$bcd_mnt"

    windows_part=$(find_windows_os_partition_any || true)
    [ -n "$windows_part" ] || die "Windows OS partition not found"

    windows_mnt="/mnt/libertix-windows-cleanup"
    echo "Removing temporary GRUB4DOS files from $windows_part"
    mount_ntfs_rw_or_die "$windows_part" "$windows_mnt"
    rm -f "$windows_mnt/grldr" "$windows_mnt/grldr.mbr" "$windows_mnt/menu.lst"
    sync
    umount "$windows_mnt"
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

echo "Libertix build: $(cat /etc/libertix-build-id 2>/dev/null || echo unknown)"
wait_for_prereqs
cleanup_windows_live_boot_artifacts

# Read config.txt
mark "010-read-config"
CONFIG_FILE=""
for mp in /run/live/medium /lib/live/mount/medium /cdrom; do
    [ -f "$mp/config.txt" ] && { CONFIG_FILE="$mp/config.txt"; break; }
done
if [ -z "$CONFIG_FILE" ]; then
    CONFIG_FILE=$(find /run/live /lib/live /cdrom -maxdepth 6 -name config.txt -print -quit 2>/dev/null || true)
fi

SYSTEM_LANG="en_US.UTF-8"
KEYBOARD_LAYOUT="us"
KEYBOARD_MODEL="pc105"
TIMEZONE="UTC"
USERNAME="user"
PASSWORD="password"
COMPUTER_NAME="linux-pc"
ISO_FILENAME="mint.iso"
ISO_WINDOWS_PATH=""
LINUX_SIZE_GB="30"

if [ -f "$CONFIG_FILE" ]; then
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        value=$(echo "$value" | sed 's/^"//;s/"$//' | sed "s/^'//;s/'$//")
        case "$key" in
            SYSTEM_LANG) SYSTEM_LANG="$value" ;;
            KEYBOARD_LAYOUT) KEYBOARD_LAYOUT="$value" ;;
            KEYBOARD_MODEL) KEYBOARD_MODEL="$value" ;;
            TIMEZONE) TIMEZONE="$value" ;;
            USERNAME) USERNAME="$value" ;;
            PASSWORD) PASSWORD="$value" ;;
            COMPUTER_NAME) COMPUTER_NAME="$value" ;;
            ISO_FILENAME) ISO_FILENAME="$value" ;;
            ISO_WINDOWS_PATH) ISO_WINDOWS_PATH="$value" ;;
            LINUX_SIZE_GB) LINUX_SIZE_GB="$value" ;;
        esac
    done < "$CONFIG_FILE"
fi

[ -z "$CONFIG_FILE" ] && die "config.txt not found on live medium"
[ -z "$ISO_WINDOWS_PATH" ] && ISO_WINDOWS_PATH="$ISO_FILENAME"

echo "Config: Lang=$SYSTEM_LANG Keyboard=$KEYBOARD_LAYOUT User=$USERNAME LinuxSize=${LINUX_SIZE_GB}GB"

# Detect disk
mark "020-detect-disk"
TARGET_DISK=""
LIVE_PART=""
for mp in /run/live/medium /lib/live/mount/medium /cdrom; do
    if mountpoint -q "$mp" 2>/dev/null; then
        LIVE_PART=$(findmnt -n -o SOURCE "$mp" 2>/dev/null || true)
        if [ -b "$LIVE_PART" ]; then
            TARGET_DISK=$(parent_disk_from_part "$LIVE_PART")
            break
        fi
    fi
done

if [ -z "$TARGET_DISK" ]; then
    for candidate in /dev/sd? /dev/nvme?n? /dev/mmcblk?; do
        [ -b "$candidate" ] || continue
        if [ -n "$(find_biggest_windows_partition "$candidate")" ]; then
            TARGET_DISK="$candidate"
            break
        fi
    done
fi

[ ! -b "$TARGET_DISK" ] && die "target disk not found: $TARGET_DISK"

DISK="$TARGET_DISK"
DISKNAME=$(basename "$DISK")

if [ -z "$LIVE_PART" ] || [ ! -b "$LIVE_PART" ]; then
    LIVE_PART=$(find_live_partition_on_disk "$DISK" || true)
fi

lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$DISK"

PART_TABLE=$(parted -sm "$DISK" print 2>/dev/null | awk -F: 'NR==2{print $6}')
PART_COUNT=$(lsblk -nr -o NAME,TYPE "$DISK" | awk '$2=="part"{c++}END{print c+0}')

# Find Windows partition
WINDOWS_PART=$(find_biggest_windows_partition "$DISK")
WINDOWS_SIZE=0
[ -n "$WINDOWS_PART" ] && WINDOWS_SIZE=$(($(blockdev --getsize64 "$WINDOWS_PART" 2>/dev/null || echo 0) / 1024 / 1024))

[ -z "$WINDOWS_PART" ] && die "No Windows partition"
echo "Windows: $WINDOWS_PART (${WINDOWS_SIZE}MB)"

# Calculate how much more we need to shrink Windows
# LINUX_SIZE_GB includes the 2GB FAT32, so we need (LINUX_SIZE_GB - 2) more for ext4
LINUX_SIZE_MB=$((LINUX_SIZE_GB * 1024))
FAT32_SIZE_MB=2048

# Get current free space on disk
CURRENT_FREE_MB=0
while IFS= read -r line; do
    if echo "$line" | grep -qi "Free Space"; then
        vals=($(echo "$line" | grep -oE '[0-9]+(\.[0-9]+)?MB' | sed 's/MB//'))
        [ "${#vals[@]}" -ge 3 ] && {
            sz=${vals[2]%%.*}
            [ "$sz" -gt "$CURRENT_FREE_MB" ] 2>/dev/null && CURRENT_FREE_MB=$sz
        }
    fi
done <<< "$(parted "$DISK" unit MB print free 2>/dev/null)"

echo "Current free space: ${CURRENT_FREE_MB}MB"
echo "Desired Linux size: ${LINUX_SIZE_MB}MB (${LINUX_SIZE_GB}GB)"

# Calculate how much more shrinking is needed
# We want: LINUX_SIZE_MB total for Linux (including FAT32)
# Current free space is what Windows already gave us
# Additional shrink needed = LINUX_SIZE_MB - CURRENT_FREE_MB
ADDITIONAL_SHRINK_MB=$((LINUX_SIZE_MB - CURRENT_FREE_MB))

if [ -n "$LIVE_PART" ] && [ "$(parent_disk_from_part "$LIVE_PART")" = "$DISK" ]; then
    echo "Live partition already exists at $LIVE_PART; skipping live-side Windows shrink."
    echo "Windows/Libertix created this partition at the final Linux size."
    ADDITIONAL_SHRINK_MB=0
fi

if [ "$ADDITIONAL_SHRINK_MB" -gt 1024 ]; then
    echo "=== Additional NTFS shrinking needed: ${ADDITIONAL_SHRINK_MB}MB ==="

    # Calculate new Windows size
    NEW_WINDOWS_SIZE_MB=$((WINDOWS_SIZE - ADDITIONAL_SHRINK_MB))

    if [ "$NEW_WINDOWS_SIZE_MB" -lt 20480 ]; then
        echo "WARNING: New Windows size would be less than 20GB, limiting shrink"
        NEW_WINDOWS_SIZE_MB=20480
        ADDITIONAL_SHRINK_MB=$((WINDOWS_SIZE - NEW_WINDOWS_SIZE_MB))
    fi

    echo "Shrinking Windows from ${WINDOWS_SIZE}MB to ${NEW_WINDOWS_SIZE_MB}MB..."

    # Make sure partition is not mounted
    umount "$WINDOWS_PART" 2>/dev/null || true

    # Check filesystem first
    echo "Checking NTFS filesystem..."
    ntfsfix "$WINDOWS_PART" || true

    # Resize NTFS filesystem (size in bytes for ntfsresize)
    NEW_SIZE_BYTES=$((NEW_WINDOWS_SIZE_MB * 1024 * 1024))
    echo "Resizing NTFS to ${NEW_WINDOWS_SIZE_MB}MB..."
    ntfsresize -f -s "${NEW_SIZE_BYTES}" "$WINDOWS_PART" <<< "y" || {
        echo "WARNING: ntfsresize failed, continuing with available space"
    }

    # Resize partition table
    PART_NUM=$(echo "$WINDOWS_PART" | grep -oE '[0-9]+$')
    echo "Resizing partition table..."
    parted -s "$DISK" resizepart "$PART_NUM" "${NEW_WINDOWS_SIZE_MB}MB" 2>/dev/null || true

    sync
    partprobe "$DISK" 2>/dev/null || true
    sleep 2

    # Update Windows size
    WINDOWS_SIZE=$(($(blockdev --getsize64 "$WINDOWS_PART" 2>/dev/null || echo 0) / 1024 / 1024))
    echo "Windows partition now: ${WINDOWS_SIZE}MB"
else
    echo "No additional shrinking needed (current free space is sufficient)"
fi

mark "030-check-mint-iso"
mkdir -p /mnt/windows
mount -t ntfs-3g -o ro "$WINDOWS_PART" /mnt/windows

ISO_WINDOWS_REL=$(windows_path_to_relative "$ISO_WINDOWS_PATH")
ISO_SOURCE="/mnt/windows/$ISO_WINDOWS_REL"

[ ! -f "$ISO_SOURCE" ] && {
    echo "ERROR: installer ISO not found: $ISO_SOURCE"
    echo "Config ISO_WINDOWS_PATH=$ISO_WINDOWS_PATH"
    find /mnt/windows -maxdepth 4 -iname "$ISO_FILENAME" 2>/dev/null | head -20 || true
    umount /mnt/windows
    die "installer ISO not found"
}
echo "ISO found: $(du -h "$ISO_SOURCE" | cut -f1) at $ISO_SOURCE"

# Keep Windows NTFS unmounted while changing the MBR table. Any mounted
# partition on the target disk can make BLKRRPART/partprobe keep the old view.
mark "035-umount-windows"
umount /mnt/windows

NEW_PART=""
NEW_PART_NUM=""

if [ -n "$LIVE_PART" ] && [ "$(parent_disk_from_part "$LIVE_PART")" = "$DISK" ]; then
    echo "=== Reusing live partition $LIVE_PART as final Linux partition ==="
    echo "The partition table keeps four entries; only the filesystem changes from FAT32 to ext4."
    mark "040-unmount-target-disk"
    unmount_target_disk_partitions
    assert_no_target_disk_mounts
    NEW_PART="$LIVE_PART"
    NEW_PART_NUM=$(partition_number "$NEW_PART")
    [ "$NEW_PART_NUM" = "3" ] || die "expected to reuse partition 3, got $NEW_PART_NUM"
    mark "050-assert-live-detached"
    assert_not_mounted_or_open "$NEW_PART"
elif [ "$PART_TABLE" = "msdos" ] && [ "$PART_COUNT" -ge 4 ]; then
    echo "ERROR: MBR has $PART_COUNT partitions and no removable live partition was found"
    echo "Refusing to delete or move the Windows recovery partition"
    print_disk_state "no live partition found"
    die "MBR full and no live partition found"
fi

if [ -z "$NEW_PART" ]; then
    # Find free space and create partition. This path is only used when the live
    # media is not on the target disk.
    unmount_target_disk_partitions
    assert_no_target_disk_mounts
    partprobe "$DISK" 2>/dev/null || true; sleep 1
    max_size=0; best_start=""; best_end=""
    while IFS= read -r line; do
        if echo "$line" | grep -qi "Free Space"; then
            vals=($(echo "$line" | grep -oE '[0-9]+(\.[0-9]+)?MB' | sed 's/MB//'))
            [ "${#vals[@]}" -ge 3 ] || continue
            sz=${vals[2]%%.*}
            [ "$sz" -gt "$max_size" ] 2>/dev/null && { max_size=$sz; best_start=${vals[0]%%.*}; best_end=${vals[1]%%.*}; }
        fi
    done <<< "$(parted "$DISK" unit MB print free 2>/dev/null)"

    [ "$max_size" -lt 5000 ] && die "<5GB free"

    echo "Creating Linux partition (${max_size}MB)"
    parted -s "$DISK" mkpart primary ext4 "${best_start}MB" "${best_end}MB"
    sync; partprobe "$DISK" 2>/dev/null || true; sleep 2

    for i in 1 2 3 4 5; do
        tp=$(partition_path "$DISK" "$i")
        [ -b "$tp" ] || continue
        fs=$(blkid -s TYPE -o value "$tp" 2>/dev/null || echo "")
        [ -z "$fs" ] && { NEW_PART="$tp"; break; }
    done
    [ -z "$NEW_PART" ] && NEW_PART=$(lsblk -nr -o NAME,TYPE "$DISK" | awk '$2=="part"{p="/dev/"$1}END{print p}')
    NEW_PART_NUM=$(echo "$NEW_PART" | grep -oE '[0-9]+$')
fi

if [ "$PART_TABLE" = "msdos" ] && [ -n "$NEW_PART_NUM" ]; then
    mark "060-set-mbr-type-83"
    echo "Setting MBR partition $NEW_PART_NUM type to Linux (0x83)"
    run_logged sfdisk --part-type "$DISK" "$NEW_PART_NUM" 83 || {
        echo "ERROR: failed to set Linux MBR type on $NEW_PART"
        debug_disk_state
        die "failed to set Linux MBR type on $NEW_PART"
    }
    udevadm settle 2>/dev/null || true
fi

mark "070-wipefs-live-part"
run_logged wipefs -a "$NEW_PART" || true
mark "080-mkfs-ext4"
run_logged mkfs.ext4 -F "$NEW_PART"
mkdir -p /mnt/target /mnt/iso
mark "090-mount-target"
run_logged mount "$NEW_PART" /mnt/target

mark "100-remount-windows-ro"
run_logged mount -t ntfs-3g -o ro "$WINDOWS_PART" /mnt/windows
[ ! -f "$ISO_SOURCE" ] && {
    echo "ERROR: installer ISO disappeared after remount: $ISO_SOURCE"
    umount /mnt/target
    umount /mnt/windows
    die "installer ISO disappeared after remount"
}

# Extract ISO
echo "Mounting installer ISO from Windows workspace..."
mark "110-loop-mount-mint-iso"
run_logged mount -o loop,ro "$ISO_SOURCE" /mnt/iso
echo "Extracting system..."
mark "120-unsquashfs"
run_logged unsquashfs -f -d /mnt/target /mnt/iso/casper/filesystem.squashfs
umount /mnt/iso

# System config
mark "130-target-system-config"
mount -t proc none /mnt/target/proc
mount -t sysfs none /mnt/target/sys
mount --bind /dev /mnt/target/dev
mount --bind /dev/pts /mnt/target/dev/pts

UUID=$(blkid -s UUID -o value "$NEW_PART")
echo "UUID=$UUID / ext4 defaults 0 1" > /mnt/target/etc/fstab

for pn in 1 2 3 4; do
    pdev=$(partition_path "$DISK" "$pn")
    [ -b "$pdev" ] || continue
    [ "$pdev" = "$NEW_PART" ] && continue
    pfs=$(blkid -s TYPE -o value "$pdev" 2>/dev/null || echo "")
    if [ "$pfs" = "ntfs" ]; then
        mdir="/mnt/target/mnt/win_$pn"
        mkdir -p "$mdir"
        mount -t ntfs-3g -o ro "$pdev" "$mdir" 2>/dev/null || true
    fi
done

install -m 0755 /usr/local/lib/libertix/configure-target.sh \
    /mnt/target/tmp/libertix-configure-target.sh
install -m 0755 /usr/local/lib/libertix/first-boot-resize.sh \
    /mnt/target/usr/local/bin/first-boot-resize.sh
install -m 0644 /usr/local/lib/libertix/first-boot-resize.service \
    /mnt/target/etc/systemd/system/first-boot-resize.service

chroot /mnt/target /usr/bin/env \
    SYSTEM_LANG="$SYSTEM_LANG" \
    KEYBOARD_LAYOUT="$KEYBOARD_LAYOUT" \
    KEYBOARD_MODEL="$KEYBOARD_MODEL" \
    TIMEZONE="$TIMEZONE" \
    USERNAME="$USERNAME" \
    PASSWORD="$PASSWORD" \
    COMPUTER_NAME="$COMPUTER_NAME" \
    DISK="$DISK" \
    DISKNAME="$DISKNAME" \
    /tmp/libertix-configure-target.sh
rm -f /mnt/target/tmp/libertix-configure-target.sh

# Cleanup mounts
for pn in 1 2 3 4; do
    mdir="/mnt/target/mnt/win_$pn"
    [ -d "$mdir" ] && umount "$mdir" 2>/dev/null || true
done

parted -s "$DISK" set "$NEW_PART_NUM" boot on 2>/dev/null || true

umount /mnt/target/dev/pts 2>/dev/null || true
umount /mnt/target/dev 2>/dev/null || true
umount /mnt/target/proc 2>/dev/null || true
umount /mnt/target/sys 2>/dev/null || true
umount /mnt/target 2>/dev/null || true

umount /mnt/windows 2>/dev/null || true
parted -s "$DISK" set "$NEW_PART_NUM" boot on 2>/dev/null || true

echo ""
echo "=== INSTALLATION COMPLETED ==="
echo "Rebooting in 1s..."
sleep 1
reboot
