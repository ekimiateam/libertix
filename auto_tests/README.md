# Libertix auto_tests

Local FastAPI service for validating Libertix on Windows test VMs.

## Responsibilities

- serve the filepool under `/filepool`;
- copy the local working tree, build the remote `dev` branch, or deploy the latest signed GitHub
  `dev` build to Samba;
- compile `Libertix.sln` on the configured Windows build VM;
- deploy `Libertix.exe` to the selected test VMs;
- run VNC and vision-model validation;
- boot the installed Linux system, run independent SSH checks, then reboot to Windows and repeat;
- verify a 100 MiB cross-OS file by SHA-256 and verify the Linux volume is read-only in Windows;
- restore the configured snapshots of the authorized test VMs.

## Source and build

The source of truth is `ekimiateam/libertix`, branch `dev`.

Samba paths, build hosts, VM definitions, snapshots, and credentials are configured in `.env`.
The service uses two runtime directories under the configured Samba root:

```text
<SMB_ROOT>/Libertix-source
<SMB_ROOT>/Libertix-release
```

The configured build VM requires Visual Studio Build Tools and MSBuild. The expected output is:

```text
Libertix.exe
```

## Local setup and server

Prerequisites:

- Linux host with Python 3.11 or newer and [uv](https://docs.astral.sh/uv/);
- SSH access to the laboratory host, Windows build VM, and test VMs;
- a Proxmox API token authorized only for the configured test VM IDs;
- an SMB share reachable by the host and Windows VMs;
- an OpenAI-compatible vision endpoint;
- Visual Studio 2022 Build Tools with the .NET Framework 4.8 SDK and targeting pack on the build VM;
- Docker and `flock` on the Linux host when mini-ISOs must be rebuilt.

Install the exact Python environment recorded in `uv.lock`, including the development tools:

```bash
git clone https://github.com/ekimiateam/libertix.git
cd libertix/auto_tests
cp .env.example .env
uv sync --frozen --extra dev
```

Fill every placeholder in `.env` before starting the service. The example uses documentation-only
addresses and contains no working credentials.

| Group | Variables |
|---|---|
| Linux orchestration host | `MAIN_SSH_HOST`, `MAIN_SSH_USER`, `MAIN_SSH_PASSWORD`, `SMB_ROOT` |
| Samba and Windows SSH | `SAMBA_UNC`, `SAMBA_USERNAME`, `SAMBA_PASSWORD`, `WINDOWS_SSH_PASSWORD`, `SSH_KNOWN_HOSTS` |
| Windows build VM | `BUILD_VM_HOST`, `BUILD_VM_USER`, `BUILD_VM_PASSWORD` |
| Source and release | `REPOSITORY_URL`, `REPOSITORY_BRANCH`, `SOURCE_DIR_NAME`, `RELEASE_DIR_NAME`, `FILEPOOL_BASE_URL`, `PUBLISHED_DEV_METADATA_BASE_URL` |
| Destructive-operation boundaries | `ALLOWED_SMB_ROOTS`, `ALLOWED_PROXMOX_VMIDS`, `RESET_SNAPSHOT`, `PROXMOX_STORAGE` |
| Proxmox API | `PROXMOX_URL`, `PROXMOX_TOKEN_ID`, `PROXMOX_TOKEN_SECRET`, `PROXMOX_VERIFY_TLS`, optional `PROXMOX_CA_BUNDLE` |
| Vision service | `LLM_API_URL`, `LLM_API_KEY`, `LLM_MODEL`, reasoning, timeout, and retry variables |
| Installed Linux development network | `DEVELOPMENT_STATIC_IPV4_PREFIX_LENGTH`, `DEVELOPMENT_STATIC_IPV4_GATEWAY`, `DEVELOPMENT_DNS_SERVERS` |
| Runtime paths and timing | `RUNTIME_DIR`, `CAPTURE_DIR`, SSH, VNC, command, monitor, boot, and polling timeout variables |
| Test VM inventory | `VMS`, including address, VNC, VM ID, firmware, dimensions, keyboard, and default-scope flag |

`CAPTURE_DIR` must be a strict child of `RUNTIME_DIR`. Every VM ID must occur in
`ALLOWED_PROXMOX_VMIDS`, and every destructive Samba target must remain under one of the
`ALLOWED_SMB_ROOTS` entries.

Start the API and filepool in the foreground with Python's module launcher:

```bash
uv run --frozen python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Using `python -m uvicorn` avoids console-script shebangs that can retain an obsolete absolute path
when an existing virtual environment is moved with the repository.

To keep the service running after the terminal closes:

```bash
setsid -f uv run --frozen python -m uvicorn app.main:app \
  --host 0.0.0.0 --port 8000 > api-background.log 2>&1
curl -fsS http://127.0.0.1:8000/health
```

The generated log is ignored by Git. The web interface is available at
`http://127.0.0.1:8000/`.

## API

Main endpoints:

```text
GET  /
GET  /health
GET  /api/v1/vms
POST /api/v1/validation
POST /api/v1/validation/stream
POST /api/v1/reset
POST /api/v1/reset/stream
POST /api/v1/automation
POST /api/v1/automation/stream
POST /api/v1/operation/kill
```

The API is a laboratory tool and does not require an authentication header or perform application-
level network filtering. Run it only on an isolated laboratory network or enforce access at the
host firewall because it can reset test VMs and start complete installations.

Stream endpoints use compact text by default. Successful checks emit one short line such as
`TEST vm1 linux.fstab OK`; failures include their full structured diagnostics and the terminal line
links to the complete on-disk log. The service creates that detailed file automatically under
`auto_tests/logs/`, so command-line clients do not need `tee` or manual redirection. Add
`?format=ndjson` for a machine-readable stream. The bundled web interface requests NDJSON
explicitly.

### Request models

`ValidationRequest` accepts `vms` (a selector list), `vm` (one selector), and `source`. `source` is
`local` to copy and compile the current working tree, `remote` to clone and compile
`REPOSITORY_URL` at `REPOSITORY_BRANCH`, or `published` to download the latest RSA-signed `dev`
metadata from `PUBLISHED_DEV_METADATA_BASE_URL`, verify the advertised WPF archive hash and size,
and deploy that archive without rebuilding it. In `published` mode Libertix is deliberately
launched without `--filepool-base-url`; its embedded `dev_<sha7>` version selects the published
GitHub Pages `dev` channel.

`AutomationRequest` additionally accepts:

| Field | Type and default | Meaning |
|---|---|---|
| `apply` | boolean, `false` | Click Apply and authorize a real installation. |
| `distribution` | `mint` or `zorin`, default `mint` | Select the catalogue entry; both use the same generic mini-ISOs. |
| `linux_username` | string, default `test` | Account created in the installed Linux system. |
| `linux_password` | string, required, 4-128 characters | Linux account and sudo password. |
| `monitor_iso` | boolean, `true` | Continue through installation and post-install operating-system checks. |
| `share_windows_files_in_linux` | boolean, `true` | Validate the Windows-to-Linux sharing path. |
| `share_linux_files_in_windows` | boolean, `true` | Validate the read-only Linux-to-Windows sharing path. |

VM selectors can also be repeated as query parameters (`?vm=vm1&vm=vm2`). Body and query
selectors are combined. `apply` and `source` query parameters override their body values.

### Copy-paste API commands

List the configured VMs:

```bash
curl -fsS http://127.0.0.1:8000/api/v1/vms
```

Validate the local source without installing:

```bash
curl -fsS -N -H 'Content-Type: application/json' \
  -d '{"vms":["vm1","vm2","vm3"],"source":"local"}' \
  http://127.0.0.1:8000/api/v1/validation/stream
```

Run a complete three-VM Mint installation:

```bash
curl -fsS -N -H 'Content-Type: application/json' \
  -d '{"vms":["vm1","vm2","vm3"],"apply":true,"distribution":"mint","linux_username":"test","linux_password":"replace-me","monitor_iso":true,"source":"local"}' \
  http://127.0.0.1:8000/api/v1/automation/stream
```

Run the same workflow with Zorin OS:

```bash
curl -fsS -N -H 'Content-Type: application/json' \
  -d '{"vms":["vm1","vm2","vm3"],"apply":true,"distribution":"zorin","linux_username":"test","linux_password":"replace-me","monitor_iso":true,"source":"local"}' \
  http://127.0.0.1:8000/api/v1/automation/stream
```

Run the complete Mint workflow with the latest signed GitHub `dev` build and its published
catalogue instead of the local filepool:

```bash
curl -fsS -N -H 'Content-Type: application/json' \
  -d '{"vms":["vm1","vm2","vm3"],"apply":true,"distribution":"mint","linux_username":"test","linux_password":"replace-me","monitor_iso":true,"source":"published"}' \
  http://127.0.0.1:8000/api/v1/automation/stream
```

Force-stop only the active streamed operation, leaving FastAPI running:

```bash
curl -fsS -X POST http://127.0.0.1:8000/api/v1/operation/kill
```

This stop is intentionally immediate and does not clean up an operation already running inside a
VM. It returns HTTP 409 when no streamed operation is active. A new installation should normally
start from the configured reset snapshot.

Reset the default VM scope and refresh the shared local source:

```bash
curl -fsS -N -X POST http://127.0.0.1:8000/api/v1/reset/stream
```

The non-stream endpoints return one JSON `OperationResult`. Stream endpoints default to compact
text and accept `?format=ndjson` for structured `step` and `result` events.

## Filepool

Files served by the current workflows:

```text
/filepool/catalog.json
/filepool/catalog.json.sig
/filepool/libertix-installer-bios.iso
/filepool/libertix-installer-uefi.iso
/filepool/aria2-64.zip
/filepool/ext4-win-driver.exe
/filepool/grldr
/filepool/grldr.mbr
/filepool/linux-integrity.sh
/filepool/menu.lst
```

The distribution catalogue points directly to the verified upstream mirrors for the supported
installer ISOs. Bind the API to an address reachable by the test VMs for the remaining filepool
artifacts. Every regular file placed directly in `auto_tests/app/filepool/` is served under
`/filepool/<filename>`; subdirectories and files outside that directory are not exposed. Run this
development service only on an isolated laboratory network. Never expose it directly to the public
Internet.

## Reset behavior

The global reset refreshes the configured Samba workspace and restores the authorized VMs.

Refreshing a local-source workspace replaces the bounded remote source directory with a clean copy
of the selected Git tree. The service validates that directory against `SMB_ROOT` before invoking
Git cleanup, but any untracked content inside that dedicated remote checkout is intentionally
removed. Do not point the source path at a shared or manually maintained directory.

A selective reset, for example `?vm=vm3`, restores only that VM and preserves the shared workspace.
The stream emits `reset.scope` so clients can distinguish both behaviors.

## Automation UI

The available automation targets and UI profiles come from `.env`.

`apply=false` launches Libertix and stops before applying changes.

`apply=true` authorizes the complete installation workflow.

`distribution` selects the signed catalogue id and accepts `mint` (default) or `zorin`. The same
generic BIOS and UEFI mini-ISOs are used for both choices.

With `monitor_iso=true`, automation continues past the installer: it confirms the installed GRUB
menu, boots Linux, runs the Linux checks over SSH, creates and hashes the sharing probes, selects
Windows for the next boot, and runs the Windows checks over SSH. A failed check does not skip the
remaining checks, but it makes the final operation result fail.

For full installations, the service launches Libertix with a complete development network profile:
`--dev-ssh-static-ip`, `--dev-ssh-prefix-length`, `--dev-ssh-gateway`, and one
`--dev-ssh-dns` argument per configured resolver. The address is the selected VM's Windows address;
the prefix, gateway and DNS servers come from `.env`. The installed Linux system therefore retains
the configured address and enables SSH for the account supplied in the automation request.
Production launches do not enable this behavior.

## Build and verification commands

Build and verify both generic mini-ISOs from the repository root:

```bash
./iso-tools/build-isos-docker.sh all
```

Use `bios` or `uefi` instead of `all` for one image. The builder stores its large work tree in the
Docker volume `libertix-iso-work`, writes logs under `build-logs/`, verifies the image contents, and
publishes the resulting ISO into `auto_tests/app/filepool/`.

Build the WPF application from a Visual Studio Developer PowerShell on Windows:

```powershell
msbuild .\Libertix.sln /restore /m /p:Configuration=Release "/p:Platform=Any CPU"
dotnet test .\Libertix.Tests\Libertix.Tests.csproj --configuration Release --no-build
```

The auto-test rebuilds the current source on `BUILD_VM_HOST` before deployment, so an automation
run also validates the real Windows build environment.

Run the local Python and cross-runtime contract checks:

```bash
cd auto_tests
uv run --frozen python -m ruff check app tests tools ../assets/live/*.py ../iso-tools/*.py ../grub/*.py
uv run --frozen python -m ruff format --check app tests tools ../assets/live/*.py ../iso-tools/*.py ../grub/*.py
uv run --frozen python -m pytest --cov=app --cov-report=term-missing --cov-fail-under=70
```

After changing `catalog.json`, sign and synchronize its two versioned copies and detached
signatures with the interactive tool:

```bash
./iso-tools/sign-distribution-catalog.sh
```

Or select the served catalogue explicitly:

```bash
./iso-tools/sign-distribution-catalog.sh auto_tests/app/filepool/catalog.json
```

The private key remains at the ignored local path printed by the tool. Only the public RSA key is
embedded in Libertix and versioned.

## Manual diagnostic tools

These tools are not part of the automated workflow and never run implicitly.

`force_uefi_bootnext_failure.py` exercises the configured UEFI recovery path on one test VM. It
requires a completed `.env`, Windows SSH access, and a VM on which Libertix recovery tasks are
already installed. The output file records the remote exit code and diagnostics:

```bash
uv run --frozen python tools/force_uefi_bootnext_failure.py \
  --vm vm2 \
  --timeout 900 \
  --output runtime/force-uefi-bootnext-failure.txt
```

`rank_capture_changes.py` compares consecutive PNG captures and prints the frames with the largest
visual changes. It is read-only and requires only the locked Python environment:

```bash
uv run --frozen python tools/rank_capture_changes.py runtime/captures \
  --pattern '*.png' \
  --top 20
```

## Local files

`.env`, `.venv`, captures, logs, ISOs, and filepool archives are local artifacts ignored by Git.
Never copy `.env` into Samba or a source archive.

Runtime evidence is organized as follows:

```text
auto_tests/logs/             complete operation logs
auto_tests/runtime/captures/ temporary VNC captures
auto_tests/runtime/filepool/ generated catalogue with current mini-ISO hashes
auto_tests/api-background.log optional background-server output
```

The compact API stream is the normal operator view. Read a complete log only to diagnose a failed
terminal `RESULT`, and keep generated runtime files out of commits.
