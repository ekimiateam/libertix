#!/bin/bash

LIBERTIX_STAGE_CATALOG=${LIBERTIX_STAGE_CATALOG:-/usr/local/lib/libertix/libertix-stages.tsv}

libertix_stage_record() {
    local stage="$1"
    if [[ "$stage" == installer-failed-* ]]; then
        printf 'stage_installer_failed\t100\n'
        return 0
    fi
    awk -F '\t' -v stage="$stage" '$1 == stage { print $2 "\t" $3; found=1; exit } END { if (!found) exit 1 }' \
        "$LIBERTIX_STAGE_CATALOG"
}

libertix_stage_label() {
    local stage="$1" record key variable
    record="$(libertix_stage_record "$stage" 2>/dev/null || true)"
    [ -n "$record" ] || { printf '%s\n' "$stage"; return 0; }
    key=${record%%$'\t'*}
    variable="LIBERTIX_I18N_${key^^}"
    printf '%s\n' "${!variable:-$stage}"
}

libertix_stage_percent() {
    local record
    record="$(libertix_stage_record "$1" 2>/dev/null || true)"
    [ -n "$record" ] || { printf '1\n'; return 0; }
    printf '%s\n' "${record##*$'\t'}"
}
