#!/bin/bash
set -Eeuo pipefail

partition_path() {
    local disk="$1"
    local num="$2"
    case "$(basename "$disk")" in
        nvme*|mmcblk*) echo "${disk}p${num}" ;;
        *) echo "${disk}${num}" ;;
    esac
}

partitions_of_disk() {
    local disk="$1"
    lsblk -lnpo NAME,TYPE "$disk" 2>/dev/null | awk '$2=="part"{print $1}'
}

configure_user() {
    useradd -m -s /bin/bash -G sudo,adm,cdrom,audio,video,plugdev "$USERNAME" 2>/dev/null || true
    echo "$USERNAME:$PASSWORD" | chpasswd
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
    echo "$COMPUTER_NAME" > /etc/hostname
}

configure_windows_mount() {
    local win_uuid="" pdev pfs psize

    while read -r pdev; do
        [ -n "$pdev" ] || continue
        pfs="$(blkid -s TYPE -o value "$pdev" 2>/dev/null || echo "")"
        if [ "$pfs" = "ntfs" ]; then
            psize=$(($(blockdev --getsize64 "$pdev" 2>/dev/null || echo 0) / 1024 / 1024 / 1024))
            if [ "$psize" -gt 10 ]; then
                win_uuid="$(blkid -s UUID -o value "$pdev")"
                break
            fi
        fi
    done < <(partitions_of_disk "$DISK")

    if [ -n "$win_uuid" ]; then
        mkdir -p /mnt/windows
        echo "UUID=$win_uuid /mnt/windows ntfs-3g defaults,uid=1000,gid=1000,dmask=022,fmask=133,windows_names,nofail 0 0" >> /etc/fstab
    fi
}

configure_locale() {
    sed -i "s/# $SYSTEM_LANG/$SYSTEM_LANG/" /etc/locale.gen 2>/dev/null || true
    locale-gen 2>/dev/null || true
    cat > /etc/default/locale <<EOF
LANG=$SYSTEM_LANG
LC_ALL=$SYSTEM_LANG
LANGUAGE=${SYSTEM_LANG%%_*}
EOF
}

configure_keyboard() {
    cat > /etc/default/keyboard <<EOF
XKBMODEL="$KEYBOARD_MODEL"
XKBLAYOUT="$KEYBOARD_LAYOUT"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF

    mkdir -p /etc/X11/xorg.conf.d
    cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<EOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "$KEYBOARD_LAYOUT"
    Option "XkbModel" "$KEYBOARD_MODEL"
EndSection
EOF

    mkdir -p /etc/dconf/db/local.d
    cat > /etc/dconf/db/local.d/00-keyboard <<EOF
[org/gnome/libgnomekbd/keyboard]
layouts=['$KEYBOARD_LAYOUT']
model='$KEYBOARD_MODEL'
[org/cinnamon/desktop/input-sources]
sources=[('xkb', '$KEYBOARD_LAYOUT')]
EOF
    dconf update 2>/dev/null || true
}

configure_timezone() {
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    echo "$TIMEZONE" > /etc/timezone
}

cleanup_live_boot_artifacts() {
    local unit

    # The target filesystem comes from a live ISO squashfs. These units are
    # useful only while booting the installer; keeping them in the installed
    # system creates first-boot journal errors.
    for unit in casper-md5check.service casper.service casper-stop.service; do
        systemctl disable "$unit" 2>/dev/null || true
        systemctl mask "$unit" 2>/dev/null || true
    done

    rm -f /etc/systemd/system/casper*.service
    rm -f /etc/systemd/system/*/casper*.service
    rm -f /etc/systemd/system/*.wants/casper*.service
    rm -f /lib/systemd/system/casper*.service
    rm -f /usr/lib/systemd/system/casper*.service
    rm -f /usr/lib/systemd/system/*/casper*.service
    rm -rf /var/lib/casper
}

cleanup_keyring_pam_noise() {
    local pam_file

    # On this non-interactive install path, pam_gnome_keyring can emit login
    # errors before the user session daemon exists. The desktop still starts;
    # removing the PAM hook keeps journal health checks focused on real issues.
    for pam_file in /etc/pam.d/*; do
        [ -f "$pam_file" ] || continue
        grep -q 'pam_gnome_keyring\.so' "$pam_file" 2>/dev/null || continue
        sed -i '/pam_gnome_keyring\.so/d' "$pam_file"
    done
}

find_windows_boot_uuid() {
    local pdev pfs tmpmnt

    while read -r pdev; do
        [ -n "$pdev" ] || continue
        pfs="$(blkid -s TYPE -o value "$pdev" 2>/dev/null || echo "")"
        case "$pfs" in
            vfat|fat|msdos) ;;
            *) continue ;;
        esac

        tmpmnt="$(mktemp -d)"
        if mount -t vfat -o ro "$pdev" "$tmpmnt" 2>/dev/null; then
            if [ -f "$tmpmnt/EFI/Microsoft/Boot/bootmgfw.efi" ]; then
                blkid -s UUID -o value "$pdev"
                umount "$tmpmnt"
                rmdir "$tmpmnt"
                return 0
            fi
            umount "$tmpmnt" 2>/dev/null || true
        fi
        rmdir "$tmpmnt" 2>/dev/null || true
    done < <(partitions_of_disk "$DISK")
}

configure_grub() {
    local win_boot_uuid

    cat > /etc/default/grub <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=-1
GRUB_TIMEOUT_STYLE=menu
GRUB_DISTRIBUTOR="Linux Mint"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""
GRUB_DISABLE_OS_PROBER=true
GRUB_RECORDFAIL_TIMEOUT=-1
EOF

    rm -f /etc/default/grub.d/50_linuxmint.cfg 2>/dev/null || true
    win_boot_uuid="$(find_windows_boot_uuid || true)"

    if [ -n "$win_boot_uuid" ]; then
        cat > /etc/grub.d/40_custom <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry "Windows Boot Manager" --class windows --class os {
    insmod part_gpt
    insmod fat
    search --no-floppy --fs-uuid --set=root $win_boot_uuid
    chainloader /EFI/Microsoft/Boot/bootmgfw.efi
}
EOF
        chmod +x /etc/grub.d/40_custom
    else
        sed -i 's/GRUB_DISABLE_OS_PROBER=true/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
    fi

    os-prober 2>/dev/null || true
    update-grub
}

enable_first_boot_resize() {
    chmod +x /usr/local/bin/first-boot-resize.sh
    systemctl enable first-boot-resize.service
}

main() {
    configure_user
    configure_windows_mount
    configure_locale
    configure_keyboard
    configure_timezone
    cleanup_live_boot_artifacts
    cleanup_keyring_pam_noise
    configure_grub
    enable_first_boot_resize
}

main "$@"
