#!/bin/sh
set -eu

marker_directory="${XDG_CONFIG_HOME:-$HOME/.config}/libertix"
marker_path="$marker_directory/keyboard-initialized"

[ ! -e "$marker_path" ] || exit 0
[ -r /etc/default/keyboard ] || exit 0

# Cinnamon can retain the configured input source while leaving the X server
# on its previous layout during the first session. Applying the root-owned
# keyboard configuration after session startup brings both states back in
# sync. The per-user marker prevents later logins from overriding a layout the
# user selected after installation.
. /etc/default/keyboard
command -v setxkbmap >/dev/null 2>&1 || exit 0

sleep 3
setxkbmap \
    -model "${XKBMODEL:-pc105}" \
    -layout "${XKBLAYOUT:?XKBLAYOUT is required}" \
    -variant "${XKBVARIANT:-}" \
    -option "${XKBOPTIONS:-}"

mkdir -p "$marker_directory"
: > "$marker_path"
