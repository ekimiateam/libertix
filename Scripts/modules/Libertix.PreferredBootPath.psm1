Set-StrictMode -Version Latest

$script:PreferredBootPathVersion = 1
$script:WindowsLoaderRelativePath = "EFI\Microsoft\Boot\bootmgfw.efi"
$script:WindowsBackupRelativePath = "EFI\Microsoft\Boot\bootmgfw.libertix-windows.efi"
$script:PreferredGrubRelativePath = "EFI\Microsoft\Boot\grubx64.efi"
$script:PreferredMokManagerRelativePath = "EFI\Microsoft\Boot\mmx64.efi"
$script:PreferredGrubConfigRelativePath = "EFI\Microsoft\Boot\grub.cfg"
$script:EspManifestRelativePath = "EFI\Libertix\preferred-boot-path.json"
$script:PreferredPathOriginalsRelativePath = "EFI\Libertix\PreferredPathOriginals"

function Get-LibertixPreferredPathProtectedFiles {
    return @(
        [pscustomobject]@{
            RelativePath = $script:WindowsBackupRelativePath
            ManifestPath = "\EFI\Microsoft\Boot\bootmgfw.libertix-windows.efi"
            ArchiveName = "preexisting-bootmgfw.libertix-windows.efi"
            EspBackupName = "bootmgfw.libertix-windows.efi"
        },
        [pscustomobject]@{
            RelativePath = $script:PreferredGrubRelativePath
            ManifestPath = "\EFI\Microsoft\Boot\grubx64.efi"
            ArchiveName = "preexisting-grubx64.efi"
            EspBackupName = "grubx64.efi"
        },
        [pscustomobject]@{
            RelativePath = $script:PreferredMokManagerRelativePath
            ManifestPath = "\EFI\Microsoft\Boot\mmx64.efi"
            ArchiveName = "preexisting-mmx64.efi"
            EspBackupName = "mmx64.efi"
        },
        [pscustomobject]@{
            RelativePath = $script:PreferredGrubConfigRelativePath
            ManifestPath = "\EFI\Microsoft\Boot\grub.cfg"
            ArchiveName = "preexisting-grub.cfg"
            EspBackupName = "grub.cfg"
        }
    )
}

function Initialize-LibertixPreferredPathMoveApi {
    if (([System.Management.Automation.PSTypeName]"LibertixPreferredPathMoveApi").Type) {
        return
    }

    Add-Type @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class LibertixPreferredPathMoveApi {
    private const UInt32 MOVEFILE_REPLACE_EXISTING = 0x00000001;
    private const UInt32 MOVEFILE_WRITE_THROUGH = 0x00000008;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool MoveFileEx(
        string existingFileName,
        string newFileName,
        UInt32 flags
    );

    public static void ReplaceAtomically(string source, string destination) {
        if (!MoveFileEx(
            source,
            destination,
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH
        )) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
"@
}

function Move-LibertixPreferredPathFileAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Initialize-LibertixPreferredPathMoveApi
    [LibertixPreferredPathMoveApi]::ReplaceAtomically($Source, $Destination)
}

function Get-LibertixPreferredPathHash {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Get-LibertixPreferredPathByteHash {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
    }
}

function Import-LibertixPreferredPathFirmwareModules {
    foreach ($name in @("Libertix.Firmware.psm1", "Libertix.FirmwareRead.psm1")) {
        $path = Join-Path $PSScriptRoot $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Preferred boot firmware dependency is missing: $path"
        }
        Import-Module -Name $path -Force -ErrorAction Stop
    }
}

function Get-LibertixPreferredPathFirmwareVariableBytes {
    param([Parameter(Mandatory = $true)][string]$Name)

    return Get-LibertixFirmwareVariableBytes -Name $Name
}

function Set-LibertixPreferredPathFirmwareVariableBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    Set-LibertixFirmwareVariableBytes -Name $Name -Bytes $Bytes
}

function Resolve-LibertixPreferredPathFileSystemPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not [IO.Path]::IsPathRooted($resolved)) {
        throw "Preferred boot path is not an absolute filesystem path: $Path"
    }
    return [IO.Path]::GetFullPath($resolved)
}

function Write-LibertixPreferredPathJsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $Path = Resolve-LibertixPreferredPathFileSystemPath -Path $Path
    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path `
        $directory `
        ".$([IO.Path]::GetFileName($Path)).$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText(
            $temporary,
            ($Value | ConvertTo-Json -Depth 12) + "`n",
            (New-Object Text.UTF8Encoding($false))
        )
        Move-LibertixPreferredPathFileAtomic `
            -Source $temporary `
            -Destination $Path
    } finally {
        if ([IO.File]::Exists($temporary)) {
            [IO.File]::Delete($temporary)
        }
    }
}

function Write-LibertixPreferredPathBytesAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )

    if ((Get-LibertixPreferredPathByteHash -Bytes $Bytes) -ne $ExpectedSha256) {
        throw "Preferred boot byte archive source hash mismatch."
    }
    $Path = Resolve-LibertixPreferredPathFileSystemPath -Path $Path
    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path `
        $directory `
        ".$([IO.Path]::GetFileName($Path)).$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        if ((Get-LibertixPreferredPathHash -Path $temporary) -ne $ExpectedSha256) {
            throw "Preferred boot byte archive staged hash mismatch."
        }
        Move-LibertixPreferredPathFileAtomic -Source $temporary -Destination $Path
        if ((Get-LibertixPreferredPathHash -Path $Path) -ne $ExpectedSha256) {
            throw "Preferred boot byte archive destination hash mismatch."
        }
    } finally {
        if ([IO.File]::Exists($temporary)) {
            [IO.File]::Delete($temporary)
        }
    }
}

function Get-LibertixPreferredPathWindowsBootEntry {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$ArchiveRoot,
        $ExistingManifest
    )

    Import-LibertixPreferredPathFirmwareModules
    $evidencePath = Join-Path $State.RecoveryRoot "firmware-boot-bypass.json"
    if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
        throw "Firmware bypass evidence is missing before preferred-path installation."
    }
    $evidence = Get-Content -LiteralPath $evidencePath -Raw -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop
    $entryName = [string]$evidence.windowsBootNumber
    if (
        [int]$evidence.schemaVersion -ne 1 -or
        [string]$evidence.runId -ne [string]$State.RunId -or
        $entryName -notmatch '^Boot[0-9A-Fa-f]{4}$' -or
        [string]$evidence.windowsLoaderPath -ne "\EFI\Microsoft\Boot\bootmgfw.efi"
    ) {
        throw "Firmware bypass evidence does not identify the expected Windows boot entry."
    }
    $entryName = "Boot" + $entryName.Substring(4).ToUpperInvariant()
    $observed = Get-LibertixPreferredPathFirmwareVariableBytes -Name $entryName
    if (
        -not $observed -or
        -not (Test-EfiLoadOptionLoaderPath `
            -Bytes $observed `
            -ExpectedPath "\EFI\Microsoft\Boot\bootmgfw.efi")
    ) {
        throw "The recorded Windows boot entry is missing or no longer targets bootmgfw.efi."
    }

    $archiveName = "windows-boot-entry.original.bin"
    $archivePath = Join-Path $ArchiveRoot $archiveName
    $hasExistingEntry = (
        $null -ne $ExistingManifest -and
        $ExistingManifest.PSObject.Properties.Name -contains "windowsBootEntry"
    )
    if ($null -ne $ExistingManifest -and -not $hasExistingEntry) {
        throw "Existing preferred boot manifest does not protect the Windows boot entry."
    }

    if ($hasExistingEntry) {
        $record = $ExistingManifest.windowsBootEntry
        $originalHash = [string]$record.originalSha256
        $preferredHash = [string]$record.preferredSha256
        try {
            $preferredBytes = [Convert]::FromBase64String([string]$record.preferredBytesBase64)
        } catch [FormatException] {
            throw "Preferred Windows boot entry encoding is invalid."
        }
        if (
            [string]$record.name -ne $entryName -or
            [string]$record.originalArchiveName -ne $archiveName -or
            $originalHash -notmatch '^[0-9a-f]{64}$' -or
            $preferredHash -notmatch '^[0-9a-f]{64}$' -or
            (Get-LibertixPreferredPathByteHash -Bytes $preferredBytes) -ne $preferredHash -or
            (Get-EfiLoadOptionOptionalDataLength -Bytes $preferredBytes) -ne 0 -or
            -not (Test-Path -LiteralPath $archivePath -PathType Leaf) -or
            (Get-LibertixPreferredPathHash -Path $archivePath) -ne $originalHash
        ) {
            throw "Existing preferred Windows boot entry archive is invalid."
        }
        $observedHash = Get-LibertixPreferredPathByteHash -Bytes ([byte[]]$observed)
        if ($observedHash -notin @($originalHash, $preferredHash)) {
            throw "The Windows boot entry changed outside the preferred-path transaction."
        }
        return [pscustomobject]@{
            Name = $entryName
            OriginalSha256 = $originalHash
            PreferredBytes = [byte[]]$preferredBytes
            PreferredSha256 = $preferredHash
            ArchiveName = $archiveName
            RemovedByteCount = [int]$record.optionalDataRemovedBytes
        }
    }

    $optionalLength = Get-EfiLoadOptionOptionalDataLength -Bytes $observed
    if ($optionalLength -lt 0) {
        throw "The recorded Windows boot entry has an invalid EFI_LOAD_OPTION layout."
    }
    $preferredBytes = Remove-EfiLoadOptionOptionalData -Bytes $observed
    if ((Get-EfiLoadOptionOptionalDataLength -Bytes $preferredBytes) -ne 0) {
        throw "The preferred Windows boot entry still contains optional data."
    }
    $originalHash = Get-LibertixPreferredPathByteHash -Bytes ([byte[]]$observed)
    $preferredHash = Get-LibertixPreferredPathByteHash -Bytes ([byte[]]$preferredBytes)
    Write-LibertixPreferredPathBytesAtomic `
        -Path $archivePath `
        -Bytes ([byte[]]$observed) `
        -ExpectedSha256 $originalHash
    return [pscustomobject]@{
        Name = $entryName
        OriginalSha256 = $originalHash
        PreferredBytes = [byte[]]$preferredBytes
        PreferredSha256 = $preferredHash
        ArchiveName = $archiveName
        RemovedByteCount = $optionalLength
    }
}

function Set-LibertixPreferredPathWindowsBootEntry {
    param([Parameter(Mandatory = $true)]$Entry)

    Import-LibertixPreferredPathFirmwareModules
    $observed = Get-LibertixPreferredPathFirmwareVariableBytes -Name ([string]$Entry.Name)
    $observedHash = if ($observed) {
        Get-LibertixPreferredPathByteHash -Bytes ([byte[]]$observed)
    } else {
        ""
    }
    if ($observedHash -eq [string]$Entry.PreferredSha256) {
        return
    }
    if ($observedHash -ne [string]$Entry.OriginalSha256) {
        throw "Windows boot entry changed before preferred optional-data removal."
    }
    Set-LibertixPreferredPathFirmwareVariableBytes `
        -Name ([string]$Entry.Name) `
        -Bytes ([byte[]]$Entry.PreferredBytes)
    $verified = Get-LibertixPreferredPathFirmwareVariableBytes -Name ([string]$Entry.Name)
    if (
        -not $verified -or
        (Get-LibertixPreferredPathByteHash -Bytes ([byte[]]$verified)) -ne `
            [string]$Entry.PreferredSha256
    ) {
        throw "Firmware did not retain the preferred Windows boot entry."
    }
}

function Copy-LibertixPreferredPathFileAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )

    $Source = Resolve-LibertixPreferredPathFileSystemPath -Path $Source
    $Destination = Resolve-LibertixPreferredPathFileSystemPath -Path $Destination
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Preferred boot source file is missing: $Source"
    }
    if ((Get-LibertixPreferredPathHash -Path $Source) -ne $ExpectedSha256) {
        throw "Preferred boot source hash changed before staging: $Source"
    }
    $directory = Split-Path -Parent $Destination
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path `
        $directory `
        ".$([IO.Path]::GetFileName($Destination)).$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::Copy($Source, $temporary, $false)
        if ((Get-LibertixPreferredPathHash -Path $temporary) -ne $ExpectedSha256) {
            throw "Preferred boot staged file hash mismatch: $Destination"
        }
        Move-LibertixPreferredPathFileAtomic `
            -Source $temporary `
            -Destination $Destination
        if ((Get-LibertixPreferredPathHash -Path $Destination) -ne $ExpectedSha256) {
            throw "Preferred boot destination hash mismatch: $Destination"
        }
    } finally {
        if ([IO.File]::Exists($temporary)) {
            [IO.File]::Delete($temporary)
        }
    }
}

function Get-LibertixPreferredPathOriginalFileRecords {
    param(
        [Parameter(Mandatory = $true)][string]$EspRoot,
        [Parameter(Mandatory = $true)][string]$ArchiveRoot,
        $ExistingManifest
    )

    $definitions = @(Get-LibertixPreferredPathProtectedFiles)
    $hasExistingRecords = (
        $null -ne $ExistingManifest -and
        $ExistingManifest.PSObject.Properties.Name -contains "originalFiles"
    )
    if ($null -ne $ExistingManifest -and -not $hasExistingRecords) {
        # Version 1 manifests created before complete destination snapshots remain restorable
        # through the legacy cleanup path. Never infer originals from an already modified ESP.
        return $null
    }

    $archiveDirectory = Join-Path $ArchiveRoot "original-files"
    $espBackupDirectory = Join-Path $EspRoot $script:PreferredPathOriginalsRelativePath
    if ($hasExistingRecords) {
        $records = @($ExistingManifest.originalFiles)
        if ($records.Count -ne $definitions.Count) {
            throw "Preferred boot original-file manifest has an invalid cardinality."
        }
        foreach ($definition in $definitions) {
            $matching = @(
                $records | Where-Object {
                    [string]$_.path -eq [string]$definition.ManifestPath
                }
            )
            if ($matching.Count -ne 1) {
                throw "Preferred boot original-file manifest contains an unexpected path set."
            }
            $record = $matching[0]
            $expectedEspBackupPath = (
                "\EFI\Libertix\PreferredPathOriginals\" +
                [string]$definition.EspBackupName
            )
            if (
                [string]$record.archiveName -ne [string]$definition.ArchiveName -or
                [string]$record.espBackupPath -ne $expectedEspBackupPath
            ) {
                throw "Preferred boot original-file manifest contains unexpected backup paths."
            }
            if ([bool]$record.existed) {
                $hash = [string]$record.sha256
                $archivePath = Join-Path $archiveDirectory $definition.ArchiveName
                $espBackupPath = Join-Path $espBackupDirectory $definition.EspBackupName
                if (
                    $hash -notmatch '^[0-9a-f]{64}$' -or
                    -not (Test-Path -LiteralPath $archivePath -PathType Leaf) -or
                    (Get-LibertixPreferredPathHash -Path $archivePath) -ne $hash -or
                    -not (Test-Path -LiteralPath $espBackupPath -PathType Leaf) -or
                    (Get-LibertixPreferredPathHash -Path $espBackupPath) -ne $hash
                ) {
                    throw "Preferred boot original-file backup is missing or corrupted."
                }
            } elseif (-not [string]::IsNullOrEmpty([string]$record.sha256)) {
                throw "Preferred boot absent original file unexpectedly has a hash."
            }
        }
        return @($records)
    }

    [IO.Directory]::CreateDirectory($archiveDirectory) | Out-Null
    [IO.Directory]::CreateDirectory($espBackupDirectory) | Out-Null
    $records = [Collections.Generic.List[object]]::new()
    foreach ($definition in $definitions) {
        $source = Join-Path $EspRoot $definition.RelativePath
        $record = [ordered]@{
            path = [string]$definition.ManifestPath
            existed = $false
            sha256 = ""
            archiveName = [string]$definition.ArchiveName
            espBackupPath = (
                "\EFI\Libertix\PreferredPathOriginals\" +
                [string]$definition.EspBackupName
            )
        }
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            $hash = Get-LibertixPreferredPathHash -Path $source
            $archivePath = Join-Path $archiveDirectory $definition.ArchiveName
            $espBackupPath = Join-Path $espBackupDirectory $definition.EspBackupName
            Copy-LibertixPreferredPathFileAtomic `
                -Source $source `
                -Destination $archivePath `
                -ExpectedSha256 $hash
            Copy-LibertixPreferredPathFileAtomic `
                -Source $archivePath `
                -Destination $espBackupPath `
                -ExpectedSha256 $hash
            $record.existed = $true
            $record.sha256 = $hash
        }
        $null = $records.Add([pscustomobject]$record)
    }
    return @($records.ToArray())
}

function Get-LibertixPreferredPathSecureBootEvidence {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$EspRoot
    )

    $libertixDirectory = Join-Path $EspRoot "EFI\Libertix"
    $evidencePath = Join-Path $libertixDirectory "secure-boot-chain.json"
    if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
        throw "Installed Secure Boot chain evidence is missing."
    }
    $evidence = Get-Content -LiteralPath $evidencePath -Raw -Encoding UTF8 -ErrorAction Stop |
        ConvertFrom-Json -ErrorAction Stop
    $expectedStatus = if ([bool]$State.SecureBootEnabled) { "verified" } else { "not-required" }
    if (
        [int]$evidence.version -ne 1 -or
        [string]$evidence.status -ne $expectedStatus -or
        [bool]$evidence.secureBootEnabled -ne [bool]$State.SecureBootEnabled
    ) {
        throw "Installed Secure Boot chain evidence does not match the recorded firmware state."
    }

    $files = [ordered]@{
        shim = [ordered]@{
            path = Join-Path $libertixDirectory "shimx64.efi"
            relativePath = "EFI\Libertix\shimx64.efi"
            preferredRelativePath = $script:WindowsLoaderRelativePath
            sha256 = [string]$evidence.images.shim.sha256
        }
        grub = [ordered]@{
            path = Join-Path $libertixDirectory "grubx64.efi"
            relativePath = "EFI\Libertix\grubx64.efi"
            preferredRelativePath = $script:PreferredGrubRelativePath
            sha256 = [string]$evidence.images.grub.sha256
        }
        mokManager = [ordered]@{
            path = Join-Path $libertixDirectory "mmx64.efi"
            relativePath = "EFI\Libertix\mmx64.efi"
            preferredRelativePath = $script:PreferredMokManagerRelativePath
            sha256 = [string]$evidence.images.mokManager.sha256
        }
    }
    foreach ($entry in $files.Values) {
        if (
            [string]$entry.sha256 -notmatch '^[0-9a-f]{64}$' -or
            -not (Test-Path -LiteralPath $entry.path -PathType Leaf) -or
            (Get-LibertixPreferredPathHash -Path $entry.path) -ne [string]$entry.sha256
        ) {
            throw "Installed EFI chain differs from its Secure Boot evidence: $($entry.path)"
        }
    }
    return [pscustomobject]@{
        EvidencePath = $evidencePath
        Files = $files
    }
}

function New-LibertixPreferredPathGrubConfig {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw "Installed Libertix GRUB redirect is missing."
    }
    $source = Get-Content -LiteralPath $SourcePath -Raw -Encoding UTF8 -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($source) -or $source -match "[`0]") {
        throw "Installed Libertix GRUB redirect is invalid."
    }
$content = @"
set libertix_windows_loader=/EFI/Microsoft/Boot/bootmgfw.libertix-windows.efi
export libertix_windows_loader
$($source.TrimStart())
"@
    [IO.File]::WriteAllText(
        $DestinationPath,
        $content,
        (New-Object Text.UTF8Encoding($false))
    )
}

function Install-LibertixPreferredBootPath {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$EspPartition,
        [Parameter(Mandatory = $true)][string]$EspRoot,
        [Parameter(Mandatory = $true)][scriptblock]$WriteLog
    )

    $secureBoot = Get-LibertixPreferredPathSecureBootEvidence `
        -State $State `
        -EspRoot $EspRoot
    $windowsLoader = Join-Path $EspRoot $script:WindowsLoaderRelativePath
    if (-not (Test-Path -LiteralPath $windowsLoader -PathType Leaf)) {
        throw "Windows Boot Manager is missing from the recorded ESP."
    }
    $observedWindowsLoaderHash = Get-LibertixPreferredPathHash -Path $windowsLoader
    $archiveRoot = Join-Path $State.RecoveryRoot "preferred-boot-path"
    [IO.Directory]::CreateDirectory($archiveRoot) | Out-Null
    $archiveLoader = Join-Path $archiveRoot "bootmgfw.efi"
    $archiveManifest = Join-Path $archiveRoot "manifest.json"
    $espBackup = Join-Path $EspRoot $script:WindowsBackupRelativePath
    $espManifest = Join-Path $EspRoot $script:EspManifestRelativePath
    $existingManifest = $null

    if (Test-Path -LiteralPath $archiveManifest -PathType Leaf) {
        $existing = Get-Content -LiteralPath $archiveManifest -Raw -Encoding UTF8 |
            ConvertFrom-Json -ErrorAction Stop
        $existingManifest = $existing
        $windowsLoaderHash = [string]$existing.windowsLoader.sha256
        $allowedActiveHashes = @(
            $windowsLoaderHash,
            [string]$existing.preferred.shimSha256
        )
        if (
            [string]$existing.runId -ne [string]$State.RunId -or
            $windowsLoaderHash -notmatch '^[0-9a-f]{64}$' -or
            -not (Test-Path -LiteralPath $archiveLoader -PathType Leaf) -or
            (Get-LibertixPreferredPathHash -Path $archiveLoader) -ne $windowsLoaderHash
        ) {
            throw "Existing preferred boot archive does not match this recovery transaction."
        }
        if ($observedWindowsLoaderHash -notin $allowedActiveHashes) {
            $signature = Get-AuthenticodeSignature `
                -LiteralPath $windowsLoader `
                -ErrorAction Stop
            $signerIdentity = if ($signature.SignerCertificate) {
                [string]$signature.SignerCertificate.Subject + " " +
                    [string]$signature.SignerCertificate.Issuer
            } else {
                ""
            }
            if (
                [string]$signature.Status -ne "Valid" -or
                $signerIdentity -notmatch '(?i)Microsoft'
            ) {
                throw "Changed Windows Boot Manager does not have a valid Microsoft signature."
            }
            $previousArchive = Join-Path `
                $archiveRoot `
                "bootmgfw-history-$windowsLoaderHash.efi"
            if (-not (Test-Path -LiteralPath $previousArchive)) {
                [IO.File]::Copy($archiveLoader, $previousArchive, $false)
            }
            Copy-LibertixPreferredPathFileAtomic `
                -Source $windowsLoader `
                -Destination $archiveLoader `
                -ExpectedSha256 $observedWindowsLoaderHash
            $windowsLoaderHash = $observedWindowsLoaderHash
            & $WriteLog "A signed Windows Boot Manager update was preserved before fallback repair."
        }
    } else {
        $windowsLoaderHash = $observedWindowsLoaderHash
        if ([IO.File]::Exists($archiveLoader)) {
            if ((Get-LibertixPreferredPathHash -Path $archiveLoader) -ne $windowsLoaderHash) {
                throw "Incomplete preferred boot archive does not match Windows Boot Manager."
            }
        } else {
            [IO.File]::Copy($windowsLoader, $archiveLoader, $false)
        }
        if ((Get-LibertixPreferredPathHash -Path $archiveLoader) -ne $windowsLoaderHash) {
            throw "Permanent Windows Boot Manager archive hash mismatch."
        }
    }
    $originalFiles = Get-LibertixPreferredPathOriginalFileRecords `
        -EspRoot $EspRoot `
        -ArchiveRoot $archiveRoot `
        -ExistingManifest $existingManifest
    $windowsBootEntry = Get-LibertixPreferredPathWindowsBootEntry `
        -State $State `
        -ArchiveRoot $archiveRoot `
        -ExistingManifest $existingManifest

    $grubConfigSource = Join-Path $EspRoot "EFI\Libertix\grub.cfg"
    $stagedGrubConfig = Join-Path $archiveRoot ".grub.cfg.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        New-LibertixPreferredPathGrubConfig `
            -SourcePath $grubConfigSource `
            -DestinationPath $stagedGrubConfig
        $grubConfigHash = Get-LibertixPreferredPathHash -Path $stagedGrubConfig
        $manifest = [ordered]@{
            version = $script:PreferredBootPathVersion
            runId = [string]$State.RunId
            installedUtc = [DateTime]::UtcNow.ToString("o")
            esp = [ordered]@{
                diskNumber = [int]$EspPartition.DiskNumber
                partitionNumber = [int]$EspPartition.PartitionNumber
                offsetBytes = [int64]$EspPartition.Offset
                sizeBytes = [int64]$EspPartition.Size
                partitionGuid = ([Guid]$EspPartition.Guid).ToString("D").ToLowerInvariant()
            }
            windowsLoader = [ordered]@{
                activePath = "\EFI\Microsoft\Boot\bootmgfw.efi"
                backupPath = "\EFI\Microsoft\Boot\bootmgfw.libertix-windows.efi"
                sha256 = $windowsLoaderHash
            }
            windowsBootEntry = [ordered]@{
                name = [string]$windowsBootEntry.Name
                originalSha256 = [string]$windowsBootEntry.OriginalSha256
                originalArchiveName = [string]$windowsBootEntry.ArchiveName
                preferredBytesBase64 = [Convert]::ToBase64String(
                    [byte[]]$windowsBootEntry.PreferredBytes
                )
                preferredSha256 = [string]$windowsBootEntry.PreferredSha256
                optionalDataRemovedBytes = [int]$windowsBootEntry.RemovedByteCount
            }
            preferred = [ordered]@{
                shimSha256 = [string]$secureBoot.Files.shim.sha256
                grubSha256 = [string]$secureBoot.Files.grub.sha256
                mokManagerSha256 = [string]$secureBoot.Files.mokManager.sha256
                grubConfigSha256 = $grubConfigHash
            }
            secureBootEnabled = [bool]$State.SecureBootEnabled
            status = "prepared"
        }
        if ($null -ne $originalFiles) {
            $manifest["originalFiles"] = @($originalFiles)
        }
        Write-LibertixPreferredPathJsonAtomic -Path $archiveManifest -Value $manifest
        Write-LibertixPreferredPathJsonAtomic -Path $espManifest -Value $manifest

        Copy-LibertixPreferredPathFileAtomic `
            -Source $archiveLoader `
            -Destination $espBackup `
            -ExpectedSha256 $windowsLoaderHash
        Copy-LibertixPreferredPathFileAtomic `
            -Source ([string]$secureBoot.Files.grub.path) `
            -Destination (Join-Path $EspRoot $script:PreferredGrubRelativePath) `
            -ExpectedSha256 ([string]$secureBoot.Files.grub.sha256)
        Copy-LibertixPreferredPathFileAtomic `
            -Source ([string]$secureBoot.Files.mokManager.path) `
            -Destination (Join-Path $EspRoot $script:PreferredMokManagerRelativePath) `
            -ExpectedSha256 ([string]$secureBoot.Files.mokManager.sha256)
        Copy-LibertixPreferredPathFileAtomic `
            -Source $stagedGrubConfig `
            -Destination (Join-Path $EspRoot $script:PreferredGrubConfigRelativePath) `
            -ExpectedSha256 $grubConfigHash
        # Publish shim last. Until this replacement, firmware still reaches the
        # original Windows loader and every supporting file is inert.
        Copy-LibertixPreferredPathFileAtomic `
            -Source ([string]$secureBoot.Files.shim.path) `
            -Destination $windowsLoader `
            -ExpectedSha256 ([string]$secureBoot.Files.shim.sha256)
        Set-LibertixPreferredPathWindowsBootEntry -Entry $windowsBootEntry

        $manifest.status = "installed"
        $manifest.installedUtc = [DateTime]::UtcNow.ToString("o")
        Write-LibertixPreferredPathJsonAtomic -Path $archiveManifest -Value $manifest
        Write-LibertixPreferredPathJsonAtomic -Path $espManifest -Value $manifest
        & $WriteLog (
            "Preferred Windows boot path installed and hash-verified; " +
            "Windows boot-entry optional data removed=$($windowsBootEntry.RemovedByteCount) bytes."
        )
        return $manifest
    } finally {
        if ([IO.File]::Exists($stagedGrubConfig)) {
            [IO.File]::Delete($stagedGrubConfig)
        }
    }
}

function Restore-LibertixPreferredPathOriginalFiles {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$ArchiveRoot,
        [Parameter(Mandatory = $true)][string]$EspRoot,
        [Parameter(Mandatory = $true)][scriptblock]$WriteLog
    )

    if ($Manifest.PSObject.Properties.Name -notcontains "originalFiles") {
        return $false
    }
    $definitions = @(Get-LibertixPreferredPathProtectedFiles)
    $records = @($Manifest.originalFiles)
    if ($records.Count -ne $definitions.Count) {
        throw "Preferred boot original-file manifest has an invalid cardinality."
    }
    $archiveDirectory = Join-Path $ArchiveRoot "original-files"
    $espBackupDirectory = Join-Path $EspRoot $script:PreferredPathOriginalsRelativePath
    foreach ($definition in $definitions) {
        $matching = @(
            $records | Where-Object {
                [string]$_.path -eq [string]$definition.ManifestPath
            }
        )
        if ($matching.Count -ne 1) {
            throw "Preferred boot original-file manifest contains an unexpected path set."
        }
        $record = $matching[0]
        $expectedEspBackupManifestPath = (
            "\EFI\Libertix\PreferredPathOriginals\" +
            [string]$definition.EspBackupName
        )
        if (
            [string]$record.archiveName -ne [string]$definition.ArchiveName -or
            [string]$record.espBackupPath -ne $expectedEspBackupManifestPath
        ) {
            throw "Preferred boot original-file manifest contains unexpected backup paths."
        }
        $ownedHash = switch ([string]$definition.ManifestPath) {
            "\EFI\Microsoft\Boot\bootmgfw.libertix-windows.efi" {
                [string]$Manifest.windowsLoader.sha256
                break
            }
            "\EFI\Microsoft\Boot\grubx64.efi" {
                [string]$Manifest.preferred.grubSha256
                break
            }
            "\EFI\Microsoft\Boot\mmx64.efi" {
                [string]$Manifest.preferred.mokManagerSha256
                break
            }
            "\EFI\Microsoft\Boot\grub.cfg" {
                [string]$Manifest.preferred.grubConfigSha256
                break
            }
            default { throw "Preferred boot original-file definition is unsupported." }
        }
        if ($ownedHash -notmatch '^[0-9a-f]{64}$') {
            throw "Preferred boot owned-file hash is invalid."
        }

        $destination = Join-Path $EspRoot $definition.RelativePath
        if ([bool]$record.existed) {
            $originalHash = [string]$record.sha256
            if ($originalHash -notmatch '^[0-9a-f]{64}$') {
                throw "Preferred boot original-file hash is invalid."
            }
            $archivePath = Join-Path $archiveDirectory $definition.ArchiveName
            $espBackupPath = Join-Path $espBackupDirectory $definition.EspBackupName
            $restoreSource = $null
            if (
                (Test-Path -LiteralPath $archivePath -PathType Leaf) -and
                (Get-LibertixPreferredPathHash -Path $archivePath) -eq $originalHash
            ) {
                $restoreSource = $archivePath
            } elseif (
                (Test-Path -LiteralPath $espBackupPath -PathType Leaf) -and
                (Get-LibertixPreferredPathHash -Path $espBackupPath) -eq $originalHash
            ) {
                $restoreSource = $espBackupPath
            } else {
                throw "Preferred boot original-file backup is missing or corrupted."
            }
            if (Test-Path -LiteralPath $destination -PathType Leaf) {
                $currentHash = Get-LibertixPreferredPathHash -Path $destination
                if ($currentHash -notin @($ownedHash, $originalHash)) {
                    $unexpected = Join-Path `
                        $archiveDirectory `
                        ("unexpected-{0}-{1}" -f $definition.ArchiveName, $currentHash)
                    if (-not (Test-Path -LiteralPath $unexpected -PathType Leaf)) {
                        Copy-LibertixPreferredPathFileAtomic `
                            -Source $destination `
                            -Destination $unexpected `
                            -ExpectedSha256 $currentHash
                    }
                    & $WriteLog (
                        "Unexpected preferred boot support file was archived before restoration: " +
                        [string]$definition.ManifestPath
                    )
                }
            }
            Copy-LibertixPreferredPathFileAtomic `
                -Source $restoreSource `
                -Destination $destination `
                -ExpectedSha256 $originalHash
            if (Test-Path -LiteralPath $espBackupPath -PathType Leaf) {
                if ((Get-LibertixPreferredPathHash -Path $espBackupPath) -ne $originalHash) {
                    throw "Preferred boot ESP original-file backup changed before cleanup."
                }
                [IO.File]::Delete($espBackupPath)
            }
        } else {
            if (-not [string]::IsNullOrEmpty([string]$record.sha256)) {
                throw "Preferred boot absent original file unexpectedly has a hash."
            }
            if (Test-Path -LiteralPath $destination -PathType Leaf) {
                if ((Get-LibertixPreferredPathHash -Path $destination) -ne $ownedHash) {
                    throw "Preferred boot cleanup refused a file whose hash changed: $destination"
                }
                [IO.File]::Delete($destination)
            }
        }
    }
    if (
        [IO.Directory]::Exists($espBackupDirectory) -and
        @([IO.Directory]::GetFileSystemEntries($espBackupDirectory)).Count -eq 0
    ) {
        [IO.Directory]::Delete($espBackupDirectory, $false)
    }
    return $true
}

function Restore-LibertixPreferredPathWindowsBootEntry {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$ArchiveRoot,
        [Parameter(Mandatory = $true)][scriptblock]$WriteLog
    )

    if ($Manifest.PSObject.Properties.Name -notcontains "windowsBootEntry") {
        throw "Preferred boot manifest does not protect the original Windows boot entry."
    }
    Import-LibertixPreferredPathFirmwareModules
    $record = $Manifest.windowsBootEntry
    $name = [string]$record.name
    $originalHash = [string]$record.originalSha256
    $preferredHash = [string]$record.preferredSha256
    $archiveName = [string]$record.originalArchiveName
    if (
        $name -notmatch '^Boot[0-9A-F]{4}$' -or
        $originalHash -notmatch '^[0-9a-f]{64}$' -or
        $preferredHash -notmatch '^[0-9a-f]{64}$' -or
        $archiveName -ne "windows-boot-entry.original.bin"
    ) {
        throw "Preferred Windows boot entry restoration contract is invalid."
    }
    $archivePath = Join-Path $ArchiveRoot $archiveName
    if (
        -not (Test-Path -LiteralPath $archivePath -PathType Leaf) -or
        (Get-LibertixPreferredPathHash -Path $archivePath) -ne $originalHash
    ) {
        throw "Original Windows boot entry archive is missing or corrupted."
    }
    $originalBytes = [IO.File]::ReadAllBytes($archivePath)
    $observed = Get-LibertixPreferredPathFirmwareVariableBytes -Name $name
    $observedHash = if ($observed) {
        Get-LibertixPreferredPathByteHash -Bytes ([byte[]]$observed)
    } else {
        ""
    }
    if ($observedHash -eq $originalHash) {
        return
    }
    if ($observedHash -and $observedHash -ne $preferredHash) {
        $unexpected = Join-Path `
            $ArchiveRoot `
            "unexpected-windows-boot-entry-$observedHash.bin"
        if (-not (Test-Path -LiteralPath $unexpected -PathType Leaf)) {
            Write-LibertixPreferredPathBytesAtomic `
                -Path $unexpected `
                -Bytes ([byte[]]$observed) `
                -ExpectedSha256 $observedHash
        }
        & $WriteLog "Unexpected Windows boot entry was archived before exact restoration."
    }
    Set-LibertixPreferredPathFirmwareVariableBytes -Name $name -Bytes $originalBytes
    $verified = Get-LibertixPreferredPathFirmwareVariableBytes -Name $name
    if (
        -not $verified -or
        (Get-LibertixPreferredPathByteHash -Bytes ([byte[]]$verified)) -ne $originalHash
    ) {
        throw "Firmware did not retain the restored Windows boot entry."
    }
    & $WriteLog "Original Windows boot entry restored exactly from the permanent archive."
}

function Restore-LibertixPreferredBootPath {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$EspRoot,
        [Parameter(Mandatory = $true)][scriptblock]$WriteLog
    )

    $archiveRoot = Join-Path $State.RecoveryRoot "preferred-boot-path"
    $archiveManifest = Join-Path $archiveRoot "manifest.json"
    if (-not (Test-Path -LiteralPath $archiveManifest -PathType Leaf)) {
        return $false
    }
    $manifest = Get-Content -LiteralPath $archiveManifest -Raw -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop
    if (
        [int]$manifest.version -ne $script:PreferredBootPathVersion -or
        [string]$manifest.runId -ne [string]$State.RunId -or
        [string]$manifest.windowsLoader.activePath -ne "\EFI\Microsoft\Boot\bootmgfw.efi" -or
        [string]$manifest.windowsLoader.backupPath -ne "\EFI\Microsoft\Boot\bootmgfw.libertix-windows.efi" -or
        [string]$manifest.windowsLoader.sha256 -notmatch '^[0-9a-f]{64}$'
    ) {
        throw "Permanent preferred boot manifest is invalid."
    }
    Restore-LibertixPreferredPathWindowsBootEntry `
        -Manifest $manifest `
        -ArchiveRoot $archiveRoot `
        -WriteLog $WriteLog
    $archiveLoader = Join-Path $archiveRoot "bootmgfw.efi"
    $espManifestPath = Join-Path $EspRoot $script:EspManifestRelativePath
    if (Test-Path -LiteralPath $espManifestPath -PathType Leaf) {
        $espManifest = Get-Content -LiteralPath $espManifestPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -ErrorAction Stop
        $espBackup = Join-Path $EspRoot $script:WindowsBackupRelativePath
        $espOriginalHash = [string]$espManifest.windowsLoader.sha256
        if (
            [int]$espManifest.version -ne $script:PreferredBootPathVersion -or
            [string]$espManifest.runId -ne [string]$State.RunId -or
            [string]$espManifest.windowsLoader.activePath -ne "\EFI\Microsoft\Boot\bootmgfw.efi" -or
            [string]$espManifest.windowsLoader.backupPath -ne "\EFI\Microsoft\Boot\bootmgfw.libertix-windows.efi" -or
            $espOriginalHash -notmatch '^[0-9a-f]{64}$'
        ) {
            throw "ESP preferred boot manifest is invalid."
        }
        $archiveLoaderValid = (
            (Test-Path -LiteralPath $archiveLoader -PathType Leaf) -and
            (Get-LibertixPreferredPathHash -Path $archiveLoader) -eq $espOriginalHash
        )
        if (-not $archiveLoaderValid) {
            $espBackupValid = (
                (Test-Path -LiteralPath $espBackup -PathType Leaf) -and
                (Get-LibertixPreferredPathHash -Path $espBackup) -eq $espOriginalHash
            )
            if (-not $espBackupValid) {
                throw "Windows loader archives are missing or corrupted."
            }
        }
        if (-not $archiveLoaderValid) {
            if (Test-Path -LiteralPath $archiveLoader -PathType Leaf) {
                $previousHash = Get-LibertixPreferredPathHash -Path $archiveLoader
                $historyPath = Join-Path $archiveRoot "bootmgfw-history-$previousHash.efi"
                if (-not (Test-Path -LiteralPath $historyPath)) {
                    [IO.File]::Copy($archiveLoader, $historyPath, $false)
                }
            }
            Copy-LibertixPreferredPathFileAtomic `
                -Source $espBackup `
                -Destination $archiveLoader `
                -ExpectedSha256 $espOriginalHash
        }
        $manifest = $espManifest
        Write-LibertixPreferredPathJsonAtomic `
            -Path $archiveManifest `
            -Value $manifest
    }
    $originalHash = [string]$manifest.windowsLoader.sha256
    if (
        -not (Test-Path -LiteralPath $archiveLoader -PathType Leaf) -or
        (Get-LibertixPreferredPathHash -Path $archiveLoader) -ne $originalHash
    ) {
        throw "Permanent Windows Boot Manager archive is missing or corrupted."
    }
    $windowsLoader = Join-Path $EspRoot $script:WindowsLoaderRelativePath
    if (Test-Path -LiteralPath $windowsLoader -PathType Leaf) {
        $observedHash = Get-LibertixPreferredPathHash -Path $windowsLoader
        $knownHashes = @(
            $originalHash,
            [string]$manifest.preferred.shimSha256
        )
        if ($observedHash -notin $knownHashes) {
            $unexpected = Join-Path $archiveRoot "unexpected-bootmgfw-$observedHash.efi"
            if (-not (Test-Path -LiteralPath $unexpected)) {
                [IO.File]::Copy($windowsLoader, $unexpected, $false)
            }
            & $WriteLog (
                "Unexpected bootmgfw.efi was archived before restoring the recorded Windows loader."
            )
        }
    }
    Copy-LibertixPreferredPathFileAtomic `
        -Source $archiveLoader `
        -Destination $windowsLoader `
        -ExpectedSha256 $originalHash

    $restoredOriginalFiles = Restore-LibertixPreferredPathOriginalFiles `
        -Manifest $manifest `
        -ArchiveRoot $archiveRoot `
        -EspRoot $EspRoot `
        -WriteLog $WriteLog
    if (-not $restoredOriginalFiles) {
        $legacyOwnedFiles = @(
            @{ RelativePath = $script:PreferredGrubRelativePath; Hash = [string]$manifest.preferred.grubSha256 },
            @{ RelativePath = $script:PreferredMokManagerRelativePath; Hash = [string]$manifest.preferred.mokManagerSha256 },
            @{ RelativePath = $script:PreferredGrubConfigRelativePath; Hash = [string]$manifest.preferred.grubConfigSha256 },
            @{ RelativePath = $script:WindowsBackupRelativePath; Hash = $originalHash }
        )
        foreach ($owned in $legacyOwnedFiles) {
            $path = Join-Path $EspRoot $owned.RelativePath
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                continue
            }
            if ((Get-LibertixPreferredPathHash -Path $path) -ne [string]$owned.Hash) {
                throw "Preferred boot cleanup refused a file whose hash changed: $path"
            }
            [IO.File]::Delete($path)
        }
    }
    if (Test-Path -LiteralPath $espManifestPath -PathType Leaf) {
        [IO.File]::Delete($espManifestPath)
    }
    $manifest.status = "restored"
    $manifest | Add-Member `
        -NotePropertyName restoredUtc `
        -NotePropertyValue ([DateTime]::UtcNow.ToString("o")) `
        -Force
    Write-LibertixPreferredPathJsonAtomic -Path $archiveManifest -Value $manifest
    & $WriteLog "Original Windows Boot Manager restored and verified from permanent archive."
    return $true
}

Export-ModuleMember -Function `
    Install-LibertixPreferredBootPath, Restore-LibertixPreferredBootPath, `
    Copy-LibertixPreferredPathFileAtomic
