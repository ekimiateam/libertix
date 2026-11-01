#!/usr/bin/env bash
# Regenerate the functional GRUB menu icons from the MingCute sources in ./mingcute.
#
# Each icon is a 48x48 RGBA PNG: a filled circle in Rosé Pine Moon "overlay" (#393552) with the
# MingCute Core Filled glyph in Rosé Pine Moon "text" (#e0def4), scaled from 24 to 28 px and
# centred. Verified with rsvg-convert 2.58.0 (Ubuntu 24.04 librsvg2-bin).
#
# Usage: render-functional-icons.sh [OUTPUT_DIR]   (default: the parent icons directory)

set -euo pipefail

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
output_dir=${1:-$(dirname -- "$source_dir")}
staging_dir=$(mktemp -d)
trap 'rm -rf -- "$staging_dir"' EXIT

# GRUB class   MingCute Core Filled source
while read -r class icon; do
  path=$(sed -nE 's/.*<path (d="[^"]*")\/>.*/\1/p' "$source_dir/mingcute/$icon.svg")
  [[ -n $path ]] || { echo "no single path in $icon.svg" >&2; exit 1; }
  cat > "$staging_dir/$class.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48" viewBox="0 0 48 48">
<circle cx="24" cy="24" r="24" fill="#393552"/>
<g fill="#e0def4" transform="translate(10 10) scale(1.1666667)"><path $path/></g>
</svg>
EOF
  rsvg-convert --width 48 --height 48 --format png \
    --output "$output_dir/$class.png" "$staging_dir/$class.svg"
done <<'EOF'
shutdown power
efi settings_5
submenu list_expansion
recovery-mode first_aid_kit
memtest memory_stick
firmware chip
EOF
