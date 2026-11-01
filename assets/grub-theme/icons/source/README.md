# Functional GRUB menu icons

Six icons in `assets/grub-theme/icons` are rendered from MingCute Icons. The distribution and
Windows logos in the same directory are not part of this set.

| PNG (GRUB class) | Menu entry | MingCute Core Filled source | Original path in the repository |
|---|---|---|---|
| `shutdown.png` | Shutdown | `power.svg` | `assets/svg/core/filled/system/power.svg` |
| `efi.png` | Advanced options | `settings_5.svg` | `assets/svg/core/filled/system/settings_5.svg` |
| `submenu.png` | The distribution's advanced submenu | `list_expansion.svg` | `assets/svg/core/filled/editing/list_expansion.svg` |
| `recovery-mode.png` | Recovery mode kernel entries | `first_aid_kit.svg` | `assets/svg/core/filled/miscellaneous/first_aid_kit.svg` |
| `memtest.png` | memtest86+ | `memory_stick.svg` | `assets/svg/core/filled/devices/memory_stick.svg` |
| `firmware.png` | UEFI firmware settings | `chip.svg` | `assets/svg/core/filled/devices/chip.svg` |

## Source

- Repository: <https://github.com/mingcute-design/mingcute-icons> (previously
  `Richard9394/MingCute`)
- Release: `v3.1.0`, commit `ef58b7d49487627a1e55b14eca8f0bf5586516f5`
- License: Apache License 2.0, copied unchanged as `LICENSE.MingCute.txt`. The repository states
  that MingCute Icons is licensed under Apache-2.0 and keeps the commercial MingCute Pro styles out
  of the public repository. It has no NOTICE file.
- The files in `mingcute/` are the original SVGs, unmodified.

## Modifications

The PNGs are derived works. `render-functional-icons.sh` places each glyph, scaled from 24 to
28 px, on a 48 px circle in Rosé Pine Moon overlay `#393552`, fills it with Rosé Pine Moon text
`#e0def4`, and rasterizes it with `rsvg-convert` to a 48x48 RGBA PNG. The output was checked to be
byte-identical across runs with rsvg-convert 2.58.0 from Ubuntu 24.04.

```bash
assets/grub-theme/icons/source/render-functional-icons.sh
```

`generate-theme.sh` copies `LICENSE.MingCute.txt` into each generated theme next to the icons.
