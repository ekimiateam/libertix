#!/bin/bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISO_DIR="$ROOT_DIR/iso"

source "$ISO_DIR/config/defaults.env"

require_root() {
    [ "$EUID" -eq 0 ] || { echo "Run with sudo!"; exit 1; }
}

install_build_dependencies() {
    echo "=== Installing build dependencies ==="
    apt update
    apt install -y debootstrap squashfs-tools xorriso isolinux syslinux-utils \
        grub-pc-bin grub-efi-amd64-bin mtools dosfstools
}

prepare_workdir() {
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"/{chroot,iso_build}
}

bootstrap_live_system() {
    echo "=== Creating minimal Debian system ==="
    debootstrap --variant=minbase stable "$WORKDIR/chroot" http://deb.debian.org/debian/
}

mount_chroot_filesystems() {
    echo "=== Mounting filesystems ==="
    mount -t proc none "$WORKDIR/chroot/proc"
    mount -t sysfs none "$WORKDIR/chroot/sys"
    mount --bind /dev "$WORKDIR/chroot/dev"
    mount --bind /dev/pts "$WORKDIR/chroot/dev/pts"
}

unmount_chroot_filesystems() {
    echo "=== Unmounting chroot ==="
    umount "$WORKDIR/chroot/dev/pts" 2>/dev/null || true
    umount "$WORKDIR/chroot/dev" 2>/dev/null || true
    umount "$WORKDIR/chroot/proc" 2>/dev/null || true
    umount "$WORKDIR/chroot/sys" 2>/dev/null || true
}

configure_live_system() {
    echo "=== Installing packages in live system ==="
    install -m 0755 "$ISO_DIR/live/setup-live-rootfs.sh" "$WORKDIR/chroot/setup.sh"
    chroot "$WORKDIR/chroot" /setup.sh
    rm -f "$WORKDIR/chroot/setup.sh"

    mkdir -p "$WORKDIR/chroot/etc/live"
    echo "LIVE_MEDIA_PATH=/live" > "$WORKDIR/chroot/etc/live/boot.conf"
}

install_live_installer_assets() {
    install -m 0755 "$ISO_DIR/live/install-mint.sh" "$WORKDIR/chroot/install-mint.sh"
    install -m 0755 -D "$ISO_DIR/live/libertix-runner.sh" \
        "$WORKDIR/chroot/usr/local/sbin/libertix-runner"
    install -m 0755 -D "$ISO_DIR/target/configure-target.sh" \
        "$WORKDIR/chroot/usr/local/lib/libertix/configure-target.sh"
    install -m 0755 -D "$ISO_DIR/target/first-boot-resize.sh" \
        "$WORKDIR/chroot/usr/local/lib/libertix/first-boot-resize.sh"
    install -m 0644 -D "$ISO_DIR/target/first-boot-resize.service" \
        "$WORKDIR/chroot/usr/local/lib/libertix/first-boot-resize.service"

    install -m 0644 -D "$ISO_DIR/systemd/libertix-install.service" \
        "$WORKDIR/chroot/etc/systemd/system/libertix-install.service"
    mkdir -p "$WORKDIR/chroot/etc/systemd/system/multi-user.target.wants"
    ln -sf /etc/systemd/system/libertix-install.service \
        "$WORKDIR/chroot/etc/systemd/system/multi-user.target.wants/libertix-install.service"

    install -m 0644 -D "$ISO_DIR/systemd/getty-tty2-override.conf" \
        "$WORKDIR/chroot/etc/systemd/system/getty@tty2.service.d/override.conf"
    mkdir -p "$WORKDIR/chroot/etc/systemd/system/getty.target.wants"
    ln -sf /lib/systemd/system/getty@.service \
        "$WORKDIR/chroot/etc/systemd/system/getty.target.wants/getty@tty2.service"
}

write_build_id() {
    local build_git build_id
    build_git="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo nogit)"
    if ! git -C "$ROOT_DIR" diff --quiet 2>/dev/null; then
        build_git="${build_git}-dirty"
    fi
    build_id="$(date -u +%Y%m%d-%H%M%S)-${build_git}"

    echo "$build_id" > "$WORKDIR/chroot/etc/libertix-build-id"
    echo "$build_id" > "$WORKDIR/iso_build/libertix-build-id.txt"
    cat > "$WORKDIR/chroot/etc/motd" <<EOF
Libertix build: $build_id
EOF
}

write_live_config() {
    cat > "$WORKDIR/iso_build/config.txt" <<CONFIGFILE
SYSTEM_LANG="$SYSTEM_LANG"
KEYBOARD_LAYOUT="$KEYBOARD_LAYOUT"
KEYBOARD_MODEL="$KEYBOARD_MODEL"
TIMEZONE="$TIMEZONE"
USERNAME="$USERNAME"
PASSWORD="$PASSWORD"
COMPUTER_NAME="$COMPUTER_NAME"
ISO_FILENAME="$ISO_FILENAME"
LINUX_SIZE_GB="$LINUX_SIZE_GB"
CONFIGFILE
}

build_squashfs() {
    echo "=== Creating squashfs ==="
    mkdir -p "$WORKDIR/iso_build/live"
    mksquashfs "$WORKDIR/chroot" "$WORKDIR/iso_build/live/filesystem.squashfs" \
        -comp xz -b 1M -e boot

    cp "$WORKDIR/chroot/boot/vmlinuz-"* "$WORKDIR/iso_build/live/vmlinuz"
    cp "$WORKDIR/chroot/boot/initrd.img-"* "$WORKDIR/iso_build/live/initrd.img"
}

configure_isolinux() {
    echo "=== Configuring ISOLINUX ==="
    mkdir -p "$WORKDIR/iso_build/isolinux"
    cp /usr/lib/ISOLINUX/isolinux.bin "$WORKDIR/iso_build/isolinux/"
    cp /usr/lib/syslinux/modules/bios/*.c32 "$WORKDIR/iso_build/isolinux/"
    install -m 0644 "$ISO_DIR/boot/isolinux.cfg" "$WORKDIR/iso_build/isolinux/isolinux.cfg"
}

configure_grub_efi() {
    echo "=== Configuring GRUB EFI ==="
    mkdir -p "$WORKDIR/iso_build/boot/grub" "$WORKDIR/iso_build/EFI/BOOT"
    install -m 0644 "$ISO_DIR/boot/grub.cfg" "$WORKDIR/iso_build/boot/grub/grub.cfg"

    grub-mkstandalone --format=x86_64-efi \
        --output="$WORKDIR/iso_build/EFI/BOOT/bootx64.efi" \
        --locales="" --fonts="" \
        "boot/grub/grub.cfg=$WORKDIR/iso_build/boot/grub/grub.cfg"

    dd if=/dev/zero of="$WORKDIR/iso_build/boot/grub/efi.img" bs=1M count=10
    mkfs.vfat "$WORKDIR/iso_build/boot/grub/efi.img"
    mmd -i "$WORKDIR/iso_build/boot/grub/efi.img" ::/EFI ::/EFI/BOOT
    mcopy -i "$WORKDIR/iso_build/boot/grub/efi.img" \
        "$WORKDIR/iso_build/EFI/BOOT/bootx64.efi" ::/EFI/BOOT/
}

create_iso() {
    echo "=== Creating ISO ==="
    xorriso -as mkisofs \
        -r -J -joliet-long \
        -V "$VOLUME_ID" \
        -o "$ROOT_DIR/$OUTPUT_ISO" \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -c isolinux/boot.cat \
        -b isolinux/isolinux.bin \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -eltorito-alt-boot \
        -e boot/grub/efi.img \
        -no-emul-boot -isohybrid-gpt-basdat \
        "$WORKDIR/iso_build"
}

cleanup() {
    unmount_chroot_filesystems
    rm -rf "$WORKDIR"
}

main() {
    require_root
    trap cleanup EXIT

    install_build_dependencies
    prepare_workdir
    bootstrap_live_system
    mount_chroot_filesystems
    configure_live_system
    install_live_installer_assets
    write_build_id
    unmount_chroot_filesystems
    write_live_config
    build_squashfs
    configure_isolinux
    configure_grub_efi
    create_iso

    echo "=== Done: $OUTPUT_ISO ($(du -h "$ROOT_DIR/$OUTPUT_ISO" | cut -f1)) ==="
}

main "$@"
