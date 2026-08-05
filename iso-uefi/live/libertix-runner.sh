#!/bin/bash
set -Eeuo pipefail

export LIBERTIX_FIRMWARE_MODE=uefi
export LIBERTIX_GUI_DISPLAY=:1
exec /usr/local/lib/libertix/libertix-runner-main.sh "$@"
