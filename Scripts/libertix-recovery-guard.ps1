[CmdletBinding()]
param(
    [ValidateSet("Check", "Revert")]
    [string]$Action = "Check"
)

$ErrorActionPreference = "Stop"

$SystemDrive = [string]$env:SystemDrive
if ($SystemDrive -notmatch "^[A-Za-z]:$") {
    throw "SystemDrive must be a valid Windows drive designator."
}
$SystemDriveLetter = $SystemDrive.Substring(0, 1)
$ProgramDataRoot = Join-Path $SystemDrive "ProgramData"
$Root = Join-Path $SystemDrive "LibertixInstallRecovery"
$TaskName = "LibertixInstallRecovery"
$PromptTaskName = "LibertixInstallRecoveryPrompt"
$Log = Join-Path $Root "recovery.log"
$Pending = Join-Path $Root "pending.env"
$ArchiveRoot = Join-Path $SystemDrive "LibertixInstallLogs\Windows"
$LinuxArchiveRoot = Join-Path $SystemDrive "LibertixInstallLogs\Linux"
$Result = Join-Path $LinuxArchiveRoot "latest\result.env"
$LiveStartedMarker = Join-Path $Root "live-started.env"
$LiveFailedMarker = Join-Path $Root "live-failed.env"
$InstallSuccessMarker = Join-Path $Root "install-success.env"
$BcdBackup = Join-Path $Root "bcd-backup"
$MbrBackup = Join-Path $Root "mbr-backup\mbr-before-grub.bin"
$MbrBackupHash = Join-Path $Root "mbr-backup\mbr-before-grub.sha256"
$ExecutionStatePath = Join-Path $Root "installation-state.json"
$InstalledLinuxBootEvidencePath = Join-Path $Root "installed-linux-boot.json"
$ExecutionStateModulePath = Join-Path $Root "Libertix.InstallationState.psm1"
$AtomicFileModulePath = Join-Path $Root "Libertix.AtomicFile.psm1"
$InstallationPolicyPath = Join-Path $Root "Libertix.InstallationPolicy.json"
$TemporaryArtifactsModulePath = Join-Path $Root "Libertix.TemporaryArtifacts.psm1"
$PostInstallVerificationModulePath = Join-Path $Root "Libertix.PostInstallVerification.psm1"
$RecoveryOperationsPath = Join-Path $Root "recovery-operations.json"
$TemporaryBootFiles = @(
    (Join-Path $SystemDrive "grldr"),
    (Join-Path $SystemDrive "grldr.mbr"),
    (Join-Path $SystemDrive "menu.lst"),
    (Join-Path $SystemDrive "libertix-live.iso")
)
$WindowsShareRoot = Join-Path $ProgramDataRoot "Libertix\WindowsShare"

if (-not (Test-Path -LiteralPath $InstallationPolicyPath -PathType Leaf)) {
    throw "Installation policy is missing from the recovery payload."
}
$InstallationPolicy = Get-Content `
    -LiteralPath $InstallationPolicyPath `
    -Raw `
    -Encoding UTF8 |
    ConvertFrom-Json -ErrorAction Stop
if (
    [int]$InstallationPolicy.schemaVersion -ne 1 -or
    $null -eq $InstallationPolicy.storage -or
    $null -eq $InstallationPolicy.volumeLabels
) {
    throw "Installation policy is incomplete or unsupported."
}
$StagingVolumeLabel = [string]$InstallationPolicy.volumeLabels.staging
$LegacyStagingVolumeLabels = @(
    $InstallationPolicy.volumeLabels.legacyStagingForRecovery |
        ForEach-Object { [string]$_ }
)
if (
    $StagingVolumeLabel -notmatch '^[A-Z0-9]{1,11}$' -or
    @($LegacyStagingVolumeLabels).Count -eq 0 -or
    @(
        $LegacyStagingVolumeLabels |
            Where-Object { $_ -notmatch '^[A-Z0-9]{1,11}$' }
    ).Count -ne 0
) {
    throw "Installation policy volume labels are invalid."
}
[int64]$PartitionAlignmentBytes =
    [int64]$InstallationPolicy.storage.partitionAlignmentBytes
if ($PartitionAlignmentBytes -le 0) {
    throw "Installation policy partition alignment is invalid."
}
if (-not (Test-Path -LiteralPath $TemporaryArtifactsModulePath -PathType Leaf)) {
    throw "Temporary-artifact cleanup module is missing from the recovery payload."
}
Import-Module -Name $TemporaryArtifactsModulePath -Force -ErrorAction Stop
if (-not (Test-Path -LiteralPath $AtomicFileModulePath -PathType Leaf)) {
    throw "Atomic-file module is missing from the recovery payload."
}
Import-Module -Name $AtomicFileModulePath -Force -ErrorAction Stop

$script:RecoveryCorrelationId = "unknown"
$script:RecoveryAttemptId = [Guid]::NewGuid().ToString("N")
$script:RecoveryOperationRecords = New-Object 'System.Collections.Generic.List[object]'
$script:RecoveryErrors = New-Object 'System.Collections.Generic.List[object]'
$script:RecoveryPriorAttempts = @()
$script:RecoveryAttemptStatus = "running"
$script:RecoveryRollbackRequested = $false
$script:RecoveryCompensationSequenceStarted = $false

function Write-RecoveryLog {
    param([string]$Message)
    $line = "[{0}] correlation={1} attempt={2} {3}" -f `
        (Get-Date -Format o), `
        $script:RecoveryCorrelationId, `
        $script:RecoveryAttemptId, `
        $Message
    [Console]::Out.WriteLine($line)
    try {
        New-Item -ItemType Directory -Force -Path $Root -ErrorAction Stop | Out-Null
        Add-Content -LiteralPath $Log -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Warning "Recovery log persistence failed: $($_.Exception.Message)"
    }
}

function Save-RecoveryOperationState {
    $currentAttempt = [pscustomobject][ordered]@{
        attemptId = $script:RecoveryAttemptId
        action = $Action
        status = $script:RecoveryAttemptStatus
        updatedAtUtc = [DateTime]::UtcNow.ToString("o")
        operations = @($script:RecoveryOperationRecords)
        errors = @($script:RecoveryErrors)
    }
    $state = [ordered]@{
        schemaVersion = 1
        correlationId = $script:RecoveryCorrelationId
        updatedAtUtc = [DateTime]::UtcNow.ToString("o")
        attempts = @($script:RecoveryPriorAttempts) + @($currentAttempt)
    }
    $directory = Split-Path -Parent $RecoveryOperationsPath
    New-Item -ItemType Directory -Force -Path $directory -ErrorAction Stop | Out-Null
    $temporaryPath = Join-Path $directory ".recovery-operations.$([Guid]::NewGuid().ToString('N')).tmp"
    $backupPath = Join-Path $directory ".recovery-operations.$([Guid]::NewGuid().ToString('N')).bak"
    try {
        $encoding = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText(
            $temporaryPath,
            (($state | ConvertTo-Json -Depth 8) + "`n"),
            $encoding
        )
        Publish-LibertixFileAtomic `
            -TemporaryPath $temporaryPath `
            -DestinationPath $RecoveryOperationsPath `
            -BackupPath $backupPath
    } finally {
        if ([IO.File]::Exists($temporaryPath)) {
            [IO.File]::Delete($temporaryPath)
        }
        if ([IO.File]::Exists($backupPath)) {
            [IO.File]::Delete($backupPath)
        }
    }
}

function Initialize-RecoveryOperationHistory {
    if (-not (Test-Path -LiteralPath $RecoveryOperationsPath -PathType Leaf)) {
        return
    }
    try {
        $existing = Get-Content `
            -LiteralPath $RecoveryOperationsPath `
            -Raw `
            -Encoding UTF8 `
            -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
        if (
            [int]$existing.schemaVersion -ne 1 -or
            [string]$existing.correlationId -ne $script:RecoveryCorrelationId
        ) {
            Write-RecoveryLog (
                "Existing recovery operation history belongs to another " +
                "schema or transaction and will not be reused."
            )
            return
        }
        $script:RecoveryPriorAttempts = @($existing.attempts)
        Write-RecoveryLog (
            "Loaded $($script:RecoveryPriorAttempts.Count) prior recovery attempt(s)."
        )
    } catch {
        # Diagnostic history must never prevent the actual rollback. The durable
        # recovery log keeps this read failure and the next atomic save repairs it.
        Write-RecoveryLog (
            "Existing recovery operation history is unreadable; starting a new " +
            "history: $($_.Exception.Message)"
        )
    }
}

function Save-RecoveryOperationStateSafely {
    param([Parameter(Mandatory = $true)][string]$Context)

    try {
        Save-RecoveryOperationState
        return $true
    } catch {
        $message = $_.Exception.Message
        $alreadyRecorded = @(
            $script:RecoveryErrors |
                Where-Object {
                    $_.operation -eq "state.persistence" -and
                    $_.message -eq $message
                }
        ).Count -gt 0
        if (-not $alreadyRecorded) {
            $script:RecoveryErrors.Add([pscustomobject][ordered]@{
                operation = "state.persistence"
                message = $message
                exceptionType = $_.Exception.GetType().FullName
            })
        }
        Write-RecoveryLog (
            "operation=state.persistence status=ERROR context=$Context message=$message"
        )
        return $false
    }
}

function Complete-RecoveryAttemptState {
    $script:RecoveryAttemptStatus = "succeeded"
    if (-not (Save-RecoveryOperationStateSafely -Context "attempt.complete")) {
        throw "Recovery succeeded but its durable operation state could not be published."
    }
}

function Invoke-RecoveryOperation {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Operation
    )

    $startedAt = [DateTime]::UtcNow
    Write-RecoveryLog "operation=$Name status=BEGIN"
    $record = [pscustomobject][ordered]@{
        name = $Name
        status = "running"
        startedAtUtc = $startedAt.ToString("o")
        completedAtUtc = ""
        message = ""
    }
    $script:RecoveryOperationRecords.Add($record)
    $beginStatePersisted = Save-RecoveryOperationStateSafely -Context "$Name.begin"
    $operationSucceeded = $false
    try {
        $null = & $Operation
        $record.status = "success"
        $record.completedAtUtc = [DateTime]::UtcNow.ToString("o")
        Write-RecoveryLog "operation=$Name status=SUCCESS"
        $operationSucceeded = $true
    } catch {
        $message = $_.Exception.Message
        $record.status = "error"
        $record.completedAtUtc = [DateTime]::UtcNow.ToString("o")
        $record.message = $message
        $script:RecoveryErrors.Add([pscustomobject][ordered]@{
            operation = $Name
            message = $message
            exceptionType = $_.Exception.GetType().FullName
        })
        Write-RecoveryLog "operation=$Name status=ERROR message=$message"
    }
    $endStatePersisted = Save-RecoveryOperationStateSafely -Context "$Name.end"
    return ($operationSucceeded -and $beginStatePersisted -and $endStatePersisted)
}

function Assert-RecoveryOperationsSucceeded {
    if ($script:RecoveryErrors.Count -eq 0) {
        return
    }
    $summary = @(
        $script:RecoveryErrors |
            ForEach-Object { "$($_.operation): $($_.message)" }
    ) -join " | "
    throw "Recovery completed with $($script:RecoveryErrors.Count) error(s): $summary"
}

function Invoke-MinimumRecoveryFallback {
    if ($script:RecoveryCompensationSequenceStarted) {
        return
    }
    $script:RecoveryCompensationSequenceStarted = $true
    Write-RecoveryLog (
        "Primary rollback preparation failed before disk identity was proven; " +
        "running only transaction-scoped compensations that do not select a disk partition."
    )
    $null = Invoke-RecoveryOperation -Name "fallback.bcd.restore" -Operation {
        Restore-BcdState
    }
    $null = Invoke-RecoveryOperation -Name "fallback.windows-share.pending-cleanup" -Operation {
        Remove-PendingWindowsSharePayload
    }
    $null = Invoke-RecoveryOperation -Name "fallback.hibernation.restore" -Operation {
        Restore-OriginalHibernationSetting
    }
    $null = Invoke-RecoveryOperation -Name "fallback.boot-payload.cleanup" -Operation {
        Remove-TemporaryBootPayload
    }
    $null = Invoke-RecoveryOperation -Name "fallback.downloads.cleanup" -Operation {
        Remove-TransactionArtifacts
    }
}

function Read-EnvValue {
    param(
        [string]$Path,
        [string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $line = @(
        Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop |
            Where-Object { $_ -match "^$([regex]::Escape($Name))=" }
    ) | Select-Object -First 1
    if (-not $line) {
        return $null
    }

    return ($line -replace "^$([regex]::Escape($Name))=", "").Trim()
}

function Remove-RecoveryTask {
    param([switch]$Required)

    $null = & schtasks.exe /Delete /TN $TaskName /F 2>&1
    $deleteExitCode = $LASTEXITCODE
    $null = & schtasks.exe /Query /TN $TaskName 2>&1
    $taskStillExists = $LASTEXITCODE -eq 0
    if (-not $taskStillExists) {
        return
    }
    $message = "Recovery task still exists after deletion attempt (rc=$deleteExitCode)."
    if ($Required) { throw $message }
    Write-RecoveryLog $message
}

function Remove-RecoveryPromptTask {
    param([switch]$Required)

    $null = & schtasks.exe /Delete /TN $PromptTaskName /F 2>&1
    $deleteExitCode = $LASTEXITCODE
    $null = & schtasks.exe /Query /TN $PromptTaskName 2>&1
    $taskStillExists = $LASTEXITCODE -eq 0
    if (-not $taskStillExists) {
        return
    }
    $message = "Recovery prompt task still exists after deletion attempt (rc=$deleteExitCode)."
    if ($Required) { throw $message }
    Write-RecoveryLog $message
}

function Start-RecoveryPromptTask {
    try {
        Start-ScheduledTask -TaskName $PromptTaskName -ErrorAction Stop
        Write-RecoveryLog "Post-install result task was started for the interactive user."
    } catch {
        # InteractiveToken tasks cannot run before their user has logged on.
        # The persistent logon trigger will start it when a session exists.
        Write-RecoveryLog (
            "Post-install result task remains armed for the next user logon: " +
            $_.Exception.Message
        )
    }
}

function Read-RecoveryExecutionState {
    if (-not (Test-Path -LiteralPath $ExecutionStatePath -PathType Leaf)) {
        throw "Recovery execution state is missing."
    }
    if (-not (Test-Path -LiteralPath $ExecutionStateModulePath -PathType Leaf)) {
        throw "Recovery execution state exists but its transition module is missing."
    }

    Import-Module -Name $ExecutionStateModulePath -Force -ErrorAction Stop
    $state = Read-LibertixExecutionState -Path $ExecutionStatePath
    $expectedPlanId = Read-EnvValue -Path $Pending -Name "PLAN_ID"
    if ($expectedPlanId -notmatch '^[0-9a-f]{32}$') {
        throw "Pending metadata plan identity is missing or invalid."
    }
    if ([string]$state.planId -ne $expectedPlanId) {
        throw "Recovery execution state does not belong to the pending installation plan."
    }
    return $state
}

function Initialize-RecoveryExecutionState {
    param([Parameter(Mandatory = $true)]$State)

    $state = $State
    if ([string]$state.status -in @("running", "failed", "succeeded")) {
        $null = Start-LibertixRollback -Path $ExecutionStatePath
    } elseif ([string]$state.status -eq "rolled-back") {
        # A previous attempt may have restored the ledger but failed while
        # retiring a task. Replaying the idempotent cleanup completes that run.
        return $false
    } elseif ([string]$state.status -ne "rollback-running") {
        throw "Recovery execution state cannot begin rollback from status '$($state.status)'."
    }
    return $true
}

function Complete-RecoveryCompensation {
    param([Parameter(Mandatory = $true)][string]$Step)

    if (-not $script:TrackRecoveryExecutionState) {
        return
    }
    $state = Read-LibertixExecutionState -Path $ExecutionStatePath
    if ($Step -in @($state.completedSteps) -and $Step -notin @($state.compensatedSteps)) {
        $null = Complete-LibertixCompensation -Path $ExecutionStatePath -Step $Step
    }
}

function Save-RecoveryLog {
    $planId = Read-EnvValue -Path $Pending -Name "PLAN_ID"
    if ($planId -notmatch '^[0-9a-f]{32}$') {
        $planId = "unknown"
    }
    $sessionArchive = Join-Path $ArchiveRoot $planId
    New-Item -ItemType Directory -Force -Path $sessionArchive | Out-Null
    if (Test-Path $Log) {
        Copy-Item `
            -LiteralPath $Log `
            -Destination (Join-Path $sessionArchive "bios-recovery.log") `
            -Force `
            -ErrorAction Stop
    }
    if (Test-Path -LiteralPath $RecoveryOperationsPath -PathType Leaf) {
        Copy-Item `
            -LiteralPath $RecoveryOperationsPath `
            -Destination (Join-Path $sessionArchive "recovery-operations.json") `
            -Force `
            -ErrorAction Stop
    }
}

function Remove-TransactionArtifacts {
    $planId = Read-EnvValue -Path $Pending -Name "PLAN_ID"
    Remove-LibertixTransactionDownloads -SystemDrive $SystemDrive -PlanId $planId
    Write-RecoveryLog "Removed transaction download artifacts."
}

function Restore-OriginalHibernationSetting {
    $originalHibernate = Read-EnvValue -Path $Pending -Name "ORIGINAL_HIBERNATE_ENABLED"
    if ($originalHibernate -eq "true") {
        Write-RecoveryLog "Restoring Windows hibernation and Fast Startup."
        $hibernateOutput = & "$env:SystemRoot\System32\powercfg.exe" /hibernate on 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Hibernation restore failed with rc=$LASTEXITCODE output=$($hibernateOutput -join ' ')"
        }
        $hibernateEnabled = (
            Get-ItemProperty `
                -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power" `
                -Name "HibernateEnabled" `
                -ErrorAction Stop
        ).HibernateEnabled
        if ($hibernateEnabled -ne 1) {
            throw "Hibernation restore did not enable HibernateEnabled."
        }
    } elseif ($originalHibernate -eq "false") {
        Write-RecoveryLog "Restoring Windows hibernation and Fast Startup to disabled."
        $hibernateOutput = & "$env:SystemRoot\System32\powercfg.exe" /hibernate off 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Hibernation disable failed with rc=$LASTEXITCODE output=$($hibernateOutput -join ' ')"
        }
        $hibernateEnabled = (
            Get-ItemProperty `
                -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power" `
                -Name "HibernateEnabled" `
                -ErrorAction Stop
        ).HibernateEnabled
        if ($hibernateEnabled -ne 0) {
            throw "Hibernation restore did not disable HibernateEnabled."
        }
    } else {
        Write-RecoveryLog "Original hibernation state unknown; left unchanged."
    }
}

function Restore-BcdState {
    param([switch]$Required)

    if (-not (Test-Path -LiteralPath $BcdBackup -PathType Leaf)) {
        if ($Required) {
            throw "Required pre-install BCD backup is missing."
        }
        Write-RecoveryLog "No BCD backup present; BCD restore skipped."
        return
    }

    $output = & bcdedit.exe /import $BcdBackup /clean 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "BCD restore failed with rc=$LASTEXITCODE output=$($output -join ' ')"
    }
    $verification = & bcdedit.exe /enum "{bootmgr}" /v 2>&1
    if ($LASTEXITCODE -ne 0 -or @($verification).Count -eq 0) {
        throw (
            "BCD restore completed but Windows Boot Manager could not be " +
            "verified (rc=$LASTEXITCODE output=$($verification -join ' '))."
        )
    }
    Write-RecoveryLog "BCD state restored from the pre-install backup."
}

function Restore-BiosMbrBootCode {
    param(
        [Parameter(Mandatory = $true)][int]$DiskNumber,
        [switch]$Required
    )

    if (
        -not (Test-Path -LiteralPath $MbrBackup -PathType Leaf) -or
        -not (Test-Path -LiteralPath $MbrBackupHash -PathType Leaf)
    ) {
        if ($Required) { throw "Required pre-GRUB MBR backup is missing." }
        Write-RecoveryLog "No pre-GRUB MBR backup exists; boot-code restore skipped."
        return
    }
    [byte[]]$backup = [IO.File]::ReadAllBytes($MbrBackup)
    if ($backup.Length -ne 512) {
        throw "Pre-GRUB MBR backup must contain exactly 512 bytes."
    }
    $expectedHash = ((Get-Content -LiteralPath $MbrBackupHash -Raw).Trim() -split '\s+')[0]
    $actualHash = (Get-FileHash -LiteralPath $MbrBackup -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expectedHash -notmatch '^[0-9a-fA-F]{64}$' -or $actualHash -ne $expectedHash.ToLowerInvariant()) {
        throw "Pre-GRUB MBR backup checksum verification failed."
    }

    $devicePath = "\\.\PhysicalDrive$DiskNumber"
    $stream = New-Object IO.FileStream(
        $devicePath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::ReadWrite
    )
    try {
        [byte[]]$current = New-Object byte[] 512
        if ($stream.Read($current, 0, $current.Length) -ne 512) {
            throw "Cannot read the current BIOS MBR."
        }
        $currentBootCode = [Convert]::ToBase64String($current, 0, 440)
        $backupBootCode = [Convert]::ToBase64String($backup, 0, 440)
        if ($currentBootCode -ne $backupBootCode) {
            $stream.Position = 0
            $stream.Write($backup, 0, 440)
            $stream.Flush($true)
        }
        $stream.Position = 0
        [byte[]]$verified = New-Object byte[] 512
        if ($stream.Read($verified, 0, $verified.Length) -ne 512) {
            throw "Cannot verify the restored BIOS MBR."
        }
        if ([Convert]::ToBase64String($verified, 0, 440) -ne $backupBootCode) {
            throw "BIOS MBR boot-code restoration could not be verified."
        }
    } finally {
        $stream.Dispose()
    }
    Write-RecoveryLog "BIOS MBR boot code restored from the durable pre-GRUB backup."
}

function Remove-TemporaryBootPayload {
    foreach ($temporaryBootFile in $TemporaryBootFiles) {
        if (Test-Path -LiteralPath $temporaryBootFile -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryBootFile -Force -ErrorAction Stop
            Write-RecoveryLog "Removed temporary boot file: $temporaryBootFile"
        }
    }
    $remainingFiles = @(
        $TemporaryBootFiles |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
    )
    if ($remainingFiles.Count -ne 0) {
        throw "Temporary boot payload remains: $($remainingFiles -join ', ')"
    }
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
    Write-RecoveryLog "Windows read-only Linux sharing finalized."
}

function Invoke-VerifiedInstallationSuccess {
    Write-RecoveryLog "Successful install marker found; starting cross-runtime verification."
    try {
        Restore-BcdState -Required
        Remove-TemporaryBootPayload
        Remove-TransactionArtifacts
        Invoke-WindowsShareFinalize
        if (-not (Test-Path -LiteralPath $PostInstallVerificationModulePath -PathType Leaf)) {
            throw "Post-install verification module is missing from the recovery payload."
        }
        Import-Module -Name $PostInstallVerificationModulePath -Force -ErrorAction Stop
        $writeLog = { param($Message) Write-RecoveryLog -Message $Message }
        $null = Invoke-LibertixPostInstallVerification `
            -RecoveryRoot $Root `
            -LogPath $Log `
            -WriteLog $writeLog
    } catch {
        $verificationFailure = $_
        try {
            $null = Set-LibertixPostInstallFailure `
                -RecoveryRoot $Root `
                -LogPath $Log `
                -CheckName "post-install-controller" `
                -ErrorMessage $verificationFailure.Exception.Message
        } catch {
            Write-RecoveryLog (
                "Could not persist the post-install controller failure: " +
                $_.Exception.Message
            )
        }
        throw $verificationFailure
    } finally {
        $verificationResultPath = Join-Path $Root "post-install-verification.json"
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
            # The prompt task remains until the interactive result window is
            # acknowledged. Only a terminal durable result retires the startup task.
            Start-RecoveryPromptTask
            # Starting the interactive task first avoids a Task Scheduler race:
            # deleting the currently running startup task can briefly make a
            # different task start fail with ERROR_FILE_NOT_FOUND.
            Remove-RecoveryTask -Required
        } else {
            Write-RecoveryLog (
                "Post-install verification was interrupted with status=" +
                "$verificationStatus; startup recovery remains armed."
            )
        }
        Save-RecoveryLog
    }
}

function Remove-PendingWindowsSharePayload {
    if (Test-Path -LiteralPath (Join-Path $WindowsShareRoot "pending.marker") -PathType Leaf) {
        Remove-Item -LiteralPath $WindowsShareRoot -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $WindowsShareRoot) {
            throw "Pending Windows sharing payload still exists after removal."
        }
        Write-RecoveryLog "Removed pending Windows sharing payload."
    }
}

function Remove-WindowsShareAfterRollback {
    if (Test-Path -LiteralPath $WindowsShareRoot -PathType Container) {
        $shareLog = Join-Path $WindowsShareRoot "windows-share.log"
        if (Test-Path -LiteralPath $shareLog -PathType Leaf) {
            Copy-Item `
                -LiteralPath $shareLog `
                -Destination (Join-Path $Root "windows-share.log") `
                -Force `
                -ErrorAction Stop
        }
    }

    $shareTask = Get-ScheduledTask `
        -TaskName "LibertixLinuxReadOnly" `
        -ErrorAction SilentlyContinue
    if ($null -ne $shareTask) {
        Unregister-ScheduledTask `
            -TaskName "LibertixLinuxReadOnly" `
            -Confirm:$false `
            -ErrorAction Stop
    }
    if (Test-Path -LiteralPath $WindowsShareRoot) {
        Remove-Item -LiteralPath $WindowsShareRoot -Recurse -Force -ErrorAction Stop
    }
    if (
        (Test-Path -LiteralPath $WindowsShareRoot) -or
        $null -ne (Get-ScheduledTask `
            -TaskName "LibertixLinuxReadOnly" `
            -ErrorAction SilentlyContinue)
    ) {
        throw "Windows read-only Linux sharing cleanup could not be verified."
    }
    Write-RecoveryLog "Removed Windows read-only Linux sharing after rollback."
}

function Wait-SystemDriveResizeCapacity {
    param(
        [Parameter(Mandatory = $true)][int]$DiskNumber,
        [Parameter(Mandatory = $true)][int64]$RequiredSize,
        [int]$TimeoutSeconds = 60
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        # Removing a partition updates the disk before every Storage CIM object
        # sees the new free extent. Refresh both caches before trusting SizeMax.
        Update-HostStorageCache -ErrorAction SilentlyContinue
        Update-Disk -Number $DiskNumber -ErrorAction SilentlyContinue | Out-Null

        $partition = Get-Partition -DriveLetter $SystemDriveLetter -ErrorAction Stop
        $supported = Get-PartitionSupportedSize -DriveLetter $SystemDriveLetter -ErrorAction Stop
        if ($partition.Size -ge $RequiredSize -or $supported.SizeMax -ge $RequiredSize) {
            return $supported
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            return $supported
        }
        Start-Sleep -Seconds 2
    } while ($true)
}

function Remove-EmptyTransactionExtendedContainer {
    param(
        [Parameter(Mandatory = $true)][int]$DiskNumber,
        [Parameter(Mandatory = $true)][int64]$TransactionOffset,
        [Parameter(Mandatory = $true)][int64]$TransactionSize,
        [Parameter(Mandatory = $true)][int64]$SystemPartitionEnd,
        [int64]$OriginalSystemPartitionEnd = 0,
        [int64]$RecoveryPartitionOffset = 0
    )

    $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
    if ([string]$disk.PartitionStyle -ne "MBR") {
        return
    }

    Update-HostStorageCache -ErrorAction SilentlyContinue
    Update-Disk -Number $DiskNumber -ErrorAction SilentlyContinue | Out-Null

    $transactionEnd = $TransactionOffset + $TransactionSize
    $partitions = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop)
    $containers = @(
        $partitions | Where-Object {
            $partitionStart = [int64]$_.Offset
            $partitionEnd = $partitionStart + [int64]$_.Size
            $mbrType = [int]$_.MbrType
            $isExtendedType = $mbrType -in @(5, 15, 133)
            $precedesRecovery = (
                $RecoveryPartitionOffset -le 0 -or
                $partitionEnd -le $RecoveryPartitionOffset
            )
            $insideOriginalSystemExtent = (
                $OriginalSystemPartitionEnd -le 0 -or
                $partitionEnd -le $OriginalSystemPartitionEnd
            )
            $containsTransaction = (
                $partitionStart -le $TransactionOffset -and
                $partitionEnd -ge $transactionEnd
            )
            $isOnlyRemainingTransactionExtent = (
                $OriginalSystemPartitionEnd -gt 0 -and
                $partitionStart -ge $SystemPartitionEnd -and
                $partitionEnd -le $OriginalSystemPartitionEnd
            )
            $isExtendedType -and
                $partitionStart -ge $SystemPartitionEnd -and
                $insideOriginalSystemExtent -and
                ($containsTransaction -or $isOnlyRemainingTransactionExtent) -and
                $precedesRecovery
        }
    )

    if ($containers.Count -gt 1) {
        throw "Multiple MBR extended containers match the removed transaction partition; refusing ambiguous rollback."
    }
    if ($containers.Count -eq 0) {
        return
    }

    $container = $containers[0]
    $containerStart = [int64]$container.Offset
    $containerEnd = $containerStart + [int64]$container.Size
    $containedPartitions = @(
        $partitions | Where-Object {
            $_.ObjectId -ne $container.ObjectId -and
            [int64]$_.Offset -ge $containerStart -and
            ([int64]$_.Offset + [int64]$_.Size) -le $containerEnd
        }
    )
    if ($containedPartitions.Count -ne 0) {
        throw "The matching MBR extended container is not empty; refusing rollback."
    }

    # Windows can place a FAT32 staging volume in a logical partition and keep
    # its automatically-created extended container after the volume is removed.
    # The container still occupies the free extent, so C: cannot grow until the
    # exact empty container proven to have enclosed the transaction is removed.
    Write-RecoveryLog (
        "Removing empty transaction MBR extended container " +
        "offset=$containerStart size=$([int64]$container.Size)."
    )
    Remove-Partition -InputObject $container -Confirm:$false -ErrorAction Stop
    Start-Sleep -Seconds 2
    Update-HostStorageCache -ErrorAction SilentlyContinue
    Update-Disk -Number $DiskNumber -ErrorAction SilentlyContinue | Out-Null

    $containerStillExists = @(
        Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop | Where-Object {
            [int64]$_.Offset -eq $containerStart -and
            [int64]$_.Size -eq [int64]$container.Size -and
            [int]$_.MbrType -in @(5, 15, 133)
        }
    ).Count -ne 0
    if ($containerStillExists) {
        throw "The empty transaction MBR extended container still exists after removal."
    }
}

try {
    $pendingRecoveryRunId = Read-EnvValue -Path $Pending -Name "RECOVERY_RUN_ID"
    $pendingPlanId = Read-EnvValue -Path $Pending -Name "PLAN_ID"
    if ($pendingRecoveryRunId -match '^[0-9a-f]{32}$') {
        $script:RecoveryCorrelationId = $pendingRecoveryRunId
    } elseif ($pendingPlanId -match '^[0-9a-f]{32}$') {
        $script:RecoveryCorrelationId = $pendingPlanId
    }
    Write-RecoveryLog "Recovery guard started."
    Initialize-RecoveryOperationHistory
    if ($Action -eq "Revert") {
        $script:RecoveryRollbackRequested = $true
    }
    if (-not (Test-Path -LiteralPath $PostInstallVerificationModulePath -PathType Leaf)) {
        throw "Post-install verification module is missing from the recovery payload."
    }
    Import-Module -Name $PostInstallVerificationModulePath -Force -ErrorAction Stop
    Set-LibertixShutdownVerificationPriority
    $script:TrackRecoveryExecutionState = $false
    $recoveryExecutionState = Read-RecoveryExecutionState
    $rollbackFromSucceeded = [string]$recoveryExecutionState.status -eq "succeeded"
    $temporaryBootWasPrepared = (
        "windows.temporary-boot-prepared" -in
        @($recoveryExecutionState.completedSteps)
    )

    $expectedRecoveryRunId = Read-EnvValue -Path $Pending -Name "RECOVERY_RUN_ID"
    $successRecoveryRunId = Read-EnvValue `
        -Path $InstallSuccessMarker `
        -Name "LIBERTIX_BIOS_RECOVERY_RUN_ID"
    $successRecoveryState = Read-EnvValue `
        -Path $InstallSuccessMarker `
        -Name "LIBERTIX_BIOS_RECOVERY_STATE"
    if (
        $Action -eq "Check" -and
        -not [string]::IsNullOrWhiteSpace($expectedRecoveryRunId) -and
        $successRecoveryRunId -eq $expectedRecoveryRunId -and
        $successRecoveryState -eq "install-success" -and
        [string]$recoveryExecutionState.status -eq "succeeded"
    ) {
        if (-not (Test-Path -LiteralPath $InstalledLinuxBootEvidencePath -PathType Leaf)) {
            $null = Set-LibertixPostInstallWaitingForLinux `
                -RecoveryRoot $Root `
                -LogPath $Log
            Write-RecoveryLog (
                "The live installation succeeded. Waiting for the installed Linux system " +
                "to boot and publish installed-linux-boot.json."
            )
            Start-RecoveryPromptTask
            Save-RecoveryLog
            exit 0
        }
        Invoke-VerifiedInstallationSuccess
        exit 0
    }

    $pendingSystemDrive = Read-EnvValue -Path $Pending -Name "SYSTEM_DRIVE"
    if (
        $null -ne $pendingSystemDrive -and
        (
            $pendingSystemDrive -notmatch "^[A-Za-z]:$" -or
            $pendingSystemDrive.ToUpperInvariant() -ne $SystemDrive.ToUpperInvariant()
        )
    ) {
        throw "Pending metadata system drive does not match the current Windows system drive; refusing recovery."
    }

    # A successful live install writes this marker before rebooting. In that case
    # the Windows guard verifies the installed system and leaves disk geometry alone.
    $success = Read-EnvValue -Path $Result -Name "LIBERTIX_INSTALL_SUCCESS"
    $resultIsFresh = (
        (Test-Path -LiteralPath $Result -PathType Leaf) -and
        (Test-Path -LiteralPath $Pending -PathType Leaf) -and
        ((Get-Item -LiteralPath $Result).LastWriteTimeUtc -gt (Get-Item -LiteralPath $Pending).LastWriteTimeUtc)
    )
    if (
        $Action -eq "Check" -and
        $success -eq "true" -and
        $resultIsFresh -and
        [string]$recoveryExecutionState.status -eq "succeeded"
    ) {
        if (-not (Test-Path -LiteralPath $InstalledLinuxBootEvidencePath -PathType Leaf)) {
            $null = Set-LibertixPostInstallWaitingForLinux `
                -RecoveryRoot $Root `
                -LogPath $Log
            Write-RecoveryLog (
                "The live installation succeeded. Waiting for the installed Linux system " +
                "to boot and publish installed-linux-boot.json."
            )
            Start-RecoveryPromptTask
            Save-RecoveryLog
            exit 0
        }
        Invoke-VerifiedInstallationSuccess
        exit 0
    }

    $liveStartedRunId = Read-EnvValue `
        -Path $LiveStartedMarker `
        -Name "LIBERTIX_BIOS_RECOVERY_RUN_ID"
    $liveStartedState = Read-EnvValue `
        -Path $LiveStartedMarker `
        -Name "LIBERTIX_BIOS_RECOVERY_STATE"
    $liveFailedRunId = Read-EnvValue `
        -Path $LiveFailedMarker `
        -Name "LIBERTIX_BIOS_RECOVERY_RUN_ID"
    $liveFailedState = Read-EnvValue `
        -Path $LiveFailedMarker `
        -Name "LIBERTIX_BIOS_RECOVERY_STATE"
    $liveStartedWithoutFailure = (
        -not [string]::IsNullOrWhiteSpace($expectedRecoveryRunId) -and
        $liveStartedRunId -eq $expectedRecoveryRunId -and
        $liveStartedState -eq "live-started" -and
        -not (
            $liveFailedRunId -eq $expectedRecoveryRunId -and
            $liveFailedState -eq "live-failed"
        )
    )
    $liveRollbackCompleted = (
        -not [string]::IsNullOrWhiteSpace($expectedRecoveryRunId) -and
        $liveFailedRunId -eq $expectedRecoveryRunId -and
        $liveFailedState -eq "live-failed" -and
        [string]$recoveryExecutionState.status -eq "rolled-back"
    )
    if ($Action -eq "Check" -and $liveRollbackCompleted) {
        $script:RecoveryRollbackRequested = $true
        $script:RecoveryCompensationSequenceStarted = $true
        Write-RecoveryLog (
            "The live installer reported failure after a verified rollback; " +
            "restoring Windows settings and retiring the recovery task."
        )
        $null = Invoke-RecoveryOperation -Name "bcd.restore" -Operation {
            Restore-BcdState -Required
        }
        $null = Invoke-RecoveryOperation -Name "windows-share.pending-cleanup" -Operation {
            Remove-PendingWindowsSharePayload
        }
        $null = Invoke-RecoveryOperation -Name "hibernation.restore" -Operation {
            Restore-OriginalHibernationSetting
        }
        $null = Invoke-RecoveryOperation -Name "boot-payload.cleanup" -Operation {
            Remove-TemporaryBootPayload
        }
        $null = Invoke-RecoveryOperation -Name "downloads.cleanup" -Operation {
            Remove-TransactionArtifacts
        }
        Assert-RecoveryOperationsSucceeded
        $null = Invoke-RecoveryOperation -Name "startup-task.remove" -Operation {
            Remove-RecoveryTask -Required
        }
        $null = Invoke-RecoveryOperation -Name "prompt-task.remove" -Operation {
            Remove-RecoveryPromptTask -Required
        }
        Assert-RecoveryOperationsSucceeded
        Complete-RecoveryAttemptState
        Save-RecoveryLog
        exit 0
    }
    if ($Action -eq "Check" -and $liveStartedWithoutFailure) {
        Write-RecoveryLog (
            "The live installer started but produced neither a success nor a failure marker. " +
            "Refusing automatic disk rollback without positive failure evidence."
        )
        Save-RecoveryLog
        exit 2
    }

    $script:RecoveryRollbackRequested = $true
    $script:TrackRecoveryExecutionState = Initialize-RecoveryExecutionState `
        -State $recoveryExecutionState

    $expectedMbText = Read-EnvValue -Path $Pending -Name "LINUX_SIZE_MB"
    $stagingMbText = Read-EnvValue -Path $Pending -Name "STAGING_SIZE_MB"
    $diskNumberText = Read-EnvValue -Path $Pending -Name "SYSTEM_DISK_NUMBER"
    $systemPartitionNumberText = Read-EnvValue -Path $Pending -Name "SYSTEM_PARTITION_NUMBER"
    $initialSystemOffsetText = Read-EnvValue -Path $Pending -Name "SYSTEM_PARTITION_OFFSET"
    $initialSystemSizeText = Read-EnvValue -Path $Pending -Name "SYSTEM_PARTITION_SIZE_BYTES"
    $expectedDiskId = Read-EnvValue -Path $Pending -Name "SYSTEM_DISK_UNIQUE_ID"
    $recoveryPartitionOffsetText = Read-EnvValue `
        -Path $Pending `
        -Name "RECOVERY_PARTITION_OFFSET_BYTES"
    if (
        -not $expectedMbText -or
        -not $diskNumberText -or
        -not $systemPartitionNumberText -or
        -not $initialSystemOffsetText -or
        -not $initialSystemSizeText
    ) {
        throw "Pending metadata is incomplete; refusing heuristic rollback."
    }

    $expectedMb = [int][double]::Parse($expectedMbText, [Globalization.CultureInfo]::InvariantCulture)
    $stagingMb = if ($stagingMbText) {
        [int][double]::Parse($stagingMbText, [Globalization.CultureInfo]::InvariantCulture)
    } else {
        $expectedMb
    }
    $diskNumber = [int]$diskNumberText
    $systemPartitionNumber = [int]$systemPartitionNumberText
    $initialSystemOffset = [int64]$initialSystemOffsetText
    $initialSystemSize = [int64]$initialSystemSizeText
    $recoveryPartitionOffset = if ($recoveryPartitionOffsetText) {
        [int64]$recoveryPartitionOffsetText
    } else {
        0
    }
    [int64]$partitionSizeTolerance = $PartitionAlignmentBytes
    [int64]$expectedBytes = [int64]$expectedMb * 1MB
    [int64]$stagingBytes = [int64]$stagingMb * 1MB
    [int64]$minBytes = $expectedBytes - $partitionSizeTolerance
    if ($minBytes -lt 1) {
        $minBytes = 1
    }
    $maxBytes = $expectedBytes + $partitionSizeTolerance
    [int64]$stagingMinBytes = $stagingBytes - $partitionSizeTolerance
    if ($stagingMinBytes -lt 1) {
        $stagingMinBytes = 1
    }
    $stagingMaxBytes = $stagingBytes + $partitionSizeTolerance
    $alignmentPadding =
        ($initialSystemOffset + $initialSystemSize) % $PartitionAlignmentBytes
    $expectedTransactionOffset = `
        $initialSystemOffset + $initialSystemSize - $alignmentPadding - $expectedBytes
    [int64]$initialSystemEnd = $initialSystemOffset + $initialSystemSize

    $script:RecoveryCompensationSequenceStarted = $true
    $diskLayoutRestored = Invoke-RecoveryOperation -Name "disk-layout.restore" -Operation {
        $systemPartition = Get-Partition -DriveLetter $SystemDriveLetter -ErrorAction Stop
        if (
            $systemPartition.DiskNumber -ne $diskNumber -or
            $systemPartition.PartitionNumber -ne $systemPartitionNumber
        ) {
            throw "Windows system partition identity changed; refusing rollback."
        }
        $disk = Get-Disk -Number $diskNumber -ErrorAction Stop
        if (
            $expectedDiskId -and
            ([string]$disk.UniqueId).Trim() -ne $expectedDiskId.Trim()
        ) {
            throw "Windows system disk identity changed; refusing rollback."
        }

        # Imaging and partitioning tools can use different alignment padding. A
        # transaction candidate must still be wholly owned by the exact extent
        # released from the recorded Windows partition. This accepts variable
        # padding without allowing recovery to cross the original Windows end.
        $partitions = Get-Partition -DiskNumber $diskNumber | Sort-Object Offset
        $candidates = @()
        [int64]$systemPartitionEnd = (
            [int64]$systemPartition.Offset + [int64]$systemPartition.Size
        )

        foreach ($partition in $partitions) {
            if ($partition.PartitionNumber -eq $systemPartition.PartitionNumber) {
                continue
            }
            [int64]$partitionStart = [int64]$partition.Offset
            [int64]$partitionEnd = $partitionStart + [int64]$partition.Size
            if (
                [int]$partition.MbrType -in @(5, 15, 133) -or
                $partitionStart -lt $systemPartitionEnd -or
                $partitionEnd -gt $initialSystemEnd -or
                (
                    $recoveryPartitionOffset -gt 0 -and
                    $partitionEnd -gt $recoveryPartitionOffset
                )
            ) {
                continue
            }

            # A raw or ext4 partition normally has no Windows Volume object.
            $volume = $partition | Get-Volume -ErrorAction SilentlyContinue

            $label = if ($null -ne $volume) {
                [string]$volume.FileSystemLabel
            } else { "" }
            $fs = if ($null -ne $volume) { [string]$volume.FileSystem } else { "" }
            $letter = if ($null -ne $volume) { [string]$volume.DriveLetter } else { "" }

            $isTemporaryFat = (
                $label -eq $StagingVolumeLabel -or
                $label -in $LegacyStagingVolumeLabels
            )
            $isLinuxFileSystem = ($fs -match "^(ext2|ext3|ext4)$")
            $isRawTransaction = [string]::IsNullOrWhiteSpace($fs)
            if (
                -not $isTemporaryFat -and
                -not $isLinuxFileSystem -and
                -not $isRawTransaction
            ) {
                continue
            }

            $matchesFinalSize = (
                $partition.Size -ge $minBytes -and
                $partition.Size -le $maxBytes
            )
            $matchesStagingSize = (
                $partition.Size -ge $stagingMinBytes -and
                $partition.Size -le $stagingMaxBytes
            )
            if (
                ($isTemporaryFat -and -not $matchesStagingSize -and -not $matchesFinalSize) -or
                ($isLinuxFileSystem -and -not $matchesFinalSize) -or
                ($isRawTransaction -and -not $matchesStagingSize)
            ) {
                continue
            }

            $candidates += [pscustomobject]@{
                Partition = $partition
                Label = $label
                FileSystem = $fs
                DriveLetter = $letter
            }
        }

        if (@($candidates).Count -gt 1) {
            throw (
                "Multiple temporary Linux partition candidates found; " +
                "refusing ambiguous rollback."
            )
        }

        if (@($candidates).Count -eq 1) {
            $candidate = $candidates[0]
            $number = $candidate.Partition.PartitionNumber
            $candidateOffset = [int64]$candidate.Partition.Offset
            $candidateSize = [int64]$candidate.Partition.Size
            $sizeMb = [Math]::Round($candidate.Partition.Size / 1MB, 0)
            Write-RecoveryLog (
                "Removing transaction partition number=$number sizeMB=$sizeMb " +
                "offset=$candidateOffset label=$($candidate.Label) " +
                "fs=$($candidate.FileSystem)."
            )
            Remove-Partition `
                -DiskNumber $diskNumber `
                -PartitionNumber $number `
                -Confirm:$false `
                -ErrorAction Stop
            Start-Sleep -Seconds 2
            Remove-EmptyTransactionExtendedContainer `
                -DiskNumber $diskNumber `
                -TransactionOffset $candidateOffset `
                -TransactionSize $candidateSize `
                -SystemPartitionEnd $systemPartitionEnd `
                -OriginalSystemPartitionEnd $initialSystemEnd `
                -RecoveryPartitionOffset $recoveryPartitionOffset
        } else {
            Write-RecoveryLog (
                "No transaction partition exists; checking whether only the " +
                "system partition needs extension."
            )
            Remove-EmptyTransactionExtendedContainer `
                -DiskNumber $diskNumber `
                -TransactionOffset $expectedTransactionOffset `
                -TransactionSize $stagingBytes `
                -SystemPartitionEnd $systemPartitionEnd `
                -OriginalSystemPartitionEnd $initialSystemEnd `
                -RecoveryPartitionOffset $recoveryPartitionOffset
        }

        $currentSystemPartition = Get-Partition `
            -DriveLetter $SystemDriveLetter `
            -ErrorAction Stop
        if ($currentSystemPartition.Size -ne $initialSystemSize) {
            $supported = Wait-SystemDriveResizeCapacity `
                -DiskNumber $diskNumber `
                -RequiredSize $initialSystemSize
            if (
                $supported.SizeMin -gt $initialSystemSize -or
                $supported.SizeMax -lt $initialSystemSize
            ) {
                throw (
                    "$SystemDrive cannot be restored to its initial size " +
                    "($initialSystemSize); SizeMin=$($supported.SizeMin), " +
                    "SizeMax=$($supported.SizeMax)."
                )
            }
            Write-RecoveryLog (
                "Restoring $SystemDrive to its exact initial size: " +
                "$initialSystemSize bytes."
            )
            Resize-Partition `
                -DriveLetter $SystemDriveLetter `
                -Size $initialSystemSize `
                -ErrorAction Stop
        } else {
            Write-RecoveryLog (
                "$SystemDrive is already at its initial size; resize skipped."
            )
        }

        $finalSystemPartition = Get-Partition -DriveLetter $SystemDriveLetter -ErrorAction Stop
        if ($finalSystemPartition.Size -ne $initialSystemSize) {
            throw "$SystemDrive rollback verification failed: size=$($finalSystemPartition.Size), expected=$initialSystemSize."
        }
    }

    $bcdRestored = Invoke-RecoveryOperation -Name "bcd.restore" -Operation {
        Restore-BcdState -Required:$temporaryBootWasPrepared
    }
    $mbrRestored = Invoke-RecoveryOperation -Name "mbr.restore" -Operation {
        Restore-BiosMbrBootCode `
            -DiskNumber $diskNumber `
            -Required:$temporaryBootWasPrepared
    }
    $null = Invoke-RecoveryOperation -Name "windows-share.cleanup" -Operation {
        if ($rollbackFromSucceeded) {
            Remove-WindowsShareAfterRollback
        } else {
            Remove-PendingWindowsSharePayload
        }
    }
    $null = Invoke-RecoveryOperation -Name "hibernation.restore" -Operation {
        Restore-OriginalHibernationSetting
    }
    $bootPayloadRemoved = Invoke-RecoveryOperation -Name "boot-payload.cleanup" -Operation {
        Remove-TemporaryBootPayload
    }
    $downloadsRemoved = Invoke-RecoveryOperation -Name "downloads.cleanup" -Operation {
        Remove-TransactionArtifacts
    }

    if ($diskLayoutRestored) {
        $null = Invoke-RecoveryOperation `
            -Name "ledger.installer-partition.compensate" `
            -Operation {
                Complete-RecoveryCompensation `
                    -Step "windows.installer-partition-created"
            }
        $null = Invoke-RecoveryOperation `
            -Name "ledger.system-volume.compensate" `
            -Operation {
                Complete-RecoveryCompensation `
                    -Step "windows.system-volume-shrunk"
            }
    }
    if ($bcdRestored -and $mbrRestored -and $bootPayloadRemoved) {
        $null = Invoke-RecoveryOperation `
            -Name "ledger.temporary-boot.compensate" `
            -Operation {
                Complete-RecoveryCompensation `
                    -Step "windows.temporary-boot-prepared"
            }
    }
    if ($bootPayloadRemoved -and $downloadsRemoved) {
        $null = Invoke-RecoveryOperation `
            -Name "ledger.live-media.compensate" `
            -Operation {
                Complete-RecoveryCompensation `
                    -Step "windows.live-media-prepared"
            }
    }
    Assert-RecoveryOperationsSucceeded

    if ($script:TrackRecoveryExecutionState) {
        $null = Invoke-RecoveryOperation `
            -Name "ledger.recovery-armed.compensate" `
            -Operation {
                Complete-RecoveryCompensation -Step "windows.recovery-armed"
            }
        Assert-RecoveryOperationsSucceeded
        $rollbackStateCompleted = Invoke-RecoveryOperation `
            -Name "ledger.rollback.complete" `
            -Operation {
                $null = Complete-LibertixRollback -Path $ExecutionStatePath
            }
        if ($rollbackStateCompleted) {
            $script:TrackRecoveryExecutionState = $false
        }
    }
    Assert-RecoveryOperationsSucceeded

    $null = Invoke-RecoveryOperation -Name "startup-task.remove" -Operation {
        Remove-RecoveryTask -Required
    }
    $null = Invoke-RecoveryOperation -Name "prompt-task.remove" -Operation {
        Remove-RecoveryPromptTask -Required
    }
    Assert-RecoveryOperationsSucceeded
    Complete-RecoveryAttemptState
    $successfulOperationCount = @(
        $script:RecoveryOperationRecords |
            Where-Object { $_.status -eq "success" }
    ).Count
    Write-RecoveryLog (
        "Recovery completed and verified with " +
        "$successfulOperationCount successful operations."
    )
    Save-RecoveryLog
    exit 0
} catch {
    $primaryFailure = $_
    if ($script:RecoveryRollbackRequested -and -not $script:RecoveryCompensationSequenceStarted) {
        Invoke-MinimumRecoveryFallback
    }
    Write-RecoveryLog (
        "Recovery failed: $($primaryFailure.Exception.Message); " +
        "operationErrors=$($script:RecoveryErrors.Count). " +
        "The recovery tasks and durable rollback payload remain armed."
    )
    $script:RecoveryAttemptStatus = "failed"
    $null = Save-RecoveryOperationStateSafely -Context "attempt.failed"
    try {
        Save-RecoveryLog
    } catch {
        Write-RecoveryLog "Recovery log archival failed: $($_.Exception.Message)"
    }
    exit 1
}
