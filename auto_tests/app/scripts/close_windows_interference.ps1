#requires -Version 5.1

param([Parameter(Mandatory = $true)][string]$ConfigPath)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$kind = [string]$config.kind
$processName = switch ($kind) {
    "settings" { "SystemSettings" }
    "security" { "SecHealthUI" }
    default { throw "Unsupported Windows interference kind: $kind" }
}

$interactiveSession = Get-Process -Name explorer -ErrorAction Stop |
    Sort-Object StartTime -Descending |
    Select-Object -First 1 -ExpandProperty SessionId
$libertixBefore = @(
    Get-CimInstance Win32_Process -Filter "Name='Libertix.exe'" -ErrorAction Stop |
        Where-Object { $_.SessionId -eq $interactiveSession }
)
if ($libertixBefore.Count -lt 1) {
    throw "Libertix is not running in the interactive session before closing $processName."
}

$targets = @(
    Get-Process -Name $processName -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $interactiveSession }
)
foreach ($target in $targets) {
    Stop-Process -Id $target.Id -Force -ErrorAction Stop
}

$deadline = [DateTime]::UtcNow.AddSeconds(10)
do {
    $remaining = @(
        Get-Process -Name $processName -ErrorAction SilentlyContinue |
            Where-Object { $_.SessionId -eq $interactiveSession }
    )
    if ($remaining.Count -eq 0) {
        break
    }
    Start-Sleep -Milliseconds 200
} while ([DateTime]::UtcNow -lt $deadline)

if ($remaining.Count -ne 0) {
    throw "$processName remains open in the interactive session."
}

$libertixAfter = @(
    Get-CimInstance Win32_Process -Filter "Name='Libertix.exe'" -ErrorAction Stop |
        Where-Object { $_.SessionId -eq $interactiveSession }
)
if ($libertixAfter.Count -lt 1) {
    throw "Libertix stopped while closing $processName."
}

Write-Output "INTERFERENCE_CLOSED=True"
Write-Output "INTERFERENCE_KIND=$kind"
Write-Output "CLOSED_PROCESS_COUNT=$($targets.Count)"
Write-Output "LIBERTIX_PROCESS_COUNT=$($libertixAfter.Count)"
