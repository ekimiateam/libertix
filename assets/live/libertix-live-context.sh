#!/bin/bash

# Locate the single validated plan published by Windows. The live ISO may run
# from RAM or from a loop device, so its mount point does not reliably expose
# the FAT staging volume that carries the plan.
copy_libertix_context_candidate() {
    local plan="$1" candidate_dir="$2" state plan_hash state_hash context_id

    state="$(dirname "$plan")/installation-state.json"
    [ -f "$plan" ] && [ -f "$state" ] || return 0
    plan_hash="$(sha256sum "$plan" | awk '{print $1}')"
    state_hash="$(sha256sum "$state" | awk '{print $1}')"
    context_id="$plan_hash-$state_hash"
    cp -f "$plan" "$candidate_dir/$context_id.plan.json"
    cp -f "$state" "$candidate_dir/$context_id.state.json"
}

find_libertix_installation_plan() {
    local candidate candidate_dir device label mount_dir plan state context_id plan_id state_plan_id
    local -A unique_contexts=()

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
            context_id="$(basename "${candidate%.plan.json}")"
            unique_contexts["$context_id"]="$candidate"
        fi
    done < <(find "$candidate_dir" -maxdepth 1 -type f -name '*.plan.json' -print)

    if [ "${#unique_contexts[@]}" -ne 1 ]; then
        echo "LIVE_E_INSTALLATION_PLAN: expected one validated plan/state context, found ${#unique_contexts[@]}" >&2
        return 2
    fi

    for candidate in "${unique_contexts[@]}"; do
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

publish_installation_state_mirror() {
    local windows_root="$1" relative destination temporary

    [ -f "$INSTALLATION_STATE_PATH" ] || return 1
    relative="$(windows_path_to_relative "$RECOVERY_ROOT_WINDOWS")"
    destination="$windows_root/$relative/installation-state.json"
    mkdir -p "$(dirname "$destination")" || return 1
    temporary="$(dirname "$destination")/.installation-state.$$.tmp"
    cp -f "$INSTALLATION_STATE_PATH" "$temporary" || return 1
    sync "$temporary" 2>/dev/null || sync
    mv -f "$temporary" "$destination" || return 1
    sync "$destination" 2>/dev/null || sync
}

mirror_installation_state_to_windows() {
    local mountpoint="/mnt/libertix-state-mirror"

    [ -n "${RECOVERY_ROOT_WINDOWS:-}" ] || {
        echo "LIVE_E_INSTALLATION_STATE: Windows recovery root is unavailable" >&2
        return 1
    }
    [ -n "${WINDOWS_PART:-}" ] && [ -b "$WINDOWS_PART" ] || {
        echo "LIVE_E_INSTALLATION_STATE: Windows partition is unavailable for state mirroring" >&2
        return 1
    }
    case "$RECOVERY_ROOT_WINDOWS" in
        [A-Za-z]:\\*) ;;
        *)
            echo "LIVE_E_INSTALLATION_STATE: invalid Windows recovery root" >&2
            return 1
            ;;
    esac

    mkdir -p "$mountpoint"
    if findmnt -rn -S "$WINDOWS_PART" | grep -q .; then
        echo "LIVE_E_INSTALLATION_STATE: Windows partition is already mounted during state mirroring" >&2
        return 1
    fi
    mount -t ntfs-3g -o rw "$WINDOWS_PART" "$mountpoint" || return 1
    if publish_installation_state_mirror "$mountpoint"; then
        sync
        umount "$mountpoint"
        return 0
    fi
    umount "$mountpoint" 2>/dev/null || true
    return 1
}

run_installation_state_transition() {
    /usr/local/lib/libertix/libertix-installation-state.py "$@" || return $?
    mirror_installation_state_to_windows
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
            run_installation_state_transition start "$INSTALLATION_STATE_PATH" "$step"
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
    run_installation_state_transition complete "$INSTALLATION_STATE_PATH" "$step"
}

fail_installation_state_best_effort() {
    local rc="$1" message="$2" status

    [ -f "${INSTALLATION_STATE_PATH:-}" ] || return 0
    status="$(/usr/local/lib/libertix/libertix-installation-state.py \
        status "$INSTALLATION_STATE_PATH" 2>/dev/null)" || return 0
    case "$status" in
        failed|rollback-running|rolled-back|succeeded) return 0 ;;
    esac
    if /usr/local/lib/libertix/libertix-installation-state.py \
        fail "$INSTALLATION_STATE_PATH" "LIVE_E_STAGE_FAILED_$rc" live "$message"; then
        mirror_installation_state_to_windows || \
            echo "WARNING: failed installation state could not be mirrored to Windows" >&2
    fi
}

begin_installation_state_rollback() {
    local status

    [ -f "${INSTALLATION_STATE_PATH:-}" ] || {
        echo "LIVE_E_INSTALLATION_STATE: rollback state is unavailable" >&2
        return 1
    }
    status="$(/usr/local/lib/libertix/libertix-installation-state.py \
        status "$INSTALLATION_STATE_PATH")" || return $?
    [ "$status" = rollback-running ] && return 0
    [ "$status" = running ] || [ "$status" = failed ] || {
        echo "LIVE_E_INSTALLATION_STATE: cannot begin rollback from $status" >&2
        return 1
    }
    run_installation_state_transition begin-rollback "$INSTALLATION_STATE_PATH"
}

compensate_installation_state_step() {
    local step="$1" step_status

    [ -f "${INSTALLATION_STATE_PATH:-}" ] || {
        echo "LIVE_E_INSTALLATION_STATE: rollback state is unavailable" >&2
        return 1
    }
    step_status="$(get_installation_state_step_status "$step")" || return $?
    case "$step_status" in
        pending) return 0 ;;
        completed)
            run_installation_state_transition compensate "$INSTALLATION_STATE_PATH" "$step"
            ;;
        *)
            echo "LIVE_E_INSTALLATION_STATE: cannot compensate step $step with status $step_status" >&2
            return 1
            ;;
    esac
}

complete_installation_state_rollback() {
    [ -f "${INSTALLATION_STATE_PATH:-}" ] || {
        echo "LIVE_E_INSTALLATION_STATE: rollback state is unavailable" >&2
        return 1
    }
    run_installation_state_transition complete-rollback "$INSTALLATION_STATE_PATH"
}

complete_installation_state() {
    run_installation_state_transition complete-installation "$INSTALLATION_STATE_PATH"
}
