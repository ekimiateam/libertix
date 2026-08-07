#!/bin/bash

# Locate the single validated plan published by Windows. The live ISO may run
# from RAM or from a loop device, so its mount point does not reliably expose
# the FAT staging volume that carries the plan.
copy_libertix_context_candidate() {
    local plan="$1" candidate_dir="$2" state hash

    state="$(dirname "$plan")/installation-state.json"
    [ -f "$plan" ] && [ -f "$state" ] || return 0
    hash="$(sha256sum "$plan" | awk '{print $1}')"
    cp -f "$plan" "$candidate_dir/$hash.plan.json"
    cp -f "$state" "$candidate_dir/$hash.state.json"
}

find_libertix_installation_plan() {
    local candidate candidate_dir device label mount_dir plan state hash plan_id state_plan_id
    local -A unique_plans=()

    # A retry must never inherit candidates from an earlier probe. A fresh
    # directory makes the uniqueness check describe this scan only.
    candidate_dir="$(mktemp -d "$LOG_DIR/plan-candidates.XXXXXX")" || return 2
    mount_dir="$LOG_DIR/plan-medium"
    mkdir -p "$candidate_dir" "$mount_dir"

    for candidate in \
        /run/live/medium/installation-plan.json \
        /lib/live/mount/medium/installation-plan.json \
        /cdrom/installation-plan.json; do
        copy_libertix_context_candidate "$candidate" "$candidate_dir"
    done

    while read -r device; do
        [ -b "$device" ] || continue
        label="$(blkid -s LABEL -o value "$device" 2>/dev/null || true)"
        case "$label" in
            LIBERTIX|LIBERTIX_INSTALLER|LIBERTIXEFI) ;;
            *) continue ;;
        esac

        if mount -t vfat -o ro "$device" "$mount_dir" 2>/dev/null; then
            plan="$mount_dir/installation-plan.json"
            copy_libertix_context_candidate "$plan" "$candidate_dir"
            umount "$mount_dir" 2>/dev/null || true
        fi
    done < <(blkid -o device 2>/dev/null || true)

    while read -r candidate; do
        [ -f "$candidate" ] || continue
        state="${candidate%.plan.json}.state.json"
        if /usr/local/lib/libertix/libertix-installation-plan.py \
            export-shell "$candidate" >/dev/null 2>&1 \
            && /usr/local/lib/libertix/libertix-installation-state.py \
                validate "$state" >/dev/null 2>&1; then
            plan_id="$(/usr/local/lib/libertix/libertix-installation-plan.py \
                plan-id "$candidate")"
            state_plan_id="$(/usr/local/lib/libertix/libertix-installation-state.py \
                plan-id "$state")"
            [ -n "$plan_id" ] && [ "$plan_id" = "$state_plan_id" ] || continue
            hash="$(sha256sum "$candidate" | awk '{print $1}')"
            unique_plans["$hash"]="$candidate"
        fi
    done < <(find "$candidate_dir" -maxdepth 1 -type f -name '*.plan.json' -print)

    if [ "${#unique_plans[@]}" -ne 1 ]; then
        echo "LIVE_E_INSTALLATION_PLAN: expected one validated plan, found ${#unique_plans[@]}" >&2
        return 2
    fi

    for candidate in "${unique_plans[@]}"; do
        state="${candidate%.plan.json}.state.json"
        cp -f "$candidate" "$LOG_DIR/installation-plan.json"
        cp -f "$state" "$LOG_DIR/installation-state.json"
        printf '%s\n' "$LOG_DIR/installation-plan.json"
        return 0
    done
}

load_libertix_live_context() {
    local plan_path expected_firmware="$1"

    plan_path="$(find_libertix_installation_plan)" || return $?
    load_libertix_installation_plan "$plan_path" || return $?
    if [ "$INSTALLATION_FIRMWARE" != "$expected_firmware" ]; then
        echo "LIVE_E_INSTALLATION_PLAN: expected firmware $expected_firmware, got $INSTALLATION_FIRMWARE" >&2
        return 2
    fi
    INSTALLATION_PLAN_PATH="$plan_path"
    INSTALLATION_STATE_PATH="$LOG_DIR/installation-state.json"
    export INSTALLATION_PLAN_PATH INSTALLATION_STATE_PATH
}

get_installation_state_step_status() {
    /usr/local/lib/libertix/libertix-installation-state.py \
        step-status "$INSTALLATION_STATE_PATH" "$1"
}

start_installation_state_step() {
    local step="$1" step_status

    step_status="$(get_installation_state_step_status "$step")" || return $?
    case "$step_status" in
        active|completed) return 0 ;;
        pending)
            /usr/local/lib/libertix/libertix-installation-state.py \
                start "$INSTALLATION_STATE_PATH" "$step"
            ;;
        *) echo "LIVE_E_INSTALLATION_STATE: invalid step status: $step_status" >&2; return 2 ;;
    esac
}

complete_installation_state_step() {
    local step="$1" step_status

    step_status="$(get_installation_state_step_status "$step")" || return $?
    [ "$step_status" = completed ] && return 0
    [ "$step_status" = active ] || {
        echo "LIVE_E_INSTALLATION_STATE: cannot complete inactive step $step" >&2
        return 2
    }
    /usr/local/lib/libertix/libertix-installation-state.py \
        complete "$INSTALLATION_STATE_PATH" "$step"
}

fail_installation_state_best_effort() {
    local rc="$1" message="$2" status

    [ -f "${INSTALLATION_STATE_PATH:-}" ] || return 0
    status="$(/usr/local/lib/libertix/libertix-installation-state.py \
        status "$INSTALLATION_STATE_PATH" 2>/dev/null)" || return 0
    case "$status" in
        failed|rollback-running|rolled-back|succeeded) return 0 ;;
    esac
    /usr/local/lib/libertix/libertix-installation-state.py \
        fail "$INSTALLATION_STATE_PATH" "LIVE_E_STAGE_FAILED_$rc" live "$message" || true
}

begin_installation_state_rollback_best_effort() {
    local status

    [ -f "${INSTALLATION_STATE_PATH:-}" ] || return 0
    status="$(/usr/local/lib/libertix/libertix-installation-state.py \
        status "$INSTALLATION_STATE_PATH" 2>/dev/null)" || return 0
    [ "$status" = rollback-running ] && return 0
    [ "$status" = running ] || [ "$status" = failed ] || return 0
    /usr/local/lib/libertix/libertix-installation-state.py \
        begin-rollback "$INSTALLATION_STATE_PATH" || true
}

compensate_installation_state_step_best_effort() {
    local step="$1" step_status

    [ -f "${INSTALLATION_STATE_PATH:-}" ] || return 0
    step_status="$(get_installation_state_step_status "$step" 2>/dev/null)" || return 0
    [ "$step_status" = completed ] || return 0
    /usr/local/lib/libertix/libertix-installation-state.py \
        compensate "$INSTALLATION_STATE_PATH" "$step" || true
}

complete_installation_state_rollback_best_effort() {
    [ -f "${INSTALLATION_STATE_PATH:-}" ] || return 0
    /usr/local/lib/libertix/libertix-installation-state.py \
        complete-rollback "$INSTALLATION_STATE_PATH" || true
}

complete_installation_state() {
    /usr/local/lib/libertix/libertix-installation-state.py \
        complete-installation "$INSTALLATION_STATE_PATH"
}
