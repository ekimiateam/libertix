#!/bin/bash
set -Eeuo pipefail

export LIBERTIX_FIRMWARE_MODE=bios
exec /tmp/configure-target-main.sh "$@"
