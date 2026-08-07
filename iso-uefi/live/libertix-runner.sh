#!/bin/bash
set -Eeuo pipefail

export LIBERTIX_FIRMWARE_MODE=uefi
# The UEFI live desktop owns display :0; the installer uses a separate X server.
export LIBERTIX_GUI_DISPLAY=:1
exec /usr/local/lib/libertix/libertix-runner-main.sh "$@"
