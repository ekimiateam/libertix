#!/bin/bash
set -Eeuo pipefail

config_path="${1:-/boot/grub/grub.cfg}"
plan_path="${2:-/etc/libertix/installation-plan.json}"
readonly expected_root_entries=4

[ -s "$config_path" ] || {
    echo "GRUB configuration is missing or empty: $config_path" >&2
    exit 1
}
[ -s "$plan_path" ] || {
    echo "Libertix installation plan is missing: $plan_path" >&2
    exit 1
}
command -v grub-script-check >/dev/null 2>&1 || {
    echo "grub-script-check is required" >&2
    exit 1
}

mapfile -t plan_values < <(python3 - "$plan_path" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8-sig") as stream:
    plan = json.load(stream)
distribution = plan.get("distribution")
if not isinstance(distribution, dict):
    raise SystemExit("installation plan distribution is missing")
display_name = distribution.get("grubDisplayName")
icon = distribution.get("grubIcon")
firmware = plan.get("firmware")
if not isinstance(display_name, str) or not re.fullmatch(
    r"[A-Za-z0-9][A-Za-z0-9 ._()+-]{0,79}", display_name
):
    raise SystemExit("installation plan GRUB display name is invalid")
if not isinstance(icon, str) or not re.fullmatch(
    r"[a-z0-9](?:[a-z0-9._-]{0,62}[a-z0-9])?", icon
):
    raise SystemExit("installation plan GRUB icon is invalid")
if firmware not in {"bios", "uefi"}:
    raise SystemExit("installation plan firmware is invalid")
print(display_name)
print(icon)
print(firmware)
PY
)
[ "${#plan_values[@]}" -eq 3 ] || {
    echo "Cannot read Libertix GRUB metadata from the installation plan" >&2
    exit 1
}
display_name="${plan_values[0]}"
icon="${plan_values[1]}"
firmware="${plan_values[2]}"

grub-script-check "$config_path" || {
    echo "Generated GRUB configuration has invalid syntax" >&2
    exit 1
}
grep -Fq -- "--class $icon" "$config_path" || {
    echo "Generated GRUB configuration is missing the distribution icon class" >&2
    exit 1
}
grep -Fq "menuentry '$display_name'" "$config_path" || {
    echo "Generated GRUB configuration is missing the distribution root entry" >&2
    exit 1
}
grep -Fq -- "--class efi --id libertix-advanced" "$config_path" || {
    echo "Generated GRUB configuration is missing the Advanced options submenu" >&2
    exit 1
}
grep -Fq -- "--class shutdown --id libertix-shutdown" "$config_path" || {
    echo "Generated GRUB configuration is missing the Shutdown entry" >&2
    exit 1
}
grep -Fq -- "--id libertix-windows" "$config_path" || {
    echo "Generated GRUB configuration is missing the Windows entry" >&2
    exit 1
}
if [ "$firmware" = uefi ]; then
    grep -Eq -- "(--id([=[:space:]]+)|\\\$menuentry_id_option[[:space:]]+)'?uefi-firmware'?([[:space:]]|$)" "$config_path" || {
        echo "Generated GRUB configuration is missing UEFI Firmware Settings" >&2
        exit 1
    }
fi

root_entry_count="$(grep -Ec '^(menuentry|submenu) ' "$config_path" || true)"
[ "$root_entry_count" -eq "$expected_root_entries" ] || {
    echo "Generated GRUB configuration has $root_entry_count root entries; expected $expected_root_entries" >&2
    exit 1
}

echo "Libertix GRUB configuration verified: firmware=$firmware roots=$root_entry_count"
