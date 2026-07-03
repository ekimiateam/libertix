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
        throw ("Échec robocopy, code={0}; sortie={1}" -f $code, ($output -join " | "))
    }
}

function Get-FreeDriveLetter {
    $used = @{}
    Get-PSDrive -PSProvider FileSystem | ForEach-Object { $used[$_.Name.ToUpperInvariant()] = $true }
    Get-SmbMapping -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.LocalPath -match "^([A-Z]):$") {
            $used[$Matches[1].ToUpperInvariant()] = $true
        }
    }

    foreach ($letter in @("Y", "X", "W", "V", "U", "T", "S", "R", "Q", "P")) {
        if (-not $used.ContainsKey($letter)) {
            return ($letter + ":")
        }
    }

    throw "Aucune lettre de lecteur libre pour monter le partage Samba"
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

try {
    $sourcePath = $config.source

    # On utilise l'UNC directement quand il est disponible. Sinon on monte un
    # lecteur temporaire non persistant, sans dépendre d'un ancien Z: utilisateur.
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
        throw "Dossier release absent du partage Samba"
    }

    $documents = [Environment]::GetFolderPath("MyDocuments")
    $target = Join-Path $documents $config.release_dir_name

    # Relance propre : pas d'ancien processus, pas d'ancienne copie locale.
    Unregister-ScheduledTask -TaskName "LibertixAutoTest" -Confirm:$false -ErrorAction SilentlyContinue
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
        throw "Libertix.exe absent après copie locale"
    }

    Write-Result -Name "LOCAL_EXE" -Value $localExe
}
finally {
    if ($mapped -and $mappedDrive) {
        Remove-SmbMapping -LocalPath $mappedDrive -Force -UpdateProfile -ErrorAction SilentlyContinue
    }
}
