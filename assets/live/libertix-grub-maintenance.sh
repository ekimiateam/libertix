#!/bin/bash
set -Eeuo pipefail

# Boot-menu maintenance for Arch-family installations, run by pacman hooks.
#
# Debian-family systems keep the GRUB generators diverted with dpkg-divert and
# let the GRUB packages reinstall their core image. pacman has neither: a GRUB
# update restores /etc/grub.d/10_linux beside the Libertix menu renderer and
# leaves the installed core image older than the modules it loads from
# /boot/grub. This script moves the generators out of the way again, writes a
# validated menu, and reinstalls the core image for the plan's firmware.

readonly generator_directory="${LIBERTIX_GRUB_GENERATOR_DIRECTORY:-/usr/local/lib/libertix/grub-generators}"
readonly grub_scripts="${LIBERTIX_GRUB_SCRIPTS:-/etc/grub.d}"
readonly plan="${LIBERTIX_PLAN_PATH:-/etc/libertix/installation-plan.json}"
readonly bios_device_file="${LIBERTIX_GRUB_BIOS_DEVICE_FILE:-/etc/libertix/grub-bios-device}"
readonly update_grub="${LIBERTIX_UPDATE_GRUB:-/usr/local/sbin/update-grub}"
readonly grub_install="${LIBERTIX_GRUB_INSTALL:-grub-install}"
readonly log="${LIBERTIX_BOOT_MAINTENANCE_LOG:-/var/log/libertix/boot-maintenance.log}"

# The Libertix renderer embeds the output of these generators; 10_linux is
# required, the others exist only on some systems.
sync_generators() {
    local name source destination

    install -d -m 0755 "$generator_directory"
    for name in 10_linux 30_uefi-firmware 20_memtest86+; do
        source="$grub_scripts/$name"
        destination="$generator_directory/$name"
        [ -f "$source" ] && [ -x "$source" ] || continue
        install -m 0755 "$source" "$destination.new"
        mv -f -- "$destination.new" "$destination"
        # grub-mkconfig skips scripts that are not executable.
        chmod 0644 "$source"
    done
    [ -x "$generator_directory/10_linux" ] || {
        echo "Required GRUB generator is missing: $generator_directory/10_linux" >&2
        return 1
    }
}

plan_firmware() {
    python3 - "$plan" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8-sig") as stream:
    firmware = json.load(stream).get("firmware")
if firmware not in {"bios", "uefi"}:
    raise SystemExit("installation plan firmware is invalid")
print(firmware)
PY
}

reinstall_bios_core() {
    local device

    [ -s "$bios_device_file" ] || {
        echo "The recorded BIOS GRUB device is missing: $bios_device_file" >&2
        return 1
    }
    device="$(sed -n '1p' "$bios_device_file")"
    [ -b "$device" ] && [ "$(lsblk -dno TYPE "$device" 2>/dev/null)" = disk ] || {
        echo "The recorded BIOS GRUB device is not a disk: $device" >&2
        return 1
    }
    "$grub_install" --target=i386-pc --recheck "$device"
}

main() {
    local action="${1:-all}"

    install -d -m 0755 "$(dirname "$log")"
    touch "$log"
    chmod 0600 "$log"
    exec > >(tee -a "$log") 2>&1
    printf '[%s] GRUB maintenance: %s\n' "$(date -u +%FT%TZ)" "$action"

    case "$action" in
        generators)
            sync_generators
            ;;
        menu)
            # A kernel change needs a new menu but not a new core image.
            sync_generators
            LIBERTIX_EFI_SYNC=/usr/bin/true "$update_grub"
            ;;
        all)
            sync_generators
            # On UEFI, update-grub finishes by reinstalling EFI/Libertix through
            # libertix-sync-efi.
            "$update_grub"
            if [ "$(plan_firmware)" = bios ]; then
                reinstall_bios_core
            fi
            ;;
        *)
            echo "Usage: ${0##*/} [generators|menu|all]" >&2
            return 2
            ;;
    esac
}

main "$@"
