#!/bin/bash
set -Eeuo pipefail

export LIBERTIX_FIRMWARE_MODE=uefi
exec /tmp/configure-target-main.sh "$@"
