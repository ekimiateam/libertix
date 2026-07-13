#!/bin/bash
set -Eeuo pipefail

mode="${1:?mode is required}"
image="${2:?ISO path is required}"

case "$mode" in
    bios) source_dir=/workspace/iso ;;
    uefi) source_dir=/workspace/iso-uefi ;;
    *)
        echo "Unsupported ISO mode: $mode" >&2
        exit 2
        ;;
esac

[ -s "$image" ] || { echo "Built ISO is missing: $image" >&2; exit 1; }

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT HUP INT TERM
squashfs="$workdir/filesystem.squashfs"

xorriso -osirrox on -indev "$image" \
    -extract /live/filesystem.squashfs "$squashfs" >/dev/null 2>&1

xorriso -osirrox on -indev "$image" \
    -extract /live/initrd.img "$workdir/initrd.img" >/dev/null 2>&1
unmkinitramfs "$workdir/initrd.img" "$workdir/initrd"

compare_rootfs_file() {
    local inside="$1" source="$2" extracted="$workdir/extracted"
    unsquashfs -cat "$squashfs" "$inside" > "$extracted" 2>/dev/null
    cmp "$source" "$extracted"
}

compare_rootfs_file install-mint.sh "$source_dir/live/install-mint.sh"
compare_rootfs_file usr/local/sbin/libertix-runner "$source_dir/live/libertix-runner.sh"
compare_rootfs_file usr/local/sbin/libertix-gui /workspace/iso-uefi/live/libertix-gui.py
compare_rootfs_file usr/local/sbin/libertix-copy-logs /workspace/assets/live/libertix-copy-logs.sh
compare_rootfs_file usr/local/lib/libertix/libertix-install-platform-common.sh \
    /workspace/assets/live/libertix-install-platform-common.sh
compare_rootfs_file usr/local/lib/libertix/libertix-runner-stage-common.sh \
    /workspace/assets/live/libertix-runner-stage-common.sh
compare_rootfs_file usr/local/lib/libertix/cleanup-bcd.py "$source_dir/live/cleanup-bcd.py"
compare_rootfs_file usr/local/lib/libertix/configure-target.sh \
    "$source_dir/target/configure-target.sh"
compare_rootfs_file usr/local/lib/libertix/first-boot-resize.sh \
    "$source_dir/target/first-boot-resize.sh"
compare_rootfs_file usr/local/lib/libertix/first-boot-resize.service \
    "$source_dir/target/first-boot-resize.service"
compare_rootfs_file usr/local/lib/libertix/10_libertix /workspace/grub/10_libertix
compare_rootfs_file usr/local/lib/libertix/render-libertix-menu.py \
    /workspace/grub/render-libertix-menu.py
compare_rootfs_file etc/systemd/system/libertix-install.service \
    "$source_dir/systemd/libertix-install.service"
compare_rootfs_file etc/systemd/system/getty@tty2.service.d/override.conf \
    "$source_dir/systemd/getty-tty2-override.conf"
compare_rootfs_file usr/share/plymouth/themes/libertix/libertix.plymouth \
    /workspace/assets/plymouth/libertix.plymouth
compare_rootfs_file usr/share/plymouth/themes/libertix/libertix.script \
    /workspace/assets/plymouth/libertix.script
compare_rootfs_file usr/share/plymouth/themes/libertix/logo.png \
    /workspace/assets/grub-theme/right_down_border.png

while IFS= read -r source; do
    relative="${source#/workspace/assets/grub-theme/}"
    compare_rootfs_file "usr/local/lib/libertix/grub-theme-source/$relative" "$source"
done < <(find /workspace/assets/grub-theme -type f | LC_ALL=C sort)

xorriso -osirrox on -indev "$image" \
    -extract /boot/grub/grub.cfg "$workdir/grub.cfg" \
    -extract /boot/grub/themes/Libertix "$workdir/theme" >/dev/null 2>&1
cmp "$source_dir/boot/grub.cfg" "$workdir/grub.cfg"
diff -qr /workspace/assets/grub-theme "$workdir/theme"

for binary in usr/bin/magick usr/bin/grub-mkfont usr/bin/xrandr usr/sbin/plymouthd; do
    unsquashfs -ll "$squashfs" "$binary" 2>/dev/null | grep -q "squashfs-root/$binary" || {
        echo "Built rootfs is missing $binary" >&2
        exit 1
    }
done

xorriso -osirrox on -indev "$image" \
    -extract /libertix-packages.txt "$workdir/packages.txt" >/dev/null 2>&1
for package in imagemagick grub-common x11-xserver-utils plymouth; do
    grep -q "^${package}=" "$workdir/packages.txt" || {
        echo "Built rootfs package manifest is missing $package" >&2
        exit 1
    }
done

initrd_root="$workdir/initrd"
if [ ! -d "$initrd_root/usr/share/plymouth" ]; then
    initrd_root="$workdir/initrd/main"
fi
cmp /workspace/assets/plymouth/libertix.plymouth \
    "$initrd_root/usr/share/plymouth/themes/libertix/libertix.plymouth"
cmp /workspace/assets/plymouth/libertix.script \
    "$initrd_root/usr/share/plymouth/themes/libertix/libertix.script"
cmp /workspace/assets/grub-theme/right_down_border.png \
    "$initrd_root/usr/share/plymouth/themes/libertix/logo.png"

toram_script="$initrd_root/usr/lib/live/boot/9990-toram-todisk.sh"
[ -f "$toram_script" ] || { echo "Built initramfs is missing live-boot toram script" >&2; exit 1; }
grep -Fq 'rsync -a ${MODULETORAMFILE} ${copyto} 1>/dev/null' "$toram_script"
grep -Fq 'rsync -a ${copyfrom}/* ${copyto} 1>/dev/null' "$toram_script"
if grep -Eq 'rsync -a --progress|Copying .* to RAM.*dev/console' "$toram_script"; then
    echo "Built initramfs still writes toram progress to the console" >&2
    exit 1
fi

xorriso -indev "$image" -report_el_torito plain 2>&1 \
    | grep -q 'El Torito boot img.*BIOS'
xorriso -indev "$image" -report_el_torito plain 2>&1 \
    | grep -q 'El Torito boot img.*UEFI'

echo "$mode ISO source verification passed"
