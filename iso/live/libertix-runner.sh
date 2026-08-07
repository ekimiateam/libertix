#!/bin/bash
set -Eeuo pipefail

export LIBERTIX_FIRMWARE_MODE=bios
# The BIOS image has no desktop X server, so the installer owns display :0.
export LIBERTIX_GUI_DISPLAY=:0
exec /usr/local/lib/libertix/libertix-runner-main.sh "$@"
