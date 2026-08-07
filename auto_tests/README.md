# Libertix auto_tests

Local FastAPI service for validating Libertix on Windows test VMs.

## Responsibilities

- serve the filepool under `/filepool`;
- copy the local working tree or the remote `dev` branch to Samba;
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
```

Protected endpoints require this header:

```text
X-API-Key: <API_ACCESS_TOKEN>
```

Stream endpoints use compact text by default. Successful checks emit one short line such as
`TEST vm1 linux.fstab OK`; failures include their full structured diagnostics and the terminal line
links to the complete on-disk log. The service creates that detailed file automatically under
`auto_tests/logs/`, so command-line clients do not need `tee` or manual redirection. Add
`?format=ndjson` for a machine-readable stream. The bundled web interface requests NDJSON
explicitly.

## Filepool

Files served by the current workflows:

```text
/filepool/distros.json
/filepool/libertix-installer-bios.iso
/filepool/libertix-installer-uefi.iso
/filepool/aria2-64.zip
```

The distribution catalogue points directly to the official Linux Mint mirror for the installer
ISO. Bind the API to an address reachable by the test VMs for the remaining filepool artifacts.
The `/filepool` routes intentionally do not require the API key because the temporary live system
must download from them without storing that secret. Run this development service only on an
isolated laboratory network or behind a firewall that limits access to the test machines. Never
expose it directly to the public Internet.

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

## Local files

`.env`, `.venv`, captures, logs, ISOs, and filepool archives are local artifacts ignored by Git.
Never copy `.env` into Samba or a source archive.
