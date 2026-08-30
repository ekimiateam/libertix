#!/bin/bash

# Locate the single validated plan published by Windows. The live ISO may run
# from RAM or from a loop device, so its mount point does not reliably expose
# the FAT staging volume that carries the plan.
load_libertix_staging_volume_label() {
    [ -z "${LIBERTIX_STAGING_VOLUME_LABEL:-}" ] || return 0
    LIBERTIX_STAGING_VOLUME_LABEL="$(
        /usr/local/lib/libertix/libertix_installation_policy.py staging-volume-label
    )" || return 2
    [ -n "$LIBERTIX_STAGING_VOLUME_LABEL" ] || return 2
    export LIBERTIX_STAGING_VOLUME_LABEL
}

copy_libertix_context_candidate() {
    local plan="$1" candidate_dir="$2" state plan_hash state_hash context_id source_bundle

    state="$(dirname "$plan")/installation-state.json"
    [ -f "$plan" ] && [ -f "$state" ] || return 0
    plan_hash="$(sha256sum "$plan" | awk '{print $1}')"
    state_hash="$(sha256sum "$state" | awk '{print $1}')"
    context_id="$plan_hash-$state_hash"
    cp -f "$plan" "$candidate_dir/$context_id.plan.json"
    cp -f "$state" "$candidate_dir/$context_id.state.json"
    source_bundle="$(dirname "$plan")/windows-preferences.secret.json"
    if [ -f "$source_bundle" ]; then
        cp -f "$source_bundle" "$candidate_dir/$context_id.preferences.secret.json"
        chmod 0600 "$candidate_dir/$context_id.preferences.secret.json"
    fi
}

find_libertix_installation_plan() (
    local candidate candidate_dir device label mount_dir plan state context_id plan_id state_plan_id
    local plan_exports migration_enabled bundle_name bundle_hash bundle_size bundle_candidate
    local -A unique_contexts=()

    load_libertix_staging_volume_label || return $?

    cleanup_plan_probe() {
        mountpoint -q "$mount_dir" && umount "$mount_dir" 2>/dev/null || true
        rm -rf "$candidate_dir" 2>/dev/null || true
    }

    # A retry must never inherit candidates from an earlier probe. A fresh
    # directory makes the uniqueness check describe this scan only.
    candidate_dir="$(mktemp -d "$LOG_DIR/plan-candidates.XXXXXX")" || return 2
    mount_dir="$LOG_DIR/plan-medium"
    trap cleanup_plan_probe EXIT
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
            "$LIBERTIX_STAGING_VOLUME_LABEL") ;;
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
        if plan_exports="$(/usr/local/lib/libertix/libertix-installation-plan.py \
            export-shell "$candidate" 2>/dev/null)" \
            && /usr/local/lib/libertix/libertix-installation-state.py \
                validate "$state" >/dev/null 2>&1; then
            plan_id="$(/usr/local/lib/libertix/libertix-installation-plan.py \
                plan-id "$candidate")"
            state_plan_id="$(/usr/local/lib/libertix/libertix-installation-state.py \
                plan-id "$state")"
            [ -n "$plan_id" ] && [ "$plan_id" = "$state_plan_id" ] || continue
            context_id="$(basename "${candidate%.plan.json}")"
            migration_enabled="$(printf '%s\n' "$plan_exports" | awk -F '\t' \
                '$1 == "WINDOWS_PREFERENCE_MIGRATION_ENABLED" { print $2; exit }')"
            if [ "$migration_enabled" = true ]; then
                bundle_name="$(printf '%s\n' "$plan_exports" | awk -F '\t' \
                    '$1 == "WINDOWS_PREFERENCE_BUNDLE_FILE_NAME" { print $2; exit }')"
                bundle_hash="$(printf '%s\n' "$plan_exports" | awk -F '\t' \
                    '$1 == "WINDOWS_PREFERENCE_BUNDLE_SHA256" { print $2; exit }')"
                bundle_size="$(printf '%s\n' "$plan_exports" | awk -F '\t' \
                    '$1 == "WINDOWS_PREFERENCE_BUNDLE_SIZE_BYTES" { print $2; exit }')"
                [ "$bundle_name" = windows-preferences.secret.json ] || continue
                bundle_candidate="$candidate_dir/$context_id.preferences.secret.json"
                [ -f "$bundle_candidate" ] || continue
                [ "$(stat -c %s "$bundle_candidate" 2>/dev/null || echo invalid)" = \
                    "$bundle_size" ] || continue
                [ "$(sha256sum "$bundle_candidate" | awk '{print $1}')" = \
                    "$bundle_hash" ] || continue
            fi
            unique_contexts["$context_id"]="$candidate"
        fi
    done < <(find "$candidate_dir" -maxdepth 1 -type f -name '*.plan.json' -print)

    if [ "${#unique_contexts[@]}" -ne 1 ]; then
        echo "LIVE_E_INSTALLATION_PLAN: expected one validated plan/state context, found ${#unique_contexts[@]}" >&2
        return 2
    fi

    for candidate in "${unique_contexts[@]}"; do
        state="${candidate%.plan.json}.state.json"
        context_id="$(basename "${candidate%.plan.json}")"
        cp -f "$candidate" "$LOG_DIR/installation-plan.json"
        cp -f "$state" "$LOG_DIR/installation-state.json"
        plan_exports="$(/usr/local/lib/libertix/libertix-installation-plan.py \
            export-shell "$candidate")" || return 2
        migration_enabled="$(printf '%s\n' "$plan_exports" | awk -F '\t' \
            '$1 == "WINDOWS_PREFERENCE_MIGRATION_ENABLED" { print $2; exit }')"
        if [ "$migration_enabled" = true ]; then
            bundle_candidate="$candidate_dir/$context_id.preferences.secret.json"
            cp -f "$bundle_candidate" "$LOG_DIR/windows-preferences.secret.json"
            chmod 0600 "$LOG_DIR/windows-preferences.secret.json"
        fi
        printf '%s\n' "$LOG_DIR/installation-plan.json"
        return 0
    done
)

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

load_libertix_live_context_with_retry() {
    local expected_firmware="$1" maximum_attempts="$2" error_file="$3" attempt

    case "$maximum_attempts" in
        ''|*[!0-9]*|0) return 2 ;;
    esac
    [ -n "$error_file" ] || return 2

    for attempt in $(seq 1 "$maximum_attempts"); do
        : > "$error_file"
        # Keep this call in the current shell. A command substitution would
        # discard the plan variables exported by load_libertix_live_context.
        if load_libertix_live_context "$expected_firmware" \
            >/dev/null 2> "$error_file"; then
            return 0
        fi
        [ "$attempt" -eq "$maximum_attempts" ] || sleep 1
    done
    return 1
}

durable_bios_mbr_backup_directory() {
    local windows_root="$1" relative

    case "${RECOVERY_ROOT_WINDOWS:-}" in
        [A-Za-z]:\\*) ;;
        *) return 2 ;;
    esac
    relative="$(windows_path_to_relative "$RECOVERY_ROOT_WINDOWS")"
    [ -n "$relative" ] || return 2
    printf '%s/%s\n' "$windows_root/$relative" "mbr-backup"
}

validate_durable_bios_mbr_backup() {
    local backup_directory="$1"

    [ -d "$backup_directory" ] || return 3
    [ -f "$backup_directory/mbr-before-grub.bin" ] || return 2
    [ -f "$backup_directory/mbr-before-grub.sha256" ] || return 2
    [ "$(stat -c %s "$backup_directory/mbr-before-grub.bin" 2>/dev/null || echo 0)" -eq 512 ] || return 2
    (
        cd "$backup_directory" &&
            sha256sum -c mbr-before-grub.sha256 >/dev/null 2>&1
    )
}

publish_durable_bios_mbr_backup() {
    local windows_root="$1" source_backup="$2" backup_directory parent temporary
    local source_hash published_hash

    [ -f "$source_backup" ] || return 2
    [ "$(stat -c %s "$source_backup" 2>/dev/null || echo 0)" -eq 512 ] || return 2
    backup_directory="$(durable_bios_mbr_backup_directory "$windows_root")" || return $?
    parent="$(dirname "$backup_directory")"
    mkdir -p "$parent" || return 1

    if [ -e "$backup_directory" ]; then
        validate_durable_bios_mbr_backup "$backup_directory" || return 2
        source_hash="$(sha256sum "$source_backup" | awk '{print $1}')"
        published_hash="$(awk 'NR == 1 {print $1}' \
            "$backup_directory/mbr-before-grub.sha256")"
        [ "$source_hash" = "$published_hash" ] || return 2
        return 0
    fi

    temporary="$(mktemp -d "$parent/.mbr-backup.XXXXXX")" || return 1
    if ! install -m 0600 "$source_backup" "$temporary/mbr-before-grub.bin" ||
        ! (
            cd "$temporary" &&
                sha256sum mbr-before-grub.bin > mbr-before-grub.sha256
        ) ||
        ! sync "$temporary/mbr-before-grub.bin" "$temporary/mbr-before-grub.sha256" 2>/dev/null; then
        rm -f "$temporary/mbr-before-grub.bin" "$temporary/mbr-before-grub.sha256"
        rmdir "$temporary" 2>/dev/null || true
        return 1
    fi
    chmod 0600 "$temporary/mbr-before-grub.sha256"
    if ! mv "$temporary" "$backup_directory"; then
        rm -f "$temporary/mbr-before-grub.bin" "$temporary/mbr-before-grub.sha256"
        rmdir "$temporary" 2>/dev/null || true
        return 1
    fi
    sync "$backup_directory" 2>/dev/null || sync
    validate_durable_bios_mbr_backup "$backup_directory"
}

load_durable_bios_mbr_backup() {
    local windows_root="$1" destination="$2" backup_directory temporary

    backup_directory="$(durable_bios_mbr_backup_directory "$windows_root")" || return $?
    validate_durable_bios_mbr_backup "$backup_directory" || return $?
    mkdir -p "$(dirname "$destination")" || return 1
    temporary="${destination}.new.$$"
    if ! install -m 0600 "$backup_directory/mbr-before-grub.bin" "$temporary"; then
        rm -f "$temporary"
        return 1
    fi
    if [ "$(stat -c %s "$temporary" 2>/dev/null || echo 0)" -ne 512 ] ||
        [ "$(sha256sum "$temporary" | awk '{print $1}')" != \
            "$(awk 'NR == 1 {print $1}' "$backup_directory/mbr-before-grub.sha256")" ]; then
        rm -f "$temporary"
        return 2
    fi
    if ! mv -f "$temporary" "$destination"; then
        rm -f "$temporary"
        return 1
    fi
}

with_windows_mounted_for_mbr_backup() {
    local operation="$1" local_backup="$2"
    local mountpoint="/mnt/libertix-mbr-backup" result=0

    [ -n "${WINDOWS_PART:-}" ] && [ -b "$WINDOWS_PART" ] || return 1
    if findmnt -rn -S "$WINDOWS_PART" | grep -q .; then
        return 1
    fi
    mkdir -p "$mountpoint"
    mount -t ntfs-3g -o rw "$WINDOWS_PART" "$mountpoint" || return 1
    case "$operation" in
        publish) publish_durable_bios_mbr_backup "$mountpoint" "$local_backup" || result=$? ;;
        load) load_durable_bios_mbr_backup "$mountpoint" "$local_backup" || result=$? ;;
        *) result=2 ;;
    esac
    sync
    umount "$mountpoint" || result=1
    return "$result"
}

prepare_bios_mbr_backup_or_die() {
    local load_result=0

    if with_windows_mounted_for_mbr_backup load "$MBR_BACKUP"; then
        echo "Reusing the verified durable pre-GRUB MBR backup."
        return 0
    else
        load_result=$?
    fi
    [ "$load_result" -eq 3 ] || return "$load_result"

    run_logged dd if="$DISK" of="$MBR_BACKUP" bs=512 count=1 iflag=fullblock status=none
    [ "$(stat -c %s "$MBR_BACKUP" 2>/dev/null || echo 0)" -eq 512 ] || return 2
    with_windows_mounted_for_mbr_backup publish "$MBR_BACKUP"
}

load_bios_mbr_backup_for_rollback() {
    with_windows_mounted_for_mbr_backup load "$MBR_BACKUP"
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
