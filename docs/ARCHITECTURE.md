# Libertix architecture contract

This document defines the safety contract shared by the Windows application, PowerShell
preparation, the live installer, the installed system, and rollback. The JSON schemas in
`schemas/` remain the machine-readable authority for persisted documents.

## Execution environments

1. `Libertix.exe` performs compatibility checks, gathers user choices, resolves verified download
   metadata, and publishes the installation plan before any disk mutation.
2. The Windows BIOS or UEFI preparation path revalidates the plan, arms recovery, shrinks Windows,
   creates the staging partition, copies verified media, and selects the live environment for the
   next boot.
3. The live installer validates both the plan and current hardware again. It expands or reformats
   only the transaction-owned staging partition, discovers and extracts the selected distribution,
   configures the target, installs the firmware-specific bootloader, and verifies the final system.
4. The installed system boots through GRUB and applies the optional sharing policy recorded in the
   plan.

## Installation plan

The plan is atomically published before disk mutation. User choices, original disk geometry,
artifact identity, sizing policy, locale, account, sharing, and development-network settings do not
change after publication. Two runtime-resolved fields may be updated atomically after they become
known: the observed staging-partition identity after creation, and a validated UEFI boot-strategy
fallback. Every writer revalidates the complete document before replacing the previous version.
The plan records:

- disk identity, size, sector size, and partition style;
- original Windows and Recovery geometry;
- transaction-owned staging offset and observed size;
- requested final Linux size;
- hashes and URLs for every downloaded artifact;
- locale, keyboard, time zone, account, sharing, and development-network choices;
- recovery identity and paths needed to prove transaction ownership.

Every runtime rejects missing, unknown, malformed, or contradictory data before using it. JSON
Schema owns the document shape and portable constraints. Runtime validators add only semantic
invariants that JSON Schema cannot express safely, such as firmware/layout parity, ordered disk
geometry, and the staging-size policy. CI compares the C# model and PowerShell property sets with
the schema so a contract change cannot update only one runtime. The live environment additionally
compares the recorded disk identity and geometry with the hardware it booted from. Policy sizes use
GiB units; observed partition geometry remains byte-exact so alignment does not weaken ownership
checks.

`InstallationPlanFactory` owns conversion from validated Windows inputs to the persisted plan.
`InstallationExecutionLedger` owns state-machine transitions, atomic persistence, live mirroring,
and rollback completion. The WPF installation page orchestrates those services but does not
implement their contracts.

All Windows paths recorded in a plan must use the same drive as `disk.systemDrive`. The live maps
that validated drive to the Windows partition identified by disk geometry; it never assumes that
Windows is installed as `C:`. Plan and state handoff files are staged, flushed, hash-checked, and
replaced in their destination directory before the staging volume is hidden from Windows.

## Distribution catalogue and release trust

CI generates the artifact and distribution catalogue from `release-config.json` after both mini-ISO
images have been built. It combines maintainer-supplied hashes for external distribution images
with hashes it calculates for WPF, the two mini-ISO images and every support file. CI signs both
`catalog.json` and `releases.json` with
the RSA private key stored in the `LIBERTIX_SIGNING_PRIVATE_KEY` Actions secret. The matching public
key is bundled in the executable; the private key is never embedded in an application or artifact.

The `dev` and `main` channels are physically separated under GitHub Pages. Both channels require a
valid catalogue signature. Stable builds additionally verify the signed main release metadata and
block an obsolete executable before the installer UI starts. Development builds skip the version
freshness check so an older commit-specific build remains usable. An explicit command-line filepool
override is reserved for isolated laboratory runs and is the only mode that disables signature
verification.

The catalogue is fetched before local ISO reuse is considered. Local ISO files reduce artifact
downloads but do not provide a standalone disconnected mode. An isolated laboratory must expose a
local HTTP filepool for the catalogue and any artifact that is not already beside the executable.

## Installation state

The persisted state follows one ordered step catalogue that each runtime restates: `OrderedSteps` in
`Installation/InstallationStateMachine.cs`, `Scripts/modules/Libertix.InstallationState.psm1` and
`assets/live/libertix-installation-state.py`, plus the reversed compensation order in
`assets/live/libertix-rollback-common.sh`. CI compares all four copies, so a step cannot be renamed,
reordered or forgotten in a single runtime. Only the next required step may start, an installation
can succeed only after every required step has completed, and rollback records compensation
separately for every completed compensable step. Atomic publication ensures that readers see either
the previous complete state or the next complete state.

The live keeps its working copy under `/run`, but every accepted transition is also mirrored
atomically to the transaction recovery directory on the Windows volume. Windows recovery accepts
terminal marker files only when the validated mirrored state belongs to the same plan and has the
corresponding terminal status. Marker files are diagnostic signals, not standalone proof.

`assets/live/libertix-stages.tsv` is a separate, presentation-only catalogue: it maps the live
progress markers to translated labels and percentages for the installer screens. It carries no
authority over the persisted state.

## Recovery and rollback

Recovery is armed before the first mutating operation. Each rollback action must prove that its
target belongs to the current transaction by matching recorded disk identity and exact partition
geometry. A successful rollback requires all of the following:

- every completed compensable stage is marked compensated;
- the temporary partition and boot entries are absent;
- original Windows and Recovery geometry is restored;
- BIOS boot code or UEFI firmware and ESP state is restored;
- hibernation and recovery settings match their captured values.

BitLocker is verified separately against its captured state. Decryption that has already continued
or completed cannot be reversed safely by the installer on every supported Windows edition. A
mismatch therefore prevents Libertix from reporting a fully verified rollback and the application
instructs the user to re-enable protection; it is never hidden behind a successful rollback result.

Logging is diagnostic evidence, not a success signal. Failure to copy logs cannot turn a completed
installation into a rollback request, and best-effort cleanup cannot be reported as verified
rollback.

## Firmware boundaries

The shared live runtime owns validation, extraction, target configuration, state transitions, and
rollback orchestration. Firmware adapters own only these differences:

- BIOS: MBR layout normalization, boot code, GRUB4DOS cleanup, and BIOS GRUB installation.
- UEFI: ESP access, signed loader placement, firmware entries, `BootNext`/`BootOrder`, and UEFI GRUB
  installation.

Both ISO entry points are intentionally thin wrappers that select a firmware mode and execute the
same shared runtime.

## Validation layers

- Static validation checks JSON schemas, language parity, shell syntax and warnings, PowerShell,
  Python, and C# contracts.
- Build validation compiles the WPF application and reconstructs both ISO images from versioned
  sources.
- Runtime validation installs on BIOS/Windows 10, UEFI/Windows 10, and UEFI/Windows 11 test systems.
  It verifies exact geometry, both sharing directions, Linux and Windows integrity, a Windows boot,
  and the subsequent return to Linux.

The runtime test service is laboratory tooling. Its private topology and credentials belong only in
the ignored local environment file and runtime `.env`.
