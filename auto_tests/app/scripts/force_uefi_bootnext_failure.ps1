param(
    [int]$TimeoutSeconds = 900
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$root = Join-Path $env:ProgramData "Libertix\UefiRecovery"

while ([DateTime]::UtcNow -lt $deadline) {
    $statePath = Get-ChildItem -LiteralPath $root -Filter "state.json" -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    if ($statePath) {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ([string]$state.Phase -eq "AwaitingReboot") {
            bcdedit.exe /set "{fwbootmgr}" bootsequence "{bootmgr}" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Unable to redirect the next firmware boot to Windows Boot Manager."
            }
            Write-Output "FORCED_BOOTNEXT_FAILURE=true"
            Write-Output "STATE_PATH=$statePath"
            bcdedit.exe /enum "{fwbootmgr}" /v
            exit 0
        }
    }
    Start-Sleep -Seconds 1
}

throw "Timed out waiting for the UEFI recovery state to reach AwaitingReboot."
