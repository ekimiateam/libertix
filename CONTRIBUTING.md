# Contributing to Libertix

This document is a map, not a rulebook. Start here to find where things live and where to look
next; the documents it links to are the actual authority on each topic.

- **AI-assisted contributions** — [`AI_POLICY.md`](AI_POLICY.md)
- **The safety contract** (plan, state machine, rollback guarantees) — [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- **Build, test, and release workflow** — the [`README.md`](README.md) sections below, and
  [`auto_tests/README.md`](auto_tests/README.md) for the full VM/API test environment
- **UEFI boot ordering specifics** — [`docs/UEFI_BOOTNEXT_BOOTORDER.md`](docs/UEFI_BOOTNEXT_BOOTORDER.md)

## Repo map

Libertix spans three execution environments (Windows app, live installer, installed system — see
the architecture diagram in `README.md`), plus the tooling that builds, tests, and ships all three.

### Windows application (WPF, .NET Framework 4.8)

| Path | What it is |
|---|---|
| `Libertix.csproj`, `App.xaml(.cs)`, `MainWindow.xaml(.cs)` | Main WPF project and application shell |
| `Standalone/` | Packages `Libertix.csproj` plus `BootGuardian/` into the single distributable `Libertix.exe` built in CI and releases |
| `BootGuardian/` | A small Windows service, bundled as a project reference of the main app, that can repair boot state outside the installer's own process |
| `Installation/` | The typed installation plan, size policy, validation, and persisted state machine — the core safety contract on the Windows side. Read `docs/ARCHITECTURE.md` before touching this. |
| `Pages/` | WPF wizard pages. `ApplyChanges.Bios.cs` and `ApplyChanges.Uefi.cs` own the firmware-specific Windows-side preparation; other pages are the compatibility, distribution, sizing, sharing, and account steps |
| `Helpers/` | Cross-cutting utilities: logging, build/version info, filepool config, the compatibility preflight runner, password hashing |
| `Models/` | Plain data shared across pages (account, compatibility, distro, sharing, installation state) |
| `Controls/`, `Converters/`, `Dialogs/` | Reusable WPF controls, value converters, and dialog windows |
| `Localization.cs`, `Resources/` | Translation lookup and its source strings/images/timezone data |
| `Properties/` | Standard .NET assembly info and generated resource/settings designer files |
| `app1.manifest` | Requests administrator elevation — required for the disk and boot operations this app performs |

### Live installer and installed system

| Path | What it is |
|---|---|
| `Scripts/modules/` | Shared PowerShell: plan, state, download, storage, and rollback logic used by both firmware paths |
| `Scripts/uefi/` | PowerShell operations specific to UEFI preparation |
| `Scripts/libertix-*.ps1` | Top-level orchestration scripts invoked at each Windows-side preparation stage |
| `assets/live/` | The shared live-environment runtime (Python/shell) that runs after reboot: validation, extraction, target configuration, rollback |
| `iso/`, `iso-uefi/` | Firmware-specific boot inputs for the two live images; each has thin entry-point wrappers that select firmware mode and hand off to `assets/live/` |
| `grub/` | Libertix's custom GRUB menu renderer and template |
| `schemas/` | Versioned JSON Schema contracts for the installation plan and state — CI cross-checks these against the C#, PowerShell, and Python copies |

### Build, packaging, and release tooling

| Path | What it is |
|---|---|
| `iso-tools/` | Host-side scripts that build both mini-ISO images (via the Docker builder), render boot config, and generate/sign release metadata |
| `docker/iso-builder/` | The container the ISO builder runs in |
| `Tools/aria2` | Bundled aria2 binary used for downloads (see `THIRD_PARTY.md`) |
| `release-config.json` | Stable-channel version used by the CI identity/release jobs |

### Tests

| Path | What it is |
|---|---|
| `auto_tests/` | Python test service: API, VM automation over SSH/VNC, visual checks, regression tests. Its own README has the full setup |
| `Libertix.Tests/` | C# contract tests, run with `dotnet test` in CI |
| `PowerShell.Tests/` | Pester contract tests for the PowerShell modules |
| `docs/` | The architecture contract, release/signing process, and UEFI boot-order details referenced above |

## Workflow

- Development happens on the `dev` branch; `main` tracks stable releases.
- Sign off commits (`git commit -s`). CI flags commits without the trailer as a warning, but does
  not block on it — `AI_POLICY.md` recommends the sign-off rather than requiring it, and a human
  reviewer judges each pull request..
- The pull request template lists the AI-assistance commit-trailer convention from `AI_POLICY.md`
  (`Assisted-by:` / `Generated-by:`, never `Co-authored-by:` for a tool).
- Run the checks in `README.md`'s Tests section (`ruff`, `pytest`, ShellCheck, PSScriptAnalyzer,
  Pester, the WPF build) before opening a PR — CI runs the same commands.
