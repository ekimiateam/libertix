param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Result {
    param([string]$Name, [string]$Value)
    Write-Output ("{0}={1}" -f $Name, $Value)
}

function Copy-WithRobocopy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $output = & robocopy.exe `
        $Source `
        $Destination `
        /E /R:3 /W:2 /COPY:DAT /DCOPY:DAT /NFL /NDL /NJH /NJS /NP

    $code = $LASTEXITCODE
    if ($code -gt 7) {
        throw ("Robocopy failed, code={0}; output={1}" -f $code, ($output -join " | "))
    }
}

function Get-FreeDriveLetter {
    $used = @{}
    Get-PSDrive -PSProvider FileSystem | ForEach-Object { $used[$_.Name.ToUpperInvariant()] = $true }
    Get-SmbMapping -ErrorAction SilentlyContinue | ForEach-Object {
        $driveMatch = [regex]::Match([string]$_.LocalPath, "^([A-Z]):$")
        if ($driveMatch.Success) {
            $used[$driveMatch.Groups[1].Value.ToUpperInvariant()] = $true
        }
    }

    foreach ($letter in @("Y", "X", "W", "V", "U", "T", "S", "R", "Q", "P")) {
        if (-not $used.ContainsKey($letter)) {
            return ($letter + ":")
        }
    }

    throw "No free drive letter is available to mount the Samba share"
}

function Convert-SharePathToMappedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Share,
        [Parameter(Mandatory = $true)]
        [string]$Drive
    )

    $normalizedShare = $Share.TrimEnd("\")
    if (-not $Path.StartsWith($normalizedShare, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("Chemin hors partage Samba: " + $Path)
    }

    $suffix = $Path.Substring($normalizedShare.Length).TrimStart("\")
    if ($suffix) {
        return (Join-Path ($Drive + "\") $suffix)
    }
    return ($Drive + "\")
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$mapped = $false
$mappedDrive = $null

if ([string]$config.release_dir_name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
    throw "release_dir_name must be a simple directory name"
}

try {
    $sourcePath = $config.source

    # Prefer the UNC path when available. A temporary non-persistent mapping
    # avoids depending on a stale drive letter in the interactive profile.
    if (-not (Test-Path -LiteralPath $config.source -PathType Container)) {
        $mappedDrive = Get-FreeDriveLetter
        New-SmbMapping `
            -LocalPath $mappedDrive `
            -RemotePath $config.samba_unc `
            -UserName $config.samba_username `
            -Password $config.samba_password `
            -Persistent $false |
            Out-Null
        $mapped = $true

        $sourcePath = Convert-SharePathToMappedPath `
            -Path $config.source `
            -Share $config.samba_unc `
            -Drive $mappedDrive
    }

    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
        throw "The release directory is missing from the Samba share"
    }

    $documents = [Environment]::GetFolderPath("MyDocuments")
    $target = Join-Path $documents $config.release_dir_name

    # A previous executable can lock the release copy or report state from an
    # earlier run, so stop it before replacing the local deployment.
    Get-ScheduledTask -TaskName "LibertixAutoInstall_*" -ErrorAction SilentlyContinue |
        Unregister-ScheduledTask -Confirm:$false -ErrorAction Stop
    Get-Process -Name "Libertix" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction Stop
    Start-Sleep -Milliseconds 500
    if (Get-Process -Name "Libertix" -ErrorAction SilentlyContinue) {
        throw "Ancien processus Libertix encore actif"
    }

    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }

    Copy-WithRobocopy -Source $sourcePath -Destination $target

    $localExe = Join-Path $target $config.relative_executable
    if (-not (Test-Path -LiteralPath $localExe -PathType Leaf)) {
        throw "Libertix.exe is missing after the local copy"
    }
    $sourceExe = Join-Path $sourcePath $config.relative_executable
    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceExe).Hash.ToLowerInvariant()
    $localHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $localExe).Hash.ToLowerInvariant()
    if ($sourceHash -ne $localHash) {
        throw "The local Libertix.exe hash does not match the Samba release"
    }

    Write-Result -Name "LOCAL_EXE" -Value $localExe
    Write-Result -Name "LOCAL_EXE_SHA256" -Value $localHash
}
finally {
    if ($mapped -and $mappedDrive) {
        Remove-SmbMapping -LocalPath $mappedDrive -Force -UpdateProfile -ErrorAction SilentlyContinue
    }
}
