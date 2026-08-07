#!/bin/bash

# Load a fully identified installation plan into the current Bash process.
# Python owns JSON parsing; this wrapper only exports its fixed key/value list.
load_libertix_installation_plan() {
    local plan_path="$1" parser_path="${2:-/usr/local/lib/libertix/libertix-installation-plan.py}"
    local exported name value

    [ -f "$plan_path" ] || {
        echo "LIVE_E_INSTALLATION_PLAN: plan file is missing: $plan_path" >&2
        return 2
    }
    [ -x "$parser_path" ] || {
        echo "LIVE_E_INSTALLATION_PLAN: parser is missing: $parser_path" >&2
        return 2
    }

    exported="$("$parser_path" export-shell "$plan_path")" || return $?
    while IFS=$'\t' read -r name value; do
        case "$name" in
            INSTALLATION_PLAN_ID|INSTALLATION_FIRMWARE|LANGUAGE_CODE|SYSTEM_LANG|KEYBOARD_LAYOUT|KEYBOARD_VARIANT|KEYBOARD_MODEL|TIMEZONE|\
            USERNAME|PASSWORD_HASH_WINDOWS_PATH|COMPUTER_NAME|ISO_FILENAME|ISO_URL|ISO_WINDOWS_PATH|ISO_SHA256|LINUX_SIZE_GB|\
            TARGET_DISK_NUMBER|TARGET_DISK_UNIQUE_ID|TARGET_DISK_SIZE_BYTES|TARGET_LOGICAL_SECTOR_SIZE_BYTES|\
            WINDOWS_PARTITION_NUMBER|WINDOWS_PARTITION_OFFSET_BYTES|WINDOWS_PARTITION_SIZE_BYTES|\
            WINDOWS_BOOT_PARTITION_NUMBER|\
            WINDOWS_BOOT_PARTITION_OFFSET_BYTES|INSTALLER_PARTITION_NUMBER|INSTALLER_PARTITION_OFFSET_BYTES|\
            INSTALLER_FINAL_SIZE_BYTES|INSTALLER_STAGING_SIZE_BYTES|EXPECTED_PARTITION_STYLE|\
            RECOVERY_PARTITION_NUMBER|RECOVERY_PARTITION_OFFSET_BYTES|RECOVERY_PARTITION_SIZE_BYTES|\
            RECOVERY_ROOT_WINDOWS|RECOVERY_RUN_ID|LOW_MEMORY_MODE|SHARE_WINDOWS_FILES_IN_LINUX|\
            SHARE_LINUX_FILES_IN_WINDOWS|WINDOWS_PROFILES_JSON_BASE64|DEVELOPMENT_SSH_ENABLED|\
            DEVELOPMENT_STATIC_IPV4_ADDRESS|DEVELOPMENT_STATIC_IPV4_PREFIX_LENGTH|\
            DEVELOPMENT_STATIC_IPV4_GATEWAY|DEVELOPMENT_DNS_SERVERS)
                export "$name=$value"
                ;;
            *)
                echo "LIVE_E_INSTALLATION_PLAN: parser returned unknown field: $name" >&2
                return 2
                ;;
        esac
    done <<< "$exported"
}
