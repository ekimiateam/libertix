#!/bin/bash
set -Eeuo pipefail

readonly grub_config="${LIBERTIX_GRUB_CONFIG:-/boot/grub/grub.cfg}"
readonly validator="${LIBERTIX_GRUB_VALIDATOR:-/usr/local/lib/libertix/libertix-validate-grub}"
readonly plan="${LIBERTIX_PLAN_PATH:-/etc/libertix/installation-plan.json}"
readonly log="${LIBERTIX_BOOT_MAINTENANCE_LOG:-/var/log/libertix/boot-maintenance.log}"
readonly lock_path="${LIBERTIX_UPDATE_GRUB_LOCK:-/run/lock/libertix-update-grub.lock}"
readonly grub_mkconfig="${LIBERTIX_GRUB_MKCONFIG:-grub-mkconfig}"
readonly efi_sync="${LIBERTIX_EFI_SYNC:-/usr/local/sbin/libertix-sync-efi}"

install -d -m 0755 "$(dirname "$log")" "$(dirname "$lock_path")"
touch "$log"
chmod 0600 "$log"
exec 9>"$lock_path"
flock -w 120 9 || {
    echo "Another GRUB update did not finish within 120 seconds" | tee -a "$log" >&2
    exit 1
}

temporary="$(mktemp "$(dirname "$grub_config")/.libertix-grub.cfg.XXXXXX")"
cleanup() {
    rm -f -- "$temporary"
}
trap cleanup EXIT HUP INT TERM

printf '[%s] Generating a candidate GRUB configuration\n' "$(date -u +%FT%TZ)" | tee -a "$log"
"$grub_mkconfig" -o "$temporary" "$@" 2>&1 | tee -a "$log"
"$validator" "$temporary" "$plan" 2>&1 | tee -a "$log"

if [ -e "$grub_config" ]; then
    chmod --reference="$grub_config" "$temporary"
    chown --reference="$grub_config" "$temporary"
else
    chmod 0644 "$temporary"
    chown root:root "$temporary"
fi
sync -f "$temporary" 2>/dev/null || sync
mv -f -- "$temporary" "$grub_config"
sync -f "$grub_config" 2>/dev/null || sync
printf '[%s] Installed the verified GRUB configuration atomically\n' "$(date -u +%FT%TZ)" | tee -a "$log"

if [ -n "${DPKG_MAINTSCRIPT_PACKAGE:-}" ]; then
    printf '[%s] EFI synchronization deferred until package configuration completes (%s)\n' \
        "$(date -u +%FT%TZ)" "$DPKG_MAINTSCRIPT_PACKAGE" | tee -a "$log"
elif [ -x "$efi_sync" ]; then
    "$efi_sync" --if-present
fi
