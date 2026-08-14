#requires -Version 5.1

param([Parameter(Mandatory = $true)][string]$ConfigPath)

$ErrorActionPreference = "Stop"
$null = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

$explorers = @(
    Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop |
        Sort-Object CreationDate -Descending
)
$logonUiProcesses = @(
    Get-CimInstance Win32_Process -Filter "Name='LogonUI.exe'" -ErrorAction Stop |
        Sort-Object CreationDate -Descending
)
$sessionId = if ($explorers.Count -gt 0) {
    [int]$explorers[0].SessionId
} elseif ($logonUiProcesses.Count -gt 0) {
    [int]$logonUiProcesses[0].SessionId
} else {
    -1
}
$loginScreenPresent = @(
    $logonUiProcesses | Where-Object { [int]$_.SessionId -eq $sessionId }
).Count -gt 0
$explorerSessionReady = $explorers.Count -gt 0 -and -not $loginScreenPresent
$setupProcesses = @(
    Get-CimInstance Win32_Process -Filter "Name='SystemSettings.exe'" -ErrorAction Stop |
        Where-Object { [int]$_.SessionId -eq $sessionId }
)

Write-Output ("EXPLORER_SESSION_READY={0}" -f $explorerSessionReady)
Write-Output ("SETUP_EXPERIENCE_PRESENT={0}" -f ($setupProcesses.Count -gt 0))
Write-Output ("LOGIN_SCREEN_PRESENT={0}" -f $loginScreenPresent)
Write-Output "SESSION_ID=$sessionId"
