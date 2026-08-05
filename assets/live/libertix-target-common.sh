#!/bin/bash

# Shared target-system preparation for both firmware modes.
#
# The active firmware adapter must provide write_target_fstab_or_die(). The
# adapter remains responsible for installing and verifying the final
# bootloader; this module only prepares the installed operating system.

mount_target_runtime_filesystems() {
    mount -t proc none /mnt/target/proc
    mount -t sysfs none /mnt/target/sys
    mount --bind /dev /mnt/target/dev
    mount --bind /dev/pts /mnt/target/dev/pts
}

mount_target_windows_partitions_read_only() {
    local partition partition_number_value filesystem mount_directory

    while read -r partition; do
        [ -n "$partition" ] || continue
        [ "$partition" = "$NEW_PART" ] && continue

        filesystem=$(blkid -s TYPE -o value "$partition" 2>/dev/null || echo "")
        [ "$filesystem" = "ntfs" ] || continue

        partition_number_value=$(partition_number "$partition")
        mount_directory="/mnt/target/mnt/win_$partition_number_value"
        mkdir -p "$mount_directory"
        mount -t ntfs-3g -o ro "$partition" "$mount_directory" 2>/dev/null || true
    done < <(partitions_of_disk "$DISK")
}

install_target_configuration_payload() {
    install -m 0755 /usr/local/lib/libertix/configure-target.sh \
        /mnt/target/tmp/libertix-configure-target.sh
    install -m 0755 /usr/local/lib/libertix/configure-target-main.sh \
        /mnt/target/tmp/configure-target-main.sh
    install -m 0755 /usr/local/lib/libertix/10_libertix \
        /mnt/target/tmp/10_libertix
    install -m 0755 /usr/local/lib/libertix/render-libertix-menu.py \
        /mnt/target/tmp/render-libertix-menu.py

    GRUB_RESOLUTION="$(detect_grub_resolution)"
    rm -rf /mnt/target/boot/grub/themes/Libertix
    /usr/local/lib/libertix/grub-theme-source/generate-theme.sh \
        "$GRUB_RESOLUTION" /mnt/target/boot/grub/themes/Libertix

    install -m 0755 /usr/local/lib/libertix/first-boot-resize.sh \
        /mnt/target/usr/local/bin/first-boot-resize.sh
    install -m 0644 /usr/local/lib/libertix/first-boot-resize.service \
        /mnt/target/etc/systemd/system/first-boot-resize.service
    install -m 0755 /usr/local/lib/libertix/libertix-apply-keyboard-once.sh \
        /mnt/target/usr/local/bin/libertix-apply-keyboard-once
    install -m 0755 /usr/local/lib/libertix/configure-development-access.sh \
        /mnt/target/tmp/libertix-configure-development-access.sh
    install -m 0755 /usr/local/lib/libertix/libertix-development-ssh-first-boot.sh \
        /mnt/target/tmp/libertix-development-ssh-first-boot.sh
    install -m 0644 /usr/local/lib/libertix/libertix-development-ssh.service \
        /mnt/target/tmp/libertix-development-ssh.service
}

run_target_configuration() {
    chroot /mnt/target /usr/bin/env \
        LANGUAGE_CODE="$LANGUAGE_CODE" \
        SYSTEM_LANG="$SYSTEM_LANG" \
        KEYBOARD_LAYOUT="$KEYBOARD_LAYOUT" \
        KEYBOARD_VARIANT="$KEYBOARD_VARIANT" \
        KEYBOARD_MODEL="$KEYBOARD_MODEL" \
        TIMEZONE="$TIMEZONE" \
        USERNAME="$USERNAME" \
        PASSWORD_HASH="$PASSWORD_HASH" \
        COMPUTER_NAME="$COMPUTER_NAME" \
        DISK="$DISK" \
        DISKNAME="$DISKNAME" \
        WINDOWS_PART="$WINDOWS_PART" \
        SHARE_WINDOWS_FILES_IN_LINUX="$SHARE_WINDOWS_FILES_IN_LINUX" \
        SHARE_LINUX_FILES_IN_WINDOWS="$SHARE_LINUX_FILES_IN_WINDOWS" \
        WINDOWS_PROFILES_JSON_BASE64="$WINDOWS_PROFILES_JSON_BASE64" \
        DEVELOPMENT_SSH_ENABLED="$DEVELOPMENT_SSH_ENABLED" \
        DEVELOPMENT_STATIC_IPV4_ADDRESS="$DEVELOPMENT_STATIC_IPV4_ADDRESS" \
        DEVELOPMENT_STATIC_IPV4_PREFIX_LENGTH="$DEVELOPMENT_STATIC_IPV4_PREFIX_LENGTH" \
        DEVELOPMENT_STATIC_IPV4_GATEWAY="$DEVELOPMENT_STATIC_IPV4_GATEWAY" \
        DEVELOPMENT_DNS_PRIMARY="$DEVELOPMENT_DNS_PRIMARY" \
        DEVELOPMENT_DNS_SECONDARY="$DEVELOPMENT_DNS_SECONDARY" \
        GRUB_RESOLUTION="$GRUB_RESOLUTION" \
        LIBERTIX_FIRMWARE_MODE="$LIBERTIX_FIRMWARE_MODE" \
        /tmp/libertix-configure-target.sh

    rm -f /mnt/target/tmp/libertix-configure-target.sh \
        /mnt/target/tmp/configure-target-main.sh \
        /mnt/target/tmp/10_libertix \
        /mnt/target/tmp/render-libertix-menu.py \
        /mnt/target/tmp/libertix-configure-development-access.sh \
        /mnt/target/tmp/libertix-development-ssh-first-boot.sh \
        /mnt/target/tmp/libertix-development-ssh.service
}

configure_target_system() {
    mark "130-target-system-config"
    mount_target_runtime_filesystems
    write_target_fstab_or_die
    mount_target_windows_partitions_read_only
    install_target_configuration_payload
    run_target_configuration
}

unmount_target_system() {
    local partition partition_number_value mount_directory

    while read -r partition; do
        [ -n "$partition" ] || continue
        partition_number_value=$(partition_number "$partition")
        mount_directory="/mnt/target/mnt/win_$partition_number_value"
        [ -d "$mount_directory" ] && umount "$mount_directory" 2>/dev/null || true
    done < <(partitions_of_disk "$DISK")

    umount /mnt/target/dev/pts 2>/dev/null || true
    umount /mnt/target/dev 2>/dev/null || true
    umount /mnt/target/proc 2>/dev/null || true
    umount /mnt/target/sys 2>/dev/null || true
    umount /mnt/target/boot/efi 2>/dev/null || true
    umount /mnt/target 2>/dev/null || true
    umount /mnt/windows 2>/dev/null || true
}
