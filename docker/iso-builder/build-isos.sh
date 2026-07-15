#!/bin/bash
set -Eeuo pipefail

mode="${1:-all}"
host_uid="${HOST_UID:?HOST_UID is required}"
host_gid="${HOST_GID:?HOST_GID is required}"

[ -f /workspace/iso/build.sh ] || {
    echo "Libertix source tree is not mounted at /workspace" >&2
    exit 1
}

git config --global --add safe.directory /workspace

case "$mode" in
    bios)
        /workspace/iso/build.sh
        verify-libertix-iso bios /workspace/libertix-installer-bios.iso
        outputs=(/workspace/libertix-installer-bios.iso)
        ;;
    uefi)
        /workspace/iso-uefi/build.sh
        verify-libertix-iso uefi /workspace/libertix-installer-uefi.iso
        outputs=(/workspace/libertix-installer-uefi.iso)
        ;;
    all)
        /workspace/iso/build.sh
        /workspace/iso-uefi/build.sh
        verify-libertix-iso bios /workspace/libertix-installer-bios.iso
        verify-libertix-iso uefi /workspace/libertix-installer-uefi.iso
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

chown "$host_uid:$host_gid" "${outputs[@]}"
sha256sum "${outputs[@]}"
