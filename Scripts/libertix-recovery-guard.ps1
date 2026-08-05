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
$ArchiveLog = Join-Path $ArchiveRoot "windows-recovery.log"
$BcdBackup = Join-Path $Root "bcd-backup"
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
    try {
        schtasks.exe /Delete /TN $TaskName /F | Out-Null
    } catch {
        Write-RecoveryLog "Task cleanup failed: $($_.Exception.Message)"
    }
}

function Save-RecoveryLog {
    New-Item -ItemType Directory -Force -Path $ArchiveRoot | Out-Null
    if (Test-Path $Log) {
        Add-Content -Path $ArchiveLog -Value ("===== Libertix recovery guard {0} =====" -f (Get-Date -Format o))
        Get-Content $Log | Add-Content -Path $ArchiveLog
    }
}

function Restore-BcdState {
    if (-not (Test-Path -LiteralPath $BcdBackup -PathType Leaf)) {
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
    if ($success -eq "true" -and $resultIsFresh) {
        Write-RecoveryLog "Successful install marker found; no disk rollback needed."
        Remove-TemporaryBootPayload
        Invoke-WindowsShareFinalize
        Remove-RecoveryTask
        Save-RecoveryLog
        Remove-Item -Path $Root -Recurse -Force -ErrorAction SilentlyContinue
        exit 0
    }

    $expectedMbText = Read-EnvValue -Path $Pending -Name "LINUX_SIZE_MB"
    $stagingMbText = Read-EnvValue -Path $Pending -Name "STAGING_SIZE_MB"
    $diskNumberText = Read-EnvValue -Path $Pending -Name "SYSTEM_DISK_NUMBER"
    $systemPartitionNumberText = Read-EnvValue -Path $Pending -Name "SYSTEM_PARTITION_NUMBER"
    $initialSystemSizeText = Read-EnvValue -Path $Pending -Name "SYSTEM_PARTITION_SIZE_BYTES"
    $expectedDiskId = Read-EnvValue -Path $Pending -Name "SYSTEM_DISK_UNIQUE_ID"
    $recoveryPartitionOffsetText = Read-EnvValue `
        -Path $Pending `
        -Name "RECOVERY_PARTITION_OFFSET_BYTES"
    if (-not $expectedMbText -or -not $diskNumberText -or -not $systemPartitionNumberText -or -not $initialSystemSizeText) {
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
    $initialSystemSize = [int64]$initialSystemSizeText
    $recoveryPartitionOffset = if ($recoveryPartitionOffsetText) {
        [int64]$recoveryPartitionOffsetText
    } else {
        0
    }
    $minBytes = [int64]([Math]::Max(1024, $expectedMb - 1024)) * 1MB
    $maxBytes = [int64]($expectedMb + 1024) * 1MB
    $stagingMinBytes = [int64]([Math]::Max(1024, $stagingMb - 1024)) * 1MB
    $stagingMaxBytes = [int64]($stagingMb + 1024) * 1MB

    $systemPartition = Get-Partition -DriveLetter $SystemDriveLetter -ErrorAction Stop
    if ($systemPartition.DiskNumber -ne $diskNumber -or $systemPartition.PartitionNumber -ne $systemPartitionNumber) {
        throw "Windows system partition identity changed; refusing rollback."
    }
    $disk = Get-Disk -Number $diskNumber -ErrorAction Stop
    if ($expectedDiskId -and ([string]$disk.UniqueId).Trim() -ne $expectedDiskId.Trim()) {
        throw "Windows system disk identity changed; refusing rollback."
    }

    # A candidate must be unique, on the exact Windows disk, after the system partition, and
    # either be the known FAT32 staging/final size or the final ext4 size.
    $partitions = Get-Partition -DiskNumber $diskNumber | Sort-Object Offset
    $candidates = @()

    foreach ($partition in $partitions) {
        if ($partition.PartitionNumber -eq $systemPartition.PartitionNumber) {
            continue
        }
        if ($partition.Offset -lt $systemPartition.Offset) {
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
        $isLinux = ($fs -match "^(ext2|ext3|ext4)$")
        if (-not $isTemporaryFat -and -not $isLinux) {
            continue
        }

        $matchesFinalSize = ($partition.Size -ge $minBytes -and $partition.Size -le $maxBytes)
        $matchesStagingSize = (
            $partition.Size -ge $stagingMinBytes -and
            $partition.Size -le $stagingMaxBytes
        )
        if (($isTemporaryFat -and -not $matchesStagingSize -and -not $matchesFinalSize) -or
            ($isLinux -and -not $matchesFinalSize)) {
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
    }

    $currentSystemPartition = Get-Partition -DriveLetter $SystemDriveLetter -ErrorAction Stop
    if ($currentSystemPartition.Size -lt $initialSystemSize) {
        $supported = Wait-SystemDriveResizeCapacity `
            -DiskNumber $diskNumber `
            -RequiredSize $initialSystemSize
        if ($supported.SizeMax -lt $initialSystemSize) {
            throw "$SystemDrive cannot be restored to its initial size ($initialSystemSize); SizeMax=$($supported.SizeMax)."
        }
        Write-RecoveryLog "Restoring $SystemDrive to its exact initial size: $initialSystemSize bytes."
        Resize-Partition -DriveLetter $SystemDriveLetter -Size $initialSystemSize -ErrorAction Stop
    } else {
        Write-RecoveryLog "$SystemDrive is already at or above its initial size; resize skipped."
    }

    Restore-BcdState
    Remove-PendingWindowsSharePayload

    # Hibernation is switched off during preparation so the installed Linux can
    # safely mount Windows read-write. A rollback removes that installation, so
    # the user's original setting must come back with it.
    $originalHibernate = Read-EnvValue -Path $Pending -Name "ORIGINAL_HIBERNATE_ENABLED"
    if ($originalHibernate -eq "true") {
        Write-RecoveryLog "Restoring Windows hibernation and Fast Startup."
        $hibernateOutput = & "$env:SystemRoot\System32\powercfg.exe" /hibernate on 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Hibernation restore failed with rc=$LASTEXITCODE output=$($hibernateOutput -join ' ')"
        }
        $hibernateEnabled = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -Name "HibernateEnabled" -ErrorAction Stop).HibernateEnabled
        if ($hibernateEnabled -ne 1) {
            throw "Hibernation restore did not enable HibernateEnabled."
        }
    } elseif ($originalHibernate -eq "false") {
        Write-RecoveryLog "Hibernation was already disabled before installation; left off."
    } else {
        Write-RecoveryLog "Original hibernation state unknown; left unchanged."
    }

    Remove-TemporaryBootPayload

    $finalSystemPartition = Get-Partition -DriveLetter $SystemDriveLetter -ErrorAction Stop
    if ($finalSystemPartition.Size -lt $initialSystemSize) {
        throw "$SystemDrive rollback verification failed: size=$($finalSystemPartition.Size), expected=$initialSystemSize."
    }

    Write-RecoveryLog "Recovery completed and verified."
    Remove-RecoveryTask
    Save-RecoveryLog
    Remove-Item -Path $Root -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
} catch {
    Write-RecoveryLog "Recovery failed: $($_.Exception.Message)"
    exit 1
}
