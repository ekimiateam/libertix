#!/bin/bash

libertix_stage_label() {
    case "$1" in
        runner-start) echo "Demarrage de l'installateur" ;;
        005-wait-prereqs) echo "Detection du live et du disque" ;;
        006-clean-windows-live-boot) echo "Nettoyage du boot temporaire Windows" ;;
        010-read-config) echo "Lecture de la configuration" ;;
        020-detect-disk) echo "Detection des partitions" ;;
        025-live-preflight) echo "Verification finale de compatibilite" ;;
        027-windows-live-boot-cleaned) echo "Boot temporaire nettoye" ;;
        030-check-mint-iso) echo "Verification de l'ISO Mint" ;;
        035-umount-windows) echo "Liberation de la partition Windows" ;;
        040-unmount-target-disk) echo "Liberation du disque cible" ;;
        050-assert-live-detached) echo "Verification du live en RAM" ;;
        060-set-mbr-type-83|060-set-linux-partition-type) echo "Preparation de la partition Linux" ;;
        070-wipefs-live-part) echo "Nettoyage de l'ancien systeme de fichiers" ;;
        080-mkfs-ext4) echo "Creation du systeme de fichiers Linux" ;;
        090-mount-target) echo "Montage de la cible Linux" ;;
        100-remount-windows-ro) echo "Remontage lecture seule de Windows" ;;
        110-loop-mount-mint-iso) echo "Montage de l'ISO Mint" ;;
        120-unsquashfs) echo "Extraction de Mint" ;;
        130-target-system-config) echo "Configuration du systeme installe" ;;
        140-install-bootloader) echo "Installation du bootloader" ;;
        150-final-verify) echo "Verification finale" ;;
        installer-success) echo "Installation terminee" ;;
        installer-failed-*) echo "Installation echouee" ;;
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
