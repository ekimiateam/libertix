#!/bin/bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIRMWARE_MODE="${LIBERTIX_BUILD_MODE:-bios}"
case "$FIRMWARE_MODE" in
    bios) ISO_DIR="$ROOT_DIR/iso" ;;
    uefi) ISO_DIR="$ROOT_DIR/iso-uefi" ;;
    *) echo "Unsupported LIBERTIX_BUILD_MODE: $FIRMWARE_MODE" >&2; exit 2 ;;
esac

source "$ISO_DIR/config/defaults.env"

require_container_root() {
    [ "$EUID" -eq 0 ] && [ -f /.dockerenv ] || {
        echo "Build this ISO with iso-tools/build-isos-docker.sh $FIRMWARE_MODE" >&2
        exit 1
    }
}

require_build_dependencies() {
    local command missing=()
    local commands=(debootstrap mksquashfs xorriso mmd mcopy mkfs.vfat)
    if [ "$FIRMWARE_MODE" = "bios" ]; then
        commands+=(grub-mkstandalone)
    else
        commands+=(sha256sum)
    fi
    for command in "${commands[@]}"; do
        command -v "$command" >/dev/null 2>&1 || missing+=("$command")
    done
    [ -f /usr/lib/ISOLINUX/isolinux.bin ] || missing+=("isolinux.bin")
    [ -f /usr/lib/ISOLINUX/isohdpfx.bin ] || missing+=("isohdpfx.bin")
    [ "${#missing[@]}" -eq 0 ] || {
        printf 'Missing ISO build prerequisites: %s\n' "${missing[*]}" >&2
        exit 1
    }
}

prepare_workdir() {
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"/{chroot,iso_build}
}

bootstrap_live_system() {
    local snapshot="${LIBERTIX_DEBIAN_SNAPSHOT:?LIBERTIX_DEBIAN_SNAPSHOT is required}"
    local suite="${LIBERTIX_DEBIAN_SUITE:?LIBERTIX_DEBIAN_SUITE is required}"
    local mirror="http://snapshot.debian.org/archive/debian/${snapshot}/"

    echo "=== Creating minimal Debian system ==="
    debootstrap --variant=minbase "$suite" "$WORKDIR/chroot" "$mirror"
    cat > "$WORKDIR/chroot/etc/apt/sources.list" <<EOF
deb [check-valid-until=no] $mirror $suite main
EOF
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
    install -m 0755 -D "$ROOT_DIR/assets/plymouth/configure-live-boot-splash.sh" \
        "$WORKDIR/chroot/usr/local/lib/libertix/configure-live-boot-splash"
    install -m 0644 -D "$ROOT_DIR/assets/plymouth/libertix.plymouth" \
        "$WORKDIR/chroot/usr/share/plymouth/themes/libertix/libertix.plymouth"
    install -m 0644 -D "$ROOT_DIR/assets/plymouth/libertix.script" \
        "$WORKDIR/chroot/usr/share/plymouth/themes/libertix/libertix.script"
    install -m 0644 -D "$ROOT_DIR/assets/grub-theme/right_down_border.png" \
        "$WORKDIR/chroot/usr/share/plymouth/themes/libertix/logo.png"
    install -m 0755 "$ROOT_DIR/iso-uefi/live/setup-live-rootfs.sh" "$WORKDIR/chroot/setup.sh"
    chroot "$WORKDIR/chroot" /usr/bin/env LIBERTIX_FIRMWARE_MODE="$FIRMWARE_MODE" /setup.sh
    rm -f "$WORKDIR/chroot/setup.sh"

    mkdir -p "$WORKDIR/chroot/etc/live"
    echo "LIVE_MEDIA_PATH=/live" > "$WORKDIR/chroot/etc/live/boot.conf"
}

install_live_installer_assets() {
    install -m 0755 "$ISO_DIR/live/install-mint.sh" "$WORKDIR/chroot/install-mint.sh"
    install -m 0755 -D "$ISO_DIR/live/libertix-runner.sh" \
        "$WORKDIR/chroot/usr/local/sbin/libertix-runner"
    install -m 0755 -D "$ROOT_DIR/iso-uefi/live/libertix-gui.py" \
        "$WORKDIR/chroot/usr/local/sbin/libertix-gui"
    install -m 0755 -D "$ROOT_DIR/assets/live/libertix-copy-logs.sh" \
        "$WORKDIR/chroot/usr/local/sbin/libertix-copy-logs"
    install -m 0755 -D "$ROOT_DIR/assets/live/libertix-install-platform-common.sh" \
        "$WORKDIR/chroot/usr/local/lib/libertix/libertix-install-platform-common.sh"
    install -m 0755 -D "$ROOT_DIR/assets/live/libertix-runner-stage-common.sh" \
        "$WORKDIR/chroot/usr/local/lib/libertix/libertix-runner-stage-common.sh"
    install -m 0755 -D "$ISO_DIR/live/cleanup-bcd.py" \
        "$WORKDIR/chroot/usr/local/lib/libertix/cleanup-bcd.py"
    install -m 0755 -D "$ISO_DIR/target/configure-target.sh" \
        "$WORKDIR/chroot/usr/local/lib/libertix/configure-target.sh"
    install -m 0755 -D "$ROOT_DIR/grub/10_libertix" \
        "$WORKDIR/chroot/usr/local/lib/libertix/10_libertix"
    install -m 0755 -D "$ROOT_DIR/grub/render-libertix-menu.py" \
        "$WORKDIR/chroot/usr/local/lib/libertix/render-libertix-menu.py"
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
    cp -a "$ROOT_DIR/assets/grub-theme" \
        "$WORKDIR/chroot/usr/local/lib/libertix/grub-theme-source"
    mkdir -p "$WORKDIR/chroot/etc/systemd/system/getty.target.wants"
    ln -sf /lib/systemd/system/getty@.service \
        "$WORKDIR/chroot/etc/systemd/system/getty.target.wants/getty@tty2.service"
}

write_build_id() {
    local build_git build_id
    build_git="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo nogit)"
    if [ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal 2>/dev/null)" ]; then
        build_git="${build_git}-dirty"
    fi
    build_id="$(date -u +%Y%m%d-%H%M%S)-${build_git}"

    echo "$build_id" > "$WORKDIR/chroot/etc/libertix-build-id"
    echo "$build_id" > "$WORKDIR/iso_build/libertix-build-id.txt"
    cat > "$WORKDIR/chroot/etc/motd" <<EOF
Libertix build: $build_id
EOF
    chroot "$WORKDIR/chroot" dpkg-query -W -f='${Package}=${Version}\n' \
        | LC_ALL=C sort > "$WORKDIR/iso_build/libertix-packages.txt"
}

write_live_config() {
    shell_quote() {
        printf '%q' "$1"
    }
    cat > "$WORKDIR/iso_build/config.txt" <<CONFIGFILE
SYSTEM_LANG=$(shell_quote "$SYSTEM_LANG")
KEYBOARD_LAYOUT=$(shell_quote "$KEYBOARD_LAYOUT")
KEYBOARD_MODEL=$(shell_quote "$KEYBOARD_MODEL")
TIMEZONE=$(shell_quote "$TIMEZONE")
USERNAME=$(shell_quote "$USERNAME")
PASSWORD_HASH=$(shell_quote "$PASSWORD_HASH")
COMPUTER_NAME=$(shell_quote "$COMPUTER_NAME")
ISO_FILENAME=$(shell_quote "$ISO_FILENAME")
LINUX_SIZE_GB=$(shell_quote "$LINUX_SIZE_GB")
CONFIGFILE
}

build_squashfs() {
    echo "=== Creating squashfs ==="
    mkdir -p "$WORKDIR/iso_build/live"
    mksquashfs "$WORKDIR/chroot" "$WORKDIR/iso_build/live/filesystem.squashfs" \
        -comp xz -b 1M -e boot

    mapfile -t kernels < <(find "$WORKDIR/chroot/boot" -maxdepth 1 -type f -name 'vmlinuz-*' | sort)
    [ "${#kernels[@]}" -eq 1 ] || { echo "Expected exactly one kernel, found ${#kernels[@]}"; exit 1; }
    initrd="$WORKDIR/chroot/boot/initrd.img-${kernels[0]##*vmlinuz-}"
    [ -f "$initrd" ] || { echo "Missing initramfs for ${kernels[0]}"; exit 1; }
    cp "${kernels[0]}" "$WORKDIR/iso_build/live/vmlinuz"
    cp "$initrd" "$WORKDIR/iso_build/live/initrd.img"
}

configure_isolinux() {
    echo "=== Configuring ISOLINUX ==="
    mkdir -p "$WORKDIR/iso_build/isolinux"
    cp /usr/lib/ISOLINUX/isolinux.bin "$WORKDIR/iso_build/isolinux/"
    cp /usr/lib/syslinux/modules/bios/*.c32 "$WORKDIR/iso_build/isolinux/"
    install -m 0644 "$ISO_DIR/boot/isolinux.cfg" "$WORKDIR/iso_build/isolinux/isolinux.cfg"
}

configure_grub_efi() {
    if [ "$FIRMWARE_MODE" = "uefi" ]; then
        configure_signed_grub_efi
        return
    fi
    echo "=== Configuring GRUB EFI ==="
    mkdir -p "$WORKDIR/iso_build/boot/grub" "$WORKDIR/iso_build/EFI/BOOT"
    install -m 0644 "$ISO_DIR/boot/grub.cfg" "$WORKDIR/iso_build/boot/grub/grub.cfg"
    mkdir -p "$WORKDIR/iso_build/boot/grub/themes"
    cp -a "$ROOT_DIR/assets/grub-theme" \
        "$WORKDIR/iso_build/boot/grub/themes/Libertix"

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

configure_signed_grub_efi() {
    echo "=== Configuring signed GRUB EFI ==="
    local shim_efi grub_efi mok_efi
    if [ -f "$ISO_DIR/assets/debian-dual-signed/shimx64.efi.signed" ]; then
        shim_efi="$ISO_DIR/assets/debian-dual-signed/shimx64.efi.signed"
        mok_efi="$ISO_DIR/assets/debian-dual-signed/mmx64.efi.signed"
    else
        shim_efi="/usr/lib/shim/shimx64.efi.signed"
        mok_efi="/usr/lib/shim/mmx64.efi.signed"
    fi
    grub_efi="/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed"

    [ -f "$shim_efi" ] || { echo "Missing $shim_efi"; exit 1; }
    [ -f "$grub_efi" ] || { echo "Missing $grub_efi"; exit 1; }
    [ -f "$mok_efi" ] || { echo "Missing $mok_efi"; exit 1; }

    mkdir -p "$WORKDIR/iso_build/boot/grub" \
        "$WORKDIR/iso_build/EFI/BOOT" \
        "$WORKDIR/iso_build/EFI/debian" \
        "$WORKDIR/iso_build/EFI/LibertixInstaller"
    install -m 0644 "$ISO_DIR/boot/grub.cfg" "$WORKDIR/iso_build/boot/grub/grub.cfg"
    mkdir -p "$WORKDIR/iso_build/boot/grub/themes"
    cp -a "$ROOT_DIR/assets/grub-theme" \
        "$WORKDIR/iso_build/boot/grub/themes/Libertix"
    install -m 0644 "$ISO_DIR/boot/grub.cfg" "$WORKDIR/iso_build/EFI/debian/grub.cfg"
    install -m 0644 "$ISO_DIR/boot/grub.cfg" "$WORKDIR/iso_build/EFI/LibertixInstaller/grub.cfg"
    install -m 0644 "$shim_efi" "$WORKDIR/iso_build/EFI/BOOT/BOOTX64.EFI"
    install -m 0644 "$grub_efi" "$WORKDIR/iso_build/EFI/BOOT/grubx64.efi"
    install -m 0644 "$mok_efi" "$WORKDIR/iso_build/EFI/BOOT/mmx64.efi"
    install -m 0644 "$shim_efi" "$WORKDIR/iso_build/EFI/debian/shimx64.efi"
    install -m 0644 "$grub_efi" "$WORKDIR/iso_build/EFI/debian/grubx64.efi"
    install -m 0644 "$mok_efi" "$WORKDIR/iso_build/EFI/debian/mmx64.efi"
    install -m 0644 "$shim_efi" "$WORKDIR/iso_build/EFI/LibertixInstaller/shimx64.efi"
    install -m 0644 "$grub_efi" "$WORKDIR/iso_build/EFI/LibertixInstaller/grubx64.efi"
    install -m 0644 "$mok_efi" "$WORKDIR/iso_build/EFI/LibertixInstaller/mmx64.efi"

    sha256sum "$shim_efi" "$grub_efi" "$mok_efi" \
        > "$WORKDIR/iso_build/libertix-efi-assets.sha256"
    dd if=/dev/zero of="$WORKDIR/iso_build/boot/grub/efi.img" bs=1M count=20
    mkfs.vfat "$WORKDIR/iso_build/boot/grub/efi.img"
    mmd -i "$WORKDIR/iso_build/boot/grub/efi.img" \
        ::/EFI ::/EFI/BOOT ::/EFI/debian ::/EFI/LibertixInstaller \
        ::/boot ::/boot/grub ::/boot/grub/themes
    mcopy -s -i "$WORKDIR/iso_build/boot/grub/efi.img" \
        "$WORKDIR/iso_build/boot/grub/themes/Libertix" ::/boot/grub/themes/
    mcopy -i "$WORKDIR/iso_build/boot/grub/efi.img" \
        "$WORKDIR/iso_build/EFI/BOOT/BOOTX64.EFI" \
        "$WORKDIR/iso_build/EFI/BOOT/grubx64.efi" \
        "$WORKDIR/iso_build/EFI/BOOT/mmx64.efi" ::/EFI/BOOT/
    mcopy -i "$WORKDIR/iso_build/boot/grub/efi.img" \
        "$WORKDIR/iso_build/EFI/debian/shimx64.efi" \
        "$WORKDIR/iso_build/EFI/debian/grubx64.efi" \
        "$WORKDIR/iso_build/EFI/debian/mmx64.efi" \
        "$WORKDIR/iso_build/EFI/debian/grub.cfg" ::/EFI/debian/
    mcopy -i "$WORKDIR/iso_build/boot/grub/efi.img" \
        "$WORKDIR/iso_build/EFI/LibertixInstaller/shimx64.efi" \
        "$WORKDIR/iso_build/EFI/LibertixInstaller/grubx64.efi" \
        "$WORKDIR/iso_build/EFI/LibertixInstaller/mmx64.efi" \
        "$WORKDIR/iso_build/EFI/LibertixInstaller/grub.cfg" ::/EFI/LibertixInstaller/
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
    require_container_root
    trap cleanup EXIT

    require_build_dependencies
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
