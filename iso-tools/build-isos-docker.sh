#!/bin/bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILDER_DIR="$ROOT_DIR/docker/iso-builder"
IMAGE_NAME="libertix-iso-builder:trixie"
APT_CACHE_VOLUME="libertix-iso-apt-cache"
WORK_VOLUME="libertix-iso-work"
MODE="${1:-all}"
LOG_DIR="${LIBERTIX_ISO_BUILD_LOG_DIR:-$ROOT_DIR/build-logs}"
LOG_FILE="$LOG_DIR/iso-build-$(date -u +%Y%m%dT%H%M%SZ)-$MODE.log"
LOCK_DIR="$ROOT_DIR/.work"
LOCK_FILE="$LOCK_DIR/iso-build.lock"
WORKSPACE_ID="$(printf '%s' "$ROOT_DIR" | sha256sum | awk '{print $1}')"

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
command -v flock >/dev/null 2>&1 || {
    echo "flock is required to serialize Libertix ISO builds" >&2
    exit 1
}

mkdir -p "$LOG_DIR" "$LOCK_DIR"
: > "$LOG_FILE"
exec 9> "$LOCK_FILE"
if ! flock -n 9; then
    echo "Another Libertix ISO build is already using this workspace" >&2
    exit 1
fi

# A builder left behind by an interrupted run still holds the shared apt cache
# lock, which makes every later build fail before it downloads anything.
stale_builders="$(docker ps -q \
    --filter "label=com.ekimia.libertix.iso-builder=true" \
    --filter "label=com.ekimia.libertix.iso-workspace=$WORKSPACE_ID")"
if [ -n "$stale_builders" ]; then
    echo "Removing leftover ISO builder containers"
    # shellcheck disable=SC2086
    docker kill $stale_builders >/dev/null
fi

docker_run_options=(
    --rm --privileged
    --label "com.ekimia.libertix.iso-builder=true"
    --label "com.ekimia.libertix.iso-workspace=$WORKSPACE_ID"
    --env "HOST_UID=$(id -u)"
    --env "HOST_GID=$(id -g)"
    --env "LIBERTIX_DEBIAN_SNAPSHOT=$DEBIAN_SNAPSHOT"
    --env "LIBERTIX_DEBIAN_SUITE=$DEBIAN_SUITE"
    --env "LIBERTIX_ISO_PARALLEL=${LIBERTIX_ISO_PARALLEL:-1}"
    --env "LIBERTIX_APT_CACHE_ROOT=/var/cache/libertix-apt"
    --env "LIBERTIX_SQUASHFS_COMPRESSOR=${LIBERTIX_SQUASHFS_COMPRESSOR:-zstd}"
    --env "LIBERTIX_SQUASHFS_LEVEL=${LIBERTIX_SQUASHFS_LEVEL:-19}"
    --volume "$ROOT_DIR:/workspace"
    --volume "$APT_CACHE_VOLUME:/var/cache/libertix-apt"
    --volume "$WORK_VOLUME:/var/lib/libertix-work"
)

echo "WORKSPACE disk-volume:$WORK_VOLUME"

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

# The base image is pinned by digest, so --pull would only add a registry
# round trip to every build without changing what is built.
run_stage "builder-image" \
    docker build \
        --build-arg "DEBIAN_SNAPSHOT=$DEBIAN_SNAPSHOT" \
        --build-arg "DEBIAN_SUITE=$DEBIAN_SUITE" \
        --tag "$IMAGE_NAME" \
        "$BUILDER_DIR"

run_stage "iso-$MODE" \
    docker run "${docker_run_options[@]}" "$IMAGE_NAME" "$MODE"

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

publish_filepool_artifact() {
    local source="$1" destination temporary

    destination="$ROOT_DIR/auto_tests/app/filepool/$(basename "$source")"
    temporary="${destination}.tmp.$$"
    cp -- "$source" "$temporary"
    chmod 0644 "$temporary"
    mv -f -- "$temporary" "$destination"
    cmp -s -- "$source" "$destination" || {
        echo "Published filepool artifact does not match: $destination" >&2
        return 1
    }
}

for output in "${outputs[@]}"; do
    publish_filepool_artifact "$output"
    echo "ARTIFACT $(basename "$output") sha256=$(sha256sum "$output" | awk '{print $1}')"
done
echo "RESULT OK log=$LOG_FILE"
