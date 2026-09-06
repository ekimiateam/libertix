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

unmount_target_windows_partitions() {
    local partition partition_number_value mount_directory

    while read -r partition; do
        [ -n "$partition" ] || continue
        partition_number_value=$(partition_number "$partition")
        mount_directory="/mnt/target/mnt/win_$partition_number_value"
        if mountpoint -q "$mount_directory"; then
            umount "$mount_directory" || return 1
        fi
    done < <(partitions_of_disk "$DISK")
}

install_target_configuration_payload() {
    install -d -m 0755 /mnt/target/etc/libertix
    install -d -m 0755 /mnt/target/usr/local/lib/libertix
    install -m 0644 "$INSTALLATION_PLAN_PATH" \
        /mnt/target/etc/libertix/installation-plan.json
    install -m 0644 /usr/local/lib/libertix/Libertix.InstallationPolicy.json \
        /mnt/target/etc/libertix/Libertix.InstallationPolicy.json
    install -m 0755 /usr/local/lib/libertix/configure-target.sh \
        /mnt/target/tmp/libertix-configure-target.sh
    install -m 0755 /usr/local/lib/libertix/configure-target-main.sh \
        /mnt/target/tmp/configure-target-main.sh
    install -m 0755 /usr/local/lib/libertix/libertix-apply-windows-preferences.py \
        /mnt/target/tmp/libertix-apply-windows-preferences.py
    install -m 0755 /usr/local/lib/libertix/libertix-storage-common.sh \
        /mnt/target/tmp/libertix-storage-common.sh
    install -m 0755 /usr/local/lib/libertix/10_libertix \
        /mnt/target/tmp/10_libertix
    install -m 0755 /usr/local/lib/libertix/render-libertix-menu.py \
        /mnt/target/tmp/render-libertix-menu.py
    install -m 0644 /usr/local/lib/libertix/Libertix.Translations.json \
        /mnt/target/usr/local/lib/libertix/Libertix.Translations.json
    install -m 0644 /usr/local/lib/libertix/Libertix.ico \
        /mnt/target/usr/local/lib/libertix/Libertix.ico
    install -m 0755 /usr/local/lib/libertix/libertix-validate-grub.sh \
        /mnt/target/usr/local/lib/libertix/libertix-validate-grub
    install -m 0755 /usr/local/lib/libertix/libertix-update-grub.sh \
        /mnt/target/usr/local/lib/libertix/libertix-update-grub.sh
    install -m 0755 /usr/local/lib/libertix/libertix-sync-efi.sh \
        /mnt/target/usr/local/sbin/libertix-sync-efi
    install -m 0755 /usr/local/lib/libertix/libertix-preferred-boot-path.py \
        /mnt/target/usr/local/lib/libertix/libertix-preferred-boot-path.py
    install -m 0755 /usr/local/lib/libertix/libertix-secure-boot-chain.py \
        /mnt/target/usr/local/lib/libertix/libertix-secure-boot-chain.py
    install -m 0644 /usr/local/lib/libertix/libertix-efi-sync.service \
        /mnt/target/etc/systemd/system/libertix-efi-sync.service
    install -m 0644 /usr/local/lib/libertix/libertix-efi-sync.path \
        /mnt/target/etc/systemd/system/libertix-efi-sync.path

    GRUB_RESOLUTION="$(detect_grub_resolution)"
    rm -rf /mnt/target/boot/grub/themes/Libertix
    /usr/local/lib/libertix/grub-theme-source/generate-theme.sh \
        "$GRUB_RESOLUTION" /mnt/target/boot/grub/themes/Libertix

    install -m 0755 /usr/local/lib/libertix/first-boot-resize.sh \
        /mnt/target/usr/local/bin/first-boot-resize.sh
    install -m 0755 /usr/local/lib/libertix/libertix-first-boot-verify.py \
        /mnt/target/usr/local/lib/libertix/libertix-first-boot-verify.py
    install -m 0755 /usr/local/lib/libertix/libertix-first-boot-result.py \
        /mnt/target/usr/local/lib/libertix/libertix-first-boot-result.py
    install -d -m 0755 /mnt/target/etc/xdg/autostart
    install -m 0644 /usr/local/lib/libertix/libertix-first-boot-result.desktop \
        /mnt/target/etc/xdg/autostart/libertix-first-boot-result.desktop
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
    if [ "$WINDOWS_PREFERENCE_MIGRATION_ENABLED" = true ]; then
        [ -f "$WINDOWS_PREFERENCE_BUNDLE_RUNTIME_PATH" ] || {
            echo "Windows preference migration runtime bundle is missing" >&2
            return 1
        }
        install -m 0600 "$WINDOWS_PREFERENCE_BUNDLE_RUNTIME_PATH" \
            /mnt/target/tmp/windows-preferences.secret.json
    fi
}

run_target_configuration() {
    local result=0

    chroot /mnt/target /usr/bin/env \
        INSTALLATION_PLAN_ID="$INSTALLATION_PLAN_ID" \
        LANGUAGE_CODE="$LANGUAGE_CODE" \
        DISTRIBUTION_ID="$DISTRIBUTION_ID" \
        DISTRIBUTION_NAME="$DISTRIBUTION_NAME" \
        DISTRIBUTION_OS_RELEASE_ID="$DISTRIBUTION_OS_RELEASE_ID" \
        DISTRIBUTION_GRUB_DISPLAY_NAME="$DISTRIBUTION_GRUB_DISPLAY_NAME" \
        DISTRIBUTION_GRUB_ICON="$DISTRIBUTION_GRUB_ICON" \
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
        WINDOWS_BOOT_PART="$WINDOWS_BOOT_PART" \
        SHARE_WINDOWS_FILES_IN_LINUX="$SHARE_WINDOWS_FILES_IN_LINUX" \
        SHARE_LINUX_FILES_IN_WINDOWS="$SHARE_LINUX_FILES_IN_WINDOWS" \
        WINDOWS_PROFILES_JSON_BASE64="$WINDOWS_PROFILES_JSON_BASE64" \
        WINDOWS_PREFERENCE_MIGRATION_ENABLED="$WINDOWS_PREFERENCE_MIGRATION_ENABLED" \
        WINDOWS_PREFERENCE_WIFI_PROFILE_COUNT="$WINDOWS_PREFERENCE_WIFI_PROFILE_COUNT" \
        DEVELOPMENT_SSH_ENABLED="$DEVELOPMENT_SSH_ENABLED" \
        DEVELOPMENT_STATIC_IPV4_ADDRESS="$DEVELOPMENT_STATIC_IPV4_ADDRESS" \
        DEVELOPMENT_STATIC_IPV4_PREFIX_LENGTH="$DEVELOPMENT_STATIC_IPV4_PREFIX_LENGTH" \
        DEVELOPMENT_STATIC_IPV4_GATEWAY="$DEVELOPMENT_STATIC_IPV4_GATEWAY" \
        DEVELOPMENT_DNS_SERVERS="$DEVELOPMENT_DNS_SERVERS" \
        GRUB_RESOLUTION="$GRUB_RESOLUTION" \
        LIBERTIX_FIRMWARE_MODE="$LIBERTIX_FIRMWARE_MODE" \
        /tmp/libertix-configure-target.sh || result=$?

    rm -f /mnt/target/tmp/libertix-configure-target.sh \
        /mnt/target/tmp/configure-target-main.sh \
        /mnt/target/tmp/libertix-apply-windows-preferences.py \
        /mnt/target/tmp/windows-preferences.secret.json \
        /mnt/target/tmp/libertix-storage-common.sh \
        /mnt/target/tmp/10_libertix \
        /mnt/target/tmp/render-libertix-menu.py \
        /mnt/target/tmp/libertix-configure-development-access.sh \
        /mnt/target/tmp/libertix-development-ssh-first-boot.sh \
        /mnt/target/tmp/libertix-development-ssh.service
    if [ -n "${WINDOWS_PREFERENCE_BUNDLE_RUNTIME_PATH:-}" ]; then
        rm -f -- "$WINDOWS_PREFERENCE_BUNDLE_RUNTIME_PATH"
        WINDOWS_PREFERENCE_BUNDLE_RUNTIME_PATH=""
        unset WINDOWS_PREFERENCE_BUNDLE_RUNTIME_PATH
    fi
    return "$result"
}

configure_target_system() {
    mark "130-target-system-config"
    mount_target_runtime_filesystems
    write_target_fstab_or_die
    mount_target_windows_partitions_read_only
    install_target_configuration_payload
    run_target_configuration
    unmount_target_windows_partitions
}

unmount_target_system() {
    local attempt

    # Some storage controllers release a recently active filesystem
    # asynchronously. Do not continue to the independent read-only verification
    # while any target mount is still present.
    for ((attempt = 1; attempt <= 10; attempt++)); do
        unmount_target_windows_partitions || true
        umount /mnt/target/dev/pts 2>/dev/null || true
        umount /mnt/target/dev 2>/dev/null || true
        umount /mnt/target/proc 2>/dev/null || true
        umount /mnt/target/sys 2>/dev/null || true
        umount /mnt/target/boot/efi 2>/dev/null || true
        if findmnt -rn -R /mnt/target 2>/dev/null | grep -q .; then
            umount -R /mnt/target 2>/dev/null || true
        fi
        umount /mnt/target 2>/dev/null || true
        umount /mnt/windows 2>/dev/null || true

        if ! findmnt -rn -R /mnt/target 2>/dev/null | grep -q . \
            && ! findmnt -rn -S "$NEW_PART" 2>/dev/null | grep -q .; then
            return 0
        fi

        sync || true
        udevadm settle 2>/dev/null || true
        sleep 1
    done

    echo "ERROR: target filesystem is still mounted after 10 release attempts"
    findmnt -rn -R /mnt/target 2>/dev/null || true
    findmnt -rn -S "$NEW_PART" 2>/dev/null || true
    return 1
}
