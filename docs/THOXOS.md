# ThoxOS distribution

Libertix installs **ThoxOS 26.10 Workstation** alongside Windows through the same
supported path it uses for every other catalog distribution: one signed catalog
entry, the shared Windows-side preparation, the shared live installer, and the
shared GRUB/dual-boot configuration. ThoxOS adds a brand and desktop layer on
top of a plain Ubuntu 26.10 base.

- Source: [`ttracx/thoxos-ubuntu-26-10`](https://github.com/ttracx/thoxos-ubuntu-26-10)
  (base policy, mkosi image kit, Look and Feel) and
  [`ttracx/thoxos-desktop`](https://github.com/ttracx/thoxos-desktop)
  (workstation toolkit, brand layer, design system).

## What the user gets

| Property | Value |
| --- | --- |
| Catalog id | `thoxos` |
| Base | Ubuntu 26.10 "Stonking Stingray" (Kubuntu Plasma flavor) |
| Desktop | KDE Plasma 6.7 |
| os-release ID | `ubuntu` (see "Identity" below) |
| GRUB menu entry | `ThoxOS 26.10 (Kubuntu 26.10 Plasma)` |
| GRUB icon | `assets/grub-theme/icons/thoxos.png` |
| Secure Boot authorities | `2011`, `2023` |
| Default disk allocation | 40 GiB |
| Telemetry | none — local-first |

## Identity

ThoxOS is a *branded Ubuntu*, not a distinct distribution ID. This is deliberate
and load-bearing:

- `InstallationPlanValidator` and `libertix-distribution-common.sh` require the
  extracted rootfs `os-release` ID to match the plan's `osReleaseId`, and both
  `configure-target-main.sh` and the first-boot verifier accept only
  Debian/Ubuntu-family payloads.
- Therefore `osReleaseId` is `ubuntu`, and the brand layer never rewrites `ID` or
  `ID_LIKE`. It overrides presentation keys only (`PRETTY_NAME`, `NAME`,
  `HOME_URL`, `SUPPORT_URL`, `BUG_REPORT_URL`, `PRIVACY_POLICY_URL`, `LOGO`) and
  appends `THOX_*` edition keys, then asserts the identity is unchanged.
- Presentation is published through `/etc/thoxos-release` and
  `/etc/thoxos-variant`, so tools can report the product without lying about the
  distribution.

Branding is derived from the target's own `/usr/lib/os-release` rather than from
a static file, so the edition always reports the exact base build it was
extracted from. The untouched upstream copy is kept at
`/usr/lib/os-release.upstream`, which makes the pass idempotent and re-derivable.

## Installer ISO pin

The catalog pins the released Kubuntu 26.10 image from Canonical's release
channel (not the daily channel, which is unpublished for this release):

```
https://cdimage.ubuntu.com/kubuntu/releases/26.10/release/snapshot-4/kubuntu-26.10-snapshot4-desktop-amd64.iso
sha256 423208af871a9eea8810c43c0e60c71eefb7ae9d0db1c22e32eabab2945d0994
size   5237479424 bytes
```

The recorded provenance, the published `SHA256SUMS`/`SHA256SUMS.gpg` URLs and the
upstream `Last-Modified` value live in
[`assets/thoxos/iso-provenance.json`](../assets/thoxos/iso-provenance.json), and a
test keeps that record in step with the catalog entry. Libertix re-verifies the
ISO against this hash on the target machine before extraction.

Refresh the pin with the ThoxOS toolkit and then update both
`release-config.json` and the provenance record:

```bash
# in ttracx/thoxos-ubuntu-26-10
scripts/refresh-daily-inputs.sh
```

## Brand layer payload

Everything the layer needs travels inside the installer ISO under
`assets/thoxos/` and is staged to `/usr/local/lib/libertix/thoxos-layer` in the
live system, then copied to `/tmp/thoxos-layer` on the target. Nothing is
downloaded at install time.

| Path | Purpose |
| --- | --- |
| `tokens/thoxos-tokens.json` | Palette, typography and boot contract |
| `fonts/Xolonium-Regular.otf`, `Xolonium-Bold.otf`, `OFL.txt` | Brand typefaces (SIL OFL 1.1) |
| `logo/*.svg`, `logo/*.png`, `logo/on-light/*` | Official THOX marks for dark and light surfaces |
| `logo/favicon.ico`, `hicolor/256x256/apps/thoxos.png` | Desktop/app icons |
| `thoxos-desk-wallpaper.jpg` | Approved ThoxOS wallpaper |
| `plymouth/thoxos.script` | Live boot splash on the ThoxOS canvas colour |
| `card/thoxos-workstation-2610.png` | Distribution card shown by the Windows wizard |
| `os-release`, `iso-provenance.json` | Reference data and ISO pin record |

Brand artwork keeps the official brand-library values (`#05A451` green,
`#F9F9F9` light text). Interface surfaces keep the semantic zinc/emerald roles
(`#09090b`, `#18181b`, `#3f3f46`, `#fafafa`, `#10b981`, `#34d399`) so contrast
stays readable.

## What the layer installs on the target

`assets/live/configure-thoxos-target.sh` sources
`assets/live/thoxos-configure-target.sh` from the target chroot. It runs only
when the signed catalog selected `DISTRIBUTION_ID=thoxos`, and it is additive —
the shared account, locale, keyboard, Windows-sharing and GRUB steps all still
run, so an installation that stopped before this point is still a complete,
bootable Ubuntu system.

1. **Identity** — branded `os-release` presentation keys, `/etc/thoxos-release`,
   `/etc/thoxos-variant`.
2. **Brand assets** — Xolonium installed to `/usr/local/share/fonts/thoxos` with
   the OFL notice, Fontconfig refreshed, and `fc-match Xolonium` verified to
   resolve (a missing font fails the install rather than silently falling back).
3. **Marks** — official SVG/PNG marks under `/usr/local/share/thoxos/branding`,
   plus hicolor and pixmap app icons.
4. **Desktop defaults** — wallpaper published to `/etc/skel`, the account home and
   `/usr/share/wallpapers/ThoxOS`.
5. **Launcher** — `thoxos-info` and an "About ThoxOS" desktop entry.
6. **Console identity** — `/etc/issue`, `/etc/motd`, `/etc/update-motd.d/90-thoxos`.
7. **First-boot report** — `thoxos-first-boot-report.service` writes
   `/var/lib/thoxos/first-boot-result.txt`.

## Dual boot

Dual boot is unchanged from every other distribution. ThoxOS participates in the
shared Libertix GRUB layout: the branded entry gets the `thoxos` icon class, the
Windows entry is preserved and hash-verified, and the generator diversions that
keep the layout across package updates apply identically. Because the pinned
image is `shim-signed`, the UEFI chain is verified against the configured
Microsoft authorities on both the `2011` and `2023` CAs.

## Windows wizard theming

The Windows application uses the ThoxOS design system: dark-first zinc surfaces,
emerald accent, brand mark as the window and tray icon. Resource keys are
unchanged from the previous theme, so pages and localization are unaffected.
Emerald fills carry dark text because light text on `#34D399` would not pass
contrast.

## Verification

```bash
cd auto_tests
python -m pytest tests/test_thoxos_integration.py -q
```

The suite pins the catalog entry, the GRUB icon, the brand payload, the palette,
the ISO provenance record, the ISO-builder staging, the additive target hook
ordering, `bash -n` validity of the layer scripts, and — by executing the real
branding pass against a real Ubuntu `os-release` — that branding never changes
the distribution identity.

## Refreshing the brand layer

The layer is a copy of owner-supplied assets. Replace files in `assets/thoxos/`
from the ThoxOS brand library and the ThoxOS Desk repository, then re-run the
suite. Do not redraw or recolour the marks: use the supplied lockups, keep their
proportions, and keep the OFL notice with the font copies.
