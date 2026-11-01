# Libertix Install Party

The kit downloads and verifies the official installation files once, then serves them over the LAN
to consenting Libertix clients. It includes both firmware installer images, support files, and the
Mint and Zorin ISO images listed in the signed catalog. It is not an operating-system update mirror.

Use the [Docker instructions](Docker/README.md) on Linux or the [Windows instructions](Windows/README.md).
Both packages use the same C# server. No compiled executable belongs in Git.

## Server operation

Open **http://127.0.0.1:18080/** on the server itself. The page and its APIs are inaccessible from
other computers, even on the LAN.
It shows update/download progress, server addresses, errors and active transfers (not an inventory
of every computer on the network). The console only reports startup, update results and errors.

Settings select `main` (default) or `dev`, the HTTP port and an absolute storage directory. Saved
settings apply on the next server restart, so saving them never interrupts an active transfer.
Changing storage does not move or delete the old directory. In Docker, choose a path inside the
persistent volume, or provide another persistent mount before changing it.

At startup, and when **Check for updates** is pressed, the server:

1. Downloads `catalog.json` and its signature from the selected official GitHub Pages channel.
2. Verifies the signature using Libertix's bundled public key.
3. Checks cached file sizes and SHA-256 hashes, and downloads missing/changed artifacts from the
   URLs in that catalog, including the official Mint and Zorin download servers.
4. Publishes only complete, verified files. A failed update preserves the previous verified set.
5. Retires obsolete files only from its own `libertix-managed` directory, after active readers finish.

The directory is exclusively owned by one kit process. Do not edit its contents while it runs.
Partial downloads are not served. After interruption, unfinished files are downloaded again; valid
cached artifacts are verified and reused. No deletion is performed outside managed storage.

## Discovery and client trust

Discovery uses fixed **UDP 18081**. The HTTP port (default **18080**) is advertised in the reply.
The server is advertised only once its complete catalog is ready. Discovery requires a common IPv4
broadcast network, working firewall rules and Wi-Fi client isolation disabled. It does not cross
routers/VLANs automatically. A matching channel is mandatory: stable Libertix only proposes `main`,
and a `dev_<sha>` build only proposes `dev`.

Libertix first proposes an adjacent `filepool` folder. If that folder is absent or refused, it searches
briefly for servers. Every proposed server requires consent; several replies are presented one by one
with their address. Refusing all servers keeps official downloads. Explicit development auto-test
filepool overrides retain their existing behavior and do not invoke discovery.

The client still retrieves the **official catalog and signature from GitHub Pages** and checks the
signature itself. The local server is not a trust authority. Stable version checks also retain their
official signed metadata source. Internet access remains necessary for those checks.

When a server is accepted, installation artifact requests are confined to that HTTP IP and port,
including BIOS and UEFI helpers. HTTP redirects are rejected, and failures do not silently fall back
to an Internet artifact source. Previously verified local/cached files may still be reused. External
distribution illustrations are not fetched in this mode because the catalog gives them no hash.
Every downloaded artifact remains subject to the normal integrity checks before use.

The server uses plain HTTP on the LAN. File integrity does not depend on the transport: Libertix
verifies every artifact against the official signed catalog and its SHA-256 hashes before use.

## Without a server: an adjacent filepool folder

This existing mode remains supported on both stable and development builds. No Docker, server,
discovery or open port is needed:

```text
Libertix.exe
filepool/
  catalog.json
  catalog.json.sig
  Libertix-<version-or-commit>.zip
  libertix-installer-bios.iso
  libertix-installer-uefi.iso
  aria2-64.zip
  ext4-win-driver.exe
  grldr
  grldr.mbr
  mint.iso
  zorin.iso
```

Use the **same signed catalog** as the executable's channel. Every artifact it names is required,
except the distribution ISOs (`mint.iso`, `zorin.iso`): each one is optional, and a missing one is
downloaded from its official URL when that distribution is chosen. The list above illustrates the
current names; the catalog is authoritative for names, URLs, hashes and sizes.

To create or complete the folder, run one of these scripts on a computer with a fast Internet
connection. They download the signed catalog, verify its signature, ask which distribution ISOs to
include, skip files that are already present and valid, and verify every size and SHA-256 hash:

```sh
bash install-party-kit/AdjacentFilepool/populate-filepool.sh --channel main --output filepool
```

```powershell
powershell -ExecutionPolicy Bypass -File .\install-party-kit\AdjacentFilepool\populate-filepool.ps1 -Channel main -Output filepool
```

Use `dev` instead of `main` for a development build (`dev_<commit>`).

Start Libertix normally and answer **Yes** when it proposes the folder. During compatibility checking,
it verifies the local signature, compares the local catalog with the official online catalog, and
checks the size and SHA-256 of every file present. A missing required file, or any stale or corrupt
file, causes an error, not a silent Internet download. Choosing **No** leaves the folder unused and
permits server discovery, then official downloads if no server is accepted.

For explicitly requested development work, `Libertix.exe --dev` with the folder accepted skips the
online catalog comparison and the published-version check. **The local catalog signature and file
hashes are still verified**, and a development warning remains visible. This is not required for
normal reuse across several PCs. The independent laboratory `--filepool-base-url` option is not this mode.

## Validation

```sh
dotnet test install-party-kit/Tests/Libertix.InstallParty.Tests.csproj
```

The Windows application and PowerShell suites remain part of the normal Libertix build verification.
The existing clean2 campaign checks official/laboratory and adjacent-folder workflows; it is not by
itself a runtime test of UDP discovery or the install-party server.
