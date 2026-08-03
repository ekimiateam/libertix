#!/bin/bash

libertix_stage_label() {
    case "$1" in
        runner-start) echo "$LIBERTIX_I18N_STAGE_RUNNER_START" ;;
        005-wait-prereqs) echo "$LIBERTIX_I18N_STAGE_005_WAIT_PREREQS" ;;
        006-clean-windows-live-boot) echo "$LIBERTIX_I18N_STAGE_006_CLEAN_WINDOWS_LIVE_BOOT" ;;
        010-read-config) echo "$LIBERTIX_I18N_STAGE_010_READ_CONFIG" ;;
        020-detect-disk) echo "$LIBERTIX_I18N_STAGE_020_DETECT_DISK" ;;
        025-live-preflight) echo "$LIBERTIX_I18N_STAGE_025_LIVE_PREFLIGHT" ;;
        027-windows-live-boot-cleaned) echo "$LIBERTIX_I18N_STAGE_027_WINDOWS_LIVE_BOOT_CLEANED" ;;
        030-check-mint-iso) echo "$LIBERTIX_I18N_STAGE_030_CHECK_MINT_ISO" ;;
        035-umount-windows) echo "$LIBERTIX_I18N_STAGE_035_UMOUNT_WINDOWS" ;;
        040-unmount-target-disk) echo "$LIBERTIX_I18N_STAGE_040_UNMOUNT_TARGET_DISK" ;;
        050-assert-live-detached) echo "$LIBERTIX_I18N_STAGE_050_ASSERT_LIVE_DETACHED" ;;
        060-set-mbr-type-83|060-set-linux-partition-type) echo "$LIBERTIX_I18N_STAGE_060_LINUX_PARTITION" ;;
        070-wipefs-live-part) echo "$LIBERTIX_I18N_STAGE_070_WIPEFS_LIVE_PART" ;;
        080-mkfs-ext4) echo "$LIBERTIX_I18N_STAGE_080_MKFS_EXT4" ;;
        090-mount-target) echo "$LIBERTIX_I18N_STAGE_090_MOUNT_TARGET" ;;
        100-remount-windows-ro) echo "$LIBERTIX_I18N_STAGE_100_REMOUNT_WINDOWS_RO" ;;
        110-loop-mount-mint-iso) echo "$LIBERTIX_I18N_STAGE_110_LOOP_MOUNT_MINT_ISO" ;;
        120-unsquashfs) echo "$LIBERTIX_I18N_STAGE_120_UNSQUASHFS" ;;
        130-target-system-config) echo "$LIBERTIX_I18N_STAGE_130_TARGET_SYSTEM_CONFIG" ;;
        140-install-bootloader) echo "$LIBERTIX_I18N_STAGE_140_INSTALL_BOOTLOADER" ;;
        150-final-verify) echo "$LIBERTIX_I18N_STAGE_150_FINAL_VERIFY" ;;
        installer-success) echo "$LIBERTIX_I18N_STAGE_INSTALLER_SUCCESS" ;;
        installer-failed-*) echo "$LIBERTIX_I18N_STAGE_INSTALLER_FAILED" ;;
        *) echo "$1" ;;
    esac
}

libertix_stage_percent() {
    case "$1" in
        runner-start) echo 1 ;;
        005-wait-prereqs) echo 3 ;;
        006-clean-windows-live-boot) echo 5 ;;
        010-read-config) echo 10 ;;
        020-detect-disk) echo 14 ;;
        025-live-preflight) echo 16 ;;
        027-windows-live-boot-cleaned) echo 17 ;;
        030-check-mint-iso) echo 18 ;;
        035-umount-windows) echo 22 ;;
        040-unmount-target-disk) echo 26 ;;
        050-assert-live-detached) echo 30 ;;
        060-set-mbr-type-83|060-set-linux-partition-type) echo 34 ;;
        070-wipefs-live-part) echo 38 ;;
        080-mkfs-ext4) echo 42 ;;
        090-mount-target) echo 46 ;;
        100-remount-windows-ro) echo 50 ;;
        110-loop-mount-mint-iso) echo 54 ;;
        120-unsquashfs) echo 64 ;;
        130-target-system-config) echo 76 ;;
        140-install-bootloader) echo 90 ;;
        150-final-verify) echo 98 ;;
        installer-success|installer-failed-*) echo 100 ;;
        *) echo 1 ;;
    esac
}
