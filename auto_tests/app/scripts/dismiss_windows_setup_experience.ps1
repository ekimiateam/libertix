#requires -Version 5.1

param([Parameter(Mandatory = $true)][string]$ConfigPath)

$ErrorActionPreference = "Stop"

$null = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop |
    Sort-Object CreationDate -Descending |
    Select-Object -First 1
if (-not $explorer) {
    throw "No interactive Explorer session is available."
}

# The caller invokes this script only after the guest inspection script found
# System Settings in the active Explorer session. Restrict termination to that
# session so unrelated background processes remain intact.
$setupProcesses = @(
    Get-CimInstance Win32_Process -Filter "Name='SystemSettings.exe'" -ErrorAction Stop |
        Where-Object { [int]$_.SessionId -eq [int]$explorer.SessionId }
)
foreach ($process in $setupProcesses) {
    Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
}

$deadline = [DateTime]::UtcNow.AddSeconds(15)
do {
    $remaining = @(
        Get-CimInstance Win32_Process -Filter "Name='SystemSettings.exe'" -ErrorAction Stop |
            Where-Object { [int]$_.SessionId -eq [int]$explorer.SessionId }
    )
    if ($remaining.Count -eq 0) { break }
    if ([DateTime]::UtcNow -ge $deadline) {
        throw "The identified Windows setup experience did not close."
    }
    Start-Sleep -Milliseconds 500
} while ($true)

Write-Output "WINDOWS_SETUP_EXPERIENCE_DISMISSED=True"
Write-Output "TERMINATED_PROCESS_COUNT=$($setupProcesses.Count)"
