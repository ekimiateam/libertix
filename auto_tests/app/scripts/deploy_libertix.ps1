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

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

# Les VM de validation ont normalement Z: monté vers le partage Samba.
# Si Z: est absent, cassé ou pointe ailleurs, on le recrée avec les identifiants
# de test fournis dans le JSON temporaire. La commande Python reste donc lisible
# et ne contient pas le mot de passe Samba.
$mapping = Get-SmbMapping -LocalPath "Z:" -ErrorAction SilentlyContinue
if ($mapping -and (($mapping.RemotePath -ne $config.samba_unc) -or ($mapping.Status -ne "OK"))) {
    Remove-SmbMapping -LocalPath "Z:" -Force -UpdateProfile -ErrorAction SilentlyContinue
    $mapping = $null
}

if (-not $mapping) {
    New-SmbMapping `
        -LocalPath "Z:" `
        -RemotePath $config.samba_unc `
        -UserName $config.samba_username `
        -Password $config.samba_password `
        -Persistent $true |
        Out-Null
}

if (-not (Test-Path "Z:\")) {
    throw "Z: reste inaccessible après reconnexion"
}

if (-not (Test-Path -LiteralPath $config.source -PathType Container)) {
    throw "Dossier release absent du partage Samba"
}

$documents = [Environment]::GetFolderPath("MyDocuments")
$target = Join-Path $documents $config.release_dir_name

# Relance propre : pas d'ancien processus, pas d'ancienne copie locale.
Unregister-ScheduledTask -TaskName "LibertixAutoTest" -Confirm:$false -ErrorAction SilentlyContinue
Get-Process -Name "Libertix", "LinuxGate" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction Stop
Start-Sleep -Milliseconds 500
if (Get-Process -Name "Libertix", "LinuxGate" -ErrorAction SilentlyContinue) {
    throw "Ancien processus Libertix/LinuxGate encore actif"
}

if (Test-Path -LiteralPath $target) {
    Remove-Item -LiteralPath $target -Recurse -Force
}

Copy-WithRobocopy -Source $config.source -Destination $target

$localExe = Join-Path $target $config.relative_executable
if (-not (Test-Path -LiteralPath $localExe -PathType Leaf)) {
    throw "Libertix.exe absent après copie locale"
}

Write-Result -Name "LOCAL_EXE" -Value $localExe
