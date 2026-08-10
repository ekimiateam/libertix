#!/bin/bash
set -Eeuo pipefail

: "${LIBERTIX_FIRMWARE_MODE:?LIBERTIX_FIRMWARE_MODE is required}"
case "$LIBERTIX_FIRMWARE_MODE" in
    bios|uefi) ;;
    *) echo "Unsupported firmware mode: $LIBERTIX_FIRMWARE_MODE" >&2; exit 2 ;;
esac

. /tmp/libertix-storage-common.sh

# The root menu intentionally contains Linux, Windows, Shutdown, and the
# Advanced options submenu. Kernel, firmware, and diagnostic entries are nested.
readonly EXPECTED_GRUB_ROOT_ENTRY_COUNT=4

configure_user() {
    local group available_groups=""

    if id "$USERNAME" >/dev/null 2>&1; then
        [ "$(id -u "$USERNAME")" -ne 0 ] || { echo "Refusing UID 0 desktop account" >&2; exit 1; }
    else
        useradd -m -s /bin/bash "$USERNAME"
    fi
    getent group sudo >/dev/null || { echo "Required sudo group is missing" >&2; exit 1; }
    for group in sudo adm cdrom audio video plugdev; do
        getent group "$group" >/dev/null || continue
        if [ -n "$available_groups" ]; then
            available_groups="$available_groups,$group"
        else
            available_groups="$group"
        fi
    done
    usermod -s /bin/bash -a -G "$available_groups" "$USERNAME"
    [[ "$PASSWORD_HASH" == \$6\$* ]] || { echo "Invalid Linux password hash" >&2; exit 1; }
    usermod --password "$PASSWORD_HASH" "$USERNAME"
    passwd -S "$USERNAME" | grep -Eq "^[^ ]+ P "
    echo "$COMPUTER_NAME" > /etc/hostname
}

assert_target_distribution_identity() {
    local actual_id id_like token compatible=false

    [ -r /etc/os-release ] || { echo "Target os-release is missing" >&2; exit 1; }
    # os-release is part of the hash-verified squashfs and defines shell-safe
    # assignments by specification.
    . /etc/os-release
    actual_id="${ID:-}"
    id_like="${ID_LIKE:-}"
    [ "$actual_id" = "$DISTRIBUTION_OS_RELEASE_ID" ] || {
        echo "Target distribution mismatch: expected $DISTRIBUTION_OS_RELEASE_ID, found ${actual_id:-missing}" >&2
        exit 1
    }
    for token in $actual_id $id_like; do
        case "$token" in
            debian|ubuntu) compatible=true ;;
        esac
    done
    [ "$compatible" = true ] || {
        echo "Target distribution is not in the Debian/Ubuntu family" >&2
        exit 1
    }
}

configure_windows_mount() {
    local win_uuid uid gid
    [ "$SHARE_WINDOWS_FILES_IN_LINUX" = "true" ] || {
        echo "Windows-to-Linux file sharing disabled by the user."
        return 0
    }
    [ -b "$WINDOWS_PART" ] || { echo "Windows partition missing: $WINDOWS_PART" >&2; exit 1; }
    [ "$(blkid -s TYPE -o value "$WINDOWS_PART" 2>/dev/null)" = "ntfs" ] || {
        echo "Windows partition is not NTFS: $WINDOWS_PART" >&2
        exit 1
    }
    win_uuid="$(blkid -s UUID -o value "$WINDOWS_PART")"
    [ -n "$win_uuid" ] || { echo "Windows UUID missing" >&2; exit 1; }
    uid="$(id -u "$USERNAME")"
    gid="$(id -g "$USERNAME")"
    mkdir -p /mnt/windows
    echo "UUID=$win_uuid /mnt/windows ntfs-3g defaults,uid=$uid,gid=$gid,dmask=022,fmask=133,windows_names,nofail 0 0" >> /etc/fstab
}

configure_windows_profile_shortcuts() {
    [ "$SHARE_WINDOWS_FILES_IN_LINUX" = "true" ] || return 0
    local home_dir bookmarks profile shortcut profiles_output
    home_dir="/home/$USERNAME"
    bookmarks="$home_dir/.config/gtk-3.0/bookmarks"
    mkdir -p "$(dirname "$bookmarks")"
    : > "$bookmarks"

    profiles_output=$(python3 - "$WINDOWS_PROFILES_JSON_BASE64" <<'PY'
import base64
import json
import sys

profiles = json.loads(base64.b64decode(sys.argv[1], validate=True).decode("utf-8"))
if not isinstance(profiles, list) or not all(isinstance(item, str) for item in profiles):
    raise SystemExit("invalid Windows profile manifest")
for profile in profiles:
    print(profile)
PY
    ) || { echo "Cannot decode Windows profile manifest" >&2; exit 1; }
    while IFS= read -r profile; do
        [ -n "$profile" ] || continue
        case "$profile" in .|..|*/*) echo "Invalid Windows profile name: $profile" >&2; exit 1 ;; esac
        shortcut="User_$profile"
        ln -sfn "/mnt/windows/Users/$profile" "$home_dir/$shortcut"
        printf 'file://%s/%s %s\n' "$home_dir" "$shortcut" "$shortcut" >> "$bookmarks"
    done <<< "$profiles_output"
    chown -h "$USERNAME:$USERNAME" "$home_dir"/User_* 2>/dev/null || true
    chown -R "$USERNAME:$USERNAME" "$home_dir/.config"
}

configure_windows_readonly_request() {
    mkdir -p /etc/libertix
    printf '%s\n' "$SHARE_LINUX_FILES_IN_WINDOWS" > /etc/libertix/share-linux-in-windows
}

configure_locale() {
    local -a selected_locales=("$SYSTEM_LANG")

    {
        printf '%s UTF-8\n' "$SYSTEM_LANG"
        if [ "$SYSTEM_LANG" != "en_US.UTF-8" ]; then
            printf '%s UTF-8\n' "en_US.UTF-8"
            selected_locales+=("en_US.UTF-8")
        fi
    } > /etc/locale.gen
    # Ubuntu language packs add broad locale lists under supported.d. Passing
    # explicit locales prevents locale-gen from compiling every regional
    # variant; Debian relies only on locale.gen and rejects positional locales.
    if [ -d /var/lib/locales/supported.d ]; then
        locale-gen "${selected_locales[@]}"
    else
        locale-gen
    fi
    cat > /etc/default/locale <<EOF
LANG=$SYSTEM_LANG
LC_ALL=$SYSTEM_LANG
LANGUAGE=$LANGUAGE_CODE
EOF
}

divert_grub_generator() {
    local generator="$1" diverted="$2" requirement="$3" owner true_name

    case "$requirement" in
        required|optional) ;;
        *) echo "Invalid GRUB generator requirement: $requirement" >&2; return 2 ;;
    esac

    owner="$(dpkg-divert --listpackage "$generator")"
    if [ -n "$owner" ]; then
        [ "$owner" = "LOCAL" ] || {
            echo "GRUB generator has a foreign diversion: $generator ($owner)" >&2
            return 1
        }
        true_name="$(dpkg-divert --truename "$generator")"
        [ "$true_name" = "$diverted" ] || {
            echo "GRUB generator diversion target mismatch: $generator -> $true_name" >&2
            return 1
        }
    else
        [ "$requirement" = optional ] || [ -f "$generator" ] || {
            echo "Required GRUB generator is missing: $generator" >&2
            return 1
        }
        [ ! -e "$diverted" ] || {
            echo "GRUB generator diversion target already exists: $diverted" >&2
            return 1
        }
        dpkg-divert --local --add --rename --divert "$diverted" "$generator"
    fi

    if [ -f "$diverted" ]; then
        chmod 0755 "$diverted"
    elif [ "$requirement" = required ]; then
        echo "Diverted GRUB generator is missing: $diverted" >&2
        return 1
    fi
}

configure_keyboard() {
    cat > /etc/default/keyboard <<EOF
XKBMODEL="$KEYBOARD_MODEL"
XKBLAYOUT="$KEYBOARD_LAYOUT"
XKBVARIANT="$KEYBOARD_VARIANT"
XKBOPTIONS=""
BACKSPACE="guess"
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

    local keyboard_source="$KEYBOARD_LAYOUT"
    if [ -n "$KEYBOARD_VARIANT" ]; then
        keyboard_source="${KEYBOARD_LAYOUT}+${KEYBOARD_VARIANT}"
    fi

    mkdir -p /etc/dconf/db/local.d
    cat > /etc/dconf/db/local.d/00-keyboard <<EOF
[org/gnome/libgnomekbd/keyboard]
layouts=['$keyboard_source']
model='$KEYBOARD_MODEL'
[org/cinnamon/desktop/input-sources]
sources=[('xkb', '$keyboard_source')]
[org/gnome/desktop/input-sources]
sources=[('xkb', '$keyboard_source')]
EOF
    dconf update

    mkdir -p /etc/xdg/autostart
    cat > /etc/xdg/autostart/libertix-keyboard.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Libertix keyboard initialization
Comment=Apply the installation keyboard layout to the first desktop session
Exec=/usr/local/bin/libertix-apply-keyboard-once
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
}

configure_timezone() {
    [ -f "/usr/share/zoneinfo/$TIMEZONE" ] || {
        echo "Unknown IANA timezone: $TIMEZONE" >&2
        return 1
    }
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    echo "$TIMEZONE" > /etc/timezone
}

configure_development_access() {
    /tmp/libertix-configure-development-access.sh
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

refresh_installed_initramfs() {
    local initrd listing found=false

    command -v update-initramfs >/dev/null || {
        echo "Target distribution does not provide update-initramfs" >&2
        return 1
    }
    command -v lsinitramfs >/dev/null || {
        echo "Target distribution does not provide lsinitramfs" >&2
        return 1
    }

    # Ubuntu-family live images can ship an initramfs that unconditionally
    # starts Casper. Rebuild it from the installed target after removing live
    # units so the next boot follows the real root filesystem capabilities.
    env -u CASPER_GENERATE_UUID update-initramfs -u -k all

    for initrd in /boot/initrd.img-*; do
        [ -f "$initrd" ] || continue
        found=true
        listing="$(lsinitramfs "$initrd")"
        if printf '%s\n' "$listing" | grep -Eq \
            '(^|/)(conf/conf.d/default-boot-to-casper\.conf|conf/conf.d/live-initrd\.conf|conf/uuid\.conf)$'; then
            echo "Installed initramfs still forces live boot: $initrd" >&2
            return 1
        fi
    done
    [ "$found" = true ] || {
        echo "Target distribution has no installed initramfs" >&2
        return 1
    }
}

find_windows_boot_uuid() {
    local filesystem mount_directory expected_file mount_type uuid

    [ -n "${WINDOWS_BOOT_PART:-}" ] && [ -b "$WINDOWS_BOOT_PART" ] || return 1
    filesystem="$(blkid -s TYPE -o value "$WINDOWS_BOOT_PART" 2>/dev/null || echo "")"
    if [ "$LIBERTIX_FIRMWARE_MODE" = "bios" ]; then
        [ "$filesystem" = "ntfs" ] || return 1
        mount_type="ntfs-3g"
        expected_file="bootmgr"
    else
        case "$filesystem" in
            vfat|fat|msdos) ;;
            *) return 1 ;;
        esac
        mount_type="vfat"
        expected_file="EFI/Microsoft/Boot/bootmgfw.efi"
    fi

    mount_directory="$(mktemp -d)"
    if ! mount -t "$mount_type" -o ro "$WINDOWS_BOOT_PART" "$mount_directory" 2>/dev/null; then
        rmdir "$mount_directory"
        return 1
    fi
    if [ ! -f "$mount_directory/$expected_file" ]; then
        umount "$mount_directory" 2>/dev/null || true
        rmdir "$mount_directory" 2>/dev/null || true
        return 1
    fi

    uuid="$(blkid -s UUID -o value "$WINDOWS_BOOT_PART" 2>/dev/null || true)"
    umount "$mount_directory" || return 1
    rmdir "$mount_directory" || return 1
    [ -n "$uuid" ] || return 1
    printf '%s\n' "$uuid"
}

write_windows_grub_entry() {
    local windows_boot_uuid="$1"

    mkdir -p /etc/libertix
    if [ "$LIBERTIX_FIRMWARE_MODE" = "bios" ]; then
        cat > /etc/libertix/grub-windows.cfg <<EOF
menuentry "Windows" --class windows --class os {
    insmod part_msdos
    insmod ntfs
    insmod ntldr
    search --no-floppy --fs-uuid --set=root $windows_boot_uuid
    ntldr /bootmgr
}
EOF
        return
    fi

    cat > /etc/libertix/grub-windows.cfg <<EOF
menuentry "Windows Boot Manager" --class windows --class os {
    insmod part_gpt
    insmod fat
    search --no-floppy --fs-uuid --set=root $windows_boot_uuid
    chainloader /EFI/Microsoft/Boot/bootmgfw.efi
}
EOF
}

assert_grub_configuration() {
    local grub_config=/boot/grub/grub.cfg root_entry_count

    grub-script-check "$grub_config" || {
        echo "Generated GRUB configuration has invalid syntax" >&2
        return 1
    }
    grep -Fq -- "--class $DISTRIBUTION_GRUB_ICON" "$grub_config" || {
        echo "Generated GRUB configuration is missing the distribution icon class" >&2
        return 1
    }
    grep -Fq "menuentry '$DISTRIBUTION_GRUB_DISPLAY_NAME'" "$grub_config" || {
        echo "Generated GRUB configuration is missing the distribution root entry" >&2
        return 1
    }
    grep -Fq -- "--class efi --id libertix-advanced" "$grub_config" || {
        echo "Generated GRUB configuration is missing the Advanced options submenu" >&2
        return 1
    }
    grep -Fq -- "--class shutdown --id libertix-shutdown" "$grub_config" || {
        echo "Generated GRUB configuration is missing the Shutdown entry" >&2
        return 1
    }

    root_entry_count="$(grep -Ec '^(menuentry|submenu) ' "$grub_config" || true)"
    [ "$root_entry_count" -eq "$EXPECTED_GRUB_ROOT_ENTRY_COUNT" ] || {
        echo "Generated GRUB configuration has $root_entry_count root entries; expected $EXPECTED_GRUB_ROOT_ENTRY_COUNT" >&2
        return 1
    }
}

configure_grub() {
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
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""
GRUB_DISABLE_OS_PROBER=true
GRUB_RECORDFAIL_TIMEOUT=-1
GRUB_THEME="/boot/grub/themes/Libertix/theme.txt"
EOF
    printf 'GRUB_GFXMODE="%s,auto"\n' "$GRUB_RESOLUTION" >> /etc/default/grub
    mkdir -p /etc/default/grub.d
    cp -f /etc/default/grub /etc/default/grub.d/99-libertix.cfg
    win_boot_uuid="$(find_windows_boot_uuid || true)"

    if [ -z "$win_boot_uuid" ]; then
        echo "Windows boot manager was not found" >&2
        exit 1
    fi
    write_windows_grub_entry "$win_boot_uuid"

    mkdir -p /usr/local/lib/libertix/grub-generators
    divert_grub_generator \
        /etc/grub.d/10_linux \
        /usr/local/lib/libertix/grub-generators/10_linux \
        required
    divert_grub_generator \
        /etc/grub.d/30_uefi-firmware \
        /usr/local/lib/libertix/grub-generators/30_uefi-firmware \
        optional
    for generator in /etc/grub.d/20_memtest86+ /etc/grub.d/20_memtest86; do
        divert_grub_generator \
            "$generator" \
            "/usr/local/lib/libertix/grub-generators/$(basename "$generator")" \
            optional
    done
    install -m 0755 /tmp/10_libertix /etc/grub.d/10_libertix
    install -m 0755 /tmp/render-libertix-menu.py \
        /usr/local/lib/libertix/render-libertix-menu.py
    chmod -x /etc/grub.d/40_custom 2>/dev/null || true

    update-grub
    assert_grub_configuration
}

enable_first_boot_resize() {
    chmod +x /usr/local/bin/first-boot-resize.sh
    systemctl enable first-boot-resize.service
}

main() {
    assert_target_distribution_identity
    configure_user
    configure_windows_mount
    configure_windows_profile_shortcuts
    configure_windows_readonly_request
    configure_locale
    configure_keyboard
    configure_timezone
    configure_development_access
    cleanup_live_boot_artifacts
    refresh_installed_initramfs
    configure_grub
    enable_first_boot_resize
}

main "$@"
