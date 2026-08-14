# UEFI BootNext and BootOrder

## Summary

UEFI stores each boot entry in a `Boot####` NVRAM variable. `BootOrder` is the persistent list of
entries the firmware tries in order. `BootNext` is a one-shot variable: when present, the firmware
tries that entry on the next boot only and deletes the variable before launching the loader.

Primary sources:
- UEFI Specification 2.10, Boot Manager : https://uefi.org/specs/UEFI/2.10/03_Boot_Manager.html
- efibootmgr README : https://github.com/dell/efibootmgr/blob/master/README
- efibootmgr manpage Debian : https://manpages.debian.org/unstable/efibootmgr/efibootmgr.8.en.html
- Microsoft BCD UEFI settings : https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/bcd-system-store-settings-for-uefi

## BootNext

`BootNext` provides a temporary boot selection. On Linux, `efibootmgr -n XXXX` writes this variable.
On the next reboot, the firmware tries `BootXXXX` and then normally returns to `BootOrder`. This
avoids changing the persistent boot order.

Practical limitations:

- Some firmware mishandles or clears NVRAM writes.
- An EFI path accepted by one firmware can fail on another.
- Windows and some firmware can resynchronize or remove firmware entries.
- Secure Boot can reject a loader even when its UEFI entry exists.

## BootOrder

`BootOrder` is persistent: placing an entry first makes the firmware try it first on every boot while
that order remains in place. This is more reliable on firmware that ignores or loses `BootNext`, but
it is also more intrusive because it changes durable machine state.

## Libertix behavior

The first attempt uses `BootNext` with a native firmware entry targeting the temporary
`EFI\LibertixInstaller\BOOTX64.EFI` loader on the Windows ESP. Before rebooting, Libertix reads back
the `Boot####` entry, loader path, EFI file hashes, and `BootNext` value.

If Windows returns without the live marker, the recovery guard launches a verified local Libertix
copy and asks whether the user wants the validated fallback: a firmware entry created through BCD
and placed temporarily at the start of `BootOrder`. Windows Boot Manager does not directly
chainload the live system. The live installer removes its BCD and EFI artifacts before changing the
disk, and `-Revert` restores the saved firmware order, ESP files, and temporary partition.

Disk-imaging systems can restore the ESP without recreating motherboard NVRAM entries.
The installed-system phase therefore matches both Windows and Libertix entries against the current
ESP partition number, GPT partition GUID, and EFI loader path. A same-named entry that targets an
old cloned ESP is never reused. If the canonical Windows entry is absent, Libertix adds one for the
verified `EFI\Microsoft\Boot\bootmgfw.efi` file without removing generic or OEM entries. It then
creates or reuses the exact current-ESP Libertix entry and reads `BootOrder` back before success.

On the first installed-system boot, the verifier decodes the binary `BootCurrent` load option and
requires its boot number, GPT ESP identity, and loader path to match the durable ownership marker.
If firmware bypasses the entry and boots Windows directly, Windows cannot accept the installation
as successful and offers the existing verified rollback path.
