param()

$ErrorActionPreference = "Stop"

$SystemDrive = [string]$env:SystemDrive
if ($SystemDrive -notmatch "^[A-Za-z]:$") {
    throw "SystemDrive must be a valid Windows drive designator."
}
$SystemDriveLetter = $SystemDrive.Substring(0, 1)
$ProgramDataRoot = Join-Path $SystemDrive "ProgramData"
$Root = Join-Path $SystemDrive "LibertixInstallRecovery"
$TaskName = "LibertixInstallRecovery"
$Log = Join-Path $Root "recovery.log"
$Pending = Join-Path $Root "pending.env"
$ArchiveRoot = Join-Path $SystemDrive "LibertixInstallLogs"
$Result = Join-Path $ArchiveRoot "latest\result.env"
$LiveStartedMarker = Join-Path $Root "live-started.env"
$LiveFailedMarker = Join-Path $Root "live-failed.env"
$InstallSuccessMarker = Join-Path $Root "install-success.env"
$ArchiveLog = Join-Path $ArchiveRoot "windows-recovery.log"
$BcdBackup = Join-Path $Root "bcd-backup"
$ExecutionStatePath = Join-Path $Root "installation-state.json"
$ExecutionStateModulePath = Join-Path $Root "Libertix.InstallationState.psm1"
$TemporaryBootFiles = @(
    (Join-Path $SystemDrive "grldr"),
    (Join-Path $SystemDrive "grldr.mbr"),
    (Join-Path $SystemDrive "menu.lst"),
    (Join-Path $SystemDrive "libertix-live.iso")
)
$WindowsShareRoot = Join-Path $ProgramDataRoot "Libertix\WindowsShare"

function Write-RecoveryLog {
    param([string]$Message)
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    Add-Content -Path $Log -Value ("[{0}] {1}" -f (Get-Date -Format o), $Message)
}

function Read-EnvValue {
    param(
        [string]$Path,
        [string]$Name
    )

    if (-not (Test-Path $Path)) {
        return $null
    }

    $line = Get-Content $Path | Where-Object { $_ -match "^$([regex]::Escape($Name))=" } | Select-Object -First 1
    if (-not $line) {
        return $null
    }

    return ($line -replace "^$([regex]::Escape($Name))=", "").Trim()
}

function Remove-RecoveryTask {
    param([switch]$Required)

    $deleteOutput = & schtasks.exe /Delete /TN $TaskName /F 2>&1
    $deleteExitCode = $LASTEXITCODE
    if ($deleteExitCode -ne 0) {
        $message = "Recovery task cleanup failed with rc=$deleteExitCode output=$($deleteOutput -join ' ')"
        if ($Required) {
            throw $message
        }
        Write-RecoveryLog $message
        return
    }

    if ($Required) {
        $null = & schtasks.exe /Query /TN $TaskName 2>&1
        if ($LASTEXITCODE -eq 0) {
            throw "Recovery task still exists after deletion."
        }
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
    if ([string]$state.status -in @("running", "failed")) {
        $null = Start-LibertixRollback -Path $ExecutionStatePath
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
    New-Item -ItemType Directory -Force -Path $ArchiveRoot | Out-Null
    if (Test-Path $Log) {
        Add-Content -Path $ArchiveLog -Value ("===== Libertix recovery guard {0} =====" -f (Get-Date -Format o))
        Get-Content $Log | Add-Content -Path $ArchiveLog
    }
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
        Write-RecoveryLog "Hibernation was already disabled before installation; left off."
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
    Write-RecoveryLog "BCD state restored from the pre-install backup."
}

function Remove-TemporaryBootPayload {
    foreach ($temporaryBootFile in $TemporaryBootFiles) {
        if (Test-Path -LiteralPath $temporaryBootFile -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryBootFile -Force -ErrorAction Stop
            Write-RecoveryLog "Removed temporary boot file: $temporaryBootFile"
        }
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

function Remove-PendingWindowsSharePayload {
    if (Test-Path -LiteralPath (Join-Path $WindowsShareRoot "pending.marker") -PathType Leaf) {
        Remove-Item -LiteralPath $WindowsShareRoot -Recurse -Force -ErrorAction SilentlyContinue
        Write-RecoveryLog "Removed pending Windows sharing payload."
    }
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
            $isExtendedType -and
                $partitionStart -ge $SystemPartitionEnd -and
                $partitionStart -le $TransactionOffset -and
                $partitionEnd -ge $transactionEnd -and
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
    Write-RecoveryLog "Recovery guard started."
    $script:TrackRecoveryExecutionState = $false
    $recoveryExecutionState = Read-RecoveryExecutionState

    $expectedRecoveryRunId = Read-EnvValue -Path $Pending -Name "RECOVERY_RUN_ID"
    $successRecoveryRunId = Read-EnvValue `
        -Path $InstallSuccessMarker `
        -Name "LIBERTIX_BIOS_RECOVERY_RUN_ID"
    $successRecoveryState = Read-EnvValue `
        -Path $InstallSuccessMarker `
        -Name "LIBERTIX_BIOS_RECOVERY_STATE"
    if (
        -not [string]::IsNullOrWhiteSpace($expectedRecoveryRunId) -and
        $successRecoveryRunId -eq $expectedRecoveryRunId -and
        $successRecoveryState -eq "install-success" -and
        [string]$recoveryExecutionState.status -eq "succeeded"
    ) {
        Write-RecoveryLog "Dedicated successful install marker found; no disk rollback needed."
        Restore-BcdState -Required
        Remove-TemporaryBootPayload
        Invoke-WindowsShareFinalize
        Remove-RecoveryTask
        Save-RecoveryLog
        Remove-Item -Path $Root -Recurse -Force -ErrorAction SilentlyContinue
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
    # the Windows guard only cleans up its scheduled task and leaves disks alone.
    $success = Read-EnvValue -Path $Result -Name "LIBERTIX_INSTALL_SUCCESS"
    $resultIsFresh = (
        (Test-Path -LiteralPath $Result -PathType Leaf) -and
        (Test-Path -LiteralPath $Pending -PathType Leaf) -and
        ((Get-Item -LiteralPath $Result).LastWriteTimeUtc -gt (Get-Item -LiteralPath $Pending).LastWriteTimeUtc)
    )
    if (
        $success -eq "true" -and
        $resultIsFresh -and
        [string]$recoveryExecutionState.status -eq "succeeded"
    ) {
        Write-RecoveryLog "Successful install marker found; no disk rollback needed."
        Restore-BcdState -Required
        Remove-TemporaryBootPayload
        Invoke-WindowsShareFinalize
        Remove-RecoveryTask
        Save-RecoveryLog
        Remove-Item -Path $Root -Recurse -Force -ErrorAction SilentlyContinue
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
    if ($liveRollbackCompleted) {
        Write-RecoveryLog (
            "The live installer reported failure after a verified rollback; " +
            "restoring Windows settings and retiring the recovery task."
        )
        Restore-BcdState -Required
        Remove-PendingWindowsSharePayload
        Restore-OriginalHibernationSetting
        Remove-TemporaryBootPayload
        Remove-RecoveryTask -Required
        Save-RecoveryLog
        Remove-Item -Path $Root -Recurse -Force -ErrorAction SilentlyContinue
        exit 0
    }
    if ($liveStartedWithoutFailure) {
        Write-RecoveryLog (
            "The live installer started but produced neither a success nor a failure marker. " +
            "Refusing automatic disk rollback without positive failure evidence."
        )
        Save-RecoveryLog
        exit 2
    }

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
    [int64]$partitionSizeTolerance = 1MB
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
    $alignmentPadding = ($initialSystemOffset + $initialSystemSize) % 1MB
    $expectedTransactionOffset = `
        $initialSystemOffset + $initialSystemSize - $alignmentPadding - $expectedBytes
    $candidateOffsets = @(
        [int64]($expectedTransactionOffset - 1MB),
        [int64]$expectedTransactionOffset,
        [int64]($expectedTransactionOffset + 1MB)
    )

    $systemPartition = Get-Partition -DriveLetter $SystemDriveLetter -ErrorAction Stop
    if ($systemPartition.DiskNumber -ne $diskNumber -or $systemPartition.PartitionNumber -ne $systemPartitionNumber) {
        throw "Windows system partition identity changed; refusing rollback."
    }
    $disk = Get-Disk -Number $diskNumber -ErrorAction Stop
    if ($expectedDiskId -and ([string]$disk.UniqueId).Trim() -ne $expectedDiskId.Trim()) {
        throw "Windows system disk identity changed; refusing rollback."
    }

    # Windows may represent the fourth MBR slot as an extended container and a
    # logical partition one alignment unit later. Accept only the three exact
    # offsets produced by the old layout, the current logical layout, or a
    # primary-partition layout, and never treat the container itself as data.
    $partitions = Get-Partition -DiskNumber $diskNumber | Sort-Object Offset
    $candidates = @()

    foreach ($partition in $partitions) {
        if ($partition.PartitionNumber -eq $systemPartition.PartitionNumber) {
            continue
        }
        if (
            [int]$partition.MbrType -in @(5, 15, 133) -or
            [int64]$partition.Offset -notin $candidateOffsets
        ) {
            continue
        }

        $volume = $null
        try {
            $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
        } catch {
            $volume = $null
        }

        $label = if ($volume) { [string]$volume.FileSystemLabel } else { "" }
        $fs = if ($volume) { [string]$volume.FileSystem } else { "" }
        $letter = if ($volume) { [string]$volume.DriveLetter } else { "" }

        $isTemporaryFat = ($label -eq "LIBERTIX")
        $isLinuxFileSystem = ($fs -match "^(ext2|ext3|ext4)$")
        $isRawTransaction = [string]::IsNullOrWhiteSpace($fs)
        if (-not $isTemporaryFat -and -not $isLinuxFileSystem -and -not $isRawTransaction) {
            continue
        }

        $matchesFinalSize = ($partition.Size -ge $minBytes -and $partition.Size -le $maxBytes)
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
        throw "Multiple temporary Linux partition candidates found; refusing ambiguous rollback."
    }

    if (@($candidates).Count -eq 1) {
        $candidate = $candidates[0]
        $number = $candidate.Partition.PartitionNumber
        $candidateOffset = [int64]$candidate.Partition.Offset
        $candidateSize = [int64]$candidate.Partition.Size
        $systemPartitionEnd = [int64]$systemPartition.Offset + [int64]$systemPartition.Size
        $sizeMb = [Math]::Round($candidate.Partition.Size / 1MB, 0)
        Write-RecoveryLog "Removing transaction partition number=$number sizeMB=$sizeMb label=$($candidate.Label) fs=$($candidate.FileSystem)."
        Remove-Partition -DiskNumber $diskNumber -PartitionNumber $number -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds 2
        Remove-EmptyTransactionExtendedContainer `
            -DiskNumber $diskNumber `
            -TransactionOffset $candidateOffset `
            -TransactionSize $candidateSize `
            -SystemPartitionEnd $systemPartitionEnd `
            -RecoveryPartitionOffset $recoveryPartitionOffset
    } else {
        Write-RecoveryLog "No transaction partition exists; checking whether only the system partition needs extension."
        Remove-EmptyTransactionExtendedContainer `
            -DiskNumber $diskNumber `
            -TransactionOffset $expectedTransactionOffset `
            -TransactionSize $stagingBytes `
            -SystemPartitionEnd ([int64]$systemPartition.Offset + [int64]$systemPartition.Size) `
            -RecoveryPartitionOffset $recoveryPartitionOffset
    }

    $currentSystemPartition = Get-Partition -DriveLetter $SystemDriveLetter -ErrorAction Stop
    if ($currentSystemPartition.Size -ne $initialSystemSize) {
        $supported = Wait-SystemDriveResizeCapacity `
            -DiskNumber $diskNumber `
            -RequiredSize $initialSystemSize
        if ($supported.SizeMin -gt $initialSystemSize -or $supported.SizeMax -lt $initialSystemSize) {
            throw (
                "$SystemDrive cannot be restored to its initial size ($initialSystemSize); " +
                "SizeMin=$($supported.SizeMin), SizeMax=$($supported.SizeMax)."
            )
        }
        Write-RecoveryLog "Restoring $SystemDrive to its exact initial size: $initialSystemSize bytes."
        Resize-Partition -DriveLetter $SystemDriveLetter -Size $initialSystemSize -ErrorAction Stop
    } else {
        Write-RecoveryLog "$SystemDrive is already at or above its initial size; resize skipped."
    }

    Restore-BcdState
    Remove-PendingWindowsSharePayload

    # A rollback removes the installation that required Fast Startup to be
    # disabled, so restore the captured Windows setting before retiring guard.
    Restore-OriginalHibernationSetting

    Remove-TemporaryBootPayload

    $finalSystemPartition = Get-Partition -DriveLetter $SystemDriveLetter -ErrorAction Stop
    if ($finalSystemPartition.Size -ne $initialSystemSize) {
        throw "$SystemDrive rollback verification failed: size=$($finalSystemPartition.Size), expected=$initialSystemSize."
    }

    Complete-RecoveryCompensation -Step "windows.temporary-boot-prepared"
    Complete-RecoveryCompensation -Step "windows.live-media-prepared"
    Complete-RecoveryCompensation -Step "windows.installer-partition-created"
    Complete-RecoveryCompensation -Step "windows.system-volume-shrunk"

    Write-RecoveryLog "Recovery completed and verified."
    Remove-RecoveryTask -Required
    Complete-RecoveryCompensation -Step "windows.recovery-armed"
    if ($script:TrackRecoveryExecutionState) {
        $null = Complete-LibertixRollback -Path $ExecutionStatePath
    }
    Save-RecoveryLog
    exit 0
} catch {
    Write-RecoveryLog "Recovery failed: $($_.Exception.Message)"
    exit 1
}
