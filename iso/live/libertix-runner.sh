#!/bin/bash
set -Eeuo pipefail

export LIBERTIX_FIRMWARE_MODE=bios
export LIBERTIX_GUI_DISPLAY=:0
exec /usr/local/lib/libertix/libertix-runner-main.sh "$@"
