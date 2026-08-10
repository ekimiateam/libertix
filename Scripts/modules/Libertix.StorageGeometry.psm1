Set-StrictMode -Version Latest

$script:WindowsPartitionAlignmentBytes = 1MB
$script:MinimumWindowsFreeSpaceBytes = 10GB
$script:WindowsFreeSpaceToleranceBytes = 2GB
$script:WindowsFreeSpaceRetryWindowBytes = 2GB

function Get-LibertixPartitionAlignmentBytes {
    return [int64]$script:WindowsPartitionAlignmentBytes
}

function Get-LibertixWindowsFreeSpaceBudget {
    param(
        [Parameter(Mandatory = $true)][int64]$AvailableBytes,
        [Parameter(Mandatory = $true)][int64]$AllocationBytes
    )

    if ($AvailableBytes -lt 0 -or $AllocationBytes -le 0) {
        throw "Windows free-space budget values are outside the supported range."
    }
    if ($AllocationBytes -gt [int64]::MaxValue - $script:MinimumWindowsFreeSpaceBytes) {
        throw "Windows free-space budget exceeds the supported integer range."
    }

    [int64]$requiredBytes = $AllocationBytes + $script:MinimumWindowsFreeSpaceBytes
    [int64]$acceptedFloorBytes = $requiredBytes - $script:WindowsFreeSpaceToleranceBytes

    # Windows can grow its page file and other managed files after the wizard
    # measures free space. The tolerance keeps that bounded drift from making
    # a valid minimum-size installation fail. The wizard still targets a 10 GiB
    # reserve, while the execution-time floor stays bounded at 8 GiB and larger
    # deficits fail closed.
    return [pscustomobject]@{
        Accepted = [bool]($AvailableBytes -ge $acceptedFloorBytes)
        WithinTolerance = [bool](
            $AvailableBytes -lt $requiredBytes -and
            $AvailableBytes -ge $acceptedFloorBytes
        )
        AvailableBytes = $AvailableBytes
        AllocationBytes = $AllocationBytes
        RequiredBytes = $requiredBytes
        AcceptedFloorBytes = $acceptedFloorBytes
        ReserveBytes = [int64]$script:MinimumWindowsFreeSpaceBytes
        ToleranceBytes = [int64]$script:WindowsFreeSpaceToleranceBytes
    }
}

function Wait-LibertixWindowsFreeSpaceBudget {
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z]$')]
        [string]$DriveLetter,
        [Parameter(Mandatory = $true)]
        [int64]$AllocationBytes,
        [ValidateRange(0, 300)]
        [int]$TimeoutSeconds = 60,
        [ValidateRange(1, 30)]
        [int]$PollIntervalSeconds = 5
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $volume = Get-Volume -DriveLetter $DriveLetter -ErrorAction Stop
        $budget = Get-LibertixWindowsFreeSpaceBudget `
            -AvailableBytes ([int64]$volume.SizeRemaining) `
            -AllocationBytes $AllocationBytes
        if ($budget.Accepted) {
            return $budget
        }

        [int64]$deficitBytes = $budget.AcceptedFloorBytes - $budget.AvailableBytes
        if (
            $deficitBytes -gt $script:WindowsFreeSpaceRetryWindowBytes -or
            $stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds
        ) {
            return $budget
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    } while ($true)
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
    "Get-LibertixWindowsFreeSpaceBudget",
    "Wait-LibertixWindowsFreeSpaceBudget",
    "Get-LibertixPartitionEndAlignmentPadding",
    "Get-LibertixAlignedShrinkGeometry"
)
