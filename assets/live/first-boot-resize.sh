#!/bin/bash
set -Eeuo pipefail

LOG="/var/log/libertix/first-boot-resize.log"
VERIFIER="/usr/local/lib/libertix/libertix-first-boot-verify.py"
CURRENT_STAGE="initialization"
mkdir -p "$(dirname "$LOG")"
touch "$LOG"
chmod 0644 "$LOG"
echo >> "$LOG"
echo "===== FIRST BOOT VERIFICATION ATTEMPT - $(date --iso-8601=seconds) =====" >> "$LOG"
ATTEMPT_ID="$("$VERIFIER" --record-service-start "$CURRENT_STAGE")"
{
    echo "===== SYSTEM CONTEXT ====="
    uname -a
    cat /etc/os-release
    findmnt -R /
    lsblk -o NAME,TYPE,SIZE,FSTYPE,PARTTYPENAME,MOUNTPOINTS
    localectl status
    systemctl --failed --no-pager --plain
    dpkg --audit
    echo "===== END SYSTEM CONTEXT ====="
} >> "$LOG" 2>&1 || true

record_failure() {
    local rc=$?
    "$VERIFIER" --record-service-failure "$ATTEMPT_ID" "$CURRENT_STAGE" \
        "first-boot service failed during ${CURRENT_STAGE} with rc=${rc}" \
        >> "$LOG" 2>&1 || true
    sync -f "$LOG" 2>/dev/null || sync
    exit "$rc"
}
trap record_failure ERR

record_shutdown_request() {
    echo "Shutdown or reboot requested during stage ${CURRENT_STAGE}; continuing within the systemd grace period." \
        >> "$LOG"
    "$VERIFIER" --update-service-attempt \
        "$ATTEMPT_ID" "$CURRENT_STAGE" "shutdown-requested" \
        >> "$LOG" 2>&1 || true
    sync -f "$LOG" 2>/dev/null || sync
}
trap record_shutdown_request TERM INT HUP

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
"$VERIFIER" --update-service-attempt \
    "$ATTEMPT_ID" "$CURRENT_STAGE" "succeeded" \
    >> "$LOG" 2>&1
sync -f "$LOG" 2>/dev/null || sync
"$VERIFIER" --archive-service-diagnostics >> "$LOG" 2>&1
systemctl disable first-boot-resize.service >> "$LOG" 2>&1
trap - ERR TERM INT HUP
rm -f /etc/systemd/system/first-boot-resize.service \
    /usr/local/bin/first-boot-resize.sh \
    >> "$LOG" 2>&1 || echo "One-shot service files could not be fully retired." >> "$LOG"
rm -f "$VERIFIER" >> "$LOG" 2>&1 || echo "Verifier could not be retired." >> "$LOG"
