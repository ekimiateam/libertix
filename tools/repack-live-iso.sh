#!/bin/bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    echo "Usage: $0 <bios|uefi> <input.iso> <output.iso>" >&2
    exit 2
}

[ "$#" -eq 3 ] || usage
MODE="$1"
INPUT_ISO="$(readlink -f "$2")"
TARGET_ISO="$(readlink -m "$3")"
case "$MODE" in
    bios) SOURCE_DIR="$ROOT_DIR/iso" ;;
    uefi) SOURCE_DIR="$ROOT_DIR/iso-uefi" ;;
    *) usage ;;
esac

[ -f "$INPUT_ISO" ] || { echo "Input ISO missing: $INPUT_ISO" >&2; exit 1; }
for command in fakeroot unsquashfs mksquashfs xorriso sha256sum; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "Missing repack prerequisite: $command" >&2
        exit 1
    }
done

WORKDIR="$(mktemp -d /tmp/libertix-repack.XXXXXX)"
FAKEROOT_STATE="$WORKDIR/fakeroot.state"
ISO_TREE="$WORKDIR/iso"
ROOTFS="$WORKDIR/rootfs"
SQUASHFS="$WORKDIR/filesystem.squashfs"
TEMP_OUTPUT="$TARGET_ISO.tmp.$$"

cleanup() {
    rm -rf "$WORKDIR"
    rm -f "$TEMP_OUTPUT"
}
trap cleanup EXIT

mkdir -p "$ISO_TREE" "$(dirname "$TARGET_ISO")"
xorriso -osirrox on -indev "$INPUT_ISO" -extract / "$ISO_TREE"
chmod -R u+w "$ISO_TREE"
[ -f "$ISO_TREE/live/filesystem.squashfs" ] || {
    echo "Input ISO has no live/filesystem.squashfs" >&2
    exit 1
}

fakeroot -s "$FAKEROOT_STATE" -- \
    unsquashfs -d "$ROOTFS" "$ISO_TREE/live/filesystem.squashfs"

install -m 0755 "$SOURCE_DIR/live/install-mint.sh" "$ROOTFS/install-mint.sh"
install -m 0755 -D "$SOURCE_DIR/live/libertix-runner.sh" \
    "$ROOTFS/usr/local/sbin/libertix-runner"
install -m 0755 -D "$SOURCE_DIR/live/libertix-gui.py" \
    "$ROOTFS/usr/local/sbin/libertix-gui"
install -m 0755 -D "$SOURCE_DIR/live/cleanup-bcd.py" \
    "$ROOTFS/usr/local/lib/libertix/cleanup-bcd.py"
install -m 0755 -D "$SOURCE_DIR/target/configure-target.sh" \
    "$ROOTFS/usr/local/lib/libertix/configure-target.sh"
install -m 0755 -D "$SOURCE_DIR/target/first-boot-resize.sh" \
    "$ROOTFS/usr/local/lib/libertix/first-boot-resize.sh"
install -m 0644 -D "$SOURCE_DIR/target/first-boot-resize.service" \
    "$ROOTFS/usr/local/lib/libertix/first-boot-resize.service"
install -m 0644 -D "$SOURCE_DIR/systemd/libertix-install.service" \
    "$ROOTFS/etc/systemd/system/libertix-install.service"
install -m 0644 -D "$SOURCE_DIR/systemd/getty-tty2-override.conf" \
    "$ROOTFS/etc/systemd/system/getty@tty2.service.d/override.conf"

build_git="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo nogit)"
if [ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal 2>/dev/null)" ]; then
    build_git="${build_git}-dirty"
fi
build_id="$(date -u +%Y%m%d-%H%M%S)-${build_git}"
printf '%s\n' "$build_id" > "$ROOTFS/etc/libertix-build-id"
printf '%s\n' "$build_id" > "$ISO_TREE/libertix-build-id.txt"

fakeroot -i "$FAKEROOT_STATE" -s "$FAKEROOT_STATE" -- chown 0:0 \
    "$ROOTFS/install-mint.sh" \
    "$ROOTFS/usr/local/sbin/libertix-runner" \
    "$ROOTFS/usr/local/sbin/libertix-gui" \
    "$ROOTFS/usr/local/lib/libertix/cleanup-bcd.py" \
    "$ROOTFS/usr/local/lib/libertix/configure-target.sh" \
    "$ROOTFS/usr/local/lib/libertix/first-boot-resize.sh" \
    "$ROOTFS/usr/local/lib/libertix/first-boot-resize.service" \
    "$ROOTFS/etc/systemd/system/libertix-install.service" \
    "$ROOTFS/etc/systemd/system/getty@tty2.service.d/override.conf" \
    "$ROOTFS/etc/libertix-build-id"

# The WPF replaces this file before boot. Keep the standalone default valid as well.
source "$SOURCE_DIR/config/defaults.env"
shell_quote() { printf '%q' "$1"; }
cat > "$ISO_TREE/config.txt" <<CONFIGFILE
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

fakeroot -i "$FAKEROOT_STATE" -- \
    mksquashfs "$ROOTFS" "$SQUASHFS" -comp xz -b 1M -e boot -noappend
mv "$SQUASHFS" "$ISO_TREE/live/filesystem.squashfs"

xorriso -as mkisofs \
    -r -J -joliet-long \
    -V LIBERTIX_INSTALLER \
    -o "$TEMP_OUTPUT" \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -c isolinux/boot.cat \
    -b isolinux/isolinux.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
    -no-emul-boot -isohybrid-gpt-basdat \
    "$ISO_TREE"

[ -s "$TEMP_OUTPUT" ] || { echo "Repacked ISO is empty" >&2; exit 1; }
mv -f "$TEMP_OUTPUT" "$TARGET_ISO"
sha256sum "$TARGET_ISO"
