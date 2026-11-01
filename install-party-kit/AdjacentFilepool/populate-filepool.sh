#!/usr/bin/env bash
# Populates a "filepool" folder that Libertix can use instead of downloading its files.
# Run it once on a computer with a fast Internet connection, then copy the folder
# next to Libertix.exe. Requires: bash, curl, openssl, sha256sum, base64 and python3.
set -Eeuo pipefail

CHANNEL="main"
OUTPUT="filepool"

# Copy of Scripts/config/Libertix.CatalogPublicKey.xml, the key Libertix itself uses
# to verify catalog.json. Update both together if the signing key ever changes.
CATALOG_PUBLIC_KEY='-----BEGIN PUBLIC KEY-----
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEApFvbBspLzX/TS1BoIYOc
ILD1/VnEL/wYjN3wQAYXDsDeWuW52RFnBXoezrI6ulw8kuowfPvy913+jztUETMl
LLabfNB/EXD9ZFjyC4A49HNq6o3L1Z0cTT7GLlWEAyBniZJJ3S5NqR6Zv+1kdE+S
tWzEm9LD6Ml/f4mR2IJLYxDC8j89jQAueJnFFP8OvTAdnkHECkqilUM8WTuaoZ6F
Zn8SfCMbYu/ZgoFPjvUl0eP6Z1xMScO6udK9W23JHN6M52Xz99Z7N55p1eItkrTj
wSJvO73pAlga7UrUI6BK3uLOAYibzn0mIT3mUwrwXPDFTQ8qIOon7L06yF0fFEOS
G9gxAQcf7nlsng2daAq2BqzFQ/oKNosG6IPvTP+ChHB9hgNnbXpZEj9gFC98fl0I
l/EH3DVUQ8dwsV1Dij9PzpZyj7c2EmzqE2udCLP8hsqHHmMl4iV9hTjXo1eknORm
yYOmK5DJk/Bzwmq4vmxm6iGqyj+BI6Luk0qLeBdT+Xg1AgMBAAE=
-----END PUBLIC KEY-----'

usage() {
    cat <<EOF
Usage: $0 [--channel main|dev] [--output DIRECTORY]

  --channel  Libertix release channel (default: main). Use "main" for a stable
             Libertix version and "dev" for a development build (dev_<commit>).
  --output   Folder to create or complete (default: ./filepool).

Files that are already present and valid are kept and not downloaded again.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

while (( $# )); do
    case "$1" in
        --channel) [[ $# -ge 2 ]] || die "--channel needs a value"; CHANNEL="$2"; shift 2 ;;
        --output) [[ $# -ge 2 ]] || die "--output needs a value"; OUTPUT="$2"; shift 2 ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[[ "$CHANNEL" == "main" || "$CHANNEL" == "dev" ]] || die "The channel must be main or dev."
for tool in curl openssl sha256sum base64 python3; do
    command -v "$tool" >/dev/null || die "Missing required tool: $tool"
done

BASE_URL="https://ekimiateam.github.io/libertix/$CHANNEL"
mkdir -p -- "$OUTPUT"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

echo "Downloading the signed $CHANNEL catalog..."
curl -fsSL --retry 3 -o "$WORK/catalog.json" "$BASE_URL/catalog.json"
curl -fsSL --retry 3 -o "$WORK/catalog.json.sig" "$BASE_URL/catalog.json.sig"
printf '%s\n' "$CATALOG_PUBLIC_KEY" >"$WORK/key.pem"
base64 -d "$WORK/catalog.json.sig" >"$WORK/signature.bin" || die "The catalog signature is not valid Base64."
openssl dgst -sha256 -verify "$WORK/key.pem" -signature "$WORK/signature.bin" \
    "$WORK/catalog.json" >/dev/null || die "The catalog signature is invalid."
echo "Catalog signature verified."

# One line per artifact: kind, file name, size, SHA-256, URL, display name.
# Relative URLs are resolved against the channel, as Libertix does.
python3 - "$WORK/catalog.json" "$BASE_URL" >"$WORK/artifacts.tsv" <<'PY'
import json, re, sys
catalog = json.load(open(sys.argv[1], encoding="utf-8"))
base = sys.argv[2]
artifacts = catalog["artifacts"]
rows = [("required", item, item["fileName"]) for item in
        [artifacts["wpf"], *artifacts["miniIso"].values(), *artifacts["support"].values()]]
rows += [("distribution", {"fileName": d["isoInstallerFileName"], "sizeBytes": d["isoInstallerSizeBytes"],
          "sha256": d["isoInstallerSha256"], "url": d["isoInstaller"]}, d["name"])
         for d in catalog["distributions"]]
for kind, item, label in rows:
    name, url = item["fileName"], item["url"]
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", name):
        sys.exit(f"Unsafe file name in the catalog: {name}")
    if not re.match(r"https?://", url):
        url = base + "/" + url.lstrip("/")
    print("\t".join((kind, name, str(item["sizeBytes"]), item["sha256"].lower(), url, label)))
PY
mapfile -t ARTIFACTS <"$WORK/artifacts.tsv"
(( ${#ARTIFACTS[@]} )) || die "The catalog lists no files."

DISTRIBUTIONS=()
for row in "${ARTIFACTS[@]}"; do
    IFS=$'\t' read -r kind name _ _ _ label <<<"$row"
    if [[ "$kind" == "distribution" ]]; then
        DISTRIBUTIONS+=("$name|$label")
    fi
done

echo
echo "Distribution ISO images are optional: Libertix downloads a missing one"
echo "when that distribution is chosen. All other files are always required."
echo "  1) All distributions"
for index in "${!DISTRIBUTIONS[@]}"; do
    echo "  $((index + 2))) ${DISTRIBUTIONS[index]#*|} only"
done
NONE_CHOICE=$(( ${#DISTRIBUTIONS[@]} + 2 ))
echo "  $NONE_CHOICE) No distribution ISO (required files only)"
read -r -p "Choice [1]: " CHOICE
CHOICE="${CHOICE:-1}"
[[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= NONE_CHOICE )) || die "Invalid choice: $CHOICE"

is_selected() {
    local name="$1"
    (( CHOICE == 1 )) && return 0
    (( CHOICE == NONE_CHOICE )) && return 1
    [[ "${DISTRIBUTIONS[CHOICE - 2]%%|*}" == "$name" ]]
}

file_is_valid() {
    local path="$1" size="$2" sha256="$3"
    [[ -f "$path" && ! -L "$path" ]] || return 1
    [[ "$(stat -c %s -- "$path")" == "$size" ]] || return 1
    [[ "$(sha256sum -- "$path" | cut -d' ' -f1)" == "$sha256" ]]
}

download() {
    local url="$1" path="$2" size="$3" sha256="$4"
    local partial="$path.partial" status=0
    # Resume an interrupted download. Restart only when resuming is impossible: the
    # server refuses byte ranges (curl 33) or the partial file is already too large.
    curl -fL --retry 3 --progress-bar -C - -o "$partial" "$url" || status=$?
    if (( status == 33 )) ||
        { (( status != 0 )) && [[ -f "$partial" ]] && (( $(stat -c %s -- "$partial") >= size )); }; then
        rm -f -- "$partial"
        status=0
        curl -fL --retry 3 --progress-bar -o "$partial" "$url" || status=$?
    fi
    # Keep a partial file after a network error so the next run resumes it.
    (( status == 0 )) || return 1
    if ! file_is_valid "$partial" "$size" "$sha256"; then
        rm -f -- "$partial"
        echo "ERROR: $(basename -- "$path") does not match the catalog size or SHA-256." >&2
        return 1
    fi
    mv -f -- "$partial" "$path"
}

FAILED=0
for row in "${ARTIFACTS[@]}"; do
    IFS=$'\t' read -r kind name size sha256 url label <<<"$row"
    path="$OUTPUT/$name"
    if [[ "$kind" == "distribution" ]] && ! is_selected "$name"; then
        # Libertix verifies every distribution ISO found in the folder.
        if [[ -e "$path" ]] && ! file_is_valid "$path" "$size" "$sha256"; then
            echo "ERROR: $name ($label) is present but outdated or corrupt." >&2
            echo "       Delete it or select it so that it is downloaded again." >&2
            FAILED=1
        fi
        continue
    fi
    if file_is_valid "$path" "$size" "$sha256"; then
        echo "OK      $name (already present and verified)"
        continue
    fi
    echo "GET     $name ($(( size / 1048576 )) MiB) from $url"
    if download "$url" "$path" "$size" "$sha256"; then
        echo "OK      $name (downloaded and verified)"
    else
        echo "ERROR: Could not obtain $name." >&2
        FAILED=1
    fi
done

echo
if (( FAILED )); then
    echo "The folder is NOT ready: fix the errors above and run the script again."
    exit 1
fi
# The catalog is written last, only once every file it requires has been verified.
cp -f -- "$WORK/catalog.json" "$OUTPUT/catalog.json"
cp -f -- "$WORK/catalog.json.sig" "$OUTPUT/catalog.json.sig"
echo "The folder is ready: $(cd -- "$OUTPUT" && pwd)"
echo "Copy it next to Libertix.exe with the name \"filepool\"."
