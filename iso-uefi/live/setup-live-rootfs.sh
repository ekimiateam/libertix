#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

firmware_mode="${LIBERTIX_FIRMWARE_MODE:?LIBERTIX_FIRMWARE_MODE is required}"
packages=(
    linux-image-amd64 live-boot live-boot-initramfs-tools live-config
    live-config-systemd systemd-sysv initramfs-tools parted fdisk e2fsprogs
    squashfs-tools dosfstools ntfs-3g python3-hivex sudo nano util-linux coreutils
    psmisc lsof xserver-xorg-core xserver-xorg-input-libinput xserver-xorg-video-vesa
    xserver-xorg-video-fbdev x11-xserver-utils python3-tk kbd
    imagemagick grub-common plymouth
)
if [ "$firmware_mode" = "uefi" ]; then
    packages+=(efibootmgr shim-signed grub-efi-amd64-bin grub-efi-amd64-signed)
elif [ "$firmware_mode" != "bios" ]; then
    echo "Unsupported LIBERTIX_FIRMWARE_MODE: $firmware_mode" >&2
    exit 2
fi

apt -o Acquire::Check-Valid-Until=false update
apt -o Acquire::Check-Valid-Until=false install -y "${packages[@]}"

# xterm is not needed and can appear as a confusing default X client.
apt purge -y xterm 2>/dev/null || true
apt autoremove -y 2>/dev/null || true

# tty1 belongs exclusively to the Libertix renderer. A login getty would race
# with the first fallback frame and briefly expose a root prompt.
ln -sf /dev/null /etc/systemd/system/getty@tty1.service
rm -f /etc/systemd/system/getty.target.wants/getty@tty1.service

/usr/local/lib/libertix/configure-live-boot-splash
update-initramfs -u -k all
lsinitramfs /boot/initrd.img-* 2>/dev/null | grep -E "live" | head -5 || true

useradd -m -s /bin/bash -G sudo user 2>/dev/null || true
echo "user:live" | chpasswd
echo "user ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

apt clean
rm -rf /var/lib/apt/lists/*
