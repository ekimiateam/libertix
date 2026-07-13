#!/bin/bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILDER_DIR="$ROOT_DIR/docker/iso-builder"
IMAGE_NAME="libertix-iso-builder:trixie"
MODE="${1:-all}"

# One version file pins the base image digest and the Debian package archive.
source "$BUILDER_DIR/versions.env"

case "$MODE" in
    all|bios|uefi) ;;
    *)
        echo "Usage: $0 [all|bios|uefi]" >&2
        exit 2
        ;;
esac

command -v docker >/dev/null 2>&1 || {
    echo "Docker is required to build the Libertix ISO images" >&2
    exit 1
}

docker build --pull \
    --build-arg "DEBIAN_SNAPSHOT=$DEBIAN_SNAPSHOT" \
    --build-arg "DEBIAN_SUITE=$DEBIAN_SUITE" \
    --tag "$IMAGE_NAME" \
    "$BUILDER_DIR"
docker run --rm --privileged \
    --env "HOST_UID=$(id -u)" \
    --env "HOST_GID=$(id -g)" \
    --env "LIBERTIX_DEBIAN_SNAPSHOT=$DEBIAN_SNAPSHOT" \
    --env "LIBERTIX_DEBIAN_SUITE=$DEBIAN_SUITE" \
    --volume "$ROOT_DIR:/workspace" \
    "$IMAGE_NAME" "$MODE"
