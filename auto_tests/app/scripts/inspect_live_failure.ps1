param(
    [Parameter(Mandatory = $true)][string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$null = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 -ErrorAction Stop |
    ConvertFrom-Json -ErrorAction Stop

function Read-EnvValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }
    $prefix = "$Name="
    $line = Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop |
        Where-Object { $_.StartsWith($prefix, [StringComparison]::Ordinal) } |
        Select-Object -Last 1
    if ($null -eq $line) {
        return ""
    }
    return $line.Substring($prefix.Length).Trim()
}

$systemDrive = [string]$env:SystemDrive
if ($systemDrive -notmatch '^[A-Za-z]:$') {
    throw "Windows did not expose a valid system drive."
}
$root = Join-Path $systemDrive "LibertixInstallLogs\Linux\latest"
$resultPath = Join-Path $root "result.env"
$success = Read-EnvValue -Path $resultPath -Name "LIBERTIX_INSTALL_SUCCESS"
if ($success -ne "false") {
    Write-Output "LIVE_FAILURE_PRESENT=False"
    exit 0
}

$failurePath = Join-Path $root "failure"
$message = Read-EnvValue -Path $failurePath -Name "error"
if ([string]::IsNullOrWhiteSpace($message)) {
    $message = "Live installer failed without a structured error message"
}
$message = (($message -replace '[\r\n]+', ' ') -replace '\s{2,}', ' ').Trim()
if ($message.Length -gt 1000) {
    $message = $message.Substring(0, 1000)
}

Write-Output "LIVE_FAILURE_PRESENT=True"
Write-Output "LIVE_FAILURE_MESSAGE=$message"
Write-Output "LIVE_FAILURE_STAGE=$(Read-EnvValue -Path $failurePath -Name 'stage')"
Write-Output "LIVE_FAILURE_EXIT_CODE=$(Read-EnvValue -Path $resultPath -Name 'LIBERTIX_INSTALL_RC')"
Write-Output "LIVE_FAILURE_ROLLBACK=$(Read-EnvValue -Path $resultPath -Name 'LIBERTIX_INSTALL_ROLLBACK')"
Write-Output "LIVE_FAILURE_RUN_ID=$(Read-EnvValue -Path $resultPath -Name 'LIBERTIX_INSTALL_RUN_ID')"
