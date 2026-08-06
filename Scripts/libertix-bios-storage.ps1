#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("QueryShrink", "Shrink", "CreateStaging")]
    [string]$Action,
    [Parameter(Mandatory = $true)]
    [ValidatePattern("^[A-Za-z]:$")]
    [string]$SystemDrive,
    [Parameter(Mandatory = $true)]
    [int]$DiskNumber,
    [Parameter(Mandatory = $true)]
    [string]$DiskUniqueId,
    [Parameter(Mandatory = $true)]
    [int64]$WindowsPartitionOffsetBytes,
    [Parameter(Mandatory = $true)]
    [int64]$RecoveryPartitionOffsetBytes,
    [int64]$SizeBytes = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$geometryModule = Join-Path $PSScriptRoot "modules\Libertix.StorageGeometry.psm1"
if (-not (Test-Path -LiteralPath $geometryModule -PathType Leaf)) {
    throw "Libertix storage geometry module is missing: $geometryModule"
}
Import-Module -Name $geometryModule -Force -ErrorAction Stop

function Get-ValidatedWindowsPartition {
    $driveLetter = $SystemDrive.TrimEnd(":")
    $partition = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
    $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
    if (
        [int]$partition.DiskNumber -ne $DiskNumber -or
        [int64]$partition.Offset -ne $WindowsPartitionOffsetBytes -or
        ([string]$disk.UniqueId).Trim() -ne $DiskUniqueId.Trim()
    ) {
        throw "Windows storage identity changed after compatibility preflight."
    }
    return $partition
}

function Write-JsonResult {
    param([Parameter(Mandatory = $true)][hashtable]$Value)
    $Value | ConvertTo-Json -Compress
}

$windowsPartition = Get-ValidatedWindowsPartition
$driveLetter = $SystemDrive.TrimEnd(":")
$systemDisk = Get-Disk -Number $windowsPartition.DiskNumber -ErrorAction Stop
$partitionAlignmentBytes = Get-LibertixPartitionAlignmentBytes

switch ($Action) {
    "QueryShrink" {
        $supported = Get-PartitionSupportedSize -DriveLetter $driveLetter -ErrorAction Stop
        $alignmentPadding = Get-LibertixPartitionEndAlignmentPadding `
            -PartitionOffsetBytes ([int64]$windowsPartition.Offset) `
            -PartitionSizeBytes ([int64]$windowsPartition.Size) `
            -LogicalSectorSizeBytes ([int64]$systemDisk.LogicalSectorSize)
        [int64]$maximumAllocationBytes = `
            [int64]$windowsPartition.Size - `
            [int64]$supported.SizeMin - `
            $alignmentPadding - `
            $partitionAlignmentBytes
        if ($maximumAllocationBytes -lt 0) {
            $maximumAllocationBytes = 0
        }
        Write-JsonResult @{
            CurrentSizeBytes = [int64]$windowsPartition.Size
            MinimumSizeBytes = [int64]$supported.SizeMin
            AlignmentPaddingBytes = [int64]$alignmentPadding
            MaximumShrinkBytes = [int64]$maximumAllocationBytes
        }
    }
    "Shrink" {
        if ($SizeBytes -le 0 -or $SizeBytes -ge [int64]$windowsPartition.Size) {
            throw "The requested shrink size is outside the Windows partition bounds."
        }
        # With three existing primary MBR partitions, Windows creates an
        # extended container and places the new logical partition one alignment
        # unit after its start. Reserve that metadata unit even on layouts where
        # Windows can still choose a primary partition; the observed identity is
        # persisted in the installation plan after creation.
        [int64]$allocationWithMbrMetadata = $SizeBytes + $partitionAlignmentBytes
        $shrinkGeometry = Get-LibertixAlignedShrinkGeometry `
            -PartitionOffsetBytes ([int64]$windowsPartition.Offset) `
            -PartitionSizeBytes ([int64]$windowsPartition.Size) `
            -RequestedAllocationBytes $allocationWithMbrMetadata `
            -LogicalSectorSizeBytes ([int64]$systemDisk.LogicalSectorSize)
        $targetSize = [int64]$shrinkGeometry.TargetSizeBytes
        $installerOffsetBytes = [int64]$shrinkGeometry.InstallerOffsetBytes
        $systemVolume = Get-Volume -DriveLetter $driveLetter -ErrorAction Stop
        $freeSpaceBudget = Get-LibertixWindowsFreeSpaceBudget `
            -AvailableBytes ([int64]$systemVolume.SizeRemaining) `
            -AllocationBytes ([int64]$shrinkGeometry.ShrinkBytes)
        if (-not $freeSpaceBudget.Accepted) {
            throw (
                "Not enough free space on $SystemDrive " +
                "(available=$($freeSpaceBudget.AvailableBytes) bytes, " +
                "required=$($freeSpaceBudget.RequiredBytes) bytes, " +
                "acceptedFloor=$($freeSpaceBudget.AcceptedFloorBytes) bytes)."
            )
        }
        if (
            $SizeBytes -gt $RecoveryPartitionOffsetBytes -or
            $installerOffsetBytes -gt `
                $RecoveryPartitionOffsetBytes - $SizeBytes - $partitionAlignmentBytes
        ) {
            throw "The requested Linux partition would overlap Windows Recovery."
        }
        $supported = Get-PartitionSupportedSize -DriveLetter $driveLetter -ErrorAction Stop
        if ($targetSize -lt [int64]$supported.SizeMin) {
            throw "Windows does not expose enough shrinkable space for the requested size."
        }
        Resize-Partition -DriveLetter $driveLetter -Size $targetSize -ErrorAction Stop
        $verified = Get-ValidatedWindowsPartition
        if ([int64]$verified.Size -ne $targetSize) {
            throw "Windows partition size does not match the requested post-shrink size."
        }
        Write-JsonResult @{
            SizeBytes = [int64]$verified.Size
            AlignmentPaddingBytes = [int64]$shrinkGeometry.PaddingBytes
            ActualShrinkBytes = [int64]$shrinkGeometry.ShrinkBytes
            FreeSpaceWithinTolerance = [bool]$freeSpaceBudget.WithinTolerance
        }
    }
    "CreateStaging" {
        if ($SizeBytes -le 0) {
            throw "The staging partition size must be positive."
        }
        $containerOffsetBytes = [int64](
            [int64]$windowsPartition.Offset + [int64]$windowsPartition.Size
        )
        $maximumPartitionOffsetBytes = $containerOffsetBytes + $partitionAlignmentBytes
        if (
            $SizeBytes -gt $RecoveryPartitionOffsetBytes -or
            $maximumPartitionOffsetBytes -gt $RecoveryPartitionOffsetBytes - $SizeBytes
        ) {
            throw "The staging partition would overlap Windows Recovery."
        }

        # Mount Manager selects an actually available access path. Fixed drive
        # letters can remain reserved by disconnected mappings that Get-Volume
        # does not report as local volumes.
        $partition = New-Partition `
            -DiskNumber $DiskNumber `
            -Size $SizeBytes `
            -Offset $containerOffsetBytes `
            -Alignment $partitionAlignmentBytes `
            -AssignDriveLetter `
            -ErrorAction Stop
        if (
            [int64]$partition.Offset -lt $containerOffsetBytes -or
            [int64]$partition.Offset -gt $maximumPartitionOffsetBytes -or
            [int64]$partition.Offset % [int64]$systemDisk.LogicalSectorSize -ne 0 -or
            [int64]$partition.Offset -gt $RecoveryPartitionOffsetBytes - $SizeBytes -or
            [int64]$partition.Size -ne $SizeBytes
        ) {
            throw "Windows created the BIOS staging partition with unexpected geometry."
        }
        if (-not $partition.DriveLetter) {
            throw "Windows created the staging partition without a drive letter."
        }
        $createdDriveLetter = [string]$partition.DriveLetter
        Format-Volume `
            -DriveLetter $createdDriveLetter `
            -FileSystem FAT32 `
            -NewFileSystemLabel "LIBERTIX" `
            -Confirm:$false `
            -Force `
            -ErrorAction Stop | Out-Null

        $verifiedPartition = Get-Partition -DriveLetter $createdDriveLetter -ErrorAction Stop
        $verifiedVolume = Get-Volume -DriveLetter $createdDriveLetter -ErrorAction Stop
        if (
            [int]$verifiedPartition.DiskNumber -ne $DiskNumber -or
            [int64]$verifiedPartition.Offset -ne [int64]$partition.Offset -or
            [int64]$verifiedPartition.Size -ne $SizeBytes -or
            [string]$verifiedVolume.FileSystem -ne "FAT32" -or
            [string]$verifiedVolume.FileSystemLabel -ne "LIBERTIX"
        ) {
            throw "The created BIOS staging partition failed postcondition checks."
        }
        Write-JsonResult @{
            DriveLetter = $createdDriveLetter
            DiskNumber = [int]$verifiedPartition.DiskNumber
            PartitionNumber = [int]$verifiedPartition.PartitionNumber
            OffsetBytes = [int64]$verifiedPartition.Offset
            SizeBytes = [int64]$verifiedPartition.Size
        }
    }
}
