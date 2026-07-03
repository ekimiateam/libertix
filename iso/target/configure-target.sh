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

configure_user() {
    useradd -m -s /bin/bash -G sudo,adm,cdrom,audio,video,plugdev "$USERNAME" 2>/dev/null || true
    echo "$USERNAME:$PASSWORD" | chpasswd
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
    echo "$COMPUTER_NAME" > /etc/hostname
}

configure_windows_mount() {
    local win_uuid="" pdev pfs psize

    for pn in 1 2 3 4; do
        pdev="$(partition_path "$DISK" "$pn")"
        [ -b "$pdev" ] || continue
        pfs="$(blkid -s TYPE -o value "$pdev" 2>/dev/null || echo "")"
        if [ "$pfs" = "ntfs" ]; then
            psize=$(($(blockdev --getsize64 "$pdev" 2>/dev/null || echo 0) / 1024 / 1024 / 1024))
            if [ "$psize" -gt 10 ]; then
                win_uuid="$(blkid -s UUID -o value "$pdev")"
                break
            fi
        fi
    done

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

find_windows_boot_uuid() {
    local pdev pfs tmpmnt

    for pn in 1 2 3 4; do
        pdev="$(partition_path "$DISK" "$pn")"
        [ -b "$pdev" ] || continue
        pfs="$(blkid -s TYPE -o value "$pdev" 2>/dev/null || echo "")"
        [ "$pfs" = "ntfs" ] || continue

        tmpmnt="$(mktemp -d)"
        if mount -t ntfs-3g -o ro "$pdev" "$tmpmnt" 2>/dev/null; then
            if [ -f "$tmpmnt/bootmgr" ]; then
                blkid -s UUID -o value "$pdev"
                umount "$tmpmnt"
                rmdir "$tmpmnt"
                return 0
            fi
            umount "$tmpmnt" 2>/dev/null || true
        fi
        rmdir "$tmpmnt" 2>/dev/null || true
    done
}

configure_grub() {
    local win_boot_uuid

    cat > /etc/default/grub <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=10
GRUB_TIMEOUT_STYLE=menu
GRUB_DISTRIBUTOR="Linux Mint"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""
GRUB_DISABLE_OS_PROBER=true
GRUB_RECORDFAIL_TIMEOUT=10
EOF

    rm -f /etc/default/grub.d/50_linuxmint.cfg 2>/dev/null || true
    win_boot_uuid="$(find_windows_boot_uuid || true)"

    if [ -n "$win_boot_uuid" ]; then
        cat > /etc/grub.d/40_custom <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry "Windows 10" --class windows --class os {
    insmod part_msdos
    insmod ntfs
    insmod ntldr
    search --no-floppy --fs-uuid --set=root $win_boot_uuid
    ntldr /bootmgr
}
EOF
        chmod +x /etc/grub.d/40_custom
    else
        sed -i 's/GRUB_DISABLE_OS_PROBER=true/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
    fi

    grub-install --target=i386-pc --recheck "$DISK"
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
    configure_grub
    enable_first_boot_resize
}

main "$@"
