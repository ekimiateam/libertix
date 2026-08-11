#!/bin/bash
set -Eeuo pipefail

export LIBERTIX_FIRMWARE_MODE=bios
exec /usr/local/lib/libertix/libertix-install-main.sh "$@"
