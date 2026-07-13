#!/bin/bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LIBERTIX_BUILD_MODE=uefi
exec "$ROOT_DIR/iso/build.sh" "$@"
