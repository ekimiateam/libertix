#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

apt update
apt install -y linux-image-amd64 live-boot live-boot-initramfs-tools live-config \
    live-config-systemd systemd-sysv initramfs-tools parted fdisk e2fsprogs \
    squashfs-tools dosfstools ntfs-3g python3-hivex sudo nano util-linux coreutils \
    psmisc lsof xserver-xorg-core xserver-xorg-input-libinput xserver-xorg-video-vesa \
    xserver-xorg-video-fbdev xinit python3-tk kbd

# xterm is not needed and can appear as a confusing default X client.
apt purge -y xterm 2>/dev/null || true
apt autoremove -y 2>/dev/null || true

update-initramfs -u -k all
lsinitramfs /boot/initrd.img-* 2>/dev/null | grep -E "live" | head -5 || true

useradd -m -s /bin/bash -G sudo user 2>/dev/null || true
echo "user:live" | chpasswd
echo "user ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

apt clean
rm -rf /var/lib/apt/lists/*
