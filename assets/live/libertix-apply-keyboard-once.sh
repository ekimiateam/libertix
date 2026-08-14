#!/bin/sh
set -eu

marker_directory="${XDG_CONFIG_HOME:-$HOME/.config}/libertix"
marker_path="$marker_directory/keyboard-initialized.json"
temporary_marker="$marker_directory/.keyboard-initialized.$$.tmp"

[ -r /etc/default/keyboard ] || exit 0
[ -r /etc/default/locale ] || exit 0

# Cinnamon can retain the configured input source while leaving the X server
# on its previous layout during the first session. Applying the root-owned
# keyboard configuration after session startup brings both states back in
# sync. The per-user marker prevents later logins from overriding a layout the
# user selected after installation.
. /etc/default/keyboard
session_language="${LANG:-}"
. /etc/default/locale

keyboard_source="${XKBLAYOUT:?XKBLAYOUT is required}"
if [ -n "${XKBVARIANT:-}" ]; then
    keyboard_source="${keyboard_source}+${XKBVARIANT}"
fi
expected_sources="[('xkb', '$keyboard_source')]"
configured_sources=0

if [ -f "$marker_path" ] && python3 - "$marker_path" "$session_language" "$LANG" \
    "$XKBLAYOUT" "${XKBVARIANT:-}" "${XKBMODEL:-pc105}" "$keyboard_source" <<'PY'
import json
import sys

path, session_language, configured_language, layout, variant, model, source = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as stream:
        marker = json.load(stream)
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)

expected = {
    "schemaVersion": 1,
    "status": "succeeded",
    "sessionLanguage": session_language,
    "configuredLanguage": configured_language,
    "layout": layout,
    "variant": variant,
    "model": model,
    "desktopSource": source,
}
raise SystemExit(0 if all(marker.get(key) == value for key, value in expected.items()) else 1)
PY
then
    exit 0
fi

sleep 3
for schema in org.gnome.desktop.input-sources org.cinnamon.desktop.input-sources; do
    if gsettings list-schemas | grep -Fxq "$schema"; then
        gsettings set "$schema" sources "$expected_sources"
        [ "$(gsettings get "$schema" sources)" = "$expected_sources" ] || {
            echo "Desktop input sources did not accept $keyboard_source for $schema" >&2
            exit 1
        }
        configured_sources=$((configured_sources + 1))
    fi
done
[ "$configured_sources" -gt 0 ] || {
    echo "No supported desktop input-source schema is installed" >&2
    exit 1
}

if gsettings list-schemas | grep -Fxq org.gnome.libgnomekbd.keyboard; then
    gsettings set org.gnome.libgnomekbd.keyboard layouts "['$keyboard_source']"
    [ "$(gsettings get org.gnome.libgnomekbd.keyboard layouts)" = "['$keyboard_source']" ] || {
        echo "Legacy desktop keyboard layout did not accept $keyboard_source" >&2
        exit 1
    }
fi

if [ "${XDG_SESSION_TYPE:-}" = x11 ] && command -v setxkbmap >/dev/null 2>&1; then
    setxkbmap \
        -model "${XKBMODEL:-pc105}" \
        -layout "$XKBLAYOUT" \
        -variant "${XKBVARIANT:-}" \
        -option "${XKBOPTIONS:-}"
    setxkbmap -query | grep -Eq "^layout:[[:space:]]+$XKBLAYOUT$"
    if [ -n "${XKBVARIANT:-}" ]; then
        setxkbmap -query | grep -Eq "^variant:[[:space:]]+$XKBVARIANT$"
    fi
fi

mkdir -p "$marker_directory"
cat > "$temporary_marker" <<EOF
{
  "schemaVersion": 1,
  "status": "succeeded",
  "sessionLanguage": "$session_language",
  "configuredLanguage": "${LANG:?LANG is required}",
  "layout": "$XKBLAYOUT",
  "variant": "${XKBVARIANT:-}",
  "model": "${XKBMODEL:-pc105}",
  "desktopSource": "$keyboard_source"
}
EOF
mv "$temporary_marker" "$marker_path"
