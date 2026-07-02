#!/bin/bash
set -e

# Configuration
SYSTEM_LANG="fr_FR.UTF-8"
KEYBOARD_LAYOUT="fr"
KEYBOARD_MODEL="pc105"
TIMEZONE="Europe/Paris"
USERNAME="mint"
PASSWORD="1234"
ISO_FILENAME="mint.iso"

[ "$EUID" -ne 0 ] && { echo "Run with sudo!"; exit 1; }

echo "=== Installing build dependencies ==="
apt update
apt install -y debootstrap squashfs-tools xorriso isolinux syslinux-utils \
    grub-pc-bin grub-efi-amd64-bin mtools dosfstools

WORKDIR="/tmp/debian_live_v9"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"/{chroot,iso_build}

echo "=== Creating minimal Debian system ==="
debootstrap --variant=minbase stable "$WORKDIR/chroot" http://deb.debian.org/debian/

echo "=== Mounting filesystems ==="
mount -t proc none "$WORKDIR/chroot/proc"
mount -t sysfs none "$WORKDIR/chroot/sys"
mount --bind /dev "$WORKDIR/chroot/dev"
mount --bind /dev/pts "$WORKDIR/chroot/dev/pts"

echo "=== Installing packages in live system ==="
cat > "$WORKDIR/chroot/setup.sh" << 'SETUPSCRIPT'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

apt update
apt install -y linux-image-amd64 live-boot live-boot-initramfs-tools live-config \
    live-config-systemd systemd-sysv initramfs-tools parted fdisk e2fsprogs \
    squashfs-tools dosfstools ntfs-3g sudo nano util-linux coreutils \
    psmisc lsof

update-initramfs -u -k all
lsinitramfs /boot/initrd.img-* 2>/dev/null | grep -E "live" | head -5 || true

useradd -m -s /bin/bash -G sudo user 2>/dev/null || true
echo "user:live" | chpasswd
echo "user ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

apt clean
rm -rf /var/lib/apt/lists/*
SETUPSCRIPT

chmod +x "$WORKDIR/chroot/setup.sh"
chroot "$WORKDIR/chroot" /setup.sh
rm -f "$WORKDIR/chroot/setup.sh"

mkdir -p "$WORKDIR/chroot/etc/live"
echo "LIVE_MEDIA_PATH=/live" > "$WORKDIR/chroot/etc/live/boot.conf"

# Installation script
cat > "$WORKDIR/chroot/install-mint.sh" << 'INSTALLSCRIPT'
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
    echo "LINUXGATE STAGE: $CURRENT_STAGE" > /dev/kmsg 2>/dev/null || true
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

find_live_partition_on_disk() {
    local disk="$1"
    local pn pdev label pfs psize
    for pn in 1 2 3 4 5; do
        pdev=$(partition_path "$disk" "$pn")
        [ -b "$pdev" ] || continue
        label=$(blkid -s LABEL -o value "$pdev" 2>/dev/null || echo "")
        if [ "$label" = "LINUXGATE" ] || [ "$label" = "LIBERTIX_INSTALLER" ]; then
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

# Chroot config
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
    /bin/bash << 'CHROOTSCRIPT'
set -e

useradd -m -s /bin/bash -G sudo,adm,cdrom,audio,video,plugdev "$USERNAME" 2>/dev/null || true
echo "$USERNAME:$PASSWORD" | chpasswd
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
echo "$COMPUTER_NAME" > /etc/hostname

# Windows mount
WIN_UUID=""
for pn in 1 2 3 4; do
    [[ "$DISKNAME" == nvme* ]] || [[ "$DISKNAME" == mmcblk* ]] && pdev="${DISK}p${pn}" || pdev="${DISK}${pn}"
    [ -b "$pdev" ] || continue
    pfs=$(blkid -s TYPE -o value "$pdev" 2>/dev/null || echo "")
    if [ "$pfs" = "ntfs" ]; then
        psize=$(($(blockdev --getsize64 "$pdev" 2>/dev/null || echo 0) / 1024 / 1024 / 1024))
        [ "$psize" -gt 10 ] && { WIN_UUID=$(blkid -s UUID -o value "$pdev"); break; }
    fi
done
[ -n "$WIN_UUID" ] && {
    mkdir -p /mnt/windows
    echo "UUID=$WIN_UUID /mnt/windows ntfs-3g defaults,uid=1000,gid=1000,dmask=022,fmask=133,windows_names,nofail 0 0" >> /etc/fstab
}

# Locale
sed -i "s/# $SYSTEM_LANG/$SYSTEM_LANG/" /etc/locale.gen 2>/dev/null || true
locale-gen 2>/dev/null || true
cat > /etc/default/locale << EOF
LANG=$SYSTEM_LANG
LC_ALL=$SYSTEM_LANG
LANGUAGE=${SYSTEM_LANG%%_*}
EOF

# Keyboard
cat > /etc/default/keyboard << EOF
XKBMODEL="$KEYBOARD_MODEL"
XKBLAYOUT="$KEYBOARD_LAYOUT"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF

mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf << EOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "$KEYBOARD_LAYOUT"
    Option "XkbModel" "$KEYBOARD_MODEL"
EndSection
EOF

mkdir -p /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/00-keyboard << EOF
[org/gnome/libgnomekbd/keyboard]
layouts=['$KEYBOARD_LAYOUT']
model='$KEYBOARD_MODEL'
[org/cinnamon/desktop/input-sources]
sources=[('xkb', '$KEYBOARD_LAYOUT')]
EOF
dconf update 2>/dev/null || true

# Timezone
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
echo "$TIMEZONE" > /etc/timezone

# GRUB
cat > /etc/default/grub << 'GRUBCFG'
GRUB_DEFAULT=0
GRUB_TIMEOUT=10
GRUB_TIMEOUT_STYLE=menu
GRUB_DISTRIBUTOR="Linux Mint"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""
GRUB_DISABLE_OS_PROBER=true
GRUB_RECORDFAIL_TIMEOUT=10
GRUBCFG

rm -f /etc/default/grub.d/50_linuxmint.cfg 2>/dev/null || true

WIN_BOOT_UUID=""
for pn in 1 2 3 4; do
    [[ "$DISKNAME" == nvme* ]] || [[ "$DISKNAME" == mmcblk* ]] && pdev="${DISK}p${pn}" || pdev="${DISK}${pn}"
    [ -b "$pdev" ] || continue
    pfs=$(blkid -s TYPE -o value "$pdev" 2>/dev/null || echo "")
    if [ "$pfs" = "ntfs" ]; then
        tmpmnt=$(mktemp -d)
        mount -t ntfs-3g -o ro "$pdev" "$tmpmnt" 2>/dev/null || continue
        if [ -f "$tmpmnt/bootmgr" ]; then
            WIN_BOOT_UUID=$(blkid -s UUID -o value "$pdev")
            umount "$tmpmnt"; rmdir "$tmpmnt"
            break
        fi
        umount "$tmpmnt" 2>/dev/null || true
        rmdir "$tmpmnt" 2>/dev/null || true
    fi
done

if [ -n "$WIN_BOOT_UUID" ]; then
    cat > /etc/grub.d/40_custom << GRUBCUSTOM
#!/bin/sh
exec tail -n +3 \$0
menuentry "Windows 10" --class windows --class os {
    insmod part_msdos
    insmod ntfs
    insmod ntldr
    search --no-floppy --fs-uuid --set=root $WIN_BOOT_UUID
    ntldr /bootmgr
}
GRUBCUSTOM
    chmod +x /etc/grub.d/40_custom
else
    sed -i 's/GRUB_DISABLE_OS_PROBER=true/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
fi

grub-install --target=i386-pc --recheck "$DISK" || true
os-prober 2>/dev/null || true
update-grub 2>/dev/null || true

# First boot resize
cat > /usr/local/bin/first-boot-resize.sh << 'FIRSTBOOT'
#!/bin/bash
LOG="/tmp/first-boot-resize.log"
echo "First boot resize - \$(date)" > "\$LOG"
ROOT_DEV=\$(findmnt -n -o SOURCE /)
resize2fs "\$ROOT_DEV" >> "\$LOG" 2>&1
systemctl disable first-boot-resize.service
rm -f /etc/systemd/system/first-boot-resize.service /usr/local/bin/first-boot-resize.sh
FIRSTBOOT
chmod +x /usr/local/bin/first-boot-resize.sh

cat > /etc/systemd/system/first-boot-resize.service << 'SERVICEUNIT'
[Unit]
Description=Resize root filesystem on first boot
After=local-fs.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/first-boot-resize.sh
RemainAfterExit=no
[Install]
WantedBy=multi-user.target
SERVICEUNIT
systemctl enable first-boot-resize.service
CHROOTSCRIPT

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
INSTALLSCRIPT

chmod +x "$WORKDIR/chroot/install-mint.sh"

cat > "$WORKDIR/chroot/usr/local/sbin/libertix-runner" << 'RUNNERSCRIPT'
#!/bin/bash
set -u

LOG_DIR="/run/libertix"
LOG="$LOG_DIR/install.log"
DEBUG_LOG="$LOG_DIR/debug.log"
STAGE_FILE="$LOG_DIR/stage"
FAIL_FILE="$LOG_DIR/failure"

mkdir -p "$LOG_DIR"
touch "$LOG" "$DEBUG_LOG"
echo "runner-start" > "$STAGE_FILE"

tty_write() {
    local tty="$1"
    shift
    [ -e "$tty" ] || return 0
    {
        printf '\033c'
        printf '%s\n' "============================================================"
        printf '%s\n' " Libertix / Libertix automatic installer"
        printf '%s\n' "============================================================"
        printf 'Time: %s\n' "$(date -Is 2>/dev/null || date)"
        printf 'Build: %s\n' "$(cat /etc/libertix-build-id 2>/dev/null || echo unknown)"
        printf 'Stage: %s\n' "$(cat "$STAGE_FILE" 2>/dev/null || echo unknown)"
        printf '%s\n' "------------------------------------------------------------"
        printf '%s\n' "$@"
        printf '%s\n' "------------------------------------------------------------"
        printf '%s\n' "Full log: /run/libertix/install.log"
        printf '%s\n' "Debug shell: Alt-F2 / tty2"
    } > "$tty" 2>/dev/null || true
}

progress_screen() {
    local tail_lines
    tail_lines="$(grep -E '^(STAGE|ERROR|OK:|rc=|Windows:|ISO found|Live partition|Setting MBR|Mounting|Extracting|Libertix build)' "$LOG" 2>/dev/null | tail -14 || true)"
    [ -n "$tail_lines" ] || tail_lines="$(tail -12 "$LOG" 2>/dev/null || true)"
    tty_write /dev/tty1 "$tail_lines"
    tty_write /dev/ttyS0 "$tail_lines"
}

collect_debug() {
    {
        echo "===== collect_debug $(date -Is 2>/dev/null || date) ====="
        echo "--- stage ---"
        cat "$STAGE_FILE" 2>/dev/null || true
        echo "--- failure ---"
        cat "$FAIL_FILE" 2>/dev/null || true
        echo "--- cmdline ---"
        cat /proc/cmdline 2>/dev/null || true
        echo "--- lsblk ---"
        lsblk -e7 -o NAME,MAJ:MIN,PKNAME,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS 2>/dev/null || true
        echo "--- findmnt ---"
        findmnt -rn -o SOURCE,TARGET,FSTYPE,OPTIONS 2>/dev/null || true
        echo "--- /proc/partitions ---"
        cat /proc/partitions 2>/dev/null || true
        echo "--- /proc/swaps ---"
        cat /proc/swaps 2>/dev/null || true
        echo "--- losetup ---"
        losetup -a 2>/dev/null || true
        echo "--- dmesg tail ---"
        dmesg | tail -200 2>/dev/null || true
        echo "--- journal libertix ---"
        journalctl -b -u libertix-install.service --no-pager 2>/dev/null || true
    } >> "$DEBUG_LOG" 2>&1
}

copy_logs_to_windows_best_effort() {
    local win="" p fs size_mb tmp

    for p in /dev/sd*[0-9] /dev/nvme*n*p[0-9]; do
        [ -b "$p" ] || continue
        fs="$(blkid -s TYPE -o value "$p" 2>/dev/null || true)"
        [ "$fs" = "ntfs" ] || continue
        size_mb=$(( $(blockdev --getsize64 "$p" 2>/dev/null || echo 0) / 1024 / 1024 ))
        [ "$size_mb" -gt 1000 ] || continue
        win="$p"
        break
    done

    [ -n "$win" ] || return 0
    tmp="/mnt/libertix-logcopy"
    mkdir -p "$tmp"
    if mount -t ntfs-3g "$win" "$tmp" 2>/dev/null; then
        mkdir -p "$tmp/Windows/Temp/Libertix" 2>/dev/null || true
        cp -f "$LOG" "$tmp/Windows/Temp/Libertix/live-install.log" 2>/dev/null || true
        cp -f "$DEBUG_LOG" "$tmp/Windows/Temp/Libertix/live-debug.log" 2>/dev/null || true
        cp -f "$STAGE_FILE" "$tmp/Windows/Temp/Libertix/live-stage.txt" 2>/dev/null || true
        cp -f "$FAIL_FILE" "$tmp/Windows/Temp/Libertix/live-failure.txt" 2>/dev/null || true
        sync
        umount "$tmp" 2>/dev/null || true
    fi
}

tty_write /dev/tty1 "Starting Libertix installer..."
tty_write /dev/ttyS0 "Starting Libertix installer..."

(
    echo "===== libertix installer started $(date -Is 2>/dev/null || date) ====="
    echo "build=$(cat /etc/libertix-build-id 2>/dev/null || echo unknown)"
    /install-mint.sh
) >> "$LOG" 2>&1 &
pid="$!"

while kill -0 "$pid" 2>/dev/null; do
    progress_screen
    sleep 5
done

wait "$pid"
rc="$?"

if [ "$rc" -eq 0 ]; then
    echo "installer-success" > "$STAGE_FILE"
    progress_screen
    tty_write /dev/tty1 "INSTALLATION COMPLETED. Rebooting in 5 seconds."
    sleep 5
    systemctl reboot -i
    exit 0
fi

echo "installer-failed-rc-$rc" > "$STAGE_FILE"
echo "rc=$rc" > "$FAIL_FILE"
collect_debug
copy_logs_to_windows_best_effort

while true; do
    tail_lines="$(tail -18 "$LOG" 2>/dev/null || true)"
    tty_write /dev/tty1 "ERROR: Libertix installer failed with rc=$rc

Stage: $(cat "$STAGE_FILE" 2>/dev/null || echo unknown)

Last install log lines:
$tail_lines

The VM is intentionally paused here for screenshot/debug."
    tty_write /dev/ttyS0 "ERROR: Libertix installer failed with rc=$rc

Stage: $(cat "$STAGE_FILE" 2>/dev/null || echo unknown)

Last install log lines:
$tail_lines"
    sleep 10
done
RUNNERSCRIPT

chmod +x "$WORKDIR/chroot/usr/local/sbin/libertix-runner"

cat > "$WORKDIR/chroot/etc/systemd/system/libertix-install.service" << 'SERVICEUNIT'
[Unit]
Description=Libertix automatic Mint installer
After=local-fs.target systemd-udev-settle.service
Wants=local-fs.target systemd-udev-settle.service
ConditionPathExists=/usr/local/sbin/libertix-runner

[Service]
Type=simple
ExecStartPre=/bin/udevadm settle
ExecStart=/usr/local/sbin/libertix-runner
StandardInput=null
StandardOutput=journal
StandardError=journal
Restart=no
TimeoutStartSec=0
KillMode=mixed

[Install]
WantedBy=multi-user.target
SERVICEUNIT

mkdir -p "$WORKDIR/chroot/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/libertix-install.service \
    "$WORKDIR/chroot/etc/systemd/system/multi-user.target.wants/libertix-install.service"

mkdir -p "$WORKDIR/chroot/etc/systemd/system/getty@tty2.service.d"
cat > "$WORKDIR/chroot/etc/systemd/system/getty@tty2.service.d/override.conf" << 'TTY2SERVICE'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear tty2 linux
Type=idle
TTY2SERVICE

mkdir -p "$WORKDIR/chroot/etc/systemd/system/getty.target.wants"
ln -sf /lib/systemd/system/getty@.service \
    "$WORKDIR/chroot/etc/systemd/system/getty.target.wants/getty@tty2.service"

BUILD_GIT="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
if ! git diff --quiet 2>/dev/null; then
    BUILD_GIT="${BUILD_GIT}-dirty"
fi
BUILD_ID="$(date -u +%Y%m%d-%H%M%S)-${BUILD_GIT}"
echo "$BUILD_ID" > "$WORKDIR/chroot/etc/libertix-build-id"
echo "$BUILD_ID" > "$WORKDIR/iso_build/libertix-build-id.txt"
cat > "$WORKDIR/chroot/etc/motd" << EOF
Libertix build: $BUILD_ID
EOF

echo "=== Unmounting chroot ==="
umount "$WORKDIR/chroot/dev/pts" 2>/dev/null || true
umount "$WORKDIR/chroot/dev" 2>/dev/null || true
umount "$WORKDIR/chroot/proc" 2>/dev/null || true
umount "$WORKDIR/chroot/sys" 2>/dev/null || true

# Create config.txt
cat > "$WORKDIR/iso_build/config.txt" << CONFIGFILE
SYSTEM_LANG="$SYSTEM_LANG"
KEYBOARD_LAYOUT="$KEYBOARD_LAYOUT"
KEYBOARD_MODEL="$KEYBOARD_MODEL"
TIMEZONE="$TIMEZONE"
USERNAME="$USERNAME"
PASSWORD="$PASSWORD"
COMPUTER_NAME="mint-pc"
ISO_FILENAME="$ISO_FILENAME"
LINUX_SIZE_GB="30"
CONFIGFILE

echo "=== Creating squashfs ==="
mkdir -p "$WORKDIR/iso_build/live"
mksquashfs "$WORKDIR/chroot" "$WORKDIR/iso_build/live/filesystem.squashfs" -comp xz -b 1M -e boot

cp "$WORKDIR/chroot/boot/vmlinuz-"* "$WORKDIR/iso_build/live/vmlinuz"
cp "$WORKDIR/chroot/boot/initrd.img-"* "$WORKDIR/iso_build/live/initrd.img"

echo "=== Configuring ISOLINUX ==="
mkdir -p "$WORKDIR/iso_build/isolinux"
cp /usr/lib/ISOLINUX/isolinux.bin "$WORKDIR/iso_build/isolinux/"
cp /usr/lib/syslinux/modules/bios/*.c32 "$WORKDIR/iso_build/isolinux/"

cat > "$WORKDIR/iso_build/isolinux/isolinux.cfg" << 'EOF'
UI menu.c32
PROMPT 0
TIMEOUT 30
DEFAULT live
MENU TITLE Libertix Installer
LABEL live
    MENU LABEL Install Linux Mint (Automatic)
    KERNEL /live/vmlinuz
    APPEND initrd=/live/initrd.img boot=live toram components quiet loglevel=3 systemd.show_status=0 console=tty1 console=ttyS0,115200n8
LABEL live-verbose
    MENU LABEL Install (Verbose mode)
    KERNEL /live/vmlinuz
    APPEND initrd=/live/initrd.img boot=live toram components systemd.show_status=1 loglevel=7 console=tty1 console=ttyS0,115200n8
EOF

echo "=== Configuring GRUB EFI ==="
mkdir -p "$WORKDIR/iso_build/boot/grub" "$WORKDIR/iso_build/EFI/BOOT"

cat > "$WORKDIR/iso_build/boot/grub/grub.cfg" << 'EOF'
set timeout=5
set default=0
menuentry "Install Linux Mint (Automatic)" {
    linux /live/vmlinuz boot=live toram components quiet loglevel=3 systemd.show_status=0 console=tty1 console=ttyS0,115200n8
    initrd /live/initrd.img
}
menuentry "Install (Verbose mode)" {
    linux /live/vmlinuz boot=live toram components systemd.show_status=1 loglevel=7 console=tty1 console=ttyS0,115200n8
    initrd /live/initrd.img
}
EOF

grub-mkstandalone --format=x86_64-efi \
    --output="$WORKDIR/iso_build/EFI/BOOT/bootx64.efi" \
    --locales="" --fonts="" \
    "boot/grub/grub.cfg=$WORKDIR/iso_build/boot/grub/grub.cfg"

dd if=/dev/zero of="$WORKDIR/iso_build/boot/grub/efi.img" bs=1M count=10
mkfs.vfat "$WORKDIR/iso_build/boot/grub/efi.img"
mmd -i "$WORKDIR/iso_build/boot/grub/efi.img" ::/EFI ::/EFI/BOOT
mcopy -i "$WORKDIR/iso_build/boot/grub/efi.img" \
    "$WORKDIR/iso_build/EFI/BOOT/bootx64.efi" ::/EFI/BOOT/

echo "=== Creating ISO ==="
xorriso -as mkisofs \
    -r -J -joliet-long \
    -V "LIBERTIX_INSTALLER" \
    -o ./libertix-installer.iso \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -c isolinux/boot.cat \
    -b isolinux/isolinux.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
    -no-emul-boot -isohybrid-gpt-basdat \
    "$WORKDIR/iso_build"

rm -rf "$WORKDIR"

echo "=== Done: libertix-installer.iso ($(du -h ./libertix-installer.iso | cut -f1)) ==="
