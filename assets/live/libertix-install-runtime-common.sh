#!/bin/bash
# Command diagnostics are written here and read by the sourcing orchestrator.
# shellcheck disable=SC2034

# Shared diagnostics, mount handling, and result reporting for the BIOS and
# UEFI live installers. The orchestrator must define die(), fail_and_exit(),
# recovery_geometry(), and the global installation paths before calling these
# functions. Keeping that contract explicit prevents firmware policy from
# leaking into the common runtime.

verify_file_sha256() {
    local path="$1" expected="$2" actual

    case "$expected" in
        *[!0-9A-Fa-f]*|'') return 2 ;;
    esac
    [ "${#expected}" -eq 64 ] || return 2
    [ -f "$path" ] || return 1
    actual="$(sha256sum -- "$path" 2>/dev/null | awk '{print $1}')" || return 1
    [ "$actual" = "$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')" ]
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
    local partition="$1"
    local device_name major_minor holder

    device_name=$(basename "$partition")
    major_minor=$(lsblk -dnro MAJ:MIN "$partition" 2>/dev/null || true)

    echo "=== DEBUG users for $partition ==="
    echo "--- findmnt source ---"
    findmnt -rn -S "$partition" -o SOURCE,TARGET,FSTYPE,OPTIONS 2>/dev/null || true
    echo "--- /proc/*/mountinfo matching MAJ:MIN=$major_minor ---"
    if [ -n "$major_minor" ]; then
        awk -v mm="$major_minor" '$3 == mm { print FILENAME ":" $0 }' \
            /proc/[0-9]*/mountinfo 2>/dev/null || true
    fi
    echo "--- fuser ---"
    fuser -vm "$partition" 2>&1 || true
    echo "--- lsof ---"
    lsof "$partition" 2>/dev/null || true
    echo "--- holders ---"
    if [ -d "/sys/class/block/$device_name/holders" ]; then
        ls -la "/sys/class/block/$device_name/holders" || true
        for holder in /sys/class/block/"$device_name"/holders/*; do
            [ -e "$holder" ] && echo "holder: $(basename "$holder")"
        done
    fi
    echo "--- inflight ---"
    cat "/sys/class/block/$device_name/inflight" 2>/dev/null || true
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
        ps -ef \
            | grep -E 'ntfs-3g|udisks|gvfs|blkid|parted|partprobe|mount|loop|systemd-udevd' \
            | grep -v grep \
            || true
    else
        echo "ps unavailable"
    fi
    echo "--- dmesg tail ---"
    dmesg | tail -20 || true
}

assert_recovery_unchanged_or_die() {
    local recovery_partition recovery_size

    recovery_partition=$(partition_at_offset "$DISK" "$RECOVERY_PARTITION_OFFSET_BYTES" || true)
    [ -n "$recovery_partition" ] && [ -b "$recovery_partition" ] \
        || die "Windows recovery partition is missing at its recorded offset"
    recovery_size=$(blockdev --getsize64 "$recovery_partition" 2>/dev/null || echo 0)
    [ "$recovery_size" = "$RECOVERY_PARTITION_SIZE_BYTES" ] \
        || die "Windows recovery partition size changed: expected $RECOVERY_PARTITION_SIZE_BYTES, got $recovery_size"

    echo "Windows recovery partition verified from manifest: $recovery_partition ($recovery_size bytes)"
}

emit_install_result() {
    local success="$1"
    local rc="${2:-0}"
    local rollback="${3:-not-attempted}"

    # The runner redirects the complete installer stdout stream to install.log
    # and extracts this machine-readable trailer after the child exits.
    {
        echo ""
        echo "LIBERTIX_INSTALL_SUCCESS=$success"
        echo "LIBERTIX_INSTALL_STAGE=$CURRENT_STAGE"
        echo "LIBERTIX_INSTALL_RC=$rc"
        echo "LIBERTIX_INSTALL_ROLLBACK=$rollback"
        echo "LIBERTIX_INSTALL_TIME=$(date -Is 2>/dev/null || date)"
    } || true
}

run_logged() {
    RUN_LOGGED_COMMAND="$*"
    RUN_LOGGED_RC=""
    echo "+ $*"
    set +e
    "$@"
    local rc=$?
    set -e
    RUN_LOGGED_RC="$rc"
    echo "rc=$rc: $*"
    if [ "$rc" -eq 0 ]; then
        RUN_LOGGED_COMMAND=""
        RUN_LOGGED_RC=""
    fi
    return "$rc"
}

unmount_if_mounted() {
    local mountpoint="$1"

    if mountpoint -q "$mountpoint"; then
        run_logged umount "$mountpoint" || return 1
    fi
}

recovery_geometry() {
    local disk="$1"
    manifest_partition_geometry "$disk" "$RECOVERY_PARTITION_OFFSET_BYTES"
}

verify_fstab_or_die() {
    local target_root="$1" output rc
    local target_dev="$target_root/dev"

    [ -f "$target_root/etc/fstab" ] || die "final verify: target fstab missing"
    [ -d "$target_dev" ] || die "final verify: target /dev directory missing"

    # findmnt resolves mount targets from /. Run it in the installed system so
    # target paths are not checked against the live environment.
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

mount_windows_ro_with_retry() {
    local partition="$1"
    local mountpoint="$2"
    local attempt rc output

    mkdir -p "$mountpoint"
    unmount_if_mounted "$mountpoint" || true

    for attempt in $(seq 1 10); do
        echo "Mounting Windows partition read-only, attempt $attempt/10: $partition -> $mountpoint"
        udevadm settle 2>/dev/null || true

        set +e
        output=$(mount -t ntfs-3g -o ro "$partition" "$mountpoint" 2>&1)
        rc=$?
        set -e

        if [ "$rc" -eq 0 ]; then
            echo "Windows partition mounted read-only on $mountpoint"
            return 0
        fi

        echo "WARNING: read-only NTFS mount failed rc=$rc on attempt $attempt"
        [ -n "$output" ] && echo "$output"

        sleep 2
    done

    die "cannot mount Windows partition read-only: $partition"
}

mount_linux_root_read_only_or_die() {
    local partition="$1"
    local mountpoint="$2"
    local attempt rc output mounted_source

    mkdir -p "$mountpoint"
    unmount_if_mounted "$mountpoint" || \
        die "final verify: cannot release previous target verification mount"

    for attempt in $(seq 1 10); do
        echo "Mounting Linux root read-only, attempt $attempt/10: $partition -> $mountpoint"
        sync || true
        udevadm settle 2>/dev/null || true

        if output=$(mount -t ext4 -o ro "$partition" "$mountpoint" 2>&1); then
            rc=0
        else
            rc=$?
        fi

        if [ "$rc" -eq 0 ]; then
            mounted_source="$(findmnt -rn -M "$mountpoint" -o SOURCE 2>/dev/null || true)"
            if [ "$(readlink -f "$mounted_source" 2>/dev/null || true)" \
                = "$(readlink -f "$partition" 2>/dev/null || true)" ]; then
                echo "Linux root mounted read-only on $mountpoint"
                return 0
            fi
            output="mount returned success but the expected source was not observed"
            rc=1
        fi

        echo "WARNING: read-only ext4 mount failed rc=$rc on attempt $attempt"
        [ -n "$output" ] && printf '%s\n' "$output"
        unmount_if_mounted "$mountpoint" || true
        sleep 1
    done

    die "final verify: cannot mount Linux partition read-only: $partition"
}

wait_for_iso_source_or_die() {
    local iso_path="$1"
    local relative_path="$2"
    local attempt size_before size_after human_size parent_directory

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
    parent_directory=$(dirname "$iso_path")
    if [ -d "$parent_directory" ]; then
        echo "--- ISO parent directory listing: $parent_directory ---"
        ls -la "$parent_directory" || true
    fi
    echo "--- Candidate ISO files on Windows partition ---"
    find /mnt/windows -maxdepth 6 -iname "$ISO_FILENAME" 2>/dev/null | head -20 || true
    die "installer ISO not available or not stable"
}

# Only strict unmounts are accepted. A lazy unmount can hide open block-device
# references and make wipefs or mkfs appear safe while the live is still using
# the target partition.
unmount_target_disk_partitions() {
    local source target parent

    echo "Unmounting mounted partitions from target disk $DISK..."
    cd /
    while read -r source target; do
        [ -n "$source" ] && [ -n "$target" ] || continue
        [ -b "$source" ] || continue
        parent=$(parent_disk_from_part "$source")
        [ "$parent" = "$DISK" ] || continue
        echo "Unmounting $source from $target"
        if ! umount "$target"; then
            echo "ERROR: strict umount failed for $source at $target"
            debug_partition_users "$source"
            debug_disk_state
            die "strict umount failed for $source at $target"
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
    local partition="$1"
    local attempt consecutive_idle_samples=0 fuser_output=""

    [ -b "$partition" ] || die "partition not found: $partition"
    # `fuser -m` treats the argument as a file on its containing filesystem.
    # For a node under /dev that can report unrelated processes using /dev and
    # falsely claim the detached partition is busy. Query the block device
    # itself after findmnt has already ruled out an active mount. Partition
    # discovery can briefly leave a udev/blkid probe on the node, so require two
    # consecutive idle samples instead of treating one transient PID as fatal.
    udevadm settle --timeout=10 2>/dev/null || true
    for attempt in $(seq 1 20); do
        if findmnt -rn -S "$partition" | grep -q .; then
            echo "ERROR: $partition is still mounted"
            debug_partition_users "$partition"
            die "partition remains mounted before a partition-table update: $partition"
        fi
        if fuser_output=$(fuser "$partition" 2>&1); then
            consecutive_idle_samples=0
        else
            consecutive_idle_samples=$((consecutive_idle_samples + 1))
            [ "$consecutive_idle_samples" -lt 2 ] || return 0
        fi
        sleep 0.25
    done

    echo "ERROR: $partition still has users after bounded retries"
    [ -z "$fuser_output" ] || printf '%s\n' "$fuser_output"
    debug_partition_users "$partition"
    die "partition remains in use before a partition-table update: $partition"
}

mount_ntfs_rw_or_die() {
    local partition="$1"
    local mountpoint="$2"

    mkdir -p "$mountpoint"
    mountpoint -q "$mountpoint" && umount "$mountpoint"

    if mount -t ntfs-3g -o rw "$partition" "$mountpoint" 2>/dev/null; then
        if touch "$mountpoint/.libertix-write-test" 2>/dev/null; then
            rm -f "$mountpoint/.libertix-write-test"
            return 0
        fi
        umount "$mountpoint" 2>/dev/null || true
    fi

    echo "NTFS write mount failed for $partition; clearing unsafe flag with ntfsfix -d"
    run_logged ntfsfix -d "$partition"
    run_logged mount -t ntfs-3g -o rw "$partition" "$mountpoint"
    touch "$mountpoint/.libertix-write-test" || die "NTFS partition is not writable: $partition"
    rm -f "$mountpoint/.libertix-write-test"
}

delete_live_bcd_entry_or_die() {
    local bcd_file="$1"

    # cleanup-bcd.py edits the offline Windows BCD hive with hivex. Keeping the
    # Python out of this shell module makes the boot cleanup auditable.
    python3 /usr/local/lib/libertix/cleanup-bcd.py "$bcd_file"
}
write_windows_recovery_marker_file_best_effort() {
    local namespace="$1"
    local state="$2"
    local rc="${3:-0}"
    local mountpoint="/mnt/libertix-recovery-state"
    local relative marker

    [ -n "$RECOVERY_ROOT_WINDOWS" ] || return 0
    [ -n "$RECOVERY_RUN_ID" ] || return 0
    [ -n "$WINDOWS_PART" ] && [ -b "$WINDOWS_PART" ] || return 0
    case "$RECOVERY_ROOT_WINDOWS" in
        [A-Za-z]:\\*) ;;
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
    local temporary
    temporary="$(dirname "$marker")/.${state}.$$.tmp"
    (
        umask 077
        {
            echo "LIBERTIX_${namespace}_RECOVERY_RUN_ID=$RECOVERY_RUN_ID"
            echo "LIBERTIX_${namespace}_RECOVERY_STATE=$state"
            echo "LIBERTIX_${namespace}_RECOVERY_STAGE=$CURRENT_STAGE"
            echo "LIBERTIX_${namespace}_RECOVERY_RC=$rc"
            echo "LIBERTIX_${namespace}_RECOVERY_TIME=$(date -Is 2>/dev/null || date)"
        } > "$temporary"
    ) 2>/dev/null || true
    if [ -s "$temporary" ]; then
        sync "$temporary" 2>/dev/null || sync || true
        mv -f "$temporary" "$marker" 2>/dev/null || true
        sync "$marker" 2>/dev/null || sync || true
    fi
    rm -f "$temporary" 2>/dev/null || true
    umount "$mountpoint" 2>/dev/null || true
    return 0
}
