#!/bin/bash
# Sourced by libertix-install-main.sh, which owns run_logged, die and mark.
# shellcheck disable=SC2034

# Online installation of Arch-family distributions (CachyOS).
#
# The hash-verified distribution ISO stays the trust root. Its read-only live
# root filesystem provides pacman, pacstrap, the distribution keyrings and the
# mirror lists. pacstrap runs from that root into the target partition, so the
# installed system is built from signed packages downloaded online and checked
# against keys that came from the verified ISO. Nothing from the live desktop
# itself is copied, which leaves no live-session state to clean up.

readonly ARCH_BOOTSTRAP_ROOT=/run/libertix-bootstrap
readonly ARCH_BOOTSTRAP_LOWER="$ARCH_BOOTSTRAP_ROOT/lower"
readonly ARCH_BOOTSTRAP_RW="$ARCH_BOOTSTRAP_ROOT/rw"
readonly ARCH_BOOTSTRAP_CHROOT="$ARCH_BOOTSTRAP_ROOT/root"
readonly ARCH_AIROOTFS_RELATIVE_PATH="arch/x86_64/airootfs.sfs"
# The CachyOS live ISO ships the pacman.conf its own installer copies to the
# target. It enables the generic x86-64 [cachyos] repository, which runs on
# every 64-bit CPU.
readonly ARCH_PACMAN_CONFIG=/etc/pacman-more.conf
readonly LIVE_NETWORK_CONFIG=/run/systemd/network/80-libertix-wired.network
readonly LIVE_RESOLV_CONF=/run/systemd/resolve/resolv.conf
readonly EFI_SECURE_BOOT_VARIABLE=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c

# Mirrors the CachyOS installer's base, common and KDE Plasma selections,
# without the alternative filesystems Libertix never creates. GRUB, ntfs-3g,
# GTK and python-gobject serve the Libertix boot menu, Windows sharing and the
# first-boot result window.
readonly -a ARCH_FAMILY_PACKAGES=(
    base base-devel linux-cachyos linux-cachyos-headers linux-firmware
    amd-ucode intel-ucode mkinitcpio grub efibootmgr
    cachyos-hooks cachyos-keyring cachyos-mirrorlist cachyos-v3-mirrorlist
    cachyos-v4-mirrorlist cachyos-rate-mirrors cachyos-settings chwd
    sudo e2fsprogs dosfstools exfatprogs ntfs-3g inetutils less logrotate
    lsb-release man-db man-pages perl python python-gobject gtk3 sysfsutils
    texinfo usbutils which openssh
    networkmanager wpa_supplicant wireless-regdb nss-mdns
    bluez bluez-utils pipewire-pulse pipewire-alsa wireplumber
    alsa-utils sof-firmware power-profiles-daemon upower cpupower
    xdg-user-dirs xdg-utils bash-completion
    noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-dejavu ttf-liberation
    plasma-desktop plasma-login-manager cachyos-kde-settings konsole dolphin kate ark
    gwenview spectacle kcalc kinfocenter kscreen kde-gtk-config breeze-gtk
    kdeplasma-addons kwallet-pam kwalletmanager plasma-nm plasma-pa
    plasma-systemmonitor powerdevil bluedevil xsettingsd ffmpegthumbs
    kdegraphics-thumbnailers kdialog firefox
)

arch_bootstrap_mount_targets() {
    findmnt -rn -o TARGET 2>/dev/null |
        awk -v root="$ARCH_BOOTSTRAP_ROOT" 'index($0, root "/") == 1 || $0 == root' |
        sort -r
}

release_arch_bootstrap() {
    local target

    # Reverse lexical order detaches children, including the mounts pacstrap
    # leaves in a failed target, before the overlay and its lower layer.
    while IFS= read -r target; do
        [ -n "$target" ] || continue
        umount "$target" 2>/dev/null || true
    done < <(arch_bootstrap_mount_targets)
    [ -z "$(arch_bootstrap_mount_targets)" ]
}

release_arch_bootstrap_best_effort() {
    release_arch_bootstrap || echo "WARNING: bootstrap mounts remain under $ARCH_BOOTSTRAP_ROOT"
}

# Windows refuses the plan while Secure Boot is on. Check the firmware again,
# because the unsigned GRUB of this family cannot boot under Secure Boot.
assert_secure_boot_disabled_or_die() {
    local state

    [ -r "$EFI_SECURE_BOOT_VARIABLE" ] || return 0
    state="$(od -An -t u1 -j 4 -N 1 "$EFI_SECURE_BOOT_VARIABLE" | tr -d '[:space:]')"
    [ "$state" != 1 ] || \
        die "Secure Boot is enabled, but $DISTRIBUTION_NAME has no Microsoft-signed bootloader"
}

start_live_network_or_die() {
    if [ -s "$LIVE_RESOLV_CONF" ] && systemctl is-active --quiet systemd-networkd.service; then
        return 0
    fi

    install -d -m 0755 "$(dirname "$LIVE_NETWORK_CONFIG")"
    cat > "$LIVE_NETWORK_CONFIG" <<'EOF'
[Match]
Type=ether
Kind=!*

[Network]
DHCP=yes
EOF
    run_logged systemctl start systemd-resolved.service systemd-networkd.service
    if ! /usr/lib/systemd/systemd-networkd-wait-online \
        --any --operational-state=routable --timeout=120; then
        ip -brief link 2>/dev/null || true
        ip -brief address 2>/dev/null || true
        die "no wired internet connection is available for the online installation"
    fi
    for _ in $(seq 1 30); do
        [ -s "$LIVE_RESOLV_CONF" ] && grep -q '^nameserver ' "$LIVE_RESOLV_CONF" && break
        sleep 1
    done
    grep -q '^nameserver ' "$LIVE_RESOLV_CONF" 2>/dev/null || \
        die "the wired network did not provide a DNS server"
    ip -brief address 2>/dev/null || true
}

mount_arch_bootstrap_or_die() {
    local iso_root="$1" airootfs

    airootfs="$iso_root/$ARCH_AIROOTFS_RELATIVE_PATH"
    [ -f "$airootfs" ] || die "distribution ISO has no live root filesystem at $ARCH_AIROOTFS_RELATIVE_PATH"
    release_arch_bootstrap || die "previous bootstrap mounts could not be released"

    mkdir -p "$ARCH_BOOTSTRAP_LOWER" "$ARCH_BOOTSTRAP_RW" "$ARCH_BOOTSTRAP_CHROOT"
    run_logged mount -t squashfs -o loop,ro "$airootfs" "$ARCH_BOOTSTRAP_LOWER"
    # Only the keyring and package databases are written here. Downloaded
    # packages go to the target's own pacman cache.
    run_logged mount -t tmpfs -o mode=0755,size=1G libertix-bootstrap "$ARCH_BOOTSTRAP_RW"
    mkdir -p "$ARCH_BOOTSTRAP_RW/upper" "$ARCH_BOOTSTRAP_RW/work"
    run_logged mount -t overlay \
        -o "lowerdir=$ARCH_BOOTSTRAP_LOWER,upperdir=$ARCH_BOOTSTRAP_RW/upper,workdir=$ARCH_BOOTSTRAP_RW/work" \
        libertix-bootstrap "$ARCH_BOOTSTRAP_CHROOT"
    run_logged mount -t proc proc "$ARCH_BOOTSTRAP_CHROOT/proc"
    run_logged mount -t sysfs sys "$ARCH_BOOTSTRAP_CHROOT/sys"
    run_logged mount --rbind /dev "$ARCH_BOOTSTRAP_CHROOT/dev"
    run_logged mount --make-rslave "$ARCH_BOOTSTRAP_CHROOT/dev"
    run_logged mount -t tmpfs -o mode=0755 run "$ARCH_BOOTSTRAP_CHROOT/run"
    run_logged mount -t tmpfs -o mode=1777 tmp "$ARCH_BOOTSTRAP_CHROOT/tmp"

    rm -f "$ARCH_BOOTSTRAP_CHROOT/etc/resolv.conf"
    install -m 0644 "$LIVE_RESOLV_CONF" "$ARCH_BOOTSTRAP_CHROOT/etc/resolv.conf"

    # archiso images initialize the keyring at boot. Do the same from the
    # keyring packages inside the verified image.
    run_logged chroot "$ARCH_BOOTSTRAP_CHROOT" pacman-key --init
    run_logged chroot "$ARCH_BOOTSTRAP_CHROOT" pacman-key --populate
}

# Run before any disk mutation: proves that the wired network, DNS and the
# distribution mirrors work, and that their signed package databases load.
# A failure here rolls back Windows without having touched Linux storage.
verify_online_installation_preflight_or_die() {
    local iso_source="$1" iso_mount=/mnt/iso distribution_rootfs result=0

    mark "031-online-preflight"
    echo "Verifying installer ISO integrity before the online preflight..."
    verify_file_sha256 "$iso_source" "$ISO_SHA256" || \
        die "installer ISO SHA-256 does not match the validated installation plan"
    start_live_network_or_die

    mkdir -p "$iso_mount"
    run_logged mount -o loop,ro "$iso_source" "$iso_mount"
    distribution_rootfs="$(resolve_distribution_rootfs_or_die "$iso_mount" arch)" || result=1
    if [ "$result" -eq 0 ]; then
        assert_distribution_rootfs_compatible_or_die \
            "$distribution_rootfs" "$DISTRIBUTION_OS_RELEASE_ID" arch || result=1
    fi
    if [ "$result" -eq 0 ]; then
        mount_arch_bootstrap_or_die "$iso_mount"
        if ! run_logged chroot "$ARCH_BOOTSTRAP_CHROOT" \
            pacman --config "$ARCH_PACMAN_CONFIG" --noconfirm -Sy; then
            result=2
        fi
    fi
    release_arch_bootstrap || result=3
    umount "$iso_mount" || result=3

    case "$result" in
        0) echo "Online installation preflight succeeded." ;;
        1) die "installer ISO payload is incompatible with the signed distribution plan" ;;
        2) die "the distribution package mirrors could not be reached over the internet" ;;
        *) die "online preflight mounts could not be released" ;;
    esac
}

copy_arch_bootstrap_file_or_die() {
    local source="$1" destination="$2"

    [ -f "$ARCH_BOOTSTRAP_CHROOT$source" ] || die "bootstrap file is missing: $source"
    install -m 0644 -D "$ARCH_BOOTSTRAP_CHROOT$source" "/mnt/target$destination"
}

install_arch_family_system_or_die() {
    local iso_root="$1"

    mount_arch_bootstrap_or_die "$iso_root"
    mkdir -p "$ARCH_BOOTSTRAP_CHROOT/mnt"
    run_logged mount --bind /mnt/target "$ARCH_BOOTSTRAP_CHROOT/mnt"
    # systemd makes mounts shared. Keep the mounts pacstrap creates inside the
    # bootstrap so they never appear under, or hold, the live /mnt/target.
    run_logged mount --make-private "$ARCH_BOOTSTRAP_CHROOT/mnt"

    echo "Downloading and installing ${#ARCH_FAMILY_PACKAGES[@]} packages..."
    run_logged chroot "$ARCH_BOOTSTRAP_CHROOT" \
        pacstrap -C "$ARCH_PACMAN_CONFIG" /mnt "${ARCH_FAMILY_PACKAGES[@]}"

    # The installed system keeps the repositories CachyOS's own installer
    # gives it. Its mkinitcpio.conf comes from its own mkinitcpio package, so
    # the initramfs hooks always match the packages actually installed.
    copy_arch_bootstrap_file_or_die "$ARCH_PACMAN_CONFIG" /etc/pacman.conf

    release_arch_bootstrap || die "bootstrap mounts could not be released after pacstrap"
    [ -s /mnt/target/etc/os-release ] || die "pacstrap did not produce an os-release file"
}
