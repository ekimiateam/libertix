#!/bin/bash
set -Eeuo pipefail

manifest="${1:?manifest path is required}"
private_key="${2:?private key path is required}"
signature="${3:-$manifest.sig}"

test -f "$manifest"
test -f "$private_key"

# The private key never enters the repository. Only the detached signature is
# published beside the manifest consumed by production installers.
openssl dgst -sha256 -sign "$private_key" "$manifest" | base64 -w0 > "$signature"
printf '\n' >> "$signature"
