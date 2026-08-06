#!/bin/bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILDER_DIR="$ROOT_DIR/docker/iso-builder"
IMAGE_NAME="libertix-iso-builder:trixie"
APT_CACHE_VOLUME="libertix-iso-apt-cache"
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

# A builder left behind by an interrupted run still holds the shared apt cache
# lock, which makes every later build fail before it downloads anything.
stale_builders="$(docker ps -q --filter "ancestor=$IMAGE_NAME")"
if [ -n "$stale_builders" ]; then
    echo "Removing leftover ISO builder containers"
    # shellcheck disable=SC2086
    docker kill $stale_builders >/dev/null
fi

# The chroots are thousands of small files written once and thrown away. Keeping
# them in RAM avoids the container overlay filesystem, which dominates the
# rootfs stages. Sized from what the host can spare, never from total memory.
tmpfs_size() {
    local requested="${LIBERTIX_ISO_TMPFS:-auto}" available_gb needed_gb size_gb
    case "$requested" in
        0|off|no) return 0 ;;
        auto) ;;
        *) printf '%s' "$requested"; return 0 ;;
    esac

    available_gb=$(awk '/^MemAvailable:/ { print int($2 / 1048576) }' /proc/meminfo)
    [ "$MODE" = "all" ] && needed_gb=10 || needed_gb=6
    [ "$available_gb" -ge "$((needed_gb + 4))" ] || return 0

    size_gb=$((available_gb * 6 / 10))
    [ "$size_gb" -le 24 ] || size_gb=24
    printf '%sg' "$size_gb"
}

docker_run_options=(
    --rm --privileged
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
)

TMPFS_SIZE="$(tmpfs_size)"
if [ -n "$TMPFS_SIZE" ]; then
    # exec and dev are required: the chroot lives here and dpkg maintainer
    # scripts run from it against the device nodes debootstrap creates.
    docker_run_options+=(--tmpfs "/tmp:rw,exec,dev,suid,size=$TMPFS_SIZE")
    echo "TMPFS /tmp size=$TMPFS_SIZE"
else
    echo "TMPFS disabled"
fi

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

for output in "${outputs[@]}"; do
    echo "ARTIFACT $(basename "$output") sha256=$(sha256sum "$output" | awk '{print $1}')"
done
echo "RESULT OK log=$LOG_FILE"
