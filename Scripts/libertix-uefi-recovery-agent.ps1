param(
    [Parameter(Mandatory = $true)][string]$StatePath,
    [ValidateSet("Check", "Prompt", "Cancel")][string]$Action = "Check",
    [ValidateRange(0, 2147483647)][int]$WaitForProcessId = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$SystemDrive = [string]$env:SystemDrive
if ($SystemDrive -notmatch "^[A-Za-z]:$") {
    throw "SystemDrive must be a valid Windows drive designator."
}
$WindowsShareRoot = Join-Path $SystemDrive "ProgramData\Libertix\WindowsShare"

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
    # This agent runs at startup and decides, from this document alone, which
    # recovery phase applies. A torn write would leave it unable to determine
    # that phase, so publish it with a same-directory atomic rename.
    param([Parameter(Mandatory = $true)]$State)

    $State.LastCheckedUtc = [DateTime]::UtcNow.ToString("o")
    $fullPath = [IO.Path]::GetFullPath($StatePath)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporaryPath = Join-Path $directory ".$(Split-Path -Leaf $fullPath).$([Guid]::NewGuid().ToString('N')).tmp"
    $backupPath = Join-Path $directory ".$(Split-Path -Leaf $fullPath).$([Guid]::NewGuid().ToString('N')).bak"
    try {
        $json = $State | ConvertTo-Json -Depth 8
        $encoding = New-Object Text.UTF8Encoding($false)
        $stream = New-Object IO.FileStream(
            $temporaryPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough
        )
        try {
            $writer = New-Object IO.StreamWriter($stream, $encoding)
            try {
                $writer.Write($json)
                $writer.Write("`n")
                $writer.Flush()
                $stream.Flush($true)
            } finally {
                $writer.Dispose()
            }
        } finally {
            $stream.Dispose()
        }

        if ([IO.File]::Exists($fullPath)) {
            [IO.File]::Replace($temporaryPath, $fullPath, $backupPath)
        } else {
            [IO.File]::Move($temporaryPath, $fullPath)
        }
    } finally {
        if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
        if ([IO.File]::Exists($backupPath)) { [IO.File]::Delete($backupPath) }
    }
}

function Assert-RecoveryState {
    param([Parameter(Mandatory = $true)]$State)

    $expectedRoot = (Join-Path $env:ProgramData "Libertix\UefiRecovery") + "\"
    if (
        [string]$State.RunId -notmatch '^[0-9a-f]{32}$' -or
        [string]$State.PlanId -notmatch '^[0-9a-f]{32}$' -or
        [string]$State.PlanId -ne [string]$State.RunId
    ) {
        throw "Recovery state plan identity is invalid."
    }
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

function Read-ValidatedExecutionState {
    param([Parameter(Mandatory = $true)]$RecoveryState)

    $executionStatePath = Join-Path $RecoveryState.RecoveryRoot "installation-state.json"
    $modulePath = Join-Path `
        $RecoveryState.PayloadRoot `
        "Scripts\modules\Libertix.InstallationState.psm1"
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Installation state validation module is missing."
    }
    Import-Module -Name $modulePath -Force -ErrorAction Stop
    $executionState = Read-LibertixExecutionState -Path $executionStatePath
    if ([string]$executionState.planId -ne [string]$RecoveryState.PlanId) {
        throw "Installation state does not belong to the UEFI recovery transaction."
    }
    return $executionState
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

    if (
        $null -eq $State.SystemDiskNumber -or
        [string]::IsNullOrWhiteSpace([string]$State.SystemDiskUniqueId) -or
        [string]::IsNullOrWhiteSpace([string]$State.SystemDiskPartitionTableId) -or
        $null -eq $State.SystemDiskSize -or
        $null -eq $State.ExpectedLinuxPartitionOffset -or
        $null -eq $State.ExpectedLinuxPartitionSize
    ) {
        return $false
    }
    $disk = Get-Disk -Number ([int]$State.SystemDiskNumber) -ErrorAction Stop
    if (
        ([string]$disk.UniqueId).Trim() -ne ([string]$State.SystemDiskUniqueId).Trim() -or
        [int64]$disk.Size -ne [int64]$State.SystemDiskSize -or
        [string]$disk.PartitionStyle -ne "GPT" -or
        -not $disk.Guid
    ) {
        return $false
    }
    $partitionTableId = "gpt:$(([Guid]$disk.Guid).ToString('D').ToLowerInvariant())"
    if ($partitionTableId -ne [string]$State.SystemDiskPartitionTableId) {
        return $false
    }
    $expectedSize = [int64]$State.ExpectedLinuxPartitionSize
    $expectedOffset = [int64]$State.ExpectedLinuxPartitionOffset
    $linuxGptType = "{0fc63daf-8483-4772-8e79-3d69d8477de4}"
    $installerPartitions = @(
        Get-Partition -DiskNumber ([int]$State.SystemDiskNumber) -ErrorAction Stop |
            Where-Object {
                [int64]$_.Offset -eq $expectedOffset -and
                [int64]$_.Size -eq $expectedSize -and
                ($_.GptType -eq $linuxGptType -or $_.Type -match "Linux")
            }
    )
    return $installerPartitions.Count -eq 1
}

function Remove-RecoveryTasks {
    param([Parameter(Mandatory = $true)]$State)

    $taskNames = @([string]$State.TaskName, [string]$State.PromptTaskName) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($taskName in $taskNames) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            throw "Recovery task still exists after removal: $taskName"
        }
    }
}

function Remove-StartupRecoveryTask {
    param([Parameter(Mandatory = $true)]$State)

    $taskName = [string]$State.TaskName
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        throw "Recovery startup task still exists after removal: $taskName"
    }
}

function Remove-TemporaryRecoveryArtifacts {
    param([Parameter(Mandatory = $true)]$State)

    $temporaryArtifactsModule = Join-Path `
        $State.PayloadRoot `
        "Scripts\modules\Libertix.TemporaryArtifacts.psm1"
    Import-Module -Name $temporaryArtifactsModule -Force -ErrorAction Stop
    Remove-LibertixTransactionDownloads `
        -SystemDrive $SystemDrive `
        -PlanId ([string]$State.PlanId)
    Remove-LibertixUefiToolArtifacts -SystemDrive $SystemDrive
}

function Save-UefiTransactionArchive {
    param([Parameter(Mandatory = $true)]$State)

    $source = Join-Path $SystemDrive "LibertixTools\uefi-transaction.json"
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "UEFI transaction state is missing before permanent archival."
    }
    $transaction = Get-Content -LiteralPath $source -Raw -Encoding UTF8 -ErrorAction Stop |
        ConvertFrom-Json -ErrorAction Stop
    if ([string]$transaction.RecoveryRunId -ne [string]$State.RunId) {
        throw "UEFI transaction state belongs to another recovery session."
    }
    $destination = Join-Path $State.RecoveryRoot "uefi-transaction.json"
    $temporary = Join-Path $State.RecoveryRoot ".uefi-transaction.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        Copy-Item -LiteralPath $source -Destination $temporary -Force -ErrorAction Stop
        if ([IO.File]::Exists($destination)) {
            [IO.File]::Replace($temporary, $destination, $null)
        } else {
            [IO.File]::Move($temporary, $destination)
        }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
    Write-AgentLog "UEFI transaction state archived permanently."
}

function Restore-UefiTransactionArchive {
    param([Parameter(Mandatory = $true)]$State)

    $destination = Join-Path $SystemDrive "LibertixTools\uefi-transaction.json"
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        $activeTransaction = Get-Content `
            -LiteralPath $destination `
            -Raw `
            -Encoding UTF8 `
            -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
        if ([string]$activeTransaction.RecoveryRunId -ne [string]$State.RunId) {
            throw "Active UEFI transaction state belongs to another recovery session."
        }
        return
    }
    $source = Join-Path $State.RecoveryRoot "uefi-transaction.json"
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Permanent UEFI transaction archive is missing."
    }
    $transaction = Get-Content -LiteralPath $source -Raw -Encoding UTF8 -ErrorAction Stop |
        ConvertFrom-Json -ErrorAction Stop
    if ([string]$transaction.RecoveryRunId -ne [string]$State.RunId) {
        throw "Permanent UEFI transaction archive belongs to another recovery session."
    }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
    $temporary = "$destination.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        Copy-Item -LiteralPath $source -Destination $temporary -Force -ErrorAction Stop
        if ([IO.File]::Exists($destination)) {
            [IO.File]::Replace($temporary, $destination, $null)
        } else {
            [IO.File]::Move($temporary, $destination)
        }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Save-RecoveryLogs {
    param([Parameter(Mandatory = $true)]$State)

    $source = Join-Path $State.RecoveryRoot "recovery-agent.log"
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        return
    }
    $archiveRoot = Join-Path $SystemDrive "LibertixInstallLogs\$($State.RunId)"
    New-Item -ItemType Directory -Path $archiveRoot -Force | Out-Null
    Copy-Item `
        -LiteralPath $source `
        -Destination (Join-Path $archiveRoot "uefi-recovery-agent.log") `
        -Force `
        -ErrorAction Stop
}

function Invoke-WindowsShareFinalize {
    $config = Join-Path $WindowsShareRoot "config.json"
    $script = Join-Path $WindowsShareRoot "mount-linux-readonly.ps1"
    if (-not (Test-Path -LiteralPath $config -PathType Leaf)) { return }
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
        throw "Windows share configuration exists but its script is missing."
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -ConfigPath $config -Finalize
    if ($LASTEXITCODE -ne 0) {
        throw "Windows read-only Linux sharing setup failed with rc=$LASTEXITCODE."
    }
    Write-AgentLog "Windows read-only Linux sharing finalized."
}

function Remove-PendingWindowsSharePayload {
    if (Test-Path -LiteralPath (Join-Path $WindowsShareRoot "pending.marker") -PathType Leaf) {
        Remove-Item -LiteralPath $WindowsShareRoot -Recurse -Force -ErrorAction SilentlyContinue
        Write-AgentLog "Removed pending Windows sharing payload."
    }
}

function Remove-WindowsShareAfterRollback {
    param([Parameter(Mandatory = $true)]$State)

    if (-not (Test-Path -LiteralPath $WindowsShareRoot -PathType Container)) { return }
    $shareLog = Join-Path $WindowsShareRoot "windows-share.log"
    if (Test-Path -LiteralPath $shareLog -PathType Leaf) {
        Copy-Item `
            -LiteralPath $shareLog `
            -Destination (Join-Path $State.RecoveryRoot "windows-share.log") `
            -Force `
            -ErrorAction Stop
    }
    Unregister-ScheduledTask `
        -TaskName "LibertixLinuxReadOnly" `
        -Confirm:$false `
        -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $WindowsShareRoot -Recurse -Force -ErrorAction Stop
    Write-AgentLog "Removed Windows read-only Linux sharing after rollback."
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

function Start-PostInstallResultUi {
    param([Parameter(Mandatory = $true)]$State)

    $resultScript = Join-Path $State.PayloadRoot "Scripts\libertix-post-install-result.ps1"
    $agentPath = Join-Path $State.PayloadRoot "Scripts\libertix-uefi-recovery-agent.ps1"
    if (-not (Test-Path -LiteralPath $resultScript -PathType Leaf)) {
        throw "Post-install result UI is missing from the recovery payload."
    }
    & $resultScript `
        -StatePath (Join-Path $State.RecoveryRoot "post-install-verification.json") `
        -RecoveryScriptPath $agentPath `
        -Firmware uefi `
        -PromptTaskName ([string]$State.PromptTaskName)
}

function Start-PostInstallPromptTask {
    param([Parameter(Mandatory = $true)]$State)

    try {
        Start-ScheduledTask -TaskName ([string]$State.PromptTaskName) -ErrorAction Stop
        Write-AgentLog "Post-install result task was started for the interactive user."
    } catch {
        # InteractiveToken tasks cannot run before their user has logged on.
        # The persistent logon trigger will start it when a session exists.
        Write-AgentLog (
            "Post-install result task remains armed for the next user logon: " +
            $_.Exception.Message
        )
    }
}

function Invoke-VerifiedInstallationSuccess {
    param([Parameter(Mandatory = $true)]$State)

    if (-not (Test-LinuxPartitionPresent -State $State)) {
        throw "Live success marker exists but the expected Linux partition is absent."
    }
    $modulePath = Join-Path `
        $State.PayloadRoot `
        "Scripts\modules\Libertix.PostInstallVerification.psm1"
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Post-install verification module is missing from the recovery payload."
    }
    Import-Module -Name $modulePath -Force -ErrorAction Stop
    $writeLog = { param($Message) Write-AgentLog -Message $Message }
    try {
        Save-UefiTransactionArchive -State $State
        Invoke-WindowsShareFinalize
        Remove-TemporaryRecoveryArtifacts -State $State
        $null = Invoke-LibertixPostInstallVerification `
            -RecoveryRoot ([string]$State.RecoveryRoot) `
            -LogPath (Join-Path $State.RecoveryRoot "recovery-agent.log") `
            -WriteLog $writeLog
        $State.Phase = "Verified"
        Save-State -State $State
    } catch {
        $verificationFailure = $_
        $State.Phase = "VerificationFailed"
        Save-State -State $State
        try {
            $null = Set-LibertixPostInstallFailure `
                -RecoveryRoot ([string]$State.RecoveryRoot) `
                -LogPath (Join-Path $State.RecoveryRoot "recovery-agent.log") `
                -CheckName "post-install-controller" `
                -ErrorMessage $verificationFailure.Exception.Message
        } catch {
            Write-AgentLog (
                "Could not persist the post-install controller failure: " +
                $_.Exception.Message
            )
        }
        throw $verificationFailure
    } finally {
        $verificationResultPath = Join-Path $State.RecoveryRoot "post-install-verification.json"
        $verificationStatus = if (Test-Path -LiteralPath $verificationResultPath -PathType Leaf) {
            try {
                [string](Get-Content `
                    -LiteralPath $verificationResultPath `
                    -Raw `
                    -Encoding UTF8 `
                    -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop).status
            } catch { "unreadable" }
        } else { "missing" }
        if ($verificationStatus -in @("succeeded", "failed")) {
            Remove-StartupRecoveryTask -State $State
            Start-PostInstallPromptTask -State $State
        } else {
            Write-AgentLog (
                "Post-install verification was interrupted with status=" +
                "$verificationStatus; startup recovery remains armed."
            )
        }
        Save-RecoveryLogs -State $State
    }
}

try {
    $state = Get-Content -LiteralPath $StatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    Assert-RecoveryState -State $state
    Test-RecoveryPayload -State $state
    $postInstallModulePath = Join-Path `
        $state.PayloadRoot `
        "Scripts\modules\Libertix.PostInstallVerification.psm1"
    if (-not (Test-Path -LiteralPath $postInstallModulePath -PathType Leaf)) {
        throw "Post-install verification module is missing from the recovery payload."
    }
    Import-Module -Name $postInstallModulePath -Force -ErrorAction Stop
    Set-LibertixShutdownVerificationPriority
    $executionState = Read-ValidatedExecutionState -RecoveryState $state
    Write-AgentLog "Recovery agent started. action=$Action phase=$($state.Phase)"

    $liveStarted = Join-Path $state.RecoveryRoot "live-started.env"
    $installSuccess = Join-Path $state.RecoveryRoot "install-success.env"
    $liveFailed = Join-Path $state.RecoveryRoot "live-failed.env"

    if ($Action -eq "Prompt") {
        $postInstallResult = Join-Path $state.RecoveryRoot "post-install-verification.json"
        $linuxBootEvidence = Join-Path $state.RecoveryRoot "installed-linux-boot.json"
        $successRunIdForPrompt = Read-EnvValue `
            -Path $installSuccess `
            -Name "LIBERTIX_UEFI_RECOVERY_RUN_ID"
        if (
            (Test-Path -LiteralPath $postInstallResult -PathType Leaf) -or
            (
                $successRunIdForPrompt -eq [string]$state.RunId -and
                (Test-Path -LiteralPath $linuxBootEvidence -PathType Leaf)
            )
        ) {
            Start-PostInstallResultUi -State $state
            exit 0
        }
        if ($successRunIdForPrompt -eq [string]$state.RunId) {
            Write-AgentLog (
                "The live installation succeeded, but installed Linux has not published " +
                "its first-boot evidence yet; no result window is shown."
            )
            exit 0
        }
        $startedRunIdForPrompt = Read-EnvValue `
            -Path $liveStarted `
            -Name "LIBERTIX_UEFI_RECOVERY_RUN_ID"
        if ($startedRunIdForPrompt -eq [string]$state.RunId) {
            Write-AgentLog "The live installer ran; no firmware fallback prompt is applicable."
            exit 0
        }
        Start-FallbackUi -State $state
        exit 0
    }

    if ($Action -eq "Cancel") {
        $rollbackFromSucceeded = [string]$executionState.status -eq "succeeded"
        if ([string]$executionState.status -ne "rolled-back") {
            Restore-UefiTransactionArchive -State $state
            $installerScript = Join-Path $state.PayloadRoot "Scripts\libertix-uefi-install.ps1"
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installerScript `
                -Revert `
                -ExpectedRecoveryRunId ([string]$state.RunId)
            if ($LASTEXITCODE -ne 0) {
                throw "UEFI revert failed with rc=$LASTEXITCODE."
            }
            Write-AgentLog "Fallback was declined; UEFI transaction reverted."
        } else {
            Write-AgentLog "UEFI transaction was already rolled back; cleanup is continuing."
        }
        if ($rollbackFromSucceeded) {
            Remove-WindowsShareAfterRollback -State $state
        } else {
            Remove-PendingWindowsSharePayload
        }
        Save-RecoveryLogs -State $state
        Remove-TemporaryRecoveryArtifacts -State $state
        Remove-RecoveryTasks -State $state
        exit 0
    }

    $successRunId = Read-EnvValue -Path $installSuccess -Name "LIBERTIX_UEFI_RECOVERY_RUN_ID"
    $successState = Read-EnvValue -Path $installSuccess -Name "LIBERTIX_UEFI_RECOVERY_STATE"

    if (
        $successRunId -eq [string]$state.RunId -and
        $successState -eq "install-success" -and
        [string]$executionState.status -eq "succeeded"
    ) {
        $linuxBootEvidence = Join-Path $state.RecoveryRoot "installed-linux-boot.json"
        if (-not (Test-Path -LiteralPath $linuxBootEvidence -PathType Leaf)) {
            $null = Set-LibertixPostInstallWaitingForLinux `
                -RecoveryRoot ([string]$state.RecoveryRoot) `
                -LogPath (Join-Path $state.RecoveryRoot "recovery-agent.log")
            $state.Phase = "AwaitingInstalledLinuxBoot"
            Save-State -State $state
            Write-AgentLog (
                "The live installation succeeded. Waiting for the installed Linux system " +
                "to boot and publish installed-linux-boot.json."
            )
            exit 0
        }
        Write-AgentLog "Live success found; starting cross-runtime post-install verification."
        Invoke-VerifiedInstallationSuccess -State $state
        exit 0
    }

    $failedRunId = Read-EnvValue -Path $liveFailed -Name "LIBERTIX_UEFI_RECOVERY_RUN_ID"
    if (
        $failedRunId -eq [string]$state.RunId -and
        [string]$executionState.status -in @("failed", "rollback-running", "rolled-back")
    ) {
        $installerScript = Join-Path $state.PayloadRoot "Scripts\libertix-uefi-install.ps1"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installerScript `
            -RestoreWindowsSettings `
            -ExpectedRecoveryRunId ([string]$state.RunId)
        if ($LASTEXITCODE -ne 0) {
            throw "Windows setting restoration failed after live rollback with rc=$LASTEXITCODE."
        }
        Remove-PendingWindowsSharePayload
        $state.Phase = "LiveFailed"
        Save-State -State $state
        Write-AgentLog "The live installer failed; Windows settings were restored and logs were archived."
        Save-RecoveryLogs -State $state
        Remove-TemporaryRecoveryArtifacts -State $state
        Remove-RecoveryTasks -State $state
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

    $state.Phase = "FallbackNeeded"
    Save-State -State $state
    Write-AgentLog "BootNext returned to Windows without a live marker; waiting for the interactive fallback prompt."
    exit 0
} catch {
    try {
        Write-AgentLog "ERROR: $($_.Exception.Message)"
    } catch {
        Write-Verbose "Unable to persist the recovery failure: $($_.Exception.Message)"
    }
    Write-Error $_.Exception.Message
    exit 1
}
