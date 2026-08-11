#!/bin/bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
served_manifest="$repo_root/auto_tests/app/filepool/distros.json"
fixture_manifest="$repo_root/Libertix.Tests/TestData/distros.json"
served_signature="$served_manifest.sig"
fixture_signature="$fixture_manifest.sig"
private_key="$repo_root/local-markdown/catalog-signing-private.pem"
public_key_xml="$repo_root/Scripts/config/Libertix.CatalogPublicKey.xml"
work_dir="$repo_root/.work/catalog-signing"
selected_manifest=""
signature_tmp=""

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    printf 'Usage: %s [distros.json]\n' "${0##*/}"
    printf 'Without an argument, an interactive catalog menu is displayed.\n'
}

print_configured_paths() {
    printf 'Configured files:\n'
    printf '  Catalog served by auto-tests: %s\n' "$served_manifest"
    printf '  Catalog test fixture:         %s\n' "$fixture_manifest"
    printf '  Served detached signature:    %s\n' "$served_signature"
    printf '  Fixture detached signature:   %s\n' "$fixture_signature"
    printf '  Private signing key:          %s\n' "$private_key"
    printf '  Public application key:       %s\n' "$public_key_xml"
}

choose_manifest() {
    printf 'Libertix signed catalog tool\n'
    print_configured_paths
    printf '\n'
    printf '  1) Sign and synchronize distros.json\n'
    printf '  q) Quit\n'
    printf '> '
    IFS= read -r choice
    case "$choice" in
        1) selected_manifest="$served_manifest" ;;
        q|Q) exit 0 ;;
        *) die "Unknown selection: $choice" ;;
    esac
}

resolve_manifest() {
    local requested="$1"
    local resolved
    resolved="$(realpath -e -- "$requested")" || die "Manifest does not exist: $requested"
    case "$resolved" in
        "$served_manifest"|"$fixture_manifest") printf '%s\n' "$resolved" ;;
        *)
            die "Only the versioned distros.json catalogs are supported: $served_manifest or $fixture_manifest"
            ;;
    esac
}

assert_private_key_matches_application_key() {
    local xml_modulus_b64 xml_exponent_b64 xml_modulus_hex xml_exponent_hex
    local private_modulus_hex private_exponent

    test -f "$private_key" || die "Private signing key is missing: $private_key"
    test -f "$public_key_xml" || die "Application public key is missing: $public_key_xml"
    if git -C "$repo_root" ls-files --error-unmatch \
        "${private_key#"$repo_root/"}" >/dev/null 2>&1; then
        die "The private signing key must never be tracked by Git."
    fi

    xml_modulus_b64="$(sed -n 's#.*<Modulus>\([^<]*\)</Modulus>.*#\1#p' "$public_key_xml")"
    xml_exponent_b64="$(sed -n 's#.*<Exponent>\([^<]*\)</Exponent>.*#\1#p' "$public_key_xml")"
    test -n "$xml_modulus_b64" || die "The application public modulus is missing."
    test -n "$xml_exponent_b64" || die "The application public exponent is missing."

    xml_modulus_hex="$(
        printf '%s' "$xml_modulus_b64" |
            base64 --decode |
            od -An -vtx1 |
            tr -d ' \n' |
            tr '[:lower:]' '[:upper:]'
    )"
    xml_exponent_hex="$(
        printf '%s' "$xml_exponent_b64" |
            base64 --decode |
            od -An -vtx1 |
            tr -d ' \n' |
            tr '[:lower:]' '[:upper:]'
    )"
    private_modulus_hex="$(
        openssl rsa -in "$private_key" -noout -modulus 2>/dev/null |
            sed 's/^Modulus=//'
    )"
    private_exponent="$(
        openssl rsa -in "$private_key" -noout -text 2>/dev/null |
            sed -n 's/.*publicExponent: \([0-9][0-9]*\).*/\1/p' |
            head -n 1
    )"

    test "$xml_modulus_hex" = "$private_modulus_hex" ||
        die "The private key does not match the public key bundled with Libertix."
    test "$xml_exponent_hex" = "010001" || die "Unsupported application RSA exponent."
    test "$private_exponent" = "65537" || die "Unsupported private RSA exponent."
}

sign_and_synchronize_catalog() {
    local source_manifest="$1"
    local manifest_target signature_target

    python3 -m json.tool "$source_manifest" >/dev/null || die "Catalog JSON is invalid."
    assert_private_key_matches_application_key

    mkdir -p "$work_dir"
    signature_tmp="$(mktemp "$work_dir/distros.json.sig.XXXXXX")"
    trap 'rm -f -- "$signature_tmp"' EXIT

    openssl dgst -sha256 -sign "$private_key" "$source_manifest" |
        base64 -w0 > "$signature_tmp"
    printf '\n' >> "$signature_tmp"
    openssl dgst -sha256 \
        -verify <(openssl pkey -in "$private_key" -pubout 2>/dev/null) \
        -signature <(base64 --decode "$signature_tmp") \
        "$source_manifest" >/dev/null || die "Generated signature verification failed."

    for manifest_target in "$served_manifest" "$fixture_manifest"; do
        if test "$source_manifest" != "$manifest_target"; then
            install -m 0644 -- "$source_manifest" "$manifest_target"
        fi
    done
    for signature_target in "$served_signature" "$fixture_signature"; do
        install -m 0644 -- "$signature_tmp" "$signature_target"
    done

    for manifest_target in "$served_manifest" "$fixture_manifest"; do
        openssl dgst -sha256 \
            -verify <(openssl pkey -in "$private_key" -pubout 2>/dev/null) \
            -signature <(base64 --decode "$served_signature") \
            "$manifest_target" >/dev/null || die "Signature verification failed for $manifest_target"
    done

    printf 'CATALOG_SHA256=%s\n' "$(sha256sum "$served_manifest" | cut -d ' ' -f 1)"
    printf 'PUBLIC_KEY_SHA256=%s\n' "$(sha256sum "$public_key_xml" | cut -d ' ' -f 1)"
    printf 'UPDATED=%s\n' "$served_manifest"
    printf 'UPDATED=%s\n' "$fixture_manifest"
    printf 'UPDATED=%s\n' "$served_signature"
    printf 'UPDATED=%s\n' "$fixture_signature"
}

case "$#" in
    0)
        choose_manifest
        manifest="$selected_manifest"
        ;;
    1)
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            *) manifest="$1" ;;
        esac
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

manifest="$(resolve_manifest "$manifest")"
sign_and_synchronize_catalog "$manifest"
