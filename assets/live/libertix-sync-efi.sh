#!/bin/bash
set -Eeuo pipefail

readonly plan="${LIBERTIX_PLAN_PATH:-/etc/libertix/installation-plan.json}"
readonly esp_mount="${LIBERTIX_ESP_MOUNT:-/boot/efi}"
readonly efi_directory="$esp_mount/EFI/Libertix"
readonly owner_file="$efi_directory/.libertix-owner"
readonly history_root="${LIBERTIX_EFI_HISTORY_ROOT:-/var/lib/libertix/efi-history}"
readonly log="${LIBERTIX_BOOT_MAINTENANCE_LOG:-/var/log/libertix/boot-maintenance.log}"
readonly lock_path="${LIBERTIX_EFI_SYNC_LOCK:-/run/lock/libertix-sync-efi.lock}"
readonly shim_directory="${LIBERTIX_SHIM_DIRECTORY:-/usr/lib/shim}"
readonly grub_signed_directory="${LIBERTIX_GRUB_SIGNED_DIRECTORY:-/usr/lib/grub/x86_64-efi-signed}"
allow_missing=false

case "${1:-}" in
    "") ;;
    --if-present) allow_missing=true ;;
    *) echo "Usage: ${0##*/} [--if-present]" >&2; exit 2 ;;
esac

if [ ! -s "$plan" ]; then
    [ "$allow_missing" = true ] && exit 0
    echo "Libertix installation plan is missing: $plan" >&2
    exit 1
fi

mapfile -t plan_values < <(python3 - "$plan" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8-sig") as stream:
    plan = json.load(stream)
if plan.get("firmware") != "uefi":
    print("bios")
    print("")
    print("")
    raise SystemExit(0)
runtime = plan.get("runtime")
distribution = plan.get("distribution")
if not isinstance(runtime, dict) or not isinstance(distribution, dict):
    raise SystemExit("installation plan boot metadata is missing")
recovery_run_id = runtime.get("recoveryRunId")
trusted = runtime.get("trustedMicrosoftUefiAuthorities")
supported = distribution.get("secureBootMicrosoftAuthorities")
if not isinstance(recovery_run_id, str) or len(recovery_run_id) != 32:
    raise SystemExit("installation plan recovery id is invalid")
if not isinstance(trusted, list) or any(item not in {"2011", "2023"} for item in trusted):
    raise SystemExit("installation plan firmware authority list is invalid")
if not isinstance(supported, list) or not supported or any(
    item not in {"2011", "2023"} for item in supported
):
    raise SystemExit("installation plan distribution authority list is invalid")
print("uefi")
print(recovery_run_id)
secure_boot_enabled = runtime.get("secureBootEnabled")
if not isinstance(secure_boot_enabled, bool):
    raise SystemExit("installation plan Secure Boot state is invalid")
print("true" if secure_boot_enabled else "false")
print(";".join(trusted))
print(";".join(supported))
PY
)
[ "${plan_values[0]:-}" = uefi ] || exit 0
recovery_run_id="${plan_values[1]:-}"
secure_boot_enabled="${plan_values[2]:-}"
plan_trusted_authorities="${plan_values[3]:-}"
plan_supported_authorities="${plan_values[4]:-}"

if [ ! -f "$owner_file" ]; then
    [ "$allow_missing" = true ] && exit 0
    echo "Owned EFI/Libertix directory is missing" >&2
    exit 1
fi
[ "$(sed -n '1p' "$owner_file" | tr -d '\r\n')" = "$recovery_run_id" ] || {
    echo "EFI/Libertix belongs to another Libertix recovery run" >&2
    exit 1
}

install -d -m 0755 "$(dirname "$log")" "$history_root" "$(dirname "$lock_path")"
touch "$log"
chmod 0600 "$log"
exec > >(tee -a "$log") 2>&1
exec 9>"$lock_path"
flock -w 120 9 || {
    echo "Another EFI synchronization did not finish within 120 seconds" >&2
    exit 1
}

for command_name in sbverify dpkg-query sha256sum python3; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "$command_name is required to verify the installed Secure Boot chain" >&2
        exit 1
    }
done
mountpoint -q "$esp_mount" || mount "$esp_mount"
mountpoint -q "$esp_mount" || {
    echo "The EFI System Partition is not mounted at $esp_mount" >&2
    exit 1
}

package_owns_file() {
    local file="$1" expected="$2" owner
    owner="$(dpkg-query -S "$file" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
    case "$owner" in
        "$expected"|"$expected":*) return 0 ;;
        *) return 1 ;;
    esac
}

signature_has_authority() {
    local file="$1" authority="$2" signatures
    signatures="$(LC_ALL=C sbverify --list "$file" 2>&1)" || return 1
    case "$authority" in
        2011) grep -Fq "CN=Microsoft Corporation UEFI CA 2011" <<< "$signatures" ;;
        2023) grep -Eq "CN=Microsoft( Corporation)? UEFI CA 2023" <<< "$signatures" ;;
        *) return 1 ;;
    esac
}

has_efi_signature() {
    local signatures
    signatures="$(LC_ALL=C sbverify --list "$1" 2>&1)" || return 1
    grep -Eq '^signature [0-9]+' <<< "$signatures"
}

append_authority() {
    local authority="$1"
    case ";$detected_authorities;" in
        *";$authority;"*) ;;
        *) detected_authorities="${detected_authorities:+$detected_authorities;}$authority" ;;
    esac
}

detected_authorities=""
if command -v mokutil >/dev/null 2>&1; then
    secure_boot_state="$(LC_ALL=C mokutil --sb-state 2>/dev/null || true)"
    if grep -Fqi "SecureBoot enabled" <<< "$secure_boot_state"; then
        secure_boot_enabled=true
    elif grep -Fqi "SecureBoot disabled" <<< "$secure_boot_state"; then
        secure_boot_enabled=false
    fi
fi
if [ "$secure_boot_enabled" = true ] && command -v mokutil >/dev/null 2>&1; then
    db_text="$(LC_ALL=C mokutil --db 2>/dev/null || true)"
    grep -Fq "Microsoft Corporation UEFI CA 2011" <<< "$db_text" && append_authority 2011
    grep -Eq "Microsoft( Corporation)? UEFI CA 2023" <<< "$db_text" && append_authority 2023
fi
if [ "$secure_boot_enabled" = true ]; then
    [ -n "$detected_authorities" ] || detected_authorities="$plan_trusted_authorities"
else
    detected_authorities="$plan_supported_authorities"
fi
[ -n "$detected_authorities" ] || {
    echo "No trusted Microsoft UEFI authority could be determined" >&2
    exit 1
}

list_shim_candidates() {
    local authority="$1" candidate
    if [ "$authority" = 2023 ]; then
        printf '%s\n' \
            "$shim_directory/shimx64.efi.signed.2023" \
            "$shim_directory/shimx64.efi.dualsigned" \
            "$shim_directory/shimx64.efi.signed.latest"
    else
        printf '%s\n' \
            "$shim_directory/shimx64.efi.signed.2011" \
            "$shim_directory/shimx64.efi.dualsigned" \
            "$shim_directory/shimx64.efi.signed.latest" \
            "$shim_directory/shimx64.efi.signed.previous"
    fi
    for candidate in "$shim_directory/shimx64.efi.signed" "$shim_directory/shimx64.efi"; do
        printf '%s\n' "$candidate"
    done
    find "$shim_directory" -maxdepth 1 -type f -name 'shimx64*.efi*' -print 2>/dev/null | sort
}

select_shim() {
    local authority candidate
    for authority in 2023 2011; do
        case ";$detected_authorities;" in
            *";$authority;"*) ;;
            *) continue ;;
        esac
        while IFS= read -r candidate; do
            [ -f "$candidate" ] || continue
            package_owns_file "$candidate" shim-signed || continue
            if signature_has_authority "$candidate" "$authority"; then
                printf '%s\n%s\n' "$candidate" "$authority"
                return 0
            fi
        done < <(list_shim_candidates "$authority" | awk '!seen[$0]++')
    done
    return 1
}

select_signed_file() {
    local expected_package="$1"
    shift
    local candidate
    for candidate in "$@"; do
        [ -f "$candidate" ] || continue
        package_owns_file "$candidate" "$expected_package" || continue
        has_efi_signature "$candidate" || continue
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

mapfile -t shim_selection < <(select_shim)
if [ "${#shim_selection[@]}" -ne 2 ]; then
    echo "No distribution shim is signed by a Microsoft UEFI CA trusted by this firmware" >&2
    exit 1
fi
shim_source="${shim_selection[0]}"
selected_authority="${shim_selection[1]}"
grub_source="$(select_signed_file grub-efi-amd64-signed \
    "$grub_signed_directory/grubx64.efi.signed" \
    "$grub_signed_directory/grubx64.efi")" || {
    echo "The distribution signed GRUB binary is missing or unverified" >&2
    exit 1
}
mm_source="$(select_signed_file shim-signed \
    "$shim_directory/mmx64.efi.signed.latest" \
    "$shim_directory/mmx64.efi.signed" \
    "$shim_directory/mmx64.efi")" || {
    echo "The distribution signed MokManager binary is missing or unverified" >&2
    exit 1
}

declare -A sources=(
    [shimx64.efi]="$shim_source"
    [grubx64.efi]="$grub_source"
    [mmx64.efi]="$mm_source"
)
changed=false
for name in shimx64.efi grubx64.efi mmx64.efi; do
    if [ ! -f "$efi_directory/$name" ] || ! cmp -s "${sources[$name]}" "$efi_directory/$name"; then
        changed=true
    fi
done

if [ "$changed" = false ]; then
    echo "[$(date -u +%FT%TZ)] EFI/Libertix already matches verified distribution packages (Microsoft UEFI CA $selected_authority)"
    exit 0
fi

if [ -f "$efi_directory/shimx64.efi" ]; then
    current_hash="$(sha256sum "$efi_directory/shimx64.efi" | cut -d' ' -f1)"
    history_directory="$(mktemp -d \
        "$history_root/$(date -u +%Y%m%dT%H%M%SZ)-${current_hash:0:16}-XXXXXX")"
    chmod 0700 "$history_directory"
    for name in shimx64.efi grubx64.efi mmx64.efi grub.cfg .libertix-owner; do
        [ -f "$efi_directory/$name" ] || continue
        cp -a "$efi_directory/$name" "$history_directory/$name"
    done
    sha256sum "$history_directory"/* > "$history_directory/SHA256SUMS"
    chmod 0600 "$history_directory/SHA256SUMS"
    echo "[$(date -u +%FT%TZ)] Archived previous EFI chain in $history_directory"
fi

staged_paths=()
cleanup_staged_paths() {
    local path
    for path in "${staged_paths[@]}"; do
        [ ! -e "$path" ] || rm -f -- "$path"
    done
}
trap cleanup_staged_paths EXIT HUP INT TERM

stage_and_replace() {
    local source="$1" destination="$2" temporary expected actual
    temporary="$efi_directory/.${destination}.new.$$"
    staged_paths+=("$temporary")
    install -m 0644 "$source" "$temporary"
    expected="$(sha256sum "$source" | cut -d' ' -f1)"
    actual="$(sha256sum "$temporary" | cut -d' ' -f1)"
    [ "$actual" = "$expected" ] || {
        echo "Staged EFI hash mismatch for $destination" >&2
        exit 1
    }
    sync -f "$temporary" 2>/dev/null || sync
    mv -f "$temporary" "$efi_directory/$destination"
    sync -f "$efi_directory/$destination" 2>/dev/null || sync
}

# GRUB and MokManager remain signed by the distribution vendor. Replacing shim
# last ensures firmware never sees a new first-stage loader before its payloads.
stage_and_replace "$grub_source" grubx64.efi
stage_and_replace "$mm_source" mmx64.efi
stage_and_replace "$shim_source" shimx64.efi

signature_has_authority "$efi_directory/shimx64.efi" "$selected_authority" || {
    echo "Installed shim signature verification failed" >&2
    exit 1
}
has_efi_signature "$efi_directory/grubx64.efi" || {
    echo "Installed GRUB signature verification failed" >&2
    exit 1
}
has_efi_signature "$efi_directory/mmx64.efi" || {
    echo "Installed MokManager signature verification failed" >&2
    exit 1
}

echo "[$(date -u +%FT%TZ)] EFI/Libertix synchronized from signed distribution packages (Microsoft UEFI CA $selected_authority)"
