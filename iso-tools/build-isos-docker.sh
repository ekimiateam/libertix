#!/bin/bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILDER_DIR="$ROOT_DIR/docker/iso-builder"
IMAGE_NAME="libertix-iso-builder:trixie"
MODE="${1:-all}"
LOG_DIR="${LIBERTIX_ISO_BUILD_LOG_DIR:-$ROOT_DIR/build-logs}"
LOG_FILE="$LOG_DIR/iso-build-$(date -u +%Y%m%dT%H%M%SZ)-$MODE.log"

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

mkdir -p "$LOG_DIR"
: > "$LOG_FILE"

report_stage_warnings() {
    local stage="$1"
    local first_line="$2"
    local warnings

    warnings="$(
        tail -n "+$first_line" "$LOG_FILE" |
            grep -Ei '(^|[^[:alpha:]])(warning|error|fatal|failed|failure)([^[:alpha:]]|$)|^W:' |
            awk '!seen[$0]++' |
            tail -n 80 || true
    )"
    if [ -n "$warnings" ]; then
        echo "WARNING $stage"
        printf '%s\n' "$warnings"
    fi
}

run_stage() {
    local stage="$1"
    local first_line rc diagnostics
    shift

    first_line=$(($(wc -l < "$LOG_FILE") + 1))
    echo "PHASE $stage"
    set +e
    "$@" >> "$LOG_FILE" 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        report_stage_warnings "$stage" "$first_line"
        return 0
    fi

    echo "ERROR $stage rc=$rc log=$LOG_FILE" >&2
    diagnostics="$(
        tail -n "+$first_line" "$LOG_FILE" |
            grep -Ei '(^|[^[:alpha:]])(warning|error|fatal|failed|failure)([^[:alpha:]]|$)|^W:' |
            tail -n 120 || true
    )"
    if [ -n "$diagnostics" ]; then
        printf '%s\n' "$diagnostics" >&2
    else
        tail -n 80 "$LOG_FILE" >&2
    fi
    return "$rc"
}

run_stage "builder-image" \
    docker build --pull \
        --build-arg "DEBIAN_SNAPSHOT=$DEBIAN_SNAPSHOT" \
        --build-arg "DEBIAN_SUITE=$DEBIAN_SUITE" \
        --tag "$IMAGE_NAME" \
        "$BUILDER_DIR"

run_stage "iso-$MODE" \
    docker run --rm --privileged \
        --env "HOST_UID=$(id -u)" \
        --env "HOST_GID=$(id -g)" \
        --env "LIBERTIX_DEBIAN_SNAPSHOT=$DEBIAN_SNAPSHOT" \
        --env "LIBERTIX_DEBIAN_SUITE=$DEBIAN_SUITE" \
        --volume "$ROOT_DIR:/workspace" \
        "$IMAGE_NAME" "$MODE"

case "$MODE" in
    bios) outputs=("$ROOT_DIR/libertix-installer-bios.iso") ;;
    uefi) outputs=("$ROOT_DIR/libertix-installer-uefi.iso") ;;
    all)
        outputs=(
            "$ROOT_DIR/libertix-installer-bios.iso"
            "$ROOT_DIR/libertix-installer-uefi.iso"
        )
        ;;
esac

for output in "${outputs[@]}"; do
    echo "ARTIFACT $(basename "$output") sha256=$(sha256sum "$output" | awk '{print $1}')"
done
echo "RESULT OK log=$LOG_FILE"
