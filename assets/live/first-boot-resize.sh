#!/bin/bash
set -Eeuo pipefail

LOG="/var/log/libertix/first-boot-resize.log"
VERIFIER="/usr/local/lib/libertix/libertix-first-boot-verify.py"
CURRENT_STAGE="initialization"
FAILURE_DETAIL=""
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
    local message="${FAILURE_DETAIL:-first-boot service failed during ${CURRENT_STAGE} with rc=${rc}}"
    "$VERIFIER" --record-service-failure "$ATTEMPT_ID" "$CURRENT_STAGE" \
        "$message" \
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

return_failure() {
    return "$1"
}

recover_interrupted_package_state() {
    local interruption_count attempt audit_output

    interruption_count="$(
        python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("interruptionCount", 0))' \
            /var/lib/libertix/first-boot-service-state.json
    )"
    [[ "$interruption_count" =~ ^[0-9]+$ ]]
    [ "$interruption_count" -gt 0 ] || return 0

    echo "A previous first-boot attempt was interrupted; resuming pending package configuration." \
        >> "$LOG"
    for attempt in $(seq 1 12); do
        if DEBIAN_FRONTEND=noninteractive dpkg --configure -a >> "$LOG" 2>&1; then
            break
        fi
        [ "$attempt" -lt 12 ] || fail_stage \
            "Pending package configuration could not be resumed after 12 attempts."
        echo "Package-manager recovery attempt ${attempt}/12 did not complete; retrying." \
            >> "$LOG"
        sleep 10
    done

    audit_output="$(dpkg --audit 2>&1)"
    if [ -n "$audit_output" ]; then
        printf '%s\n' "$audit_output" >> "$LOG"
        fail_stage "Package-manager state remains incomplete after interruption recovery."
    fi

}

CURRENT_STAGE="package-manager-recovery"
recover_interrupted_package_state

CURRENT_STAGE="root-device-validation"
ROOT_DEV="$(findmnt -n -o SOURCE /)"
[ -b "$ROOT_DEV" ] || fail_stage "Root source is not a block device: $ROOT_DEV"
[ "$(findmnt -n -o FSTYPE /)" = "ext4" ] || fail_stage "Root filesystem is not ext4"
CURRENT_STAGE="root-filesystem-resize"
resize2fs "$ROOT_DEV" >> "$LOG" 2>&1
resize2fs -P "$ROOT_DEV" >> "$LOG" 2>&1
df -hT / >> "$LOG" 2>&1
CURRENT_STAGE="installed-system-verification"
if VERIFICATION_OUTPUT="$("$VERIFIER" 2>&1)"; then
    VERIFICATION_RC=0
else
    VERIFICATION_RC=$?
fi
printf '%s\n' "$VERIFICATION_OUTPUT" >> "$LOG"
if [ "$VERIFICATION_RC" -ne 0 ]; then
    FAILURE_DETAIL="$(
        printf '%s\n' "$VERIFICATION_OUTPUT" \
            | sed -n 's/^FIRST_BOOT_VERIFICATION_ERROR=//p' \
            | tail -n 1
    )"
    return_failure "$VERIFICATION_RC"
fi

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
