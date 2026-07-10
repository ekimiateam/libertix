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

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$releaseDirName = [string]$config.release_dir_name
$disableDefender = [bool]$config.disable_defender

$documents = [Environment]::GetFolderPath("MyDocuments")
$releasePath = Join-Path $documents $releaseDirName

if ($disableDefender) {
    if (-not (Get-Command Set-MpPreference -ErrorAction SilentlyContinue)) {
        throw "Defender preparation was requested but Set-MpPreference is unavailable"
    }
    New-Item -ItemType Directory -Path $releasePath -Force | Out-Null

    Add-MpPreference -ExclusionPath $releasePath -ErrorAction Stop
    Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
    # Windows can surface SecHealthUI above the wizard after this setting changes.
    # It is only a notification surface; closing it keeps VNC automation focused.
    Get-Process -Name "SecHealthUI" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    $status = Get-MpComputerStatus -ErrorAction Stop
    $preferences = Get-MpPreference -ErrorAction Stop
    if ($preferences.ExclusionPath -notcontains $releasePath) {
        throw "Defender exclusion was not applied to $releasePath"
    }
    $preparedState = if ($status.RealTimeProtectionEnabled) {
        "exclusion-only"
    } else {
        "realtime-disabled"
    }
    Write-Result -Name "DEFENDER_PREPARED" -Value $preparedState
    Write-Result -Name "DEFENDER_REALTIME" -Value ([string]$status.RealTimeProtectionEnabled)
    Write-Result -Name "DEFENDER_EXCLUSION" -Value $releasePath
}
else {
    Write-Result -Name "DEFENDER_PREPARED" -Value "not-requested"
    Write-Result -Name "DEFENDER_EXCLUSION" -Value $releasePath
}
