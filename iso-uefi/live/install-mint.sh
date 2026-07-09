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
WINDOWS_PART=""
NEW_PART=""
NEW_PART_NUM=""
INSTALL_SUCCESS=false
INSTALL_COMMITTED=false
BOOTLOADER_WRITE_STARTED=false
MBR_BACKUP="$LOG_DIR/mbr-before-grub.bin"
ROLLBACK_ATTEMPTED=false
RECOVERY_GEOMETRY_BEFORE=""
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
    fail_and_exit 1 "$msg"
}

on_err() {
    local rc="$?"
    local line="${BASH_LINENO[0]:-unknown}"
    local cmd="${BASH_COMMAND:-unknown}"
    local msg="stage=$CURRENT_STAGE rc=$rc line=$line cmd=$cmd"
    echo "ERROR: $msg"
    {
        echo "stage=$CURRENT_STAGE"
        echo "rc=$rc"
        echo "line=$line"
        echo "cmd=$cmd"
        echo "time=$(date -Is 2>/dev/null || date)"
    } > "$FAIL_FILE"
    fail_and_exit "$rc" "$msg"
}
trap on_err ERR

safe_run() { "$@" || echo "WARNING: $* failed"; }

candidate_disks() {
    local disk

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
    done | awk '!seen[$0]++' || true
}

partitions_of_disk() {
    local disk="$1"
    lsblk -lnpo NAME,TYPE "$disk" 2>/dev/null | awk '$2=="part"{print $1}'
}

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

find_biggest_windows_partition() {
    local disk="$1"
    local best=""
    local best_size=0
    local pdev pfs psize

    while read -r pdev; do
        [ -n "$pdev" ] || continue
        pfs=$(blkid -s TYPE -o value "$pdev" 2>/dev/null || echo "")
        [ "$pfs" = "ntfs" ] || continue
        psize=$(($(blockdev --getsize64 "$pdev" 2>/dev/null || echo 0) / 1024 / 1024))
        if [ "$psize" -gt 1000 ] && [ "$psize" -gt "$best_size" ]; then
            best="$pdev"
            best_size="$psize"
        fi
    done < <(partitions_of_disk "$disk")

    echo "$best"
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
    legacy_label="$(printf '%s%s' 'LINUX' 'GATE')"

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

print_disk_state() {
    echo "--- Disk state: $1 ---"
    if [ -n "$DISK" ] && [ -b "$DISK" ]; then
        lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT "$DISK" || true
        parted -s "$DISK" unit MiB print free || true
    else
        lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT || true
    fi
    echo "Mounted from live partition:"
    [ -n "$LIVE_PART" ] && findmnt -rn -S "$LIVE_PART" || true
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
    if [ -n "$DISK" ] && [ -b "$DISK" ]; then
        lsblk -e7 -o NAME,MAJ:MIN,PKNAME,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS "$DISK" || true
    else
        lsblk -e7 -o NAME,MAJ:MIN,PKNAME,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS || true
    fi
    echo "--- parted sectors ---"
    [ -n "$DISK" ] && [ -b "$DISK" ] && parted -s "$DISK" unit s print free || true
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
    if command -v ps >/dev/null 2>&1; then
        ps -ef | grep -E 'ntfs-3g|udisks|gvfs|blkid|parted|partprobe|mount|loop|systemd-udevd' | grep -v grep || true
    else
        echo "ps unavailable"
    fi
    echo "--- dmesg tail ---"
    dmesg | tail -20 || true
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

recovery_start_sector() {
    local geometry start
    geometry="$(recovery_geometry "$1")"
    [ -n "$geometry" ] || return 0
    start="$(printf '%s\n' "$geometry" | awk -F: '{print $2; exit}')"
    start="${start%s}"
    [ -n "$start" ] && printf '%s\n' "$start"
}

normalize_recovery_geometry() {
    local geometry="$1"
    local num start end size type

    [ -n "$geometry" ] || return 0
    num="$(printf '%s\n' "$geometry" | awk -F: '{print $1; exit}')"
    start="$(printf '%s\n' "$geometry" | awk -F: '{print $2; exit}')"
    end="$(printf '%s\n' "$geometry" | awk -F: '{print $3; exit}')"
    size="$(printf '%s\n' "$geometry" | awk -F: '{print $4; exit}')"
    type="$(printf '%s\n' "$geometry" | awk -F: '{print $5; exit}' | tr '[:upper:]' '[:lower:]')"

    start="${start%s}"
    end="${end%s}"
    size="${size%s}"
    type="${type:-unknown}"

    [ -n "$num" ] && [ -n "$start" ] && [ -n "$end" ] && [ -n "$size" ] || return 0
    printf '%s:%s:%s:%s:%s\n' "$num" "$start" "$end" "$size" "$type"
}

assert_recovery_unchanged_or_die() {
    local current attempt before_key current_key
    [ -n "$RECOVERY_GEOMETRY_BEFORE" ] || return 0

    before_key="$(normalize_recovery_geometry "$RECOVERY_GEOMETRY_BEFORE")"
    for attempt in $(seq 1 30); do
        partprobe "$DISK" 2>/dev/null || true
        udevadm settle 2>/dev/null || true
        current="$(recovery_geometry "$DISK")"
        [ "$current" = "$RECOVERY_GEOMETRY_BEFORE" ] && return 0
        current_key="$(normalize_recovery_geometry "$current")"
        if [ -n "$before_key" ] && [ "$current_key" = "$before_key" ]; then
            echo "Recovery geometry raw format changed but normalized geometry is identical"
            echo "before raw: $RECOVERY_GEOMETRY_BEFORE"
            echo "after raw : $current"
            return 0
        fi
        echo "Recovery geometry check attempt $attempt/30 differs"
        echo "before: $RECOVERY_GEOMETRY_BEFORE"
        echo "after : $current"
        sleep 1
    done

    echo "ERROR: Windows recovery partition geometry changed"
    die "Windows recovery partition changed"
}

final_verify_or_die() {
    local target_verify="/mnt/libertix-final-verify"
    local windows_verify="/mnt/libertix-windows-final-verify"
    local fs uuid count part_table esp_part esp_verify

    mark "150-final-verify"
    echo "FINAL VERIFY: checking installed system before success"

    [ -n "$DISK" ] && [ -b "$DISK" ] || die "final verify: target disk missing"
    [ -n "$NEW_PART" ] && [ -b "$NEW_PART" ] || die "final verify: Linux partition missing"
    [ -n "$WINDOWS_PART" ] && [ -b "$WINDOWS_PART" ] || die "final verify: Windows partition missing"

    assert_recovery_unchanged_or_die

    part_table="$(parted -sm "$DISK" print 2>/dev/null | awk -F: 'NR==2{print $6}')"
    count="$(partition_count "$DISK")"
    if [ "$part_table" = "msdos" ]; then
        [ "$count" -le 4 ] || die "final verify: MBR partition count is $count"
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
    umount "$target_verify"

    esp_part="$(find_esp_partition || true)"
    [ -n "$esp_part" ] && [ -b "$esp_part" ] || die "final verify: UEFI ESP missing"
    esp_verify="/mnt/libertix-esp-final-verify"
    mkdir -p "$esp_verify"
    mount -t vfat -o ro "$esp_part" "$esp_verify"
    [ -f "$esp_verify/EFI/Libertix/shimx64.efi" ] || die "final verify: Libertix shim missing"
    [ -f "$esp_verify/EFI/Libertix/grubx64.efi" ] || die "final verify: Libertix signed GRUB missing"
    [ -f "$esp_verify/EFI/Libertix/grub.cfg" ] || die "final verify: Libertix EFI grub.cfg missing"
    umount "$esp_verify"

    mkdir -p "$windows_verify"
    mount -t ntfs-3g -o ro "$WINDOWS_PART" "$windows_verify"
    [ ! -e "$windows_verify/grldr" ] || die "final verify: temporary grldr still present"
    [ ! -e "$windows_verify/grldr.mbr" ] || die "final verify: temporary grldr.mbr still present"
    [ ! -e "$windows_verify/menu.lst" ] || die "final verify: temporary menu.lst still present"
    umount "$windows_verify"

    echo "FINAL VERIFY: success"
}

# The runner copies stdout/stderr to the main install log. These result markers
# make the final state machine-readable after the log is copied back to Windows.
append_install_result() {
    local success="$1"
    local rc="${2:-0}"
    local rollback="${3:-not-attempted}"

    {
        echo ""
        echo "LIBERTIX_INSTALL_SUCCESS=$success"
        echo "LIBERTIX_INSTALL_STAGE=$CURRENT_STAGE"
        echo "LIBERTIX_INSTALL_RC=$rc"
        echo "LIBERTIX_INSTALL_ROLLBACK=$rollback"
        echo "LIBERTIX_INSTALL_TIME=$(date -Is 2>/dev/null || date)"
    } || true
}

# Keep cleanup non-fatal: this is used from the error path, where preserving the
# rollback attempt is more important than failing on a stale mountpoint.
cleanup_live_mounts_best_effort() {
    cd / 2>/dev/null || true
    sync || true
    umount /mnt/iso 2>/dev/null || true
    umount /mnt/target/dev/pts 2>/dev/null || true
    umount /mnt/target/dev 2>/dev/null || true
    umount /mnt/target/proc 2>/dev/null || true
    umount /mnt/target/sys 2>/dev/null || true
    umount /mnt/target/boot/efi 2>/dev/null || true
    for mp in /mnt/target/mnt/win_*; do
        [ -d "$mp" ] && umount "$mp" 2>/dev/null || true
    done
    umount /mnt/target 2>/dev/null || true
    umount /mnt/windows 2>/dev/null || true
    umount /mnt/libertix-final-verify 2>/dev/null || true
    umount /mnt/libertix-windows-final-verify 2>/dev/null || true
    umount /mnt/libertix-esp-final-verify 2>/dev/null || true
}

# Rollback is intentionally conservative. It only deletes the live/final Linux
# slot that was already identified during this run. The Windows recovery
# partition is never moved or removed here.
rollback_windows_layout_best_effort() {
    local win_num recovery_start resize_end rollback_ok=false candidate live_candidate deleted_linux_part=false

    [ "$INSTALL_SUCCESS" = false ] || return 0
    [ "$ROLLBACK_ATTEMPTED" = false ] || return 0
    ROLLBACK_ATTEMPTED=true

    echo "=== ROLLBACK: best-effort Windows layout restore ==="

    if [ -z "$DISK" ] || [ ! -b "$DISK" ]; then
        while read -r candidate; do
            [ -n "$candidate" ] || continue
            [ -b "$candidate" ] || continue
            if [ -n "$(find_biggest_windows_partition "$candidate")" ]; then
                DISK="$candidate"
                DISKNAME="$(basename "$DISK")"
                echo "ROLLBACK: detected target disk as $DISK"
                break
            fi
        done < <(candidate_disks)
    fi
    if [ -z "$WINDOWS_PART" ] && [ -n "$DISK" ] && [ -b "$DISK" ]; then
        WINDOWS_PART="$(find_biggest_windows_partition "$DISK")"
        [ -n "$WINDOWS_PART" ] && echo "ROLLBACK: detected Windows partition as $WINDOWS_PART"
    fi

    if [ -z "$DISK" ] || [ ! -b "$DISK" ]; then
        echo "ROLLBACK: skipped because target disk is unknown"
        return 1
    fi
    if [ -z "$WINDOWS_PART" ] || [ ! -b "$WINDOWS_PART" ]; then
        echo "ROLLBACK: skipped because Windows partition is unknown"
        return 1
    fi

    cleanup_live_mounts_best_effort
    swapoff -a 2>/dev/null || true

    # GRUB is installed at the very end. If that write started and a later step
    # fails, restore the previous boot code bytes so Windows remains bootable.
    if [ "$BOOTLOADER_WRITE_STARTED" = true ] && [ -f "$MBR_BACKUP" ]; then
        echo "ROLLBACK: restoring pre-GRUB MBR boot code from $MBR_BACKUP"
        dd if="$MBR_BACKUP" of="$DISK" bs=446 count=1 conv=notrunc || true
        sync || true
    fi

    cleanup_final_uefi_bootloader_best_effort || true

    if [ -z "$NEW_PART" ]; then
        if [ -n "$LIVE_PART" ] && [ -b "$LIVE_PART" ] && [ "$(parent_disk_from_part "$LIVE_PART")" = "$DISK" ]; then
            NEW_PART="$LIVE_PART"
            NEW_PART_NUM="$(partition_number "$NEW_PART")"
            echo "ROLLBACK: using known live/Linux partition $NEW_PART"
        else
            live_candidate="$(find_live_partition_on_disk "$DISK" || true)"
            if [ -n "$live_candidate" ]; then
            NEW_PART="$live_candidate"
                NEW_PART_NUM="$(partition_number "$NEW_PART")"
            echo "ROLLBACK: detected temporary Linux partition as $NEW_PART"
            fi
        fi
    fi

    if [ -n "$NEW_PART" ] && [ -b "$NEW_PART" ]; then
        NEW_PART_NUM="${NEW_PART_NUM:-$(partition_number "$NEW_PART")}"
        if [ "$NEW_PART" != "$WINDOWS_PART" ] && [ "$(parent_disk_from_part "$NEW_PART")" = "$DISK" ]; then
            if findmnt -rn -S "$NEW_PART" | grep -q .; then
                echo "ROLLBACK: cannot delete $NEW_PART because it is still mounted"
            elif fuser -m "$NEW_PART" >/tmp/libertix-rollback-fuser.txt 2>&1; then
                echo "ROLLBACK: cannot delete $NEW_PART because it still has users"
                cat /tmp/libertix-rollback-fuser.txt || true
            else
                echo "ROLLBACK: deleting temporary Linux partition $NEW_PART"
                if parted -s "$DISK" rm "$NEW_PART_NUM"; then
                    deleted_linux_part=true
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

    if [ -n "$NEW_PART_NUM" ] && parted -sm "$DISK" print 2>/dev/null | awk -F: -v n="$NEW_PART_NUM" '$1==n{found=1} END{exit !found}'; then
        if [ "$deleted_linux_part" != true ]; then
            echo "ROLLBACK: skipping Windows resize because partition $NEW_PART_NUM is still present"
            debug_disk_state || true
            return 1
        fi
    fi

    win_num="$(partition_number "$WINDOWS_PART")"
    recovery_start="$(recovery_start_sector "$DISK" || true)"
    if [ -n "$recovery_start" ]; then
        resize_end="$((recovery_start - 1))s"
    else
        resize_end="100%"
    fi

    echo "ROLLBACK: resizing Windows partition $WINDOWS_PART to $resize_end"
    if parted -s "$DISK" unit s resizepart "$win_num" "$resize_end"; then
        partprobe "$DISK" 2>/dev/null || true
        udevadm settle 2>/dev/null || true
        echo "ROLLBACK: growing NTFS filesystem"
        ntfsresize -f "$WINDOWS_PART" <<< "y" || true
        ntfsfix -d "$WINDOWS_PART" || true
        rollback_ok=true
    else
        echo "ROLLBACK: partition resize failed"
    fi

    parted -s "$DISK" set 1 boot on 2>/dev/null || true
    if [ -n "$RECOVERY_GEOMETRY_BEFORE" ]; then
        echo "ROLLBACK: recovery before=$RECOVERY_GEOMETRY_BEFORE"
        echo "ROLLBACK: recovery after=$(recovery_geometry "$DISK")"
    fi
    debug_disk_state || true

    if [ "$rollback_ok" = true ]; then
        echo "ROLLBACK: completed best-effort Windows layout restore"
        return 0
    fi
    return 1
}

fail_and_exit() {
    local rc="$1"
    local msg="$2"

    trap - ERR
    set +e
    echo "ERROR: $msg"
    debug_disk_state || true
    if rollback_windows_layout_best_effort; then
        append_install_result false "$rc" "completed"
    else
        append_install_result false "$rc" "skipped-or-failed"
    fi
    exit "$rc"
}

# Log command return codes without hiding failures from callers.
run_logged() {
    echo "+ $*"
    set +e
    "$@"
    local rc=$?
    set -e
    echo "rc=$rc: $*"
    return "$rc"
}

unmount_if_mounted() {
    local mountpoint="$1"

    if mountpoint -q "$mountpoint"; then
        run_logged umount "$mountpoint" || return 1
    fi
}

mount_windows_ro_with_retry() {
    local part="$1"
    local mountpoint="$2"
    local attempt rc output

    mkdir -p "$mountpoint"
    unmount_if_mounted "$mountpoint" || true

    for attempt in $(seq 1 10); do
        echo "Mounting Windows partition read-only, attempt $attempt/10: $part -> $mountpoint"
        udevadm settle 2>/dev/null || true

        set +e
        output=$(mount -t ntfs-3g -o ro "$part" "$mountpoint" 2>&1)
        rc=$?
        set -e

        if [ "$rc" -eq 0 ]; then
            echo "Windows partition mounted read-only on $mountpoint"
            return 0
        fi

        echo "WARNING: read-only NTFS mount failed rc=$rc on attempt $attempt"
        [ -n "$output" ] && echo "$output"

        # A dirty NTFS flag after a reboot can make early live mounts flaky.
        # Clear it after a few failed read-only attempts, then retry mounting.
        if [ "$attempt" -eq 4 ] || [ "$attempt" -eq 8 ]; then
            echo "Running ntfsfix -d before retrying read-only mount"
            ntfsfix -d "$part" || true
            udevadm settle 2>/dev/null || true
        fi

        sleep 2
    done

    die "cannot mount Windows partition read-only: $part"
}

wait_for_iso_source_or_die() {
    local iso_path="$1"
    local relative_path="$2"
    local attempt size_before size_after human_size parent_dir

    for attempt in $(seq 1 10); do
        if [ -f "$iso_path" ]; then
            size_before=$(stat -c '%s' "$iso_path" 2>/dev/null || echo 0)
            sleep 1
            size_after=$(stat -c '%s' "$iso_path" 2>/dev/null || echo 0)
            if [ "$size_before" -eq "$size_after" ] && [ "$size_after" -gt 10485760 ]; then
                human_size=$(du -h "$iso_path" | cut -f1)
                echo "ISO found: $human_size (${size_after} bytes) at $iso_path"
                return 0
            fi
            echo "Waiting for stable ISO file, attempt $attempt/10: size ${size_before} -> ${size_after}"
        else
            echo "Waiting for installer ISO, attempt $attempt/10: $iso_path"
        fi
        sleep 2
    done

    echo "ERROR: installer ISO not available or not stable: $iso_path"
    echo "Config ISO_WINDOWS_PATH=$ISO_WINDOWS_PATH"
    echo "Relative ISO path=$relative_path"
    parent_dir=$(dirname "$iso_path")
    if [ -d "$parent_dir" ]; then
        echo "--- ISO parent directory listing: $parent_dir ---"
        ls -la "$parent_dir" || true
    fi
    echo "--- Candidate ISO files on Windows partition ---"
    find /mnt/windows -maxdepth 6 -iname "$ISO_FILENAME" 2>/dev/null | head -20 || true
    die "installer ISO not available or not stable"
}

# Strict unmount only. Lazy unmount would hide open block-device references and
# make wipefs/mkfs look safe while the live medium is still in use.
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

        while read -r candidate; do
            [ -n "$candidate" ] || continue
            [ -b "$candidate" ] && { disk_ready=1; break; }
        done < <(candidate_disks)

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

# Windows can leave NTFS dirty after a forced reboot. Try a normal rw mount
# first, then clear the unsafe flag and mount again.
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
    local parttype expected

    [ -n "$NEW_PART_NUM" ] || die "Linux partition number missing"

    mark "060-set-linux-partition-type"
    if [ "$PART_TABLE" = "msdos" ]; then
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

    if [ "$PART_TABLE" != "msdos" ]; then
        parttype="$(lsblk -dnro PARTTYPE "$NEW_PART" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
        expected="$(echo "$linux_gpt_guid" | tr '[:upper:]' '[:lower:]')"
        [ "$parttype" = "$expected" ] || \
            die "Linux GPT type verification failed on $NEW_PART: $parttype"
    fi
}

verify_linux_partition_type_or_die() {
    local linux_gpt_guid="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
    local parttype expected

    [ "$PART_TABLE" != "msdos" ] || return 0

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
    umount "$esp_mount"
}

find_windows_os_partition_any() {
    local best=""
    local best_size=0
    local candidate pdev pfs psize tmp

    while read -r candidate; do
        [ -n "$candidate" ] || continue
        [ -b "$candidate" ] || continue
        while read -r pdev; do
            [ -n "$pdev" ] || continue
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
        done < <(partitions_of_disk "$candidate")
    done < <(candidate_disks)

    echo "$best"
}

delete_live_bcd_entry_or_die() {
    local bcd_file="$1"

    # cleanup-bcd.py edits the offline Windows BCD hive with hivex. Keeping the
    # Python out of this shell script makes the boot cleanup auditable.
    python3 /usr/local/lib/libertix/cleanup-bcd.py "$bcd_file"
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

echo "Libertix build: $(cat /etc/libertix-build-id 2>/dev/null || echo unknown)"
wait_for_prereqs
cleanup_windows_live_boot_artifacts
mark "007-windows-live-boot-cleaned"

# Read config.txt
mark "010-read-config"
CONFIG_FILE=""
for mp in /run/live/medium /lib/live/mount/medium /cdrom; do
    [ -f "$mp/config.txt" ] && { CONFIG_FILE="$mp/config.txt"; break; }
done
if [ -z "$CONFIG_FILE" ]; then
    CONFIG_FILE=$(find /run/live /lib/live /cdrom -maxdepth 6 -name config.txt -print -quit 2>/dev/null || true)
fi
[ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ] || die "config.txt not found on live medium"

SYSTEM_LANG="en_US.UTF-8"
KEYBOARD_LAYOUT="us"
KEYBOARD_MODEL="pc105"
TIMEZONE="UTC"
USERNAME=""
PASSWORD=""
COMPUTER_NAME=""
ISO_FILENAME="mint.iso"
ISO_WINDOWS_PATH=""
LINUX_SIZE_GB="30"

if [ -f "$CONFIG_FILE" ]; then
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        value=$(python3 - "$value" <<'PY'
import shlex
import sys

raw = sys.argv[1]
try:
    parsed = shlex.split("x=" + raw, posix=True)
    print(parsed[0].split("=", 1)[1] if parsed else "")
except Exception:
    print(raw.strip().strip('"').strip("'"))
PY
)
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

[ -n "$USERNAME" ] || die "config.txt missing USERNAME"
[ -n "$PASSWORD" ] || die "config.txt missing PASSWORD"
[ -n "$COMPUTER_NAME" ] || die "config.txt missing COMPUTER_NAME"
[ -n "$LINUX_SIZE_GB" ] || die "config.txt missing LINUX_SIZE_GB"
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
    while read -r candidate; do
        [ -n "$candidate" ] || continue
        [ -b "$candidate" ] || continue
        if [ -n "$(find_biggest_windows_partition "$candidate")" ]; then
            TARGET_DISK="$candidate"
            break
        fi
    done < <(candidate_disks)
fi

if [ -z "$TARGET_DISK" ]; then
    while read -r candidate; do
        [ -n "$candidate" ] || continue
        [ -b "$candidate" ] || continue
        LIVE_PART="$(find_live_partition_on_disk "$candidate" || true)"
        if [ -n "$LIVE_PART" ]; then
            TARGET_DISK="$candidate"
            break
        fi
    done < <(candidate_disks)
fi

if [ -z "$TARGET_DISK" ]; then
    echo "ERROR: no target disk found"
    echo "--- candidate disks ---"
    candidate_disks || true
    echo "--- lsblk ---"
    lsblk -e7 -o NAME,MAJ:MIN,PKNAME,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS || true
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
RECOVERY_GEOMETRY_BEFORE="$(recovery_geometry "$DISK")"
[ -n "$RECOVERY_GEOMETRY_BEFORE" ] && echo "Recovery partition geometry before install: $RECOVERY_GEOMETRY_BEFORE"

# Find Windows partition
WINDOWS_PART=$(find_biggest_windows_partition "$DISK")
WINDOWS_SIZE=0
[ -n "$WINDOWS_PART" ] && WINDOWS_SIZE=$(($(blockdev --getsize64 "$WINDOWS_PART" 2>/dev/null || echo 0) / 1024 / 1024))

if [ -z "$WINDOWS_PART" ]; then
    BITLOCKER_PART="$(find_biggest_bitlocker_partition "$DISK" || true)"
    if [ -n "$BITLOCKER_PART" ]; then
        die "Windows partition is BitLocker-encrypted: $BITLOCKER_PART"
    fi
    echo "--- no NTFS Windows partition detected on $DISK ---"
    lsblk -e7 -o NAME,MAJ:MIN,PKNAME,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS "$DISK" || true
    die "No Windows partition"
fi
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
ISO_WINDOWS_REL=$(windows_path_to_relative "$ISO_WINDOWS_PATH")
ISO_SOURCE="/mnt/windows/$ISO_WINDOWS_REL"

mount_windows_ro_with_retry "$WINDOWS_PART" /mnt/windows
wait_for_iso_source_or_die "$ISO_SOURCE" "$ISO_WINDOWS_REL"

# Keep Windows NTFS unmounted while changing the MBR table. Any mounted
# partition on the target disk can make BLKRRPART/partprobe keep the old view.
mark "035-umount-windows"
run_logged umount /mnt/windows

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
    if [ "$PART_TABLE" = "msdos" ]; then
        [ "$NEW_PART_NUM" = "3" ] || die "expected to reuse partition 3, got $NEW_PART_NUM"
    fi
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

set_linux_partition_type_or_die

mark "070-wipefs-live-part"
run_logged wipefs -a "$NEW_PART" || true
mark "080-mkfs-ext4"
run_logged mkfs.ext4 -F "$NEW_PART"
mkdir -p /mnt/target /mnt/iso
mark "090-mount-target"
run_logged mount "$NEW_PART" /mnt/target

mark "100-remount-windows-ro"
mount_windows_ro_with_retry "$WINDOWS_PART" /mnt/windows
wait_for_iso_source_or_die "$ISO_SOURCE" "$ISO_WINDOWS_REL"

# Extract ISO
echo "Mounting installer ISO from Windows workspace..."
mark "110-loop-mount-mint-iso"
run_logged mount -o loop,ro "$ISO_SOURCE" /mnt/iso
echo "Extracting system..."
mark "120-unsquashfs"
if command -v stdbuf >/dev/null 2>&1; then
    run_logged stdbuf -oL -eL unsquashfs -f -d /mnt/target /mnt/iso/casper/filesystem.squashfs
else
    run_logged unsquashfs -f -d /mnt/target /mnt/iso/casper/filesystem.squashfs
fi
umount /mnt/iso

# System config
mark "130-target-system-config"
mount -t proc none /mnt/target/proc
mount -t sysfs none /mnt/target/sys
mount --bind /dev /mnt/target/dev
mount --bind /dev/pts /mnt/target/dev/pts

write_target_fstab_or_die

while read -r pdev; do
    [ -n "$pdev" ] || continue
    [ "$pdev" = "$NEW_PART" ] && continue
    pfs=$(blkid -s TYPE -o value "$pdev" 2>/dev/null || echo "")
    if [ "$pfs" = "ntfs" ]; then
        pn="$(partition_number "$pdev")"
        mdir="/mnt/target/mnt/win_$pn"
        mkdir -p "$mdir"
        mount -t ntfs-3g -o ro "$pdev" "$mdir" 2>/dev/null || true
    fi
done < <(partitions_of_disk "$DISK")

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

mark "140-install-bootloader"
echo "Installing signed UEFI bootloader..."
BOOTLOADER_WRITE_STARTED=true
install_signed_uefi_bootloader_or_die
INSTALL_COMMITTED=true

# Cleanup mounts
for pn in $(seq 1 32); do
    mdir="/mnt/target/mnt/win_$pn"
    [ -d "$mdir" ] && umount "$mdir" 2>/dev/null || true
done

# In GPT, the "boot" flag means EFI System Partition. Keep it away from the
# Linux root partition; the real ESP is mounted at /boot/efi above.
verify_linux_partition_type_or_die

umount /mnt/target/dev/pts 2>/dev/null || true
umount /mnt/target/dev 2>/dev/null || true
umount /mnt/target/proc 2>/dev/null || true
umount /mnt/target/sys 2>/dev/null || true
umount /mnt/target/boot/efi 2>/dev/null || true
umount /mnt/target 2>/dev/null || true

umount /mnt/windows 2>/dev/null || true
assert_recovery_unchanged_or_die
final_verify_or_die

echo ""
echo "=== INSTALLATION COMPLETED ==="
INSTALL_SUCCESS=true
append_install_result true 0 "not-needed"
exit 0
