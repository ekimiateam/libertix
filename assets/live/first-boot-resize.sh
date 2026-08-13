#!/bin/bash
set -Eeuo pipefail

LOG="/var/log/libertix/first-boot-resize.log"
VERIFIER="/usr/local/lib/libertix/libertix-first-boot-verify.py"
CURRENT_STAGE="initialization"
mkdir -p "$(dirname "$LOG")"
echo "First boot resize - $(date)" > "$LOG"

record_failure() {
    local rc=$?
    "$VERIFIER" --record-service-failure \
        "first-boot service failed during ${CURRENT_STAGE} with rc=${rc}" \
        >> "$LOG" 2>&1 || true
    exit "$rc"
}
trap record_failure ERR

fail_stage() {
    echo "$1" >> "$LOG"
    return 1
}

CURRENT_STAGE="root-device-validation"
ROOT_DEV="$(findmnt -n -o SOURCE /)"
[ -b "$ROOT_DEV" ] || fail_stage "Root source is not a block device: $ROOT_DEV"
[ "$(findmnt -n -o FSTYPE /)" = "ext4" ] || fail_stage "Root filesystem is not ext4"
CURRENT_STAGE="root-filesystem-resize"
resize2fs "$ROOT_DEV" >> "$LOG" 2>&1
resize2fs -P "$ROOT_DEV" >> "$LOG" 2>&1
df -hT / >> "$LOG" 2>&1
CURRENT_STAGE="installed-system-verification"
"$VERIFIER" >> "$LOG" 2>&1

CURRENT_STAGE="one-shot-service-retirement"
systemctl disable first-boot-resize.service >> "$LOG" 2>&1
rm -f /etc/systemd/system/first-boot-resize.service \
    /usr/local/bin/first-boot-resize.sh \
    "$VERIFIER"
