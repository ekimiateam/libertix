#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 || ! $1 =~ ^[0-9]+x[0-9]+$ ]]; then
  echo "Utilisation : $0 LARGEURxHAUTEUR DOSSIER_SORTIE" >&2
  exit 1
fi

resolution=$1
output_dir=$(realpath -m -- "$2")
screen_height=${resolution#*x}
screen_width=${resolution%x*}
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
staging_dir=$(mktemp -d)
generated_theme="$staging_dir/Libertix_grub"

cleanup() {
  rm -rf -- "$staging_dir"
}
trap cleanup EXIT

if [[ -e $output_dir ]]; then
  echo "Le dossier de sortie existe déjà : $output_dir" >&2
  exit 1
fi

scale() {
  local reference_value=$1
  local scaled_value=$(( (reference_value * screen_height + 540) / 1080 ))

  (( scaled_value > 0 )) || scaled_value=1
  printf '%s' "$scaled_value"
}

mkdir -p -- "$generated_theme/icons"
cp -- "$source_dir/theme.txt" "$generated_theme/theme.txt"
left_height=$(scale 160)
right_height=$(scale 120)
magick "$source_dir/left_down_border.png" -resize "x${left_height}" \
  "$staging_dir/left_down_border.png"
magick "$source_dir/right_down_border.png" -resize "x${right_height}" \
  "$staging_dir/right_down_border.png"

left_dimensions=$(magick identify -format '%w %h' "$staging_dir/left_down_border.png")
right_dimensions=$(magick identify -format '%w %h' "$staging_dir/right_down_border.png")
read -r left_width left_height <<< "$left_dimensions"
read -r right_width right_height <<< "$right_dimensions"

magick -size "${screen_width}x${screen_height}" 'xc:#222134' \
  "$staging_dir/left_down_border.png" -gravity southwest -composite \
  "$staging_dir/right_down_border.png" -gravity southeast -composite \
  "PNG32:$generated_theme/background.png"

icon_size=$(scale 48)
while IFS= read -r -d '' icon; do
  icon_name=$(basename -- "$icon")
  magick "$icon" -channel A -threshold 1% +channel \
    -resize "${icon_size}x${icon_size}" "PNG32:$generated_theme/icons/$icon_name"
done < <(find "$source_dir/icons" -type f -name '*.png' -print0)

selector_height=$(scale 56)
for selector in select_c.png select_e.png select_w.png; do
  magick "$source_dir/$selector" -resize "x${selector_height}" \
    "PNG32:$generated_theme/$selector"
done

display_font_size=$(scale 24)
console_font_size=$(scale 16)
grub-mkfont "$source_dir/Terminus.ttf" \
  -o "$generated_theme/Display.pf2" -s "$display_font_size" -n Display -b
grub-mkfont "$source_dir/Terminus.ttf" \
  -o "$generated_theme/Console.pf2" -s "$console_font_size" -n Console -b

item_icon_space=$(scale 26)
item_height=$(scale 56)
item_padding=$(scale 12)
item_spacing=$(scale 16)
menu_width=$(scale 960)
menu_height=$(scale 540)
menu_left_offset=$((menu_width / 2))
label_width=$(scale 576)
label_left_offset=$((label_width / 2))

sed -i \
  -e "s/terminal-font: .*/terminal-font: \"Console Bold ${console_font_size}\"/" \
  -e "/+ boot_menu {/,/}/ s/left = .*/left = 50%-$((menu_width / 2))/" \
  -e "/+ boot_menu {/,/}/ s/top = .*/top = $(scale 270)/" \
  -e "/+ boot_menu {/,/}/ s/width = .*/width = ${menu_width}/" \
  -e "/+ boot_menu {/,/}/ s/height = .*/height = ${menu_height}/" \
  -e "/+ boot_menu {/,/}/ s/item_font = .*/item_font = \"Display Bold ${display_font_size}\"/" \
  -e "/+ boot_menu {/,/}/ s/icon_width = .*/icon_width = ${icon_size}/" \
  -e "/+ boot_menu {/,/}/ s/icon_height = .*/icon_height = ${icon_size}/" \
  -e "/+ boot_menu {/,/}/ s/item_icon_space = .*/item_icon_space = ${item_icon_space}/" \
  -e "/+ boot_menu {/,/}/ s/item_height = .*/item_height = ${item_height}/" \
  -e "/+ boot_menu {/,/}/ s/item_padding = .*/item_padding = ${item_padding}/" \
  -e "/+ boot_menu {/,/}/ s/item_spacing = .*/item_spacing = ${item_spacing}/" \
  -e "/+ label {/,/}/ s/top = .*/top = $(scale 864)/" \
  -e "/+ label {/,/}/ s/left = .*/left = 50%-${label_left_offset}/" \
  -e "/+ label {/,/}/ s/width = .*/width = ${label_width}/" \
  -e "/+ label {/,/}/ s/font = .*/font = \"Display Bold ${display_font_size}\"/" \
  "$generated_theme/theme.txt"

mkdir -p -- "$(dirname -- "$output_dir")"
mv -- "$generated_theme" "$output_dir"

echo "Thème ${resolution} généré dans : $output_dir"
