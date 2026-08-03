#!/bin/bash

# Discover the requested UI language before the installer has parsed the full
# plan. The live medium is already mounted when the runner starts.
detect_libertix_language() {
    local config candidate value

    if [[ "${LANGUAGE_CODE:-}" =~ ^(en|fr|es|ja)$ ]]; then
        printf '%s\n' "$LANGUAGE_CODE"
        return 0
    fi

    for config in \
        /run/libertix/config.txt \
        /run/live/medium/config.txt \
        /lib/live/mount/medium/config.txt \
        /cdrom/config.txt; do
        [ -f "$config" ] || continue
        candidate=$(sed -n 's/^LANGUAGE_CODE=//p' "$config" | tail -1)
        candidate=${candidate#\"}
        candidate=${candidate%\"}
        candidate=${candidate#\'}
        candidate=${candidate%\'}
        case "$candidate" in
            en|fr|es|ja)
                printf '%s\n' "$candidate"
                return 0
                ;;
        esac
    done

    value=${SYSTEM_LANG:-en}
    case "$value" in
        fr*) printf 'fr\n' ;;
        es*) printf 'es\n' ;;
        ja*) printf 'ja\n' ;;
        *) printf 'en\n' ;;
    esac
}

load_libertix_translations() {
    local helper="${1:-/usr/local/lib/libertix/libertix-i18n.py}"
    LANGUAGE_CODE=$(detect_libertix_language)
    export LANGUAGE_CODE
    [ -x "$helper" ] || return 1

    # The helper emits only fixed LIBERTIX_I18N_* names and shell-quoted values
    # from the versioned catalogue, so no runtime input is evaluated as code.
    eval "$("$helper" export-shell "$LANGUAGE_CODE")"
}
