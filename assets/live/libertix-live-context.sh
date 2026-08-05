#!/bin/bash

# Locate the single validated plan published by Windows. The live ISO may run
# from RAM or from a loop device, so its mount point does not reliably expose
# the FAT staging volume that carries the plan.
find_libertix_installation_plan() {
    local candidate candidate_dir device label mount_dir plan hash
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
        [ -f "$candidate" ] || continue
        hash="$(sha256sum "$candidate" | awk '{print $1}')"
        cp -f "$candidate" "$candidate_dir/$hash.json"
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
            if [ -f "$plan" ]; then
                hash="$(sha256sum "$plan" | awk '{print $1}')"
                cp -f "$plan" "$candidate_dir/$hash.json"
            fi
            umount "$mount_dir" 2>/dev/null || true
        fi
    done < <(blkid -o device 2>/dev/null || true)

    while read -r candidate; do
        [ -f "$candidate" ] || continue
        if /usr/local/lib/libertix/libertix-installation-plan.py \
            export-shell "$candidate" >/dev/null 2>&1; then
            hash="$(sha256sum "$candidate" | awk '{print $1}')"
            unique_plans["$hash"]="$candidate"
        fi
    done < <(find "$candidate_dir" -maxdepth 1 -type f -name '*.json' -print)

    if [ "${#unique_plans[@]}" -ne 1 ]; then
        echo "LIVE_E_INSTALLATION_PLAN: expected one validated plan, found ${#unique_plans[@]}" >&2
        return 2
    fi

    for candidate in "${unique_plans[@]}"; do
        cp -f "$candidate" "$LOG_DIR/installation-plan.json"
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
}
