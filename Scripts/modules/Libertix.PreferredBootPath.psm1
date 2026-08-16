Set-StrictMode -Version Latest

$script:PreferredBootPathVersion = 1
$script:WindowsLoaderRelativePath = "EFI\Microsoft\Boot\bootmgfw.efi"
$script:WindowsBackupRelativePath = "EFI\Microsoft\Boot\bootmgfw.libertix-windows.efi"
$script:PreferredGrubRelativePath = "EFI\Microsoft\Boot\grubx64.efi"
$script:PreferredMokManagerRelativePath = "EFI\Microsoft\Boot\mmx64.efi"
$script:PreferredGrubConfigRelativePath = "EFI\Microsoft\Boot\grub.cfg"
$script:EspManifestRelativePath = "EFI\Libertix\preferred-boot-path.json"

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

    if (Test-Path -LiteralPath $archiveManifest -PathType Leaf) {
        $existing = Get-Content -LiteralPath $archiveManifest -Raw -Encoding UTF8 |
            ConvertFrom-Json -ErrorAction Stop
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
    Copy-LibertixPreferredPathFileAtomic `
        -Source $archiveLoader `
        -Destination $espBackup `
        -ExpectedSha256 $windowsLoaderHash

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
            preferred = [ordered]@{
                shimSha256 = [string]$secureBoot.Files.shim.sha256
                grubSha256 = [string]$secureBoot.Files.grub.sha256
                mokManagerSha256 = [string]$secureBoot.Files.mokManager.sha256
                grubConfigSha256 = $grubConfigHash
            }
            secureBootEnabled = [bool]$State.SecureBootEnabled
            status = "prepared"
        }
        Write-LibertixPreferredPathJsonAtomic -Path $archiveManifest -Value $manifest
        Write-LibertixPreferredPathJsonAtomic -Path $espManifest -Value $manifest

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

        $manifest.status = "installed"
        $manifest.installedUtc = [DateTime]::UtcNow.ToString("o")
        Write-LibertixPreferredPathJsonAtomic -Path $archiveManifest -Value $manifest
        Write-LibertixPreferredPathJsonAtomic -Path $espManifest -Value $manifest
        & $WriteLog "Preferred Windows boot path installed and hash-verified."
        return $manifest
    } finally {
        if ([IO.File]::Exists($stagedGrubConfig)) {
            [IO.File]::Delete($stagedGrubConfig)
        }
    }
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
            $espOriginalHash -notmatch '^[0-9a-f]{64}$' -or
            -not (Test-Path -LiteralPath $espBackup -PathType Leaf) -or
            (Get-LibertixPreferredPathHash -Path $espBackup) -ne $espOriginalHash
        ) {
            throw "ESP preferred boot manifest or Windows loader backup is invalid."
        }
        if (
            -not (Test-Path -LiteralPath $archiveLoader -PathType Leaf) -or
            (Get-LibertixPreferredPathHash -Path $archiveLoader) -ne $espOriginalHash
        ) {
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

    $ownedFiles = @(
        @{ RelativePath = $script:PreferredGrubRelativePath; Hash = [string]$manifest.preferred.grubSha256 },
        @{ RelativePath = $script:PreferredMokManagerRelativePath; Hash = [string]$manifest.preferred.mokManagerSha256 },
        @{ RelativePath = $script:PreferredGrubConfigRelativePath; Hash = [string]$manifest.preferred.grubConfigSha256 },
        @{ RelativePath = $script:WindowsBackupRelativePath; Hash = $originalHash },
        @{ RelativePath = $script:EspManifestRelativePath; Hash = "" }
    )
    foreach ($owned in $ownedFiles) {
        $path = Join-Path $EspRoot $owned.RelativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }
        if (
            $owned.Hash -and
            (Get-LibertixPreferredPathHash -Path $path) -ne [string]$owned.Hash
        ) {
            throw "Preferred boot cleanup refused a file whose hash changed: $path"
        }
        [IO.File]::Delete($path)
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
    Install-LibertixPreferredBootPath, Restore-LibertixPreferredBootPath
