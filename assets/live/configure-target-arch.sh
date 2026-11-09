#!/bin/bash
# Sourced by configure-target-main.sh inside the installed Arch-family target.
# The family-neutral helpers (Windows sharing, time zone, GRUB Windows entry,
# development access) come from that file; only package-manager, initramfs and
# boot-maintenance specifics live here.

readonly ARCH_GRUB_MAINTENANCE=/usr/local/lib/libertix/libertix-grub-maintenance.sh

configure_arch_user() {
    local group groups=wheel

    if id "$USERNAME" >/dev/null 2>&1; then
        [ "$(id -u "$USERNAME")" -ne 0 ] || { echo "Refusing UID 0 desktop account" >&2; exit 1; }
    else
        useradd -m -s /bin/bash "$USERNAME"
    fi
    getent group wheel >/dev/null || { echo "Required wheel group is missing" >&2; exit 1; }
    # The groups CachyOS's own installer gives the first account.
    for group in rfkill sys users; do
        getent group "$group" >/dev/null && groups="$groups,$group"
    done
    usermod -s /bin/bash -a -G "$groups" "$USERNAME"
    [[ "$PASSWORD_HASH" == \$6\$* ]] || { echo "Invalid Linux password hash" >&2; exit 1; }
    command -v chpasswd >/dev/null 2>&1 || { echo "chpasswd is required" >&2; exit 1; }
    printf '%s:%s\n' "$USERNAME" "$PASSWORD_HASH" | chpasswd -e
    passwd -S "$USERNAME" | grep -Eq "^[^ ]+ P "

    install -d -m 0750 /etc/sudoers.d
    printf '%%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/10-libertix-wheel
    chmod 0440 /etc/sudoers.d/10-libertix-wheel
    visudo -cf /etc/sudoers
    echo "$COMPUTER_NAME" > /etc/hostname
}

configure_arch_locale() {
    {
        printf '%s UTF-8\n' "$SYSTEM_LANG"
        if [ "$SYSTEM_LANG" != "en_US.UTF-8" ]; then
            printf '%s UTF-8\n' "en_US.UTF-8"
        fi
    } > /etc/locale.gen
    locale-gen
    # systemd rejects LC_ALL in locale.conf; LANG covers every category.
    cat > /etc/locale.conf <<EOF
LANG=$SYSTEM_LANG
LANGUAGE=$LANGUAGE_CODE
EOF
}

configure_arch_keyboard() {
    local console_keymap=us

    # The console shares the XKB layout name for most layouts. A name without a
    # console keymap falls back to US so the virtual console always starts.
    if find /usr/share/kbd/keymaps -type f -name "${KEYBOARD_LAYOUT}.map.gz" -print -quit | grep -q .; then
        console_keymap="$KEYBOARD_LAYOUT"
    fi
    cat > /etc/vconsole.conf <<EOF
KEYMAP=$console_keymap
XKBLAYOUT=$KEYBOARD_LAYOUT
XKBMODEL=$KEYBOARD_MODEL
XKBVARIANT=$KEYBOARD_VARIANT
XKBOPTIONS=
EOF

    mkdir -p /etc/X11/xorg.conf.d
    cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<EOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "$KEYBOARD_LAYOUT"
    Option "XkbVariant" "$KEYBOARD_VARIANT"
    Option "XkbModel" "$KEYBOARD_MODEL"
EndSection
EOF

    # KDE Plasma reads its system-wide default layout from /etc/xdg/kxkbrc.
    mkdir -p /etc/xdg
    cat > /etc/xdg/kxkbrc <<EOF
[Layout]
LayoutList=$KEYBOARD_LAYOUT
VariantList=$KEYBOARD_VARIANT
Model=$KEYBOARD_MODEL
Use=true
EOF
}

configure_arch_hardware_drivers() {
    # CachyOS's installer runs its hardware detection after pacstrap and fails
    # the installation when it cannot finish. Libertix does the same.
    command -v chwd >/dev/null 2>&1 || { echo "chwd is missing from the target" >&2; exit 1; }
    chwd --autoconfigure
}

configure_arch_services() {
    local unit

    # plasmalogin is the Plasma login manager CachyOS's KDE edition uses.
    for unit in NetworkManager.service plasmalogin.service bluetooth.service \
        systemd-timesyncd.service fstrim.timer; do
        systemctl enable "$unit"
    done
}

refresh_arch_initramfs() {
    local kernel pkgbase found=false

    command -v mkinitcpio >/dev/null || { echo "Target distribution does not provide mkinitcpio" >&2; return 1; }
    # chwd may add GPU modules; rebuild every preset from the final configuration.
    mkinitcpio -P

    for kernel in /usr/lib/modules/*/pkgbase; do
        [ -f "$kernel" ] || continue
        pkgbase="$(cat "$kernel")"
        [ -f "/boot/vmlinuz-$pkgbase" ] || { echo "Kernel image is missing: /boot/vmlinuz-$pkgbase" >&2; return 1; }
        [ -f "/boot/initramfs-$pkgbase.img" ] || {
            echo "Initramfs is missing: /boot/initramfs-$pkgbase.img" >&2
            return 1
        }
        found=true
    done
    [ "$found" = true ] || { echo "Target distribution has no installed kernel" >&2; return 1; }
}

record_bios_grub_device() {
    local disk_name link

    [ "$LIBERTIX_FIRMWARE_MODE" = bios ] || return 0
    # GRUB lives in the MBR of the Windows disk. Record a stable name so a GRUB
    # package update can reinstall the matching core image on that disk only.
    disk_name="$(lsblk -dno PKNAME "$WINDOWS_PART" 2>/dev/null || true)"
    [ -n "$disk_name" ] || { echo "Cannot resolve the Windows disk of $WINDOWS_PART" >&2; return 1; }
    link="$(find /dev/disk/by-id -maxdepth 1 -type l \
        \( -name 'wwn-*' -o -name 'nvme-eui.*' -o -name 'ata-*' -o -name 'nvme-*' -o -name 'scsi-*' \) \
        -lname "*/$disk_name" -print 2>/dev/null | sort | head -n1)"
    [ -n "$link" ] || link="/dev/$disk_name"
    install -d -m 0755 /etc/libertix
    printf '%s\n' "$link" > /etc/libertix/grub-bios-device
}

install_arch_boot_maintenance_hooks() {
    install -d -m 0755 /etc/pacman.d/hooks
    # A GRUB update restores /etc/grub.d and leaves the installed core image
    # older than its modules; resynchronize both.
    cat > /etc/pacman.d/hooks/99-libertix-grub.hook <<EOF
[Trigger]
Type = Package
Operation = Install
Operation = Upgrade
Target = grub

[Action]
Description = Updating the Libertix boot menu and GRUB core image...
When = PostTransaction
Exec = $ARCH_GRUB_MAINTENANCE all
EOF
    # Kernel file names are stable on Arch, but an added or removed kernel
    # must appear in the validated menu. mkinitcpio's 90- hook runs first.
    cat > /etc/pacman.d/hooks/99-libertix-grub-menu.hook <<EOF
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Operation = Remove
Target = usr/lib/modules/*/vmlinuz

[Action]
Description = Updating the Libertix boot menu...
When = PostTransaction
Exec = $ARCH_GRUB_MAINTENANCE menu
EOF
}

configure_arch_grub() {
    local win_boot_uuid

    [[ "${GRUB_RESOLUTION:-}" =~ ^[0-9]+x[0-9]+$ ]] || {
        echo "Invalid GRUB resolution: ${GRUB_RESOLUTION:-missing}" >&2
        exit 1
    }

    cat > /etc/default/grub <<EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=-1
GRUB_TIMEOUT_STYLE=menu
GRUB_DISTRIBUTOR="$DISTRIBUTION_GRUB_DISPLAY_NAME"
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX=""
GRUB_PRELOAD_MODULES="part_gpt part_msdos"
GRUB_DISABLE_OS_PROBER=true
GRUB_THEME="/boot/grub/themes/Libertix/theme.txt"
GRUB_GFXPAYLOAD_LINUX=keep
EOF
    printf 'GRUB_GFXMODE="%s,auto"\n' "$GRUB_RESOLUTION" >> /etc/default/grub
    win_boot_uuid="$(find_windows_boot_uuid || true)"
    if [ -z "$win_boot_uuid" ]; then
        echo "Windows boot manager was not found" >&2
        exit 1
    fi
    write_windows_grub_entry "$win_boot_uuid"

    install -m 0755 /tmp/10_libertix /etc/grub.d/10_libertix
    install -m 0755 /tmp/render-libertix-menu.py \
        /usr/local/lib/libertix/render-libertix-menu.py
    chmod -x /etc/grub.d/40_custom 2>/dev/null || true
    "$ARCH_GRUB_MAINTENANCE" generators

    # pacman owns /usr/bin. /usr/local/sbin comes first in PATH, so the
    # validating wrapper serves update-grub without conflicting with a package.
    install -m 0755 /usr/local/lib/libertix/libertix-update-grub.sh /usr/local/sbin/update-grub
    record_bios_grub_device
    install_arch_boot_maintenance_hooks
    /usr/local/sbin/update-grub
    assert_grub_configuration
}

main_arch() {
    assert_target_distribution_identity
    configure_arch_user
    configure_windows_mount
    configure_windows_readonly_request
    configure_arch_locale
    configure_windows_profile_shortcuts
    configure_arch_keyboard
    configure_timezone
    configure_development_access
    configure_arch_hardware_drivers
    configure_arch_services
    refresh_arch_initramfs
    configure_arch_grub
    enable_first_boot_resize
}
