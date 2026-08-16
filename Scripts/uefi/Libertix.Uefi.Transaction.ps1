#requires -Version 5.1

# Persistent transaction state and verified rollback orchestration.

function Save-LibertixTransactionStateAtomic {
    # Invoke-Revert depends entirely on this document to know whether the
    # Windows volume must be grown back and to which size. A torn write would
    # make rollback impossible after that volume has already been shrunk, so
    # publish it with the same-directory atomic rename used for the plan
    # and execution state. Depth 8 covers the nested SHA-256 maps.
    param([Parameter(Mandatory = $true)][object]$State)

    $fullPath = [IO.Path]::GetFullPath($TransactionStatePath)
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

        Publish-LibertixFileAtomic `
            -TemporaryPath $temporaryPath `
            -DestinationPath $fullPath `
            -BackupPath $backupPath
    } finally {
        if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
        if ([IO.File]::Exists($backupPath)) { [IO.File]::Delete($backupPath) }
    }
}

function Save-TransactionPreparationState {
    param([Parameter(Mandatory = $true)]$SystemPartition)

    $disk = Get-Disk -Number $SystemPartition.DiskNumber -ErrorAction Stop
    $state = [ordered]@{
        Version = 1
        DiskNumber = [int]$SystemPartition.DiskNumber
        DiskUniqueId = [string]$disk.UniqueId
        SystemDrive = $SystemDrive
        OriginalCSize = [int64]$SystemPartition.Size
        PartitionNumber = 0
        PartitionOffset = 0
        PartitionSize = 0
        Label = $InstallerLabel
        BootStrategy = $BootStrategy
        RecoveryRoot = $RecoveryRoot
        RecoveryRunId = $RecoveryRunId
        OriginalBootOrder = @()
        InstallerBootNumber = $null
        InstallerBootVariable = ""
        FirmwareEntryId = ""
        EspLoaderSha256 = @{}
        InstallerFileSha256 = @{}
        OriginalHibernateEnabled = Get-HibernateEnabled
        LowMemoryMode = [bool]$LowMemoryMode
        CreatedUtc = [DateTime]::UtcNow.ToString("o")
    }
    $directory = Split-Path -Parent $TransactionStatePath
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    Save-LibertixTransactionStateAtomic -State $state
}

function Save-TransactionPartitionState {
    param([Parameter(Mandatory = $true)]$Partition)

    $disk = Get-Disk -Number $Partition.DiskNumber -ErrorAction Stop
    $existing = Get-TransactionPartitionState
    $originalCSize = if ($existing -and $existing.OriginalCSize) {
        [int64]$existing.OriginalCSize
    } else {
        [int64](Get-Partition -DriveLetter $SystemDriveLetter -ErrorAction Stop).Size
    }
    $state = [ordered]@{
        Version = 1
        DiskNumber = [int]$Partition.DiskNumber
        DiskUniqueId = [string]$disk.UniqueId
        SystemDrive = if (
            $existing -and
            $existing.PSObject.Properties.Name -contains "SystemDrive" -and
            $existing.SystemDrive
        ) { [string]$existing.SystemDrive } else { $SystemDrive }
        OriginalCSize = $originalCSize
        PartitionNumber = [int]$Partition.PartitionNumber
        PartitionOffset = [int64]$Partition.Offset
        PartitionSize = [int64]$Partition.Size
        Label = $InstallerLabel
        BootStrategy = if ($existing -and $existing.BootStrategy) { [string]$existing.BootStrategy } else { $BootStrategy }
        RecoveryRoot = if ($existing -and $existing.RecoveryRoot) { [string]$existing.RecoveryRoot } else { $RecoveryRoot }
        RecoveryRunId = if ($existing -and $existing.RecoveryRunId) { [string]$existing.RecoveryRunId } else { $RecoveryRunId }
        OriginalBootOrder = if ($existing -and $existing.OriginalBootOrder) { @($existing.OriginalBootOrder) } else { @() }
        InstallerBootNumber = if ($existing) { $existing.InstallerBootNumber } else { $null }
        InstallerBootVariable = if ($existing) { [string]$existing.InstallerBootVariable } else { "" }
        FirmwareEntryId = if ($existing) { [string]$existing.FirmwareEntryId } else { "" }
        EspLoaderSha256 = if ($existing -and $existing.EspLoaderSha256) { $existing.EspLoaderSha256 } else { @{} }
        InstallerFileSha256 = if ($existing -and $existing.InstallerFileSha256) { $existing.InstallerFileSha256 } else { @{} }
        OriginalHibernateEnabled = if (
            $existing -and
            $existing.PSObject.Properties.Name -contains "OriginalHibernateEnabled" -and
            $null -ne $existing.OriginalHibernateEnabled
        ) {
            $existing.OriginalHibernateEnabled
        } else {
            Get-HibernateEnabled
        }
        LowMemoryMode = if (
            $existing -and
            $existing.PSObject.Properties.Name -contains "LowMemoryMode"
        ) {
            [bool]$existing.LowMemoryMode
        } else {
            [bool]$LowMemoryMode
        }
        CreatedUtc = [DateTime]::UtcNow.ToString("o")
    }
    $directory = Split-Path -Parent $TransactionStatePath
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    Save-LibertixTransactionStateAtomic -State $state
}

function Get-TransactionPartitionState {
    if (-not (Test-Path -LiteralPath $TransactionStatePath -PathType Leaf)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $TransactionStatePath -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Invalid UEFI transaction state file: $($_.Exception.Message)"
    }
}

function Assert-LibertixTransactionRecoveryRunId {
    param([Parameter(Mandatory = $true)][string]$ExpectedRecoveryRunId)

    if ($ExpectedRecoveryRunId -notmatch '^[0-9a-f]{32}$') {
        throw "A valid ExpectedRecoveryRunId is required for UEFI rollback."
    }
    $state = Get-TransactionPartitionState
    if (-not $state) {
        return
    }
    if (
        -not ($state.PSObject.Properties.Name -contains "RecoveryRunId") -or
        [string]$state.RecoveryRunId -ne $ExpectedRecoveryRunId
    ) {
        throw "The UEFI transaction belongs to another recovery run; refusing rollback."
    }
}

function Restore-LibertixTransactionWindowsSettings {
    $state = Get-TransactionPartitionState
    if (-not $state) {
        throw "UEFI transaction state is missing; Windows settings cannot be restored."
    }
    if (
        $state.PSObject.Properties.Name -contains "OriginalHibernateEnabled" -and
        $null -ne $state.OriginalHibernateEnabled
    ) {
        $expected = [bool]$state.OriginalHibernateEnabled
        if ($expected -ne (Get-HibernateEnabled)) {
            Set-HibernateEnabled -Enabled $expected
        }
        if ($expected -ne (Get-HibernateEnabled)) {
            throw "Windows hibernation did not return to its pre-installation state."
        }
    }
}

function Save-PreparedInstallerManifest {
    param([Parameter(Mandatory = $true)][string]$InstallerDrive)

    $state = Get-TransactionPartitionState
    if (-not $state) {
        throw "Cannot save prepared installer manifest without transaction state."
    }
    $manifest = Get-FileHashManifest `
        -Root "$InstallerDrive\" `
        -RelativePaths (Get-InstallerManifestRelativePaths)
    $state | Add-Member -NotePropertyName InstallerFileSha256 -NotePropertyValue $manifest -Force
    $state | Add-Member -NotePropertyName InstallerManifestUtc -NotePropertyValue ([DateTime]::UtcNow.ToString("o")) -Force
    Save-LibertixTransactionStateAtomic -State $state
    Write-Log "Prepared installer SHA256 manifest saved ($($manifest.Count) files)." "Green"
}

function Assert-PreparedInstallerManifest {
    param([Parameter(Mandatory = $true)][string]$InstallerDrive)

    $state = Get-TransactionPartitionState
    if (-not $state -or -not $state.InstallerFileSha256) {
        throw "Prepared installer SHA256 manifest is missing; refusing firmware fallback."
    }
    $expectedPaths = @(Get-InstallerManifestRelativePaths)
    $savedProperties = @($state.InstallerFileSha256.PSObject.Properties)
    if ($savedProperties.Count -ne $expectedPaths.Count) {
        throw "Prepared installer SHA256 manifest is incomplete; refusing firmware fallback."
    }
    foreach ($relativePath in $expectedPaths) {
        $saved = $state.InstallerFileSha256.PSObject.Properties[$relativePath]
        if (-not $saved -or [string]::IsNullOrWhiteSpace([string]$saved.Value)) {
            throw "Prepared installer SHA256 manifest has no hash for $relativePath"
        }
        $fullPath = Join-Path "$InstallerDrive\" $relativePath
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "Prepared installer verification failed; missing $relativePath"
        }
        $actual = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($actual -ne ([string]$saved.Value).ToLowerInvariant()) {
            throw "Prepared installer SHA256 mismatch: $relativePath"
        }
    }
    Write-Log "Prepared installer SHA256 manifest verified ($($expectedPaths.Count) files)." "Green"
}

function Update-TransactionFirmwareState {
    param(
        [Parameter(Mandatory = $true)][uint16]$BootNumber,
        [Parameter(Mandatory = $true)][string]$BootVariable,
        [string]$FirmwareEntryId = "",
        [hashtable]$EspLoaderSha256 = @{},
        [uint16[]]$OriginalBootOrder = @()
    )

    $state = Get-TransactionPartitionState
    if (-not $state) {
        throw "Cannot save UEFI firmware state without a transaction state file."
    }

    $state | Add-Member -NotePropertyName BootStrategy -NotePropertyValue $BootStrategy -Force
    $state | Add-Member -NotePropertyName InstallerBootNumber -NotePropertyValue ([int]$BootNumber) -Force
    $state | Add-Member -NotePropertyName InstallerBootVariable -NotePropertyValue $BootVariable -Force
    $state | Add-Member -NotePropertyName FirmwareEntryId -NotePropertyValue $FirmwareEntryId -Force
    $state | Add-Member -NotePropertyName EspLoaderSha256 -NotePropertyValue $EspLoaderSha256 -Force
    $state | Add-Member -NotePropertyName OriginalBootOrder -NotePropertyValue @($OriginalBootOrder | ForEach-Object { [int]$_ }) -Force
    $state | Add-Member -NotePropertyName BootPreparedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString("o")) -Force
    Save-LibertixTransactionStateAtomic -State $state
}

function Update-TransactionBcdEntryState {
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}$')]
        [string]$FirmwareEntryId
    )

    $state = Get-TransactionPartitionState
    if (-not $state) {
        throw "Cannot save the BCD firmware owner without a transaction state file."
    }
    if (
        -not ($state.PSObject.Properties.Name -contains "RecoveryRunId") -or
        [string]$state.RecoveryRunId -ne $RecoveryRunId
    ) {
        throw "The BCD firmware owner does not match the active recovery run."
    }

    $state | Add-Member `
        -NotePropertyName FirmwareEntryId `
        -NotePropertyValue $FirmwareEntryId `
        -Force
    $state | Add-Member `
        -NotePropertyName BcdEntryCreatedUtc `
        -NotePropertyValue ([DateTime]::UtcNow.ToString("o")) `
        -Force
    Save-LibertixTransactionStateAtomic -State $state
}

function Get-ValidatedLibertixTransactionState {
    $state = Get-TransactionPartitionState
    if (-not $state) {
        return $null
    }
    if (
        -not ($state.PSObject.Properties.Name -contains "RecoveryRunId") -or
        [string]$state.RecoveryRunId -notmatch '^[0-9a-f]{32}$'
    ) {
        throw "UEFI transaction recovery identity is invalid."
    }
    if (-not ($state.PSObject.Properties.Name -contains "RecoveryRoot")) {
        throw "UEFI transaction recovery root is missing."
    }

    $expectedRoot = [IO.Path]::GetFullPath(
        (Join-Path $env:ProgramData "Libertix\UefiRecovery\$($state.RecoveryRunId)")
    ).TrimEnd('\')
    $actualRoot = [IO.Path]::GetFullPath([string]$state.RecoveryRoot).TrimEnd('\')
    if (-not $actualRoot.Equals($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "UEFI transaction recovery root does not match its recovery identity."
    }
    return $state
}

function Save-LibertixRollbackTransactionArchive {
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[0-9a-f]{32}$')]
        [string]$ExpectedRecoveryRunId
    )

    $state = Get-ValidatedLibertixTransactionState
    if (-not $state -or [string]$state.RecoveryRunId -ne $ExpectedRecoveryRunId) {
        throw "UEFI transaction changed before rollback archival."
    }
    $state | Add-Member -NotePropertyName Status -NotePropertyValue "rolled-back" -Force
    $state | Add-Member `
        -NotePropertyName RolledBackUtc `
        -NotePropertyValue ([DateTime]::UtcNow.ToString("o")) `
        -Force
    Save-LibertixTransactionStateAtomic -State $state

    [IO.Directory]::CreateDirectory([string]$state.RecoveryRoot) | Out-Null
    $destination = Join-Path ([string]$state.RecoveryRoot) "uefi-transaction.json"
    $temporary = Join-Path `
        ([string]$state.RecoveryRoot) `
        ".uefi-transaction.$([Guid]::NewGuid().ToString('N')).tmp"
    $backup = Join-Path `
        ([string]$state.RecoveryRoot) `
        ".uefi-transaction.$([Guid]::NewGuid().ToString('N')).bak"
    try {
        Copy-Item -LiteralPath $TransactionStatePath -Destination $temporary -Force -ErrorAction Stop
        Publish-LibertixFileAtomic `
            -TemporaryPath $temporary `
            -DestinationPath $destination `
            -BackupPath $backup
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
    }
    Write-Log "UEFI rollback transaction state archived permanently." "Green"
}

function Remove-LibertixRecoveryTasksForRunId {
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[0-9a-f]{32}$')]
        [string]$RunId
    )

    foreach ($taskName in @(
        "LibertixUefiRecovery_$RunId",
        "LibertixUefiRecoveryPrompt_$RunId"
    )) {
        Unregister-ScheduledTask `
            -TaskName $taskName `
            -Confirm:$false `
            -ErrorAction SilentlyContinue
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            throw "Recovery task still exists after removal: $taskName"
        }
    }
}

function Get-VerifiedTransactionPartition {
    param([switch]$AllowMissing)

    $state = Get-TransactionPartitionState
    if (-not $state) {
        return $null
    }
    if ([int]$state.PartitionNumber -le 0) {
        return $null
    }
    $diskNumber = [int]$state.DiskNumber
    $disk = Get-Disk -Number $diskNumber -ErrorAction Stop
    if (([string]$disk.UniqueId).Trim() -ne ([string]$state.DiskUniqueId).Trim()) {
        throw "UEFI transaction partition identity does not match the saved state."
    }

    $partitionMatches = @(
        Get-Partition -DiskNumber $diskNumber -ErrorAction Stop |
            Where-Object {
                [int64]$_.Offset -eq [int64]$state.PartitionOffset -and
                [int64]$_.Size -eq [int64]$state.PartitionSize
            }
    )
    if (
        $partitionMatches.Count -eq 0 -and
        $null -ne $installationPlan -and
        [string]$installationPlan.disk.installer.resizeMode -eq "live-offline" -and
        [string]$installationPlan.runtime.recoveryRunId -eq [string]$state.RecoveryRunId -and
        [int]$installationPlan.disk.number -eq $diskNumber
    ) {
        [int64]$finalOffset = [int64]$installationPlan.disk.installer.finalOffsetBytes
        [int64]$finalSize = [int64]$installationPlan.disk.installer.finalSizeBytes
        $partitionMatches = @(
            Get-Partition -DiskNumber $diskNumber -ErrorAction Stop |
                Where-Object {
                    [int64]$_.Offset -eq $finalOffset -and
                    [int64]$_.Size -eq $finalSize
                }
        )
        if ($partitionMatches.Count -eq 1) {
            $state.PartitionNumber = [int]$partitionMatches[0].PartitionNumber
            $state.PartitionOffset = $finalOffset
            $state.PartitionSize = $finalSize
            Save-LibertixTransactionStateAtomic -State $state
            Write-Log (
                "Resolved the offline-resized UEFI partition from the durable plan: " +
                "disk=$diskNumber offset=$finalOffset size=$finalSize."
            ) "Yellow"
        }
    }
    if ($partitionMatches.Count -eq 0 -and $AllowMissing) {
        Write-Log (
            "The saved UEFI transaction partition is already absent: " +
            "disk=$diskNumber offset=$($state.PartitionOffset) size=$($state.PartitionSize)."
        ) "Yellow"
        return $null
    }
    if ($partitionMatches.Count -ne 1) {
        throw (
            "UEFI transaction partition geometry is ambiguous: disk=$diskNumber " +
            "offset=$($state.PartitionOffset) size=$($state.PartitionSize) " +
            "matches=$($partitionMatches.Count)."
        )
    }
    $partition = $partitionMatches[0]
    if ([int]$state.PartitionNumber -ne [int]$partition.PartitionNumber) {
        Write-Log "Windows renumbered the transaction partition from $($state.PartitionNumber) to $($partition.PartitionNumber); updating saved state." "Yellow"
        $state.PartitionNumber = [int]$partition.PartitionNumber
        Save-LibertixTransactionStateAtomic -State $state
    }
    return $partition
}

function Invoke-Revert {
    Write-Log "Reverting Libertix UEFI installer changes..." "Cyan"

    $rollbackState = Get-TransactionPartitionState
    if (-not $rollbackState -and (Test-LibertixTrackedExecution)) {
        $executionState = Read-LibertixExecutionState -Path $ExecutionStatePath
        $stateDependentSteps = @(
            "windows.system-volume-shrunk",
            "windows.installer-partition-created",
            "windows.live-media-prepared",
            "windows.temporary-boot-prepared"
        )
        $uncompensatedStateDependentSteps = @(
            $executionState.completedSteps |
                Where-Object {
                    $_ -in $stateDependentSteps -and
                    $_ -notin @($executionState.compensatedSteps)
                }
        )
        if ($uncompensatedStateDependentSteps.Count -gt 0) {
            throw (
                "UEFI transaction state is missing while rollback still requires " +
                "'$($uncompensatedStateDependentSteps[0])'; refusing unverified recovery."
            )
        }
    }
    if ($rollbackState) {
        Assert-LibertixTransactionRecoveryRunId -ExpectedRecoveryRunId $RecoveryRunId
    }

    $esp = $null
    try {
        $esp = Mount-Esp -Letter $EspLetter

        Remove-LibertixTemporaryEspFiles -EspDrive $esp

        # A post-install rollback also owns the final loader, but only when its
        # durable ESP marker matches this exact recovery run.
        if (Assert-LibertixInstalledEspOwnership -EspDrive $esp) {
            Remove-LibertixInstalledFirmwareEntries -EspDrive $esp
            Remove-LibertixInstalledEspFiles -EspDrive $esp
        }

        Remove-LibertixTemporaryFirmwareEntries `
            -ExpectedLoaderPath "\$InstallerEspDirectory\BOOTX64.EFI"
        Restore-OriginalFirmwareBootOrder
        Complete-LibertixTrackedCompensation -Step "windows.temporary-boot-prepared"

    } finally {
        if ($esp) { Dismount-Letter -Letter $EspLetter }
    }

    Remove-LibertixInstallerPartitionIfPresent
    $transactionUsedLowMemory = (
        $rollbackState -and
        $rollbackState.PSObject.Properties.Name -contains "LowMemoryMode" -and
        [bool]$rollbackState.LowMemoryMode
    )
    if ($transactionUsedLowMemory -and (Test-Path -LiteralPath $LowMemoryIsoPath -PathType Leaf)) {
        Write-Log "Removing low-memory live ISO: $LowMemoryIsoPath" "Cyan"
        Remove-Item -LiteralPath $LowMemoryIsoPath -Force -ErrorAction Stop
    }
    Complete-LibertixTrackedCompensation -Step "windows.live-media-prepared"
    Complete-LibertixTrackedCompensation -Step "windows.installer-partition-created"
    if (-not $rollbackState) {
        # No transaction state means the workflow failed before Windows was resized.
        # Remove-LibertixInstallerPartitionIfPresent already refuses to continue
        # if an unowned staging partition exists, so there is nothing left
        # to restore in this early-failure case.
        Write-Log "No transaction state found; $SystemDrive was not resized by this run." "Gray"
        Remove-LibertixTransactionDownloads `
            -SystemDrive $SystemDrive `
            -PlanId $RecoveryRunId
        Remove-LibertixRecoveryTasksForRunId -RunId $RecoveryRunId
        Remove-LibertixUefiToolArtifacts -SystemDrive $SystemDrive
        Complete-LibertixTrackedCompensation -Step "windows.recovery-armed"
        Complete-LibertixTrackedRollback
        Write-Log "Revert complete." "Green"
        return
    }
    Restore-LibertixSystemDriveInitialSize -State $rollbackState
    Complete-LibertixTrackedCompensation -Step "windows.system-volume-shrunk"

    # Hibernation is switched off so that the installed Linux can safely mount
    # Windows read-write. A rollback removes that Linux installation, so the
    # user's original setting must come back with it.
    if (
        $rollbackState.PSObject.Properties.Name -contains "OriginalHibernateEnabled" -and
        $null -ne $rollbackState.OriginalHibernateEnabled
    ) {
        $originalHibernate = [bool]$rollbackState.OriginalHibernateEnabled
        if ($originalHibernate -ne (Get-HibernateEnabled)) {
            Set-HibernateEnabled -Enabled $originalHibernate
        }
    }

    Remove-LibertixRecoveryTasksForRunId -RunId $RecoveryRunId
    Remove-LibertixTransactionDownloads `
        -SystemDrive $SystemDrive `
        -PlanId $RecoveryRunId
    Remove-LibertixUefiToolArtifacts `
        -SystemDrive $SystemDrive `
        -PreserveTransactionState
    Complete-LibertixTrackedCompensation -Step "windows.recovery-armed"
    Complete-LibertixTrackedRollback

    # Keep the active owner document until every physical compensation and the
    # execution ledger are terminal. A later retry can then finish archival if
    # power is lost at any preceding boundary.
    Save-LibertixRollbackTransactionArchive -ExpectedRecoveryRunId $RecoveryRunId
    Remove-Item -LiteralPath $TransactionStatePath -Force -ErrorAction Stop
    Remove-LibertixUefiToolArtifacts -SystemDrive $SystemDrive

    Write-Log "Revert complete." "Green"
}
