# Recovery cleanup (developer tool)

`Clear-LibertixRecovery.ps1` removes managed Windows installation data **after a
verified rollback**. It is not an uninstaller, a rollback implementation, or a
way to bypass a failed installation check. Do not use it unless you understand
the recovery records and have reviewed the preview. Deleted logs and backups
cannot be recovered by Libertix.

Run from a complete, trusted source checkout, outside the directories listed
below, using **64-bit Windows PowerShell 5.1 as administrator**. The script imports
the checkout's validators, never executable code from the old recovery archive.
Close Libertix first. Do not run an installer or change storage while checking or
cleaning. Save any diagnostics needed for a bug report outside the cleanup paths.

```powershell
# Read-only preview: verification plus the exact file/directory inventory.
.\maintenance\Clear-LibertixRecovery.ps1

# Exercise the deletion decision without deleting anything.
.\maintenance\Clear-LibertixRecovery.ps1 -Apply -WhatIf

# Recheck, display the inventory, ask for confirmation, then delete.
.\maintenance\Clear-LibertixRecovery.ps1 -Apply
```

## What is checked

- Every BIOS/UEFI recovery session, including archived BIOS sessions, must have
  a valid plan and execution ledger, with status `rolled-back` and all required
  compensations completed. No post-install or post-uninstall report is required.
- Current affected disks, original NTFS volume identity, every recorded
  partition's position, size, identity and attributes must match the saved
  pre-installation inventory. Unexpected partitions cause refusal. Unrelated
  disks are not modified or treated as installation targets.
- BIOS boot code is compared with its hash-checked original backup. UEFI boot
  order must match the saved order, no `BootNext` may be pending, the original
  EFI system partition must be readable without mounting it, Windows Boot
  Manager must exist, and Libertix EFI directories must be absent. If the
  preferred Windows boot path was used, its original files and firmware entry
  are checked against their archived hashes.
- No Libertix tasks or visible running processes may reference the cleanup paths.
  BCD must be readable and contain no Libertix/GRUB4DOS references. A residual
  BootGuardian service is accepted only if its executable path, LocalSystem
  account and protected configuration identify one of the verified sessions.
  It is stopped and unregistered only after confirmation, before rechecking boot
  and storage and deleting files. Other residual services cause refusal.
- Symbolic links, junctions and directory mount points in cleanup paths or their
  ancestors cause refusal. Unknown top-level product directories are refused.
- The existing Libertix permission rules check ownership and replacement rights
  for every deletion path and its parents. Being allowed to create a sibling file
  is not treated as permission to replace an existing protected item. Recovery
  evidence additionally requires protection against content modification. Unsafe
  replacement rights cause refusal; this tool never repairs permissions.
- Machine checks are repeated after confirmation; a changed inventory causes
  refusal before deletion starts.

These checks deliberately reject incomplete or old evidence. A failed installation
whose rollback completed can be cleaned even if the post-install verifier never
created its result. A missing post-install result (such as the case discussed in
issue #32) alone is not evidence of a completed rollback. Do not
create a success JSON file by hand, remove a guard, or delete the archive to
make this tool accept it. Diagnose or complete the supported recovery first.

Windows updates, firmware changes, a changed disk identity, multiple historical
sessions with different baselines, or unreadable EFI storage can also cause
refusal even when Windows boots. The tool does not guess or repair these cases.

## What is removed

Only these existing, fixed Windows locations and their enumerated contents:

- `%SystemDrive%\LibertixInstallRecovery`
- `%SystemDrive%\LibertixInstallLogs` (Windows and archived Linux diagnostics)
- `%SystemDrive%\LibertixTools`
- `%SystemDrive%\libertix-live.iso`
- `%ProgramData%\Libertix` (verified recovery sessions/history, extracted runtime,
  managed downloads, sharing payload, BootGuardian files and laboratory metadata)
- `AppData\Local\Libertix\Logs` under each registered Windows profile

The script does **not** search the computer for names containing `Libertix`.
Downloaded executables, adjacent `filepool` folders, source checkouts, manually
saved logs, logs in redirected/custom profile locations, Windows event logs and
OS history are not erased. It is a reset of managed installation/recovery data,
not a forensic eraser of every trace. It does not remove other operating systems,
drivers, user documents, partitions, firmware entries or scheduled tasks; those
must already have been handled by the normal rollback. BootGuardian is the only
residual service it can remove, after checking ownership as described above.

## Failure and limitations

There is no force/bypass option for verification. Permission errors, locked files
and disk errors stop the script and are reported; it does not change ACLs or kill
processes. Deletion is not transactional: an error during deletion can leave a
partially cleaned directory. Do not interpret this as a completed reset or
manually remove remaining recovery data without investigation.

Verification cannot prove that the machine or its administrator-owned evidence
has never been tampered with, nor that user data is identical to a disk image
from before installation. It checks the existing recovery contracts and current
storage/boot evidence. Keep independent backups.

PowerShell confirmation and `-WhatIf` follow Microsoft's
[ShouldProcess documentation](https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess).
The outer confirmation gate runs before any removal command; no recursive
deletion is used, so a newly added child is not silently included.
