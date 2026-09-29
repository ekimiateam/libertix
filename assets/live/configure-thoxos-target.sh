#!/bin/bash
# =============================================================================
# assets/live/configure-thoxos-target.sh
#
# Thin ThoxOS entrypoint, mirroring iso-uefi/target/configure-target.sh. It
# re-exports the firmware mode for the shared target configuration and then
# sources the ThoxOS layer. Staged into the target at
# /tmp/libertix-configure-thoxos.sh, alongside the other target payload.
# =============================================================================
set -Eeuo pipefail

: "${LIBERTIX_FIRMWARE_MODE:?LIBERTIX_FIRMWARE_MODE is required}"

. /tmp/thoxos-configure-target.sh
thoxos_configure_target

echo "ThoxOS brand layer applied: $(sed -n 's/^PRETTY_NAME=//p' /etc/thoxos-release | head -n1)"
