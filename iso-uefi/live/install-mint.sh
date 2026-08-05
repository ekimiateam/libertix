#!/bin/bash
set -Eeuo pipefail

export LIBERTIX_FIRMWARE_MODE=uefi
exec /usr/local/lib/libertix/libertix-install-main.sh "$@"
