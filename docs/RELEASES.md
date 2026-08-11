# Release, signing and GitHub Pages workflow

Libertix publishes two independent channels from one repository and one configuration file.

| Branch | WPF version | Release tag | Pages directory | Retention |
|---|---|---|---|---|
| `dev` | `dev_<sha7>` | `<sha7>` | `/dev` | Three newest SHA prereleases |
| `main` | `mainRelease.version` | `mainRelease.version` | `/main` | Every stable release |

The channels never share generated files. A `dev` workflow changes only the `dev/` directory on
`gh-pages`; a `main` workflow changes only `main/`.

## Maintainer configuration

[`release-config.json`](../release-config.json) is the only hand-maintained release input. Its
`mainRelease` section supplies the stable version, title and notes. A dev build ignores those three
values. Its `distributions` section is shared by both channels and contains the public presentation
metadata plus the official external ISO URL, filename, SHA-256 and byte size.

The file is validated against
[`schemas/release-config.schema.json`](../schemas/release-config.schema.json). Distribution IDs are
unique, external URLs use HTTPS, hashes are lowercase SHA-256 values, and the stable version is a
plain release number such as `0.1` or `0.1.0`.

## Automated workflow

For a push to `dev` or `main`, [the CI workflow](../.github/workflows/ci.yml) performs these steps:

1. Resolve the channel, release tag and WPF informational version.
2. Run source-quality, Python, PowerShell and C# tests and build `Libertix.exe`.
3. Rebuild and verify the generic BIOS and UEFI mini-ISO images.
4. Package the WPF output and calculate every release-asset SHA-256.
5. Generate `distros.json` and `releases.json` from the one configuration and the built artifacts.
6. Sign both JSON files with RSA/SHA-256 and verify that the private key matches the public key
   embedded in Libertix.
7. Publish `Libertix-wpf.zip`, both mini-ISO files and `SHA256SUMS` in a GitHub Release.
8. Commit the four JSON/signature files to only the selected channel on `gh-pages` and request a
   GitHub Pages build.

Dev release creation is safe to rerun for the same commit. A main run fails before publication if
its stable tag already exists; update `mainRelease.version` before publishing another stable release.
No stable release or tag is deleted automatically.

## Required repository setup

Create one Actions repository secret named `LIBERTIX_SIGNING_PRIVATE_KEY`. Its value is the complete
PEM RSA private key matching `Scripts/config/Libertix.CatalogPublicKey.xml`. Never add the private
key to Git, workflow artifacts, Pages or release assets.

GitHub Pages must use `Deploy from a branch`, branch `gh-pages`, directory `/ (root)`. The workflow
needs `contents: write` to update that branch and `pages: write` to request the branch deployment.
Repository workflow permissions must allow the workflow token to write repository contents.

## Runtime behavior

A stamped dev executable reads `https://ekimiateam.github.io/libertix/dev/distros.json`, verifies
its signature and downloads its mini-ISO from the release tagged with its SHA. It does not fetch
`releases.json` and never blocks because a newer dev commit exists.

A stable executable first downloads and verifies `/main/releases.json` and its signature. It starts
only when `latest.version` exactly matches its embedded version. Otherwise it shows a translated
blocking message and offers to open the current GitHub Release. It then verifies the signed main
distribution catalogue before trusting any URL or checksum.

## Local metadata checks

The local private key is intentionally outside version control. When it is available, metadata can
be generated and signed with:

```bash
uv run --project auto_tests --frozen python iso-tools/generate-release-metadata.py \
  --channel dev \
  --tag "$(git rev-parse --short=7 HEAD)" \
  --commit "$(git rev-parse HEAD)" \
  --bios-iso libertix-installer-bios.iso \
  --uefi-iso libertix-installer-uefi.iso \
  --wpf-zip path/to/Libertix-wpf.zip \
  --output-dir .work/release-metadata

uv run --project auto_tests --frozen python iso-tools/sign-release-metadata.py \
  --private-key /secure/path/catalog-signing-private.pem \
  .work/release-metadata/distros.json \
  .work/release-metadata/releases.json
```

Generated metadata and private keys must remain outside commits.
