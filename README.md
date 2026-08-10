# Libertix

Libertix is a Windows application that installs a supported Debian/Ubuntu-family desktop system
alongside an existing Windows system. It handles the Windows-side preparation, boots a
purpose-built live environment, installs the selected distribution and configures a dual-boot menu
for either BIOS/MBR or UEFI/GPT machines.

> [!WARNING]
> Libertix modifies disk partitions and boot configuration. Back up important data before using it.
> The compatibility checks deliberately reject layouts that cannot be handled safely.

## Architecture overview

Libertix is split into three execution environments: the Windows application prepares the machine,
a small live system performs the Linux installation, and the installed system receives the final
boot and sharing configuration. BIOS and UEFI use separate boot adapters, while the safety rules,
installation plan, state tracking and most live operations are shared.

The authoritative lifecycle, state, and rollback guarantees are documented in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

```mermaid
flowchart TB
    subgraph Windows["Windows application"]
        Startup["Startup options and filepool configuration"]
        Wizard["WPF wizard<br/>compatibility, distribution, size, sharing and account"]
        Preflight["Compatibility preflight<br/>firmware, storage, BitLocker and shrinkable space"]
        Plan["Typed installation plan<br/>disk identity, partitions, hashes, locale and features"]
        State["Persisted state machine<br/>completed stages, failure and rollback state"]
        BiosPrep["Windows BIOS preparation<br/>recovery guard, shrink, staging, media and GRUB4DOS"]
        UefiPrep["Windows UEFI preparation<br/>recovery guard, shrink, staging, EFI media and firmware boot"]
    end

    Filepool["Filepool<br/>distribution ISO, Libertix ISO, boot files and verified hashes"]

    subgraph Images["Versioned live images"]
        BiosImage["BIOS live ISO"]
        UefiImage["UEFI live ISO"]
        LivePlan["Plan and hardware revalidation"]
        SharedRuntime["Shared live runtime<br/>translations, progress, storage and rollback"]
        FirmwareAdapters["Firmware adapters<br/>BIOS disk boot or UEFI firmware boot"]
        Installer["Linux installation<br/>inspect ISO, expand staging, ext4, extract and configure target"]
    end

    subgraph Installed["Installed dual-boot system"]
        Linux["Selected Linux system<br/>locale, keyboard, account and desktop"]
        Grub["Final GRUB menu<br/>Linux, Windows, shutdown and advanced options"]
        Sharing["Optional file sharing<br/>Windows folders in Linux and read-only Linux files in Windows"]
    end

    Recovery["Verified recovery path<br/>cancel, compensate completed stages and restore Windows boot"]
    Tests["Automated validation<br/>Python API, SSH, VNC and visual checks on test VMs"]
    CI["Continuous integration<br/>quality checks, WPF build and full ISO builds"]

    Startup --> Wizard
    Wizard --> Preflight
    Preflight --> Plan
    Plan --> State
    Plan --> BiosPrep
    Plan --> UefiPrep
    Filepool --> BiosPrep
    Filepool --> UefiPrep

    BiosPrep --> BiosImage
    UefiPrep --> UefiImage
    BiosImage --> LivePlan
    UefiImage --> LivePlan
    LivePlan --> SharedRuntime
    SharedRuntime --> FirmwareAdapters
    FirmwareAdapters --> Installer
    Filepool --> Installer

    Installer --> Linux
    Installer --> Grub
    Installer --> Sharing
    State --> Recovery
    SharedRuntime --> Recovery

    Tests -.-> Windows
    Tests -.-> Images
    Tests -.-> Installed
    CI -.-> Windows
    CI -.-> Images

    classDef windows fill:#dbeafe,stroke:#60a5fa,color:#111827,stroke-width:1.5px
    classDef live fill:#dcfce7,stroke:#4ade80,color:#111827,stroke-width:1.5px
    classDef target fill:#fef3c7,stroke:#fbbf24,color:#111827,stroke-width:1.5px
    classDef support fill:#f3e8ff,stroke:#c084fc,color:#111827,stroke-width:1.5px
    classDef external fill:#f1f5f9,stroke:#94a3b8,color:#111827,stroke-width:1.5px

    class Startup,Wizard,Preflight,Plan,State,BiosPrep,UefiPrep windows
    class BiosImage,UefiImage,LivePlan,SharedRuntime,FirmwareAdapters,Installer live
    class Linux,Grub,Sharing target
    class Recovery,Tests,CI support
    class Filepool external
```

### Main responsibilities

- `Libertix.exe` owns user interaction, compatibility checks and the initial Windows-side
  preparation. It produces one validated installation plan instead of letting each firmware path
  calculate its own disk values.
- `Installation/` contains the typed plan, size policy, validation and persisted state machine used
  to keep BIOS and UEFI behavior consistent.
- `Pages/ApplyChanges.Bios.cs` owns the complete Windows-side BIOS preparation: recovery guard,
  hibernation policy, shrink validation, FAT32 staging, live and distribution media, GRUB4DOS and
  the temporary BCD boot sequence.
- `Pages/ApplyChanges.Uefi.cs`, `Scripts/modules/` and `Scripts/uefi/` own the Windows-side UEFI
  preparation. The C# layer starts and observes the operation; the PowerShell modules implement
  staging, EFI media, firmware variables, transaction state and Windows-side rollback.
- `assets/live/` contains the shared live orchestrator and the small BIOS/UEFI adapters used after
  reboot. `iso/live/libertix-install.sh`, `iso/live/libertix-runner.sh` and their `iso-uefi/live/`
  counterparts are the actual image entry points; each is a thin wrapper that selects the firmware
  mode and executes the shared implementation.
- `iso/` and `iso-uefi/` contain the remaining firmware-specific boot inputs used to construct the
  two distinct live images.
- The recovery path reads the persisted state and compensates only operations that were completed;
  it then verifies the disk and boot state before reporting a successful rollback.
- `auto_tests/` builds and deploys the current working tree, controls the three authorized test VMs
  through SSH and VNC, and records visual and command-level evidence.

## Supported configuration

- Windows 10 or Windows 11, 64-bit
- BIOS with an MBR disk, or UEFI with a GPT disk
- .NET Framework 4.8
- Administrator privileges
- Linux Mint 22.3 Cinnamon or Zorin OS 18.1 Core
- At least 20 GiB of shrinkable space on the Windows system disk
- A storage layout accepted by the compatibility preflight

Libertix supports common local SATA/AHCI and NVMe system disks. It refuses ambiguous or unsafe
topologies such as Windows dynamic disks, Storage Spaces, USB system disks, VHD/iSCSI system disks,
unsupported RAID controllers and unsupported Intel RST/VMD or AMD RAID configurations.

BitLocker or Device Encryption must be fully decrypted before the live installer boots. Libertix
can request decryption and waits for it to finish. The detected Windows Recovery partition is kept
outside the Linux allocation and is checked again before the live environment writes to disk.

## Optional file sharing

The installer can expose Windows user folders in Linux and Linux user files in Windows. Linux files
are mounted read-only on Windows. Both directions are optional and selected before installation.

## Runtime configuration

The production executable uses this filepool by default:

```text
https://ekimia.fr/libertix
```

Reusing local ISO files does not remove the catalogue requirement. With the production filepool,
Libertix first downloads `distros.json` and its detached signature, verifies that signature, and
only then looks beside `Libertix.exe` for the exact filenames selected by the catalogue. A matching
local file is used after its SHA-256 is verified; otherwise Libertix downloads the artifact from the
configured URL. A laboratory machine without Internet access therefore needs an accessible local
HTTP filepool containing the catalogue and every artifact that is not beside the executable.

Development and test runs can override it for one process without changing the production default:

```powershell
.\Libertix.exe --filepool-base-url "http://127.0.0.1:8000/filepool"
```

The override must be an absolute HTTP or HTTPS URL without embedded credentials, query parameters or
fragments. It is an explicit development mode and does not require the production catalogue
signature; it must not be used to trust an unverified third-party server.

Automated development installations also use an explicit static-address option:

```powershell
.\Libertix.exe --filepool-base-url "http://192.0.2.10:8000/filepool" `
  --dev-ssh-static-ip "192.0.2.50" `
  --dev-ssh-prefix-length 24 `
  --dev-ssh-gateway "192.0.2.1" `
  --dev-ssh-dns "9.9.9.9" `
  --dev-ssh-dns "1.1.1.1"
```

These development options are intentionally absent from production launches. They configure the
installed system with the supplied IPv4 profile, then install and enable password SSH for the Linux
account created by Libertix. The address, prefix, gateway and at least one DNS server form one
mandatory profile; providing only part of it is rejected. Repeat `--dev-ssh-dns` to configure more
than one resolver. Libertix rejects network, broadcast, loopback, multicast and link-local addresses,
prefixes outside `/1` through `/30`, and gateways outside the selected subnet.

On UEFI systems the compatibility preflight normally verifies firmware support by writing, reading
and restoring `BootNext` itself. Diagnostic environments that cannot permit this write can
explicitly use `--skip-nvram-write-probe`. The preflight records the probe as skipped and warns that
`BootNext` support is unproven; it never reports the skipped probe as successful. This option
reduces compatibility assurance and is not intended for normal installations.

## Build the Windows application

Libertix targets WPF on .NET Framework 4.8. A complete build requires Visual Studio 2022 Build Tools
with the managed desktop workload, the .NET Framework 4.8 SDK and the .NET Framework 4.8 targeting
pack.

From a Developer PowerShell prompt:

```powershell
msbuild .\Libertix.sln /restore /m /p:Configuration=Release "/p:Platform=Any CPU"
```

The executable is written to `bin\Release\Libertix.exe`.

## Build the live ISO images

The BIOS and UEFI ISO images are rebuilt completely from versioned sources with the Docker builder.
The process does not repack an existing ISO and does not require `sudo` on the host.

```bash
./iso-tools/build-isos-docker.sh all
```

Build a single firmware variant with `bios` or `uefi` instead of `all`. Successful builds produce:

```text
libertix-installer-bios.iso
libertix-installer-uefi.iso
```

The builder verifies the embedded scripts, schemas, boot configuration, theme and required runtime
tools before accepting either image.

Version, origin, license and SHA-256 information for binaries and fonts stored in the repository is
recorded in [THIRD_PARTY.md](THIRD_PARTY.md).

## Tests

The automated test service is located in `auto_tests`. Its runtime configuration is loaded from a
local `.env` file; `auto_tests/.env.example` documents the required fields.
The complete developer environment, API reference, build workflow, and copy-paste Mint/Zorin
commands are documented in [`auto_tests/README.md`](auto_tests/README.md).

```bash
cd auto_tests
uv sync --frozen --extra dev
uv run --frozen python -m ruff check app tests tools ../assets/live/*.py ../iso-tools/*.py ../grub/*.py
uv run --frozen python -m ruff format --check app tests tools ../assets/live/*.py ../iso-tools/*.py ../grub/*.py
uv run --frozen python -m pytest --cov=app --cov-report=term-missing --cov-fail-under=70
```

The GitHub Actions workflow also validates Shell syntax, runs ShellCheck, analyzes PowerShell with
PSScriptAnalyzer, runs the Pester contract suite, builds `Libertix.exe` on Windows and builds both
ISO images on trusted `dev` branch runs. Successful workflow runs publish the WPF build and the
verified ISO images as GitHub Actions artifacts. Dev prereleases include the WPF archive, both ISO
images and a `SHA256SUMS` file. The WPF archive contains `BUILD-INFO.txt`, `LICENSE` and
`THIRD_PARTY.md`; the executable informational version records the complete source revision.

## Source layout

- `Installation/` — typed installation plan, validation, size policy and persisted state machine
- `Pages/ApplyChanges.*.cs` — Windows orchestration, including the complete BIOS preparation and
  the C# control layer for the PowerShell UEFI workflow
- `Scripts/modules/` — shared PowerShell plan, state, download, storage and rollback functions
- `Scripts/uefi/` — operations that are specific to UEFI preparation
- `assets/live/` — shared live installer, runner, target configuration and firmware adapters
- `iso/` and `iso-uefi/` — firmware-specific boot inputs and thin live entry wrappers
- `schemas/` — versioned JSON contracts for the plan and execution state
- `auto_tests/` — API, VM automation, visual checks and regression tests

Additional UEFI boot details are documented in
[`docs/UEFI_BOOTNEXT_BOOTORDER.md`](docs/UEFI_BOOTNEXT_BOOTORDER.md).

## Community and acknowledgements

Libertix is developed by Félix ([felix068](https://github.com/felix068)) and Ekimia, with
contributions from Michel Memeteau, MopigamesYT / Margot and Aamir Shahzad. Thank you to everyone
who has contributed code, tests, issue reports and documentation.

The project has also been made possible by its donors. Public supporters of the Libertix campaign
include **Olivier**, **Boyka**, **Coin des Geeks** and **Matthieu**. The campaign exceeded its
€3,000 goal through 41 donations. We are grateful to every donor, including those who chose to
remain anonymous.

To help fund continued development and testing, visit the
[Libertix donation campaign](https://ekimia.fr/donations/campagne-libertix/).

## Contributing

Development takes place on the `dev` branch. Keep firmware-neutral behavior in the shared plan and
runtime modules, and limit BIOS/UEFI adapters to operations that genuinely differ. Changes to disk
or rollback behavior should include parity tests for both firmware paths and a replay of the
relevant failure scenario where possible.

The separate [development and auto-test guide](auto_tests/README.md) documents the locked `uv`
environment, Windows and mini-ISO builds, filepool, API, `curl` workflows, VM automation, and local
verification commands.

## License

Libertix is distributed under the GNU General Public License v3.0. See [`LICENSE`](LICENSE).

## Acknowledgments

- [Rose Pine](https://rosepinetheme.com/) for the application color palette
- [WPF](https://github.com/dotnet/wpf) for the Windows desktop framework
