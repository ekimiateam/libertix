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

# Downloaded .deb files survive between builds when the caller mounts a cache
# directory. snapshot.debian.org is the slowest stage of the build by far.
APT_CACHE_DIR="${LIBERTIX_APT_CACHE_DIR:-}"
SQUASHFS_PROCESSORS="${LIBERTIX_SQUASHFS_PROCESSORS:-$(nproc)}"
SQUASHFS_COMPRESSOR="${LIBERTIX_SQUASHFS_COMPRESSOR:-zstd}"
SQUASHFS_LEVEL="${LIBERTIX_SQUASHFS_LEVEL:-19}"
# mksquashfs defaults to a quarter of physical memory, which two concurrent
# builds plus a tmpfs workdir cannot afford.
SQUASHFS_MEM="${LIBERTIX_SQUASHFS_MEM:-2G}"

# dpkg fsyncs every unpacked file by default. The chroot is a disposable
# artifact rebuilt from scratch, so durability buys nothing here.
export DPKG_FORCE=unsafe-io

require_container_root() {
    [ "$EUID" -eq 0 ] && [ -f /.dockerenv ] || {
        echo "Build this ISO with iso-tools/build-isos-docker.sh $FIRMWARE_MODE" >&2
        exit 1
    }
}

require_build_dependencies() {
    local command missing=()
    local commands=(debootstrap mksquashfs xorriso mmd mcopy mkfs.vfat python3 findmnt nproc)
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

render_boot_config() {
    local template="$1" output="$2"
    python3 "$ROOT_DIR/iso-tools/render-boot-config.py" \
        --arguments "$ROOT_DIR/Scripts/config/Libertix.BootArguments.json" \
        --template "$template" \
        --grub-menu-template "$ROOT_DIR/Scripts/config/Libertix.LiveGrubMenu.cfg.in" \
        --output "$output"
}

prepare_workdir() {
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"/{chroot,iso_build}
}

bootstrap_live_system() {
    local snapshot="${LIBERTIX_DEBIAN_SNAPSHOT:?LIBERTIX_DEBIAN_SNAPSHOT is required}"
    local suite="${LIBERTIX_DEBIAN_SUITE:?LIBERTIX_DEBIAN_SUITE is required}"
    local mirror="http://snapshot.debian.org/archive/debian/${snapshot}/"
    local -a options=(--variant=minbase)
    if [ -n "$APT_CACHE_DIR" ]; then
        mkdir -p "$APT_CACHE_DIR"
        options+=("--cache-dir=$APT_CACHE_DIR")
    fi

    echo "=== Creating minimal Debian system ==="
    debootstrap "${options[@]}" "$suite" "$WORKDIR/chroot" "$mirror"
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
    [ -z "$APT_CACHE_DIR" ] || mount_shared_apt_cache
}

# apt refuses to start without the partial subdirectory and downloads unsandboxed
# unless it belongs to _apt, so both are set up on the shared cache once mounted.
mount_shared_apt_cache() {
    mkdir -p "$APT_CACHE_DIR/partial" "$WORKDIR/chroot/var/cache/apt/archives"
    # An interrupted build leaves its lock file behind. apt then reports it as
    # held by process 0, because the previous owner lived in another container
    # PID namespace, and refuses to run. Only cached .deb files must survive.
    rm -f "$APT_CACHE_DIR/lock" "$APT_CACHE_DIR/partial/"*
    mount --bind "$APT_CACHE_DIR" "$WORKDIR/chroot/var/cache/apt/archives"
    chroot "$WORKDIR/chroot" chown _apt:root /var/cache/apt/archives/partial
}

unmount_chroot_filesystems() {
    echo "=== Unmounting chroot ==="
    umount "$WORKDIR/chroot/var/cache/apt/archives" 2>/dev/null || true
    umount "$WORKDIR/chroot/dev/pts" 2>/dev/null || true
    umount "$WORKDIR/chroot/dev" 2>/dev/null || true
    umount "$WORKDIR/chroot/proc" 2>/dev/null || true
    umount "$WORKDIR/chroot/sys" 2>/dev/null || true
}

# The chroot keeps its packages only while the shared cache is bind mounted.
# Emptying it must happen after the unmount so the host cache stays intact.
purge_chroot_apt_cache() {
    rm -rf "$WORKDIR/chroot/var/cache/apt/archives" "$WORKDIR/chroot/var/lib/apt/lists"
    mkdir -p "$WORKDIR/chroot/var/cache/apt/archives/partial" \
        "$WORKDIR/chroot/var/lib/apt/lists/partial"
}

workdir_has_mounts() {
    findmnt -rn -o TARGET \
        | awk -v prefix="$WORKDIR/" 'index($0, prefix) == 1 { found = 1 } END { exit !found }'
}

configure_live_system() {
    echo "=== Installing packages in live system ==="
    install_chroot_asset 0755 \
        "$ROOT_DIR/assets/plymouth/configure-live-boot-splash.sh" \
        /usr/local/lib/libertix/configure-live-boot-splash
    install_chroot_asset 0644 \
        "$ROOT_DIR/assets/plymouth/libertix.plymouth" \
        /usr/share/plymouth/themes/libertix/libertix.plymouth
    install_chroot_asset 0644 \
        "$ROOT_DIR/assets/plymouth/libertix.script" \
        /usr/share/plymouth/themes/libertix/libertix.script
    install_chroot_asset 0644 \
        "$ROOT_DIR/assets/grub-theme/right_down_border.png" \
        /usr/share/plymouth/themes/libertix/logo.png
    install -m 0755 "$ROOT_DIR/assets/live/setup-live-rootfs.sh" "$WORKDIR/chroot/setup.sh"
    local keep_apt_cache=0
    [ -z "$APT_CACHE_DIR" ] || keep_apt_cache=1
    chroot "$WORKDIR/chroot" /usr/bin/env \
        LIBERTIX_FIRMWARE_MODE="$FIRMWARE_MODE" \
        LIBERTIX_KEEP_APT_CACHE="$keep_apt_cache" \
        DPKG_FORCE=unsafe-io \
        /setup.sh
    rm -f "$WORKDIR/chroot/setup.sh"

    mkdir -p "$WORKDIR/chroot/etc/live"
    echo "LIVE_MEDIA_PATH=/live" > "$WORKDIR/chroot/etc/live/boot.conf"
}

install_chroot_asset() {
    local mode="$1" source="$2" destination="$3"
    install -m "$mode" -D "$source" "$WORKDIR/chroot$destination"
}

install_live_installer_assets() {
    local -a assets=(
        "0755|$ISO_DIR/live/libertix-install.sh|/libertix-install.sh"
        "0755|$ISO_DIR/live/libertix-runner.sh|/usr/local/sbin/libertix-runner"
        "0755|$ROOT_DIR/assets/live/libertix-runner-main.sh|/usr/local/lib/libertix/libertix-runner-main.sh"
        "0755|$ROOT_DIR/assets/live/libertix-gui.py|/usr/local/sbin/libertix-gui"
        "0755|$ROOT_DIR/assets/live/libertix-copy-logs.sh|/usr/local/sbin/libertix-copy-logs"
        "0755|$ROOT_DIR/assets/live/libertix-install-platform-common.sh|/usr/local/lib/libertix/libertix-install-platform-common.sh"
        "0755|$ROOT_DIR/assets/live/libertix-storage-common.sh|/usr/local/lib/libertix/libertix-storage-common.sh"
        "0755|$ROOT_DIR/assets/live/libertix-install-runtime-common.sh|/usr/local/lib/libertix/libertix-install-runtime-common.sh"
        "0755|$ROOT_DIR/assets/live/libertix-distribution-common.sh|/usr/local/lib/libertix/libertix-distribution-common.sh"
        "0755|$ROOT_DIR/assets/live/libertix-installation-plan.py|/usr/local/lib/libertix/libertix-installation-plan.py"
        "0755|$ROOT_DIR/assets/live/libertix-uefi-bootentries.py|/usr/local/lib/libertix/libertix-uefi-bootentries.py"
        "0755|$ROOT_DIR/assets/live/libertix_installation_policy.py|/usr/local/lib/libertix/libertix_installation_policy.py"
        "0644|$ROOT_DIR/Scripts/config/Libertix.InstallationPolicy.json|/usr/local/lib/libertix/Libertix.InstallationPolicy.json"
        "0755|$ROOT_DIR/assets/live/libertix-installation-state.py|/usr/local/lib/libertix/libertix-installation-state.py"
        "0755|$ROOT_DIR/assets/live/libertix_json_schema.py|/usr/local/lib/libertix/libertix_json_schema.py"
        "0644|$ROOT_DIR/schemas/installation-plan.schema.json|/usr/local/lib/libertix/schemas/installation-plan.schema.json"
        "0644|$ROOT_DIR/schemas/installation-state.schema.json|/usr/local/lib/libertix/schemas/installation-state.schema.json"
        "0755|$ROOT_DIR/assets/live/libertix-installation-plan.sh|/usr/local/lib/libertix/libertix-installation-plan.sh"
        "0755|$ROOT_DIR/assets/live/configure-development-access.sh|/usr/local/lib/libertix/configure-development-access.sh"
        "0755|$ROOT_DIR/assets/live/libertix-development-ssh-first-boot.sh|/usr/local/lib/libertix/libertix-development-ssh-first-boot.sh"
        "0644|$ROOT_DIR/assets/live/libertix-development-ssh.service|/usr/local/lib/libertix/libertix-development-ssh.service"
        "0755|$ROOT_DIR/assets/live/libertix-live-context.sh|/usr/local/lib/libertix/libertix-live-context.sh"
        "0755|$ROOT_DIR/assets/live/libertix-install-main.sh|/usr/local/lib/libertix/libertix-install-main.sh"
        "0755|$ROOT_DIR/assets/live/libertix-i18n.py|/usr/local/lib/libertix/libertix-i18n.py"
        "0755|$ROOT_DIR/assets/live/libertix_progress.py|/usr/local/lib/libertix/libertix_progress.py"
        "0755|$ROOT_DIR/assets/live/libertix-i18n.sh|/usr/local/lib/libertix/libertix-i18n.sh"
        "0644|$ROOT_DIR/assets/live/libertix-translations.json|/usr/local/lib/libertix/libertix-translations.json"
        "0755|$ROOT_DIR/assets/live/libertix-target-common.sh|/usr/local/lib/libertix/libertix-target-common.sh"
        "0755|$ROOT_DIR/assets/live/libertix-apply-keyboard-once.sh|/usr/local/lib/libertix/libertix-apply-keyboard-once.sh"
        "0755|$ROOT_DIR/assets/live/libertix-rollback-common.sh|/usr/local/lib/libertix/libertix-rollback-common.sh"
        "0755|$ROOT_DIR/assets/live/libertix-runner-stage-common.sh|/usr/local/lib/libertix/libertix-runner-stage-common.sh"
        "0644|$ROOT_DIR/assets/live/libertix-stages.tsv|/usr/local/lib/libertix/libertix-stages.tsv"
        "0755|$ROOT_DIR/assets/live/cleanup-bcd.py|/usr/local/lib/libertix/cleanup-bcd.py"
        "0755|$ROOT_DIR/assets/live/cleanup-bcd-main.py|/usr/local/lib/libertix/cleanup-bcd-main.py"
        "0755|$ISO_DIR/target/configure-target.sh|/usr/local/lib/libertix/configure-target.sh"
        "0755|$ROOT_DIR/assets/live/configure-target-main.sh|/usr/local/lib/libertix/configure-target-main.sh"
        "0755|$ROOT_DIR/grub/10_libertix|/usr/local/lib/libertix/10_libertix"
        "0755|$ROOT_DIR/grub/render-libertix-menu.py|/usr/local/lib/libertix/render-libertix-menu.py"
        "0755|$ROOT_DIR/assets/live/libertix-validate-grub.sh|/usr/local/lib/libertix/libertix-validate-grub.sh"
        "0755|$ROOT_DIR/assets/live/libertix-update-grub.sh|/usr/local/lib/libertix/libertix-update-grub.sh"
        "0755|$ROOT_DIR/assets/live/libertix-sync-efi.sh|/usr/local/lib/libertix/libertix-sync-efi.sh"
        "0644|$ROOT_DIR/assets/live/libertix-efi-sync.service|/usr/local/lib/libertix/libertix-efi-sync.service"
        "0644|$ROOT_DIR/assets/live/libertix-efi-sync.path|/usr/local/lib/libertix/libertix-efi-sync.path"
        "0755|$ROOT_DIR/assets/live/first-boot-resize.sh|/usr/local/lib/libertix/first-boot-resize.sh"
        "0755|$ROOT_DIR/assets/live/libertix-first-boot-verify.py|/usr/local/lib/libertix/libertix-first-boot-verify.py"
        "0644|$ROOT_DIR/assets/live/first-boot-resize.service|/usr/local/lib/libertix/first-boot-resize.service"
        "0644|$ISO_DIR/systemd/libertix-install.service|/etc/systemd/system/libertix-install.service"
        "0644|$ROOT_DIR/assets/live/getty-tty2-override.conf|/etc/systemd/system/getty@tty2.service.d/override.conf"
    )
    local asset mode source destination
    for asset in "${assets[@]}"; do
        IFS='|' read -r mode source destination <<< "$asset"
        install_chroot_asset "$mode" "$source" "$destination"
    done

    if [ "$FIRMWARE_MODE" = "bios" ]; then
        install_chroot_asset 0755 \
            "$ROOT_DIR/assets/live/libertix-bios-adapter.sh" \
            /usr/local/lib/libertix/libertix-bios-adapter.sh
    else
        install_chroot_asset 0755 \
            "$ROOT_DIR/assets/live/libertix-uefi-adapter.sh" \
            /usr/local/lib/libertix/libertix-uefi-adapter.sh
    fi
    mkdir -p "$WORKDIR/chroot/etc/systemd/system/multi-user.target.wants"
    ln -sf /etc/systemd/system/libertix-install.service \
        "$WORKDIR/chroot/etc/systemd/system/multi-user.target.wants/libertix-install.service"

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

build_squashfs() {
    echo "=== Creating squashfs ==="
    mkdir -p "$WORKDIR/iso_build/live"
    # zstd compresses several times faster than xz for a comparable image size
    # and decompresses far faster, which also shortens the live boot.
    local -a compression=(-comp "$SQUASHFS_COMPRESSOR")
    case "$SQUASHFS_COMPRESSOR" in
        zstd|gzip|lz4) compression+=(-Xcompression-level "$SQUASHFS_LEVEL") ;;
    esac
    mksquashfs "$WORKDIR/chroot" "$WORKDIR/iso_build/live/filesystem.squashfs" \
        "${compression[@]}" \
        -b 1M -processors "$SQUASHFS_PROCESSORS" -mem "$SQUASHFS_MEM" \
        -no-progress -e boot

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
    render_boot_config \
        "$ISO_DIR/boot/isolinux.cfg" \
        "$WORKDIR/iso_build/isolinux/isolinux.cfg"
}

configure_grub_efi() {
    if [ "$FIRMWARE_MODE" = "uefi" ]; then
        configure_signed_grub_efi
        return
    fi
    echo "=== Configuring GRUB EFI ==="
    mkdir -p "$WORKDIR/iso_build/boot/grub" "$WORKDIR/iso_build/EFI/BOOT"
    render_boot_config \
        "$ISO_DIR/boot/grub.cfg" \
        "$WORKDIR/iso_build/boot/grub/grub.cfg"
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
    render_boot_config \
        "$ISO_DIR/boot/grub.cfg" \
        "$WORKDIR/iso_build/boot/grub/grub.cfg"
    mkdir -p "$WORKDIR/iso_build/boot/grub/themes"
    cp -a "$ROOT_DIR/assets/grub-theme" \
        "$WORKDIR/iso_build/boot/grub/themes/Libertix"
    install -m 0644 "$WORKDIR/iso_build/boot/grub/grub.cfg" \
        "$WORKDIR/iso_build/EFI/debian/grub.cfg"
    install -m 0644 "$WORKDIR/iso_build/boot/grub/grub.cfg" \
        "$WORKDIR/iso_build/EFI/LibertixInstaller/grub.cfg"
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
    # A leftover bind mount would make this delete the shared host apt cache.
    if workdir_has_mounts; then
        echo "Refusing to remove $WORKDIR while mounts remain under it" >&2
        return
    fi
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
    purge_chroot_apt_cache
    build_squashfs
    configure_isolinux
    configure_grub_efi
    create_iso

    echo "=== Done: $OUTPUT_ISO ($(du -h "$ROOT_DIR/$OUTPUT_ISO" | cut -f1)) ==="
}

main "$@"
