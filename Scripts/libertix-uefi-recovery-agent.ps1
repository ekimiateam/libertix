param(
    [Parameter(Mandatory = $true)][string]$StatePath,
    [ValidateSet("Check", "Prompt", "Cancel")][string]$Action = "Check"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-AgentLog {
    param([Parameter(Mandatory = $true)][string]$Message)

    $root = Split-Path -Parent $StatePath
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Add-Content -LiteralPath (Join-Path $root "recovery-agent.log") -Value (
        "[{0}] {1}" -f (Get-Date -Format o), $Message
    )
}

function Read-EnvValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $line = Get-Content -LiteralPath $Path | Where-Object {
        $_ -match "^$([regex]::Escape($Name))="
    } | Select-Object -First 1
    if (-not $line) {
        return $null
    }
    return ($line -replace "^$([regex]::Escape($Name))=", "").Trim()
}

function Save-State {
    param([Parameter(Mandatory = $true)]$State)

    $State.LastCheckedUtc = [DateTime]::UtcNow.ToString("o")
    $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Assert-RecoveryState {
    param([Parameter(Mandatory = $true)]$State)

    $expectedRoot = (Join-Path $env:ProgramData "Libertix\UefiRecovery") + "\"
    $fullRoot = [IO.Path]::GetFullPath([string]$State.RecoveryRoot)
    if (-not $fullRoot.StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Recovery state is outside the Libertix recovery root."
    }
    if ([IO.Path]::GetFullPath($StatePath) -ne (Join-Path $fullRoot "state.json")) {
        throw "Recovery state path does not match its declared recovery root."
    }
    foreach ($path in @($State.PayloadRoot, $State.ConfigPath)) {
        if (-not [IO.Path]::GetFullPath([string]$path).StartsWith($fullRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Recovery payload path is outside the declared recovery root."
        }
    }
}

function Test-RecoveryPayload {
    param([Parameter(Mandatory = $true)]$State)

    $manifestPath = Join-Path $State.RecoveryRoot "payload-manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Recovery payload manifest is missing."
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    foreach ($item in @($manifest.Files)) {
        $path = Join-Path $State.PayloadRoot ([string]$item.RelativePath)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Recovery payload file is missing: $($item.RelativePath)"
        }
        $info = Get-Item -LiteralPath $path
        if ([int64]$info.Length -ne [int64]$item.Length) {
            throw "Recovery payload length mismatch: $($item.RelativePath)"
        }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne [string]$item.Sha256) {
            throw "Recovery payload hash mismatch: $($item.RelativePath)"
        }
    }
}

function Test-LinuxPartitionPresent {
    param([Parameter(Mandatory = $true)]$State)

    if ($null -eq $State.SystemDiskNumber -or $null -eq $State.ExpectedLinuxPartitionSize) {
        return $false
    }
    $expectedSize = [int64]$State.ExpectedLinuxPartitionSize
    $tolerance = 256MB
    $linuxGptType = "{0fc63daf-8483-4772-8e79-3d69d8477de4}"
    $matches = @(
        Get-Partition -DiskNumber ([int]$State.SystemDiskNumber) -ErrorAction Stop |
            Where-Object {
                [math]::Abs([int64]$_.Size - $expectedSize) -le $tolerance -and
                ($_.GptType -eq $linuxGptType -or $_.Type -match "Linux")
            }
    )
    return $matches.Count -eq 1
}

function Remove-RecoveryArtifacts {
    param([Parameter(Mandatory = $true)]$State)

    schtasks.exe /Delete /TN $State.TaskName /F 2>$null | Out-Null
    if (-not [string]::IsNullOrWhiteSpace([string]$State.PromptTaskName)) {
        schtasks.exe /Delete /TN $State.PromptTaskName /F 2>$null | Out-Null
    }
    $root = [IO.Path]::GetFullPath([string]$State.RecoveryRoot)
    $quotedRoot = '"' + $root.Replace('"', '""') + '"'
    Start-Process -FilePath "$env:ComSpec" -ArgumentList "/c ping 127.0.0.1 -n 3 > nul & rmdir /s /q $quotedRoot" -WindowStyle Hidden
}

function Start-FallbackUi {
    param([Parameter(Mandatory = $true)]$State)

    $exe = Join-Path $State.PayloadRoot "Libertix.exe"
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "Cached Libertix.exe is missing."
    }
    $State.Phase = "FallbackPrompted"
    Save-State -State $State
    Write-AgentLog "BootNext returned to Windows without a live marker; opening the firmware fallback prompt."
    Start-Process -FilePath $exe -ArgumentList @(
        "--uefi-bootnext-failed",
        "--uefi-recovery-state",
        $StatePath
    )
}

try {
    $state = Get-Content -LiteralPath $StatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    Assert-RecoveryState -State $state
    Test-RecoveryPayload -State $state
    Write-AgentLog "Recovery agent started. action=$Action phase=$($state.Phase)"

    if ($Action -eq "Cancel") {
        $installerScript = Join-Path $state.PayloadRoot "Scripts\libertix-uefi-install.ps1"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installerScript -Revert
        if ($LASTEXITCODE -ne 0) {
            throw "UEFI revert failed with rc=$LASTEXITCODE."
        }
        Write-AgentLog "Fallback was declined; UEFI transaction reverted."
        Remove-RecoveryArtifacts -State $state
        exit 0
    }

    $liveStarted = Join-Path $state.RecoveryRoot "live-started.env"
    $installSuccess = Join-Path $state.RecoveryRoot "install-success.env"
    $liveFailed = Join-Path $state.RecoveryRoot "live-failed.env"
    $successRunId = Read-EnvValue -Path $installSuccess -Name "LIBERTIX_UEFI_RECOVERY_RUN_ID"
    $successState = Read-EnvValue -Path $installSuccess -Name "LIBERTIX_UEFI_RECOVERY_STATE"

    if ($successRunId -eq [string]$state.RunId -and $successState -eq "install-success") {
        if (-not (Test-LinuxPartitionPresent -State $state)) {
            throw "Live success marker exists but the expected Linux partition is absent."
        }
        $state.Phase = "Completed"
        Save-State -State $state
        Write-AgentLog "Live success and Linux partition verified; removing temporary recovery payload."
        Remove-RecoveryArtifacts -State $state
        exit 0
    }

    $failedRunId = Read-EnvValue -Path $liveFailed -Name "LIBERTIX_UEFI_RECOVERY_RUN_ID"
    if ($failedRunId -eq [string]$state.RunId) {
        $state.Phase = "LiveFailed"
        Save-State -State $state
        Write-AgentLog "The live installer started but reported a failure; fallback is not retried automatically."
        exit 2
    }

    $startedRunId = Read-EnvValue -Path $liveStarted -Name "LIBERTIX_UEFI_RECOVERY_RUN_ID"
    if ($startedRunId -eq [string]$state.RunId) {
        $state.Phase = "LiveStartedWithoutResult"
        Save-State -State $state
        Write-AgentLog "Live marker exists without a final result; preserving recovery files and logs."
        exit 3
    }

    if ([string]$state.Phase -eq "FallbackPrompted" -or [string]$state.Phase -eq "FallbackRunning" -or [string]$state.Phase -eq "AwaitingFallbackReboot") {
        Write-AgentLog "Fallback was already offered or is running; no duplicate prompt is started."
        exit 0
    }

    if ($Action -eq "Prompt") {
        Start-FallbackUi -State $state
        exit 0
    }

    $state.Phase = "FallbackNeeded"
    Save-State -State $state
    Write-AgentLog "BootNext returned to Windows without a live marker; waiting for the interactive fallback prompt."
    exit 0
} catch {
    try { Write-AgentLog "ERROR: $($_.Exception.Message)" } catch {}
    Write-Error $_.Exception.Message
    exit 1
}
