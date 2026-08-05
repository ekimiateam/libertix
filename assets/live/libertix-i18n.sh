#!/bin/bash

# Resolve the UI language from the validated installation plan loaded by the
# runner before this helper is called.
detect_libertix_language() {
    local value

    if [[ "${LANGUAGE_CODE:-}" =~ ^(en|fr|es|ja)$ ]]; then
        printf '%s\n' "$LANGUAGE_CODE"
        return 0
    fi

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
