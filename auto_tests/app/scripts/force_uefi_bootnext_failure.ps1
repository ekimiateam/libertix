param(
    [string]$ConfigPath = "",
    [int]$TimeoutSeconds = 900
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop
    if ($config.PSObject.Properties.Name -contains "timeout_seconds") {
        $TimeoutSeconds = [int]$config.timeout_seconds
    }
}
if ($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 900) {
    throw "The BootNext fault timeout must be between 1 and 900 seconds."
}

$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$root = Join-Path $env:ProgramData "Libertix\UefiRecovery"

while ([DateTime]::UtcNow -lt $deadline) {
    $statePath = Get-ChildItem -LiteralPath $root -Filter "state.json" -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    if ($statePath) {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ([string]$state.Phase -eq "AwaitingReboot") {
            $bootId = (
                Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            ).LastBootUpTime.ToUniversalTime().ToString("o")
            $setOutput = @(bcdedit.exe /set "{fwbootmgr}" bootsequence "{bootmgr}" 2>&1)
            if ($LASTEXITCODE -ne 0) {
                throw (
                    "Unable to redirect the next firmware boot to Windows Boot Manager: " +
                    ($setOutput -join " | ")
                )
            }
            $firmwareOutput = @(bcdedit.exe /enum "{fwbootmgr}" /v 2>&1)
            if ($LASTEXITCODE -ne 0) {
                throw (
                    "Unable to verify the injected firmware boot sequence: " +
                    ($firmwareOutput -join " | ")
                )
            }
            Write-Output "FORCED_BOOTNEXT_FAILURE=True"
            Write-Output "STATE_PATH=$statePath"
            Write-Output "STATE_PHASE=AwaitingReboot"
            Write-Output "WINDOWS_BOOT_ID=$bootId"
            Write-Output "RESULT=OK"
            exit 0
        }
    }
    Start-Sleep -Seconds 1
}

throw "Timed out waiting for the UEFI recovery state to reach AwaitingReboot."
