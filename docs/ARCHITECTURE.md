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
   only the transaction-owned staging partition, extracts Mint, configures the target, installs the
   firmware-specific bootloader, and verifies the final system.
4. The installed system boots through GRUB and applies the optional sharing policy recorded in the
   plan.

## Installation plan

The plan is immutable after publication. It records:

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

## Distribution catalogue trust

The production distribution catalogue is authenticated independently of the filepool. Libertix
verifies `distros.json.sig` with the RSA public key bundled in the executable before trusting any
download URL or checksum. The signing key remains offline; maintainers create the detached
signature with `iso-tools/sign-distribution-catalog.sh` and publish both files atomically. An
explicit development filepool override skips this production trust check so isolated auto-tests
can publish per-build ISO hashes.

## Installation state

The persisted state follows the ordered stage catalogue in `assets/live/libertix-stages.tsv`. Only
the next required stage may start, an installation can succeed only after every required stage has
completed, and rollback records compensation separately for every completed compensable stage.
Atomic publication ensures that readers see either the previous complete state or the next complete
state.

## Recovery and rollback

Recovery is armed before the first mutating operation. Each rollback action must prove that its
target belongs to the current transaction by matching recorded disk identity and exact partition
geometry. A successful rollback requires all of the following:

- every completed compensable stage is marked compensated;
- the temporary partition and boot entries are absent;
- original Windows and Recovery geometry is restored;
- BIOS boot code or UEFI firmware and ESP state is restored;
- BitLocker, hibernation, and recovery settings match their captured values.

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
