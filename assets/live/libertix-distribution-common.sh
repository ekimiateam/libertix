#!/bin/bash

# Discover and validate the payload by filesystem capabilities. Distribution
# names are presentation metadata and never select an extraction code path.

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

resolve_distribution_rootfs_or_die() {
    local iso_root="$1" candidate
    local -a candidates=()

    while IFS= read -r -d '' candidate; do
        candidates+=("$candidate")
    done < <(
        find -L "$iso_root" -mindepth 2 -maxdepth 3 -type f \
            -name filesystem.squashfs -print0
    )

    if [ "${#candidates[@]}" -ne 1 ]; then
        echo "Expected exactly one filesystem.squashfs payload, found ${#candidates[@]}" >&2
        return 1
    fi
    printf '%s\n' "${candidates[0]}"
}

assert_distribution_rootfs_compatible_or_die() {
    local rootfs="$1" expected_id="$2" actual_id id_like token compatible=false

    [ -f "$rootfs" ] || {
        echo "Distribution root filesystem is missing: $rootfs" >&2
        return 1
    }
    for required in \
        etc/os-release \
        var/lib/dpkg/status \
        usr/sbin/update-grub \
        usr/sbin/update-initramfs \
        usr/bin/lsinitramfs; do
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
        case "$token" in
            debian|ubuntu) compatible=true ;;
        esac
    done
    [ "$compatible" = true ] || {
        echo "Distribution payload is not in the Debian/Ubuntu family" >&2
        return 1
    }

    echo "Distribution payload verified: ID=$actual_id ID_LIKE=${id_like:-none} rootfs=$rootfs"
}
