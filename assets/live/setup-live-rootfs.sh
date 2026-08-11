#!/bin/bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# The rootfs is a throwaway build artifact, so dpkg does not need to fsync.
export DPKG_FORCE="${DPKG_FORCE:-unsafe-io}"

firmware_mode="${LIBERTIX_FIRMWARE_MODE:?LIBERTIX_FIRMWARE_MODE is required}"
# When the builder bind mounts a shared .deb cache over the apt archives, this
# script must leave it alone; the caller empties the chroot copy after unmount.
keep_apt_cache="${LIBERTIX_KEEP_APT_CACHE:-0}"
packages=(
    linux-image-amd64 live-boot live-boot-initramfs-tools live-config
    live-config-systemd systemd-sysv initramfs-tools parted fdisk e2fsprogs
    squashfs-tools dosfstools ntfs-3g python3-hivex python3-jsonschema sudo nano util-linux coreutils
    psmisc lsof xserver-xorg-core xserver-xorg-input-libinput xserver-xorg-video-vesa
    xserver-xorg-video-fbdev x11-xserver-utils python3-tk kbd
    fonts-dejavu-core fonts-noto-cjk imagemagick grub-common plymouth
)
if [ "$firmware_mode" = "uefi" ]; then
    packages+=(efibootmgr shim-signed grub-efi-amd64-bin grub-efi-amd64-signed)
elif [ "$firmware_mode" != "bios" ]; then
    echo "Unsupported LIBERTIX_FIRMWARE_MODE: $firmware_mode" >&2
    exit 2
fi

apt_options=(
    -o Acquire::Check-Valid-Until=false
    -o Acquire::Languages=none
    -o Dpkg::Use-Pty=0
    # The apt CLI defaults to discarding downloaded .deb files, unlike apt-get.
    # The shared build cache only fills up when they are kept.
    -o APT::Keep-Downloaded-Packages=true
)

apt "${apt_options[@]}" update
apt "${apt_options[@]}" install -y "${packages[@]}"

# xterm is not needed and can appear as a confusing default X client.
apt purge -y xterm 2>/dev/null || true
apt autoremove -y 2>/dev/null || true

# tty1 belongs exclusively to the Libertix renderer. A login getty would race
# with the first fallback frame and briefly expose a root prompt.
ln -sf /dev/null /etc/systemd/system/getty@tty1.service
rm -f /etc/systemd/system/getty.target.wants/getty@tty1.service

# Keep kernel messages available on ttyS0, but do not start a login prompt on
# machines that advertise a serial console without a usable serial terminal.
# Otherwise serial-getty restarts every ten seconds and pollutes diagnostics.
ln -sf /dev/null /etc/systemd/system/serial-getty@ttyS0.service

/usr/local/lib/libertix/configure-live-boot-splash
update-initramfs -u -k all
lsinitramfs /boot/initrd.img-* 2>/dev/null | grep -E "live" | head -5 || true

useradd -m -s /bin/bash -G sudo user 2>/dev/null || true
echo "user:live" | chpasswd
echo "user ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

if [ "$keep_apt_cache" != "1" ]; then
    apt clean
    rm -rf /var/lib/apt/lists/*
fi
