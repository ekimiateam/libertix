Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Libertix.StorageTargets.psm1') -ErrorAction Stop

function Assert-LibertixDiskMatchesPlan {
    param(
        [Parameter(Mandatory = $true)][object]$Disk,
        [Parameter(Mandatory = $true)][object]$PlanDisk
    )

    $tableIdentity = switch ([string]$Disk.PartitionStyle) {
        'GPT' {
            $guid = [guid]$Disk.Guid
            if ($guid -eq [guid]::Empty) { throw 'The disk has no GPT identity.' }
            'gpt:' + $guid.ToString('D').ToLowerInvariant()
        }
        'MBR' { 'mbr:' + ([uint32]$Disk.Signature).ToString('x8') }
        default { throw 'The disk no longer has a supported partition table.' }
    }
    # Storage UniqueId can be a vendor string shared by several virtual disks.
    if ([int]$Disk.Number -ne [int]$PlanDisk.number -or
        ([string]$Disk.UniqueId).Trim() -ne ([string]$PlanDisk.uniqueId).Trim() -or
        $tableIdentity -ne [string]$PlanDisk.partitionTableId -or
        [long]$Disk.Size -ne [long]$PlanDisk.sizeBytes -or
        [int]$Disk.LogicalSectorSize -ne [int]$PlanDisk.logicalSectorSizeBytes -or
        [string]$Disk.PartitionStyle -ne [string]$PlanDisk.partitionStyle) {
        throw 'Disk identity does not match the validated installation plan; refusing storage mutation.'
    }
}

function Test-BitLockerVolumeReadable {
    param([Parameter(Mandatory = $true)]$Volume)
    foreach ($field in @('VolumeStatus', 'EncryptionPercentage', 'ProtectionStatus')) {
        if ($Volume.PSObject.Properties.Name -notcontains $field -or $null -eq $Volume.$field) {
            return $false
        }
    }
    # BitLocker rounds its percentage: zero can still mean conversion in progress.
    # Wait for the terminal conversion state instead of treating rounding as proof.
    return [string]$Volume.VolumeStatus -eq 'FullyDecrypted' -and
        $Volume.EncryptionPercentage -eq 0 -and [string]$Volume.ProtectionStatus -in @('Off', '0')
}

function Wait-LibertixSystemDriveResizeCapacity {
    param(
        [Parameter(Mandatory = $true)][string]$DriveLetter,
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

        try {
            $partition = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop
            $supported = Get-PartitionSupportedSize -DriveLetter $DriveLetter -ErrorAction Stop
        } catch {
            if ([DateTime]::UtcNow -ge $deadline) {
                throw "Storage capacity for ${DriveLetter}: did not become readable within ${TimeoutSeconds}s: $($_.Exception.Message)"
            }
            Start-Sleep -Seconds 2
            continue
        }
        if ($partition.Size -ge $RequiredSize -or $supported.SizeMax -ge $RequiredSize) {
            return $supported
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            return $supported
        }
        Start-Sleep -Seconds 2
    } while ($true)
}

function Assert-LibertixSourceVolumeIdentity {
    param(
        [Parameter(Mandatory = $true)][object]$Partition,
        [Parameter(Mandatory = $true)][object]$PlanDisk,
        [Parameter(Mandatory = $true)][object]$SourcePartition,
        [Parameter(Mandatory = $true)][string]$DriveLetter,
        [string]$ExpectedVolumeId = ''
    )
    Assert-LibertixDiskMatchesPlan `
        -Disk (Get-Disk -Number $Partition.DiskNumber -ErrorAction Stop) -PlanDisk $PlanDisk
    if ([long]$Partition.Offset -ne [long]$SourcePartition.offsetBytes) {
        throw 'The source volume start changed; refusing rollback resize.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedVolumeId)) {
        $volume = Get-Volume -DriveLetter $DriveLetter -ErrorAction Stop
        if ([string]$volume.UniqueId -ne $ExpectedVolumeId -or [string]$volume.FileSystem -ne 'NTFS') {
            throw 'The source volume filesystem identity changed; refusing rollback resize.'
        }
        if ((Get-LibertixNtfsVolumeSerial -Drive ($DriveLetter.ToUpperInvariant() + ':')) -cne
            [string]$PlanDisk.sourceNtfsUuid) {
            throw 'The source NTFS serial changed; refusing rollback resize.'
        }
    }
}

function Restore-LibertixSourceVolumeInitialSize {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDrive,
        [Parameter(Mandatory = $true)][object]$PlanDisk,
        [Parameter(Mandatory = $true)][object]$SourcePartition,
        [string]$ExpectedVolumeId = ''
    )
    $initialSize = [long]$SourcePartition.sizeBytes
    $offset = [long]$SourcePartition.offsetBytes
    $sector = [int]$PlanDisk.logicalSectorSizeBytes
    if ($SourceDrive -notmatch '^[A-Za-z]:$' -or $sector -notin @(512, 4096) -or
        $offset -le 0 -or $initialSize -le 0 -or $initialSize -gt [long]$PlanDisk.sizeBytes -or
        $offset -gt ([long]$PlanDisk.sizeBytes - $initialSize) -or
        ($offset % $sector) -ne 0 -or ($initialSize % $sector) -ne 0) {
        throw 'Invalid source volume geometry in rollback plan.'
    }
    $driveLetter = $SourceDrive.TrimEnd(':')
    $partition = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
    $identityArguments = @{
        PlanDisk = $PlanDisk; SourcePartition = $SourcePartition
        DriveLetter = $driveLetter; ExpectedVolumeId = $ExpectedVolumeId
    }
    Assert-LibertixSourceVolumeIdentity -Partition $partition @identityArguments
    if ([int64]$partition.Size -gt $initialSize) {
        throw 'The source volume exceeds its original extent; refusing rollback shrink.'
    }
    if ($partition.Size -ne $initialSize) {
        $supported = Wait-LibertixSystemDriveResizeCapacity `
            -DriveLetter $driveLetter `
            -DiskNumber ([int]$partition.DiskNumber) `
            -RequiredSize $initialSize
        if ($supported.SizeMin -gt $initialSize -or $supported.SizeMax -lt $initialSize) {
            throw (
                "$SourceDrive cannot be restored to its initial size; " +
                "SizeMin=$($supported.SizeMin), SizeMax=$($supported.SizeMax)."
            )
        }
        $partition = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
        Assert-LibertixSourceVolumeIdentity -Partition $partition @identityArguments
        if ([long]$partition.Size -gt $initialSize) {
            throw 'The source volume size changed while waiting for resize capacity.'
        }
        Resize-Partition -DriveLetter $driveLetter -Size $initialSize -ErrorAction Stop
    }
    $verified = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
    Assert-LibertixDiskMatchesPlan `
        -Disk (Get-Disk -Number $verified.DiskNumber -ErrorAction Stop) -PlanDisk $PlanDisk
    if ($verified.Size -ne $initialSize -or
        [long]$verified.Offset -ne $offset) {
        throw "$SourceDrive rollback size verification failed."
    }
    Assert-LibertixSourceVolumeIdentity -Partition $verified @identityArguments
}

function Restore-LibertixSystemDriveInitialSize {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][object]$PlanDisk
    )
    if (-not $State.OriginalCSize) {
        throw 'Cannot restore the Windows system volume without the saved initial size.'
    }
    $hasSystemDrive = $State.PSObject.Properties.Name -contains 'SystemDrive'
    $systemDrive = if ($hasSystemDrive -and $State.SystemDrive) {
        [string]$State.SystemDrive
    } else {
        [string]$env:SystemDrive
    }
    if ($systemDrive -notmatch '^[A-Za-z]:$' -or
        $systemDrive -ne [string]$PlanDisk.systemDrive -or
        [int]$State.DiskNumber -ne [int]$PlanDisk.number -or
        ([string]$State.DiskUniqueId).Trim() -ne ([string]$PlanDisk.uniqueId).Trim() -or
        [long]$State.OriginalCSize -ne [long]$PlanDisk.windows.sizeBytes) {
        throw "$systemDrive disk identity changed; refusing rollback resize."
    }
    Restore-LibertixSourceVolumeInitialSize -SourceDrive $systemDrive `
        -PlanDisk $PlanDisk -SourcePartition $PlanDisk.windows
}

Export-ModuleMember -Function @(
    'Assert-LibertixSourceVolumeIdentity',
    'Test-BitLockerVolumeReadable', 'Assert-LibertixDiskMatchesPlan',
    'Restore-LibertixSystemDriveInitialSize', 'Restore-LibertixSourceVolumeInitialSize'
)
