# Third-party components

This file records the upstream identity of third-party binaries and fonts distributed by the WPF
archive, the development filepool, or the mini-ISO images. SHA-256 values identify the exact
reviewed files; upstream license terms remain authoritative.

## aria2 1.37.0

- Distributed files: `aria2-64.zip` in the development filepool and `Tools/aria2/aria2c.exe` in the
  WPF archive
- Upstream release: <https://github.com/aria2/aria2/releases/tag/release-1.37.0>
- Original archive: `aria2-1.37.0-win-64bit-build1.zip`
- License: GPL-2.0-or-later; the original archive retains `COPYING` and bundled dependency notices
- Archive SHA-256: `67d015301eef0b612191212d564c5bb0a14b5b9c4796b76454276a4d28d9b288`
- Executable SHA-256: `be2099c214f63a3cb4954b09a0becd6e2e34660b886d4c898d260febfe9d70c2`

## ext4-win-driver 0.2.2

- File: `auto_tests/app/filepool/ext4-win-driver.exe`
- Upstream release: <https://github.com/antimatter-studios/ext4-win-driver/releases/tag/v0.2.2>
- Original asset: `ext4-win-driver-0.2.2-x64-Setup.exe`
- License: GPL-3.0
- SHA-256: `967a001e6bd80de0af44b085c73097a96ea4ab0f5dd4d766cca4959231891031`

## GRUB4DOS 0.4.4

- Files: `auto_tests/app/filepool/grldr`, `auto_tests/app/filepool/grldr.mbr`
- Upstream repository: <https://github.com/chenall/grub4dos>
- Version evidence: `grldr` embeds `GRUB4DOS 0.4.4 2009-03-31`
- License: GPL-2.0
- `grldr` SHA-256: `124988a6091248111f5d372ad210f21250a42cfd05d9d6366be28347b6368675`
- `grldr.mbr` SHA-256: `53fce0d82a09531b1a7af728e712a957db3966835304e8bdae5e350220270b33`

## Debian-signed shim 16.1

- Files: `iso-uefi/assets/debian-dual-signed/shimx64.efi.signed`,
  `iso-uefi/assets/debian-dual-signed/mmx64.efi.signed`, and
  `iso-uefi/assets/debian-dual-signed/fbx64.efi.signed`
- Upstream source package: <https://packages.debian.org/source/trixie/shim-signed>
- Upstream shim: <https://github.com/rhboot/shim>
- Version evidence: the binaries embed Debian shim SBAT metadata for version `16.1`
- License and notices: see the upstream shim `COPYRIGHT` file and Debian source-package copyright
- `shimx64.efi.signed` SHA-256:
  `637d7916c0b0b9cb505612f39e8c47b47894957f15a1e711b22a2ae5bbec286d`
- `mmx64.efi.signed` SHA-256:
  `3480a42892865d356a15759cb2271bfeb009d5687c153896d3983c354cd2d949`
- `fbx64.efi.signed` SHA-256:
  `4de1fa2de3099c47650704cb31546c3fbb1e1b339dd36e83a3a92888ad0546b2`

## Terminus TTF

- File: `assets/grub-theme/Terminus.ttf`
- Upstream: <https://files.ax86.net/terminus-ttf/>
- License: SIL Open Font License 1.1, following the upstream Terminus Font license
- SHA-256: `e42051ff7083331c4c9c2fb7df393da534c908ff54b446167360630d5e52af2f`
- `Terminus_16.pf2` and `Terminus_24.pf2` are generated GRUB font forms kept for the static theme;
  the ISO build also generates its runtime sizes from `Terminus.ttf`.

## MingCute Icons 3.1.0

- Files: `assets/grub-theme/icons/source/mingcute/*.svg` (unmodified sources) and the derived
  `shutdown.png`, `efi.png`, `submenu.png`, `recovery-mode.png`, `memtest.png` and `firmware.png`
  in `assets/grub-theme/icons`
- Upstream: <https://github.com/mingcute-design/mingcute-icons>, tag `v3.1.0`, commit
  `ef58b7d49487627a1e55b14eca8f0bf5586516f5`, Core Filled style
- License: Apache-2.0; `assets/grub-theme/icons/source/LICENSE.MingCute.txt` is shipped with the
  theme source and copied into each generated theme
- Modifications: recoloured and placed on a 48 px badge; the original file names, the conversion
  command and the per-icon mapping are in `assets/grub-theme/icons/source/README.md`
- Source SVG SHA-256:
  - `power.svg`: `debb19d9773e8c4f7db98f2b1ab351ba49ee11a5cd3b2e93041dc71703f04729`
  - `settings_5.svg`: `8c086f8079cfe97e62e7be6005f11efef181bc8f9b1f7f43c02d5e59af55f590`
  - `list_expansion.svg`: `56785d6d75ce1d2800503880b24ca451ccc2b100643360900d934f2b1a4f447c`
  - `first_aid_kit.svg`: `c78db5460cd34de808b55d2640680aabbeb250d5f231c601243a3808271bfe02`
  - `memory_stick.svg`: `db389a01413e42a1fead3def5bf26d2fe69658d93f12926fa1a671c0f5bf5da0`
  - `chip.svg`: `34605716cbb023ed068db9f982e1bb47269dd8d37be713f728aab80b4bb92eb8`

The remaining GRUB theme layout and artwork under `assets/grub-theme` are maintained as Libertix
project assets. They are not represented here as upstream binaries.
