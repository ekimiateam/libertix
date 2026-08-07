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

function Get-VerifiedTransactionPartition {
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
    if ($partitionMatches.Count -ne 1) {
        throw "UEFI transaction partition geometry does not resolve to exactly one partition."
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

    $esp = $null
    try {
        $esp = Mount-Esp -Letter $EspLetter

        foreach ($relativeDir in @("EFI\LibertixInstaller")) {
            $path = Join-Path $esp $relativeDir
            if (Test-Path $path) {
                Write-Log "Removing ESP directory: $relativeDir" "Cyan"
                Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
            }
        }

        Remove-LibertixTemporaryFirmwareEntries
        Restore-OriginalFirmwareBootOrder
        Complete-LibertixTrackedCompensation -Step "windows.temporary-boot-prepared"

    } finally {
        if ($esp) { Dismount-Letter -Letter $EspLetter }
    }

    $rollbackState = Get-TransactionPartitionState
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
        # if an unowned LIBERTIXEFI partition exists, so there is nothing left
        # to restore in this early-failure case.
        Write-Log "No transaction state found; $SystemDrive was not resized by this run." "Gray"
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

    Remove-Item -LiteralPath $TransactionStatePath -Force -ErrorAction SilentlyContinue
    Complete-LibertixTrackedCompensation -Step "windows.recovery-armed"

    Write-Log "Revert complete." "Green"
}
