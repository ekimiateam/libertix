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

verification_root="/var/lib/libertix-work/$mode/verification"
mkdir -p "$verification_root"
workdir="$(mktemp -d "$verification_root/run.XXXXXX")"
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

compare_rootfs_file libertix-install.sh "$source_dir/live/libertix-install.sh"
compare_rootfs_file usr/local/sbin/libertix-runner "$source_dir/live/libertix-runner.sh"
compare_rootfs_file usr/local/lib/libertix/libertix-runner-main.sh \
    /workspace/assets/live/libertix-runner-main.sh
compare_rootfs_file usr/local/sbin/libertix-gui /workspace/assets/live/libertix-gui.py
compare_rootfs_file usr/local/sbin/libertix-copy-logs /workspace/assets/live/libertix-copy-logs.sh
compare_rootfs_file usr/local/lib/libertix/libertix-install-platform-common.sh \
    /workspace/assets/live/libertix-install-platform-common.sh
compare_rootfs_file usr/local/lib/libertix/libertix-storage-common.sh \
    /workspace/assets/live/libertix-storage-common.sh
compare_rootfs_file usr/local/lib/libertix/libertix-install-runtime-common.sh \
    /workspace/assets/live/libertix-install-runtime-common.sh
compare_rootfs_file usr/local/lib/libertix/libertix-distribution-common.sh \
    /workspace/assets/live/libertix-distribution-common.sh
compare_rootfs_file usr/local/lib/libertix/libertix-installation-plan.py \
    /workspace/assets/live/libertix-installation-plan.py
compare_rootfs_file usr/local/lib/libertix/libertix-uefi-bootentries.py \
    /workspace/assets/live/libertix-uefi-bootentries.py
compare_rootfs_file usr/local/lib/libertix/libertix_installation_policy.py \
    /workspace/assets/live/libertix_installation_policy.py
compare_rootfs_file usr/local/lib/libertix/Libertix.InstallationPolicy.json \
    /workspace/Scripts/config/Libertix.InstallationPolicy.json
compare_rootfs_file usr/local/lib/libertix/libertix-installation-state.py \
    /workspace/assets/live/libertix-installation-state.py
compare_rootfs_file usr/local/lib/libertix/libertix_progress.py \
    /workspace/assets/live/libertix_progress.py
compare_rootfs_file usr/local/lib/libertix/libertix_json_schema.py \
    /workspace/assets/live/libertix_json_schema.py
compare_rootfs_file usr/local/lib/libertix/schemas/installation-plan.schema.json \
    /workspace/schemas/installation-plan.schema.json
compare_rootfs_file usr/local/lib/libertix/schemas/installation-state.schema.json \
    /workspace/schemas/installation-state.schema.json
compare_rootfs_file usr/local/lib/libertix/libertix-installation-plan.sh \
    /workspace/assets/live/libertix-installation-plan.sh
compare_rootfs_file usr/local/lib/libertix/libertix-live-context.sh \
    /workspace/assets/live/libertix-live-context.sh
compare_rootfs_file usr/local/lib/libertix/libertix-install-main.sh \
    /workspace/assets/live/libertix-install-main.sh
compare_rootfs_file usr/local/lib/libertix/libertix-i18n.py \
    /workspace/assets/live/libertix-i18n.py
compare_rootfs_file usr/local/lib/libertix/libertix-i18n.sh \
    /workspace/assets/live/libertix-i18n.sh
compare_rootfs_file usr/local/lib/libertix/libertix-translations.json \
    /workspace/assets/live/libertix-translations.json
compare_rootfs_file usr/local/lib/libertix/libertix-target-common.sh \
    /workspace/assets/live/libertix-target-common.sh
compare_rootfs_file usr/local/lib/libertix/configure-development-access.sh \
    /workspace/assets/live/configure-development-access.sh
compare_rootfs_file usr/local/lib/libertix/libertix-development-ssh-first-boot.sh \
    /workspace/assets/live/libertix-development-ssh-first-boot.sh
compare_rootfs_file usr/local/lib/libertix/libertix-development-ssh.service \
    /workspace/assets/live/libertix-development-ssh.service
compare_rootfs_file usr/local/lib/libertix/libertix-apply-keyboard-once.sh \
    /workspace/assets/live/libertix-apply-keyboard-once.sh
compare_rootfs_file usr/local/lib/libertix/libertix-rollback-common.sh \
    /workspace/assets/live/libertix-rollback-common.sh
compare_rootfs_file usr/local/lib/libertix/libertix-runner-stage-common.sh \
    /workspace/assets/live/libertix-runner-stage-common.sh
compare_rootfs_file usr/local/lib/libertix/libertix-stages.tsv \
    /workspace/assets/live/libertix-stages.tsv

case "$mode" in
    bios)
        expected_adapter=libertix-bios-adapter.sh
        unexpected_adapter=libertix-uefi-adapter.sh
        ;;
    uefi)
        expected_adapter=libertix-uefi-adapter.sh
        unexpected_adapter=libertix-bios-adapter.sh
        ;;
esac
compare_rootfs_file "usr/local/lib/libertix/$expected_adapter" \
    "/workspace/assets/live/$expected_adapter"
if unsquashfs -ll "$squashfs" "usr/local/lib/libertix/$unexpected_adapter" 2>/dev/null \
    | grep -q "squashfs-root/usr/local/lib/libertix/$unexpected_adapter"; then
    echo "Built $mode rootfs contains unexpected adapter $unexpected_adapter" >&2
    exit 1
fi
compare_rootfs_file usr/local/lib/libertix/cleanup-bcd.py /workspace/assets/live/cleanup-bcd.py
compare_rootfs_file usr/local/lib/libertix/cleanup-bcd-main.py \
    /workspace/assets/live/cleanup-bcd-main.py
compare_rootfs_file usr/local/lib/libertix/configure-target.sh \
    "$source_dir/target/configure-target.sh"
compare_rootfs_file usr/local/lib/libertix/configure-target-main.sh \
    /workspace/assets/live/configure-target-main.sh
compare_rootfs_file usr/local/lib/libertix/first-boot-resize.sh \
    /workspace/assets/live/first-boot-resize.sh
compare_rootfs_file usr/local/lib/libertix/libertix-first-boot-verify.py \
    /workspace/assets/live/libertix-first-boot-verify.py
compare_rootfs_file usr/local/lib/libertix/libertix-first-boot-result.py \
    /workspace/assets/live/libertix-first-boot-result.py
compare_rootfs_file usr/local/lib/libertix/libertix-first-boot-result.desktop \
    /workspace/assets/live/libertix-first-boot-result.desktop
compare_rootfs_file usr/local/lib/libertix/first-boot-resize.service \
    /workspace/assets/live/first-boot-resize.service
compare_rootfs_file usr/local/lib/libertix/10_libertix /workspace/grub/10_libertix
compare_rootfs_file usr/local/lib/libertix/render-libertix-menu.py \
    /workspace/grub/render-libertix-menu.py
compare_rootfs_file usr/local/lib/libertix/libertix-validate-grub.sh \
    /workspace/assets/live/libertix-validate-grub.sh
compare_rootfs_file usr/local/lib/libertix/libertix-update-grub.sh \
    /workspace/assets/live/libertix-update-grub.sh
compare_rootfs_file usr/local/lib/libertix/libertix-sync-efi.sh \
    /workspace/assets/live/libertix-sync-efi.sh
compare_rootfs_file usr/local/lib/libertix/libertix-efi-sync.service \
    /workspace/assets/live/libertix-efi-sync.service
compare_rootfs_file usr/local/lib/libertix/libertix-efi-sync.path \
    /workspace/assets/live/libertix-efi-sync.path
compare_rootfs_file etc/systemd/system/libertix-install.service \
    "$source_dir/systemd/libertix-install.service"
compare_rootfs_file etc/systemd/system/getty@tty2.service.d/override.conf \
    /workspace/assets/live/getty-tty2-override.conf
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
python3 /workspace/iso-tools/render-boot-config.py \
    --arguments /workspace/Scripts/config/Libertix.BootArguments.json \
    --grub-menu-template /workspace/Scripts/config/Libertix.LiveGrubMenu.cfg.in \
    --template "$source_dir/boot/grub.cfg" \
    --output "$workdir/expected-grub.cfg"
cmp "$workdir/expected-grub.cfg" "$workdir/grub.cfg"
diff -qr /workspace/assets/grub-theme "$workdir/theme"

for binary in usr/bin/magick usr/bin/grub-mkfont usr/bin/xrandr usr/sbin/plymouthd; do
    unsquashfs -ll "$squashfs" "$binary" 2>/dev/null | grep -q "squashfs-root/$binary" || {
        echo "Built rootfs is missing $binary" >&2
        exit 1
    }
done

ssh_first_boot="$workdir/ssh-first-boot.sh"
unsquashfs -cat "$squashfs" \
    usr/local/lib/libertix/libertix-development-ssh-first-boot.sh \
    > "$ssh_first_boot"
cmp /workspace/assets/live/libertix-development-ssh-first-boot.sh "$ssh_first_boot"
bash -n "$ssh_first_boot"

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
module_copy_pattern='^[[:space:]]*rsync[[:space:]].*(\$\{MODULETORAMFILE\}|\$MODULETORAMFILE).*(\$\{copyto\}|\$copyto)'
medium_copy_pattern='^[[:space:]]*rsync[[:space:]].*(\$\{copyfrom\}|\$copyfrom)/\*.*(\$\{copyto\}|\$copyto)'
unsafe_progress_pattern='^[[:space:]]*rsync[[:space:]].*(--progress|dev/console)|Copying .* to RAM.*dev/console'
if ! grep -Eq "$module_copy_pattern" "$toram_script"; then
    echo "Built initramfs no longer copies the module payload to RAM" >&2
    exit 1
fi
if ! grep -Eq "$medium_copy_pattern" "$toram_script"; then
    echo "Built initramfs no longer copies the live medium to RAM" >&2
    exit 1
fi
if grep -Eq "$unsafe_progress_pattern" "$toram_script"; then
    echo "Built initramfs still writes toram progress to the console" >&2
    exit 1
fi

xorriso -indev "$image" -report_el_torito plain 2>&1 \
    | grep -q 'El Torito boot img.*BIOS'
xorriso -indev "$image" -report_el_torito plain 2>&1 \
    | grep -q 'El Torito boot img.*UEFI'

echo "$mode ISO source verification passed"
