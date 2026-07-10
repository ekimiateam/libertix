#!/bin/bash
set +e
export LANG=C
export LC_ALL=C
exec 2>&1

section() { printf '\n===== %s =====\n' "$1"; }
run() { printf '\n$ %s\n' "$*"; "$@"; printf '[rc=%s]\n' "$?"; }
sudo_run() { printf '\n# %s\n' "$*"; printf 'test\n' | sudo -S -p '' "$@"; printf '[rc=%s]\n' "$?"; }

section "IDENTITY"
run date --iso-8601=seconds
run id
run hostnamectl
run cat /etc/os-release
run uname -a

section "BLOCK DEVICES AND FILESYSTEMS"
run lsblk -e 7 -o NAME,SIZE,TYPE,FSTYPE,FSVER,LABEL,UUID,PARTUUID,PARTTYPE,MOUNTPOINTS
run findmnt -R /
run findmnt /mnt/windows
run df -hT
sudo_run blkid
sudo_run fdisk -l /dev/sda
sudo_run parted -s /dev/sda unit B print
root_device="$(findmnt -n -o SOURCE /)"
printf 'ROOT_DEVICE=%s\n' "$root_device"
if [[ "$root_device" == /dev/* ]]; then
    sudo_run tune2fs -l "$root_device"
fi

section "BOOT CONFIGURATION"
run cat /etc/default/grub
sudo_run grep -nE 'timeout|menuentry .(Linux Mint|Windows)' /boot/grub/grub.cfg
if [[ -d /sys/firmware/efi ]]; then
    sudo_run efibootmgr -v
else
    echo "FIRMWARE_MODE=BIOS"
fi

section "PACKAGE INTEGRITY"
sudo_run dpkg --audit
sudo_run apt-get check
run dpkg-query -W -f '${db:Status-Abbrev} ${binary:Package} ${Version}\n'

section "SYSTEMD AND BOOT ERRORS"
run systemctl is-system-running
run systemctl --failed --no-pager
sudo_run journalctl -b -p err --no-pager

section "LIBERTIX MARKERS AND LOGS"
sudo_run find /var/lib /var/log -maxdepth 3 -type f -iname '*libertix*' -print
for log in /var/log/libertix*.log /var/lib/libertix/*; do
    if [[ -f "$log" ]]; then
        echo "--- $log ---"
        sudo_run tail -n 120 "$log"
    fi
done

section "NETWORK"
run ip -brief address
run ip route

section "SUMMARY"
echo "LINUX_INTEGRITY_SCRIPT_COMPLETED=true"
