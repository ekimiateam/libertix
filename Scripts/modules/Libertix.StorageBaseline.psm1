Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Libertix.Rollback.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Libertix.StorageTargets.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Libertix.AtomicFile.psm1') -ErrorAction Stop

function Get-LibertixPartitionRecord {
    param([Parameter(Mandatory = $true)][object]$Partition)

    [pscustomobject]@{
        number = [int]$Partition.PartitionNumber
        offsetBytes = [long]$Partition.Offset
        sizeBytes = [long]$Partition.Size
        guid = [string]$Partition.Guid
        gptType = [string]$Partition.GptType
        mbrType = [int]$Partition.MbrType
        isActive = [bool]$Partition.IsActive
        isHidden = [bool]$Partition.IsHidden
        isReadOnly = [bool]$Partition.IsReadOnly
        noDefaultDriveLetter = [bool]$Partition.NoDefaultDriveLetter
        accessPaths = @($Partition.AccessPaths | Sort-Object)
    }
}

function Get-LibertixStorageBaselineTargets {
    param([Parameter(Mandatory = $true)][object]$Plan)

    $Plan.disk
    if ([int]$Plan.schemaVersion -eq 5) { $Plan.allocation }
}

function Save-LibertixStorageBaseline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$RecoveryRoot
    )

    $path = Join-Path $RecoveryRoot 'storage-before-installation.json'
    if (Test-Path -LiteralPath $path) {
        throw 'The initial storage inventory already exists; refusing to replace recovery evidence.'
    }
    $targets = @(Get-LibertixStorageBaselineTargets -Plan $Plan)
    $records = @(foreach ($disk in @(Get-Disk -ErrorAction Stop)) {
        $record = [pscustomobject]@{
            number = [int]$disk.Number; uniqueId = ([string]$disk.UniqueId).Trim()
            sizeBytes = [long]$disk.Size; partitionStyle = [string]$disk.PartitionStyle
            logicalSectorSizeBytes = [int]$disk.LogicalSectorSize
            physicalSectorSizeBytes = [int]$disk.PhysicalSectorSize
            guid = [string]$disk.Guid; signature = [uint32]$disk.Signature
            partitions = @(); inventoryError = $null; sourceVolume = $null
        }
        try {
            $record.partitions = @(Get-Partition -DiskNumber $disk.Number -ErrorAction Stop |
                ForEach-Object { Get-LibertixPartitionRecord -Partition $_ } | Sort-Object offsetBytes)
        } catch {
            # An unreadable unrelated medium is diagnostic evidence, not an installation target.
            $record.inventoryError = $_.Exception.Message
            if ([int]$disk.Number -in @($targets.number)) { throw }
        }
        $record
    })
    foreach ($target in $targets) {
        Assert-LibertixDiskMatchesPlan -Disk (Get-Disk -Number $target.number -ErrorAction Stop) -PlanDisk $target
        if (@($records | Where-Object number -EQ $target.number).Count -ne 1) {
            throw 'An affected disk is missing from the initial storage inventory.'
        }
        $drive = if ([int]$target.number -eq [int]$Plan.disk.number) { [string]$Plan.disk.systemDrive } else { [string]$target.sourceDrive }
        $volume = Get-Volume -DriveLetter $drive.TrimEnd(':') -ErrorAction Stop
        $record = $records | Where-Object number -EQ $target.number
        $record.sourceVolume = [pscustomobject]@{
            drive = $drive; uniqueId = [string]$volume.UniqueId
            ntfsSerial = Get-LibertixNtfsVolumeSerial -Drive $drive.ToUpperInvariant()
        }
    }
    $baseline = [pscustomobject]@{
        schemaVersion = 1; planId = [string]$Plan.planId
        capturedAtUtc = [DateTime]::UtcNow.ToString('o'); disks = $records
    }
    Assert-LibertixStorageBaseline -Plan $Plan -Baseline $baseline -Restored
    $temporary = "$path.$PID.tmp"
    [IO.File]::WriteAllText($temporary, ($baseline | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    Publish-LibertixFileAtomic -TemporaryPath $temporary -DestinationPath $path -BackupPath "$path.bak"
}

function Assert-LibertixStorageBaseline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][object]$Baseline,
        [switch]$Restored
    )

    if ([int]$Baseline.schemaVersion -ne 1 -or [string]$Baseline.planId -cne [string]$Plan.planId) {
        throw 'The initial storage inventory belongs to another installation or has an unsupported format.'
    }
    $targets = @(Get-LibertixStorageBaselineTargets -Plan $Plan)
    $allocation = $targets[-1]
    $linuxOffset = Get-LibertixPlannedLinuxOffset -Plan $Plan
    $source = if ([int]$Plan.schemaVersion -eq 5) { $allocation.sourcePartition } else { $Plan.disk.windows }
    foreach ($target in $targets) {
        # Only planned disks can veto recovery. Never query or restore unrelated recorded disks.
        $disk = Get-Disk -Number $target.number -ErrorAction Stop
        Assert-LibertixDiskMatchesPlan -Disk $disk -PlanDisk $target
        if ($disk.IsOffline -or $disk.IsReadOnly) {
            throw "Affected disk $($target.number) is offline or read-only; refusing uninstall."
        }
        $saved = @($Baseline.disks | Where-Object number -EQ $target.number)
        if ($saved.Count -ne 1 -or $null -ne $saved[0].inventoryError) {
            throw "Disk $($target.number) has no complete initial partition inventory."
        }
        $saved = $saved[0]
        $drive = if ([int]$target.number -eq [int]$Plan.disk.number) { [string]$Plan.disk.systemDrive } else { [string]$target.sourceDrive }
        $volume = Get-Volume -DriveLetter $drive.TrimEnd(':') -ErrorAction Stop
        if ([string]$saved.sourceVolume.drive -ne $drive -or
            [string]$volume.FileSystem -ne 'NTFS' -or
            [string]$volume.UniqueId -ne [string]$saved.sourceVolume.uniqueId -or
            (Get-LibertixNtfsVolumeSerial -Drive $drive.ToUpperInvariant()) -cne [string]$saved.sourceVolume.ntfsSerial) {
            throw "The original NTFS volume on disk $($target.number) was replaced or is unavailable."
        }
        if ([string]$saved.uniqueId -ne ([string]$disk.UniqueId).Trim() -or
            [string]$saved.partitionStyle -ne [string]$disk.PartitionStyle -or
            [long]$saved.sizeBytes -ne [long]$disk.Size -or
            [int]$saved.logicalSectorSizeBytes -ne [int]$disk.LogicalSectorSize -or
            [int]$saved.physicalSectorSizeBytes -ne [int]$disk.PhysicalSectorSize -or
            [string]$saved.guid -ne [string]$disk.Guid -or [uint32]$saved.signature -ne [uint32]$disk.Signature) {
            throw "Disk $($target.number) no longer matches its initial identity."
        }
        $current = @(Get-Partition -DiskNumber $target.number -ErrorAction Stop |
            ForEach-Object { Get-LibertixPartitionRecord -Partition $_ })
        $targetSource = if ([int]$target.number -eq [int]$Plan.disk.number) { $Plan.disk.windows } else { $target.sourcePartition }
        $offsets = @{}
        foreach ($original in @($saved.partitions)) {
            $offset = [long]$original.offsetBytes
            if ($offsets.ContainsKey($offset)) { throw 'The initial partition inventory contains duplicate offsets.' }
            $offsets[$offset] = $true
            $match = @($current | Where-Object offsetBytes -EQ $offset)
            if ($match.Count -ne 1) { throw "An original partition on disk $($target.number) is missing or moved (offset $offset)." }
            $match = $match[0]
            foreach ($field in @('guid', 'gptType', 'mbrType', 'isActive', 'isHidden', 'isReadOnly', 'noDefaultDriveLetter')) {
                if ($original.$field -ne $match.$field) {
                    throw "Partition identity or attributes changed on disk $($target.number), offset ${offset}: $field."
                }
            }
            $isSource = [int]$target.number -eq [int]$allocation.number -and $offset -eq [long]$source.offsetBytes
            if ($offset -eq [long]$targetSource.offsetBytes -and [long]$original.sizeBytes -ne [long]$targetSource.sizeBytes) {
                throw 'The initial source extent disagrees with the installation plan.'
            }
            if ($Restored -or -not $isSource) {
                if ([long]$match.sizeBytes -ne [long]$original.sizeBytes) {
                    throw "Partition size changed on disk $($target.number), offset $offset."
                }
            } elseif ([long]$match.sizeBytes -le 0 -or [long]$match.sizeBytes -gt [long]$original.sizeBytes -or
                ($offset + [long]$match.sizeBytes) -lt ([long]$Plan.disk.installer.finalOffsetBytes - 1MB)) {
                throw 'The current source extent is outside the planned installation reduction.'
            }
        }
        if ([int]$target.number -eq [int]$Plan.disk.number -and
            -not $offsets.ContainsKey([long]$Plan.disk.windows.offsetBytes)) {
            throw 'The Windows partition is missing from the initial inventory.'
        }
        if ([int]$target.number -eq [int]$allocation.number -and -not $offsets.ContainsKey([long]$source.offsetBytes)) {
            throw 'The source partition is missing from the initial inventory.'
        }
        foreach ($partition in $current) {
            if ($offsets.ContainsKey([long]$partition.offsetBytes)) { continue }
            $isOwnedLinuxPartition = [int]$target.number -eq [int]$allocation.number -and
                [long]$partition.offsetBytes -eq $linuxOffset -and
                [long]$partition.sizeBytes -le [long]$Plan.disk.installer.finalSizeBytes -and
                [long]$partition.sizeBytes -ge ([long]$Plan.disk.installer.finalSizeBytes - 1MB) -and
                (([string]$disk.PartitionStyle -eq 'GPT' -and $partition.gptType -eq '{0fc63daf-8483-4772-8e79-3d69d8477de4}') -or
                    ([string]$disk.PartitionStyle -eq 'MBR' -and $partition.mbrType -eq 0x83))
            # Windows can create a logical Linux partition inside one new MBR container.
            # Only that exact reserved extent is removable, never an existing container.
            $isContainer = [int]$target.number -eq [int]$allocation.number -and
                [string]$disk.PartitionStyle -eq 'MBR' -and [int]$partition.mbrType -in @(5, 15, 133) -and
                [long]$partition.offsetBytes -eq ($linuxOffset - 1MB) -and
                [long]$partition.sizeBytes -eq ([long]$Plan.disk.installer.finalSizeBytes + 1MB)
            if ($Restored -or (-not $isOwnedLinuxPartition -and -not $isContainer)) {
                throw "An unexpected partition exists on disk $($target.number), offset $($partition.offsetBytes)."
            }
            $currentSource = @($current | Where-Object offsetBytes -EQ $source.offsetBytes)[0]
            if (([long]$currentSource.offsetBytes + [long]$currentSource.sizeBytes) -gt [long]$partition.offsetBytes) {
                throw 'The source volume overlaps the installation extent; refusing uninstall.'
            }
        }
    }
}

function Assert-LibertixUninstallStorageBaseline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RecoveryRoot,
        [switch]$Restored
    )

    $plan = Get-Content -LiteralPath (Join-Path $RecoveryRoot 'installation-plan.json') -Raw -ErrorAction Stop |
        ConvertFrom-Json -ErrorAction Stop
    $path = Join-Path $RecoveryRoot 'storage-before-installation.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'The initial storage inventory is missing; a complete layout verification is not possible. No uninstall changes are allowed.'
    }
    $baseline = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    Assert-LibertixStorageBaseline -Plan $plan -Baseline $baseline -Restored:$Restored
}

Export-ModuleMember -Function Save-LibertixStorageBaseline, Assert-LibertixUninstallStorageBaseline
