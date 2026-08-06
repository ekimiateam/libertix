#!/bin/bash
set -Eeuo pipefail

mode="${1:-all}"
host_uid="${HOST_UID:?HOST_UID is required}"
host_gid="${HOST_GID:?HOST_GID is required}"
parallel="${LIBERTIX_ISO_PARALLEL:-1}"
apt_cache_root="${LIBERTIX_APT_CACHE_ROOT:-}"

[ -f /workspace/iso/build.sh ] || {
    echo "Libertix source tree is not mounted at /workspace" >&2
    exit 1
}

git config --global --add safe.directory /workspace

# Each firmware mode owns its cache directory. A shared one would serialize the
# two builds on the apt archives lock and race on partial downloads.
apt_cache_for() {
    [ -n "$apt_cache_root" ] || return 0
    printf '%s/%s' "$apt_cache_root" "$1"
}

build_one() {
    local target="$1" script
    case "$target" in
        bios) script=/workspace/iso/build.sh ;;
        uefi) script=/workspace/iso-uefi/build.sh ;;
    esac
    LIBERTIX_APT_CACHE_DIR="$(apt_cache_for "$target")" "$script"
    verify-libertix-iso "$target" "/workspace/libertix-installer-$target.iso"
}

# Both modes rebuild a full rootfs from scratch and share nothing but the
# read-only source tree, so running them together overlaps the network bound
# debootstrap of one with the CPU bound squashfs of the other.
build_both_in_parallel() {
    local bios_log=/tmp/libertix-build-bios.log
    local uefi_log=/tmp/libertix-build-uefi.log
    local bios_pid uefi_pid bios_rc=0 uefi_rc=0

    # Each build writes to its own file rather than through a tagging pipe.
    # Maintainer scripts run inside the chroot inherit the build stdout, and a
    # daemon that outlives the build keeps a pipe reader alive forever, which
    # hangs the whole container. A plain file cannot be held open that way.
    build_one bios > "$bios_log" 2>&1 &
    bios_pid=$!
    build_one uefi > "$uefi_log" 2>&1 &
    uefi_pid=$!

    wait "$bios_pid" || bios_rc=$?
    wait "$uefi_pid" || uefi_rc=$?

    sed 's/^/[bios] /' "$bios_log"
    sed 's/^/[uefi] /' "$uefi_log"

    [ "$bios_rc" -eq 0 ] || return "$bios_rc"
    [ "$uefi_rc" -eq 0 ] || return "$uefi_rc"
}

case "$mode" in
    bios)
        build_one bios
        python3 /workspace/iso-tools/sync_filepool_checksums.py \
            --bios /workspace/libertix-installer-bios.iso
        outputs=(/workspace/libertix-installer-bios.iso)
        ;;
    uefi)
        build_one uefi
        python3 /workspace/iso-tools/sync_filepool_checksums.py \
            --uefi /workspace/libertix-installer-uefi.iso
        outputs=(/workspace/libertix-installer-uefi.iso)
        ;;
    all)
        if [ "$parallel" = "1" ]; then
            build_both_in_parallel
        else
            build_one bios
            build_one uefi
        fi
        python3 /workspace/iso-tools/sync_filepool_checksums.py \
            --bios /workspace/libertix-installer-bios.iso \
            --uefi /workspace/libertix-installer-uefi.iso
        outputs=(
            /workspace/libertix-installer-bios.iso
            /workspace/libertix-installer-uefi.iso
        )
        ;;
    *)
        echo "Usage: build-libertix-isos [all|bios|uefi]" >&2
        exit 2
        ;;
esac

chown "$host_uid:$host_gid" \
    "${outputs[@]}" \
    /workspace/auto_tests/app/filepool/distros.json
sha256sum "${outputs[@]}"
