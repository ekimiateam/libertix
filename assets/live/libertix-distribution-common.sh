#!/bin/bash

# Discover and validate the payload by filesystem capabilities. Distribution
# names are presentation metadata and never select an extraction code path;
# only the signed plan's distribution family does.
#
#   debian  the ISO's filesystem.squashfs is extracted as the installed system.
#   arch    the ISO's archiso airootfs.sfs is a read-only bootstrap root that
#           installs the system with pacstrap (libertix-arch-family.sh).

distribution_squashfs_path_exists() {
    local rootfs="$1" path="$2"

    unsquashfs -ll "$rootfs" "$path" 2>/dev/null |
        grep -Fq "squashfs-root/$path"
}

read_distribution_os_release_value() {
    local rootfs="$1" key="$2"

    unsquashfs -cat "$rootfs" etc/os-release 2>/dev/null |
        awk -F= -v expected="$key" '
            $1 == expected {
                value = substr($0, index($0, "=") + 1)
                if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) {
                    value = substr(value, 2, length(value) - 2)
                }
                print value
                exit
            }
        '
}

distribution_rootfs_name() {
    case "$1" in
        debian) printf '%s\n' filesystem.squashfs ;;
        arch) printf '%s\n' airootfs.sfs ;;
        *) echo "Unsupported distribution family: $1" >&2; return 1 ;;
    esac
}

distribution_required_capabilities() {
    case "$1" in
        debian)
            printf '%s\n' \
                etc/os-release \
                var/lib/dpkg/status \
                usr/sbin/update-grub \
                usr/sbin/update-initramfs \
                usr/bin/lsinitramfs
            ;;
        arch)
            # pacman-more.conf is the target pacman.conf an archiso installer
            # image ships; the online preflight proves its repositories work.
            printf '%s\n' \
                etc/os-release \
                etc/pacman-more.conf \
                etc/pacman.d/mirrorlist \
                usr/bin/pacman \
                usr/bin/pacman-key \
                usr/bin/pacstrap \
                usr/share/pacman/keyrings/archlinux.gpg
            ;;
        *) echo "Unsupported distribution family: $1" >&2; return 1 ;;
    esac
}

distribution_family_tokens() {
    case "$1" in
        debian) printf '%s\n' debian ubuntu ;;
        arch) printf '%s\n' arch ;;
        *) echo "Unsupported distribution family: $1" >&2; return 1 ;;
    esac
}

resolve_distribution_rootfs_or_die() {
    local iso_root="$1" family="${2:-debian}" candidate name
    local -a candidates=()

    name="$(distribution_rootfs_name "$family")" || return 1
    while IFS= read -r -d '' candidate; do
        candidates+=("$candidate")
    done < <(
        find -L "$iso_root" -mindepth 2 -maxdepth 3 -type f \
            -name "$name" -print0
    )

    if [ "${#candidates[@]}" -ne 1 ]; then
        echo "Expected exactly one $name payload, found ${#candidates[@]}" >&2
        return 1
    fi
    printf '%s\n' "${candidates[0]}"
}

assert_distribution_rootfs_compatible_or_die() {
    local rootfs="$1" expected_id="$2" family="${3:-debian}"
    local actual_id id_like token compatible=false required
    local -a required_paths family_tokens

    [ -f "$rootfs" ] || {
        echo "Distribution root filesystem is missing: $rootfs" >&2
        return 1
    }
    mapfile -t required_paths < <(distribution_required_capabilities "$family")
    mapfile -t family_tokens < <(distribution_family_tokens "$family")
    [ "${#required_paths[@]}" -gt 0 ] && [ "${#family_tokens[@]}" -gt 0 ] || return 1
    for required in "${required_paths[@]}"; do
        distribution_squashfs_path_exists "$rootfs" "$required" || {
            echo "Distribution payload is missing required capability: $required" >&2
            return 1
        }
    done

    actual_id="$(read_distribution_os_release_value "$rootfs" ID)"
    id_like="$(read_distribution_os_release_value "$rootfs" ID_LIKE)"
    [[ "$actual_id" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || {
        echo "Distribution payload has an invalid or missing os-release ID" >&2
        return 1
    }
    [ "$actual_id" = "$expected_id" ] || {
        echo "Distribution identity mismatch: expected $expected_id, found $actual_id" >&2
        return 1
    }

    for token in $actual_id $id_like; do
        if printf '%s\n' "${family_tokens[@]}" | grep -Fxq -- "$token"; then
            compatible=true
        fi
    done
    [ "$compatible" = true ] || {
        echo "Distribution payload is not in the $family family" >&2
        return 1
    }

    echo "Distribution payload verified: ID=$actual_id ID_LIKE=${id_like:-none} rootfs=$rootfs family=$family"
}
