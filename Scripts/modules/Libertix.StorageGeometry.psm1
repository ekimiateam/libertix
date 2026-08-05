Set-StrictMode -Version Latest

$script:WindowsPartitionAlignmentBytes = 1MB

function Get-LibertixPartitionAlignmentBytes {
    return [int64]$script:WindowsPartitionAlignmentBytes
}

function Get-LibertixPartitionEndAlignmentPadding {
    param(
        [Parameter(Mandatory = $true)][int64]$PartitionOffsetBytes,
        [Parameter(Mandatory = $true)][int64]$PartitionSizeBytes,
        [Parameter(Mandatory = $true)][int64]$LogicalSectorSizeBytes
    )

    if ($LogicalSectorSizeBytes -notin @(512, 4096)) {
        throw "Unsupported logical sector size: $LogicalSectorSizeBytes."
    }
    if (
        $PartitionOffsetBytes -le 0 -or
        $PartitionSizeBytes -le 0 -or
        $PartitionOffsetBytes % $LogicalSectorSizeBytes -ne 0 -or
        $PartitionSizeBytes % $LogicalSectorSizeBytes -ne 0
    ) {
        throw "Partition geometry is not aligned to its logical sector size."
    }
    if ($script:WindowsPartitionAlignmentBytes % $LogicalSectorSizeBytes -ne 0) {
        throw "Windows partition alignment is incompatible with the logical sector size."
    }
    if ($PartitionOffsetBytes -gt [int64]::MaxValue - $PartitionSizeBytes) {
        throw "Partition geometry exceeds the supported integer range."
    }

    $partitionEndBytes = $PartitionOffsetBytes + $PartitionSizeBytes
    return [int64]($partitionEndBytes % $script:WindowsPartitionAlignmentBytes)
}

function Get-LibertixAlignedShrinkGeometry {
    param(
        [Parameter(Mandatory = $true)][int64]$PartitionOffsetBytes,
        [Parameter(Mandatory = $true)][int64]$PartitionSizeBytes,
        [Parameter(Mandatory = $true)][int64]$RequestedAllocationBytes,
        [Parameter(Mandatory = $true)][int64]$LogicalSectorSizeBytes
    )

    if (
        $RequestedAllocationBytes -le 0 -or
        $RequestedAllocationBytes % $LogicalSectorSizeBytes -ne 0
    ) {
        throw "Requested allocation is not aligned to the logical sector size."
    }

    $paddingBytes = Get-LibertixPartitionEndAlignmentPadding `
        -PartitionOffsetBytes $PartitionOffsetBytes `
        -PartitionSizeBytes $PartitionSizeBytes `
        -LogicalSectorSizeBytes $LogicalSectorSizeBytes
    if ($RequestedAllocationBytes -gt [int64]::MaxValue - $paddingBytes) {
        throw "Requested allocation exceeds the supported integer range."
    }
    $shrinkBytes = $RequestedAllocationBytes + $paddingBytes
    if ($shrinkBytes -ge $PartitionSizeBytes) {
        throw "Requested allocation would consume the Windows partition."
    }

    return [pscustomobject]@{
        AlignmentBytes = [int64]$script:WindowsPartitionAlignmentBytes
        PaddingBytes = [int64]$paddingBytes
        ShrinkBytes = [int64]$shrinkBytes
        TargetSizeBytes = [int64]($PartitionSizeBytes - $shrinkBytes)
        InstallerOffsetBytes = [int64](
            $PartitionOffsetBytes + $PartitionSizeBytes - $shrinkBytes
        )
    }
}

Export-ModuleMember -Function @(
    "Get-LibertixPartitionAlignmentBytes",
    "Get-LibertixPartitionEndAlignmentPadding",
    "Get-LibertixAlignedShrinkGeometry"
)
