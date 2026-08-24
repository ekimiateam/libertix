Set-StrictMode -Version Latest

$policyModulePath = Join-Path $PSScriptRoot "Libertix.InstallationPolicy.psm1"
Import-Module -Name $policyModulePath -Force -ErrorAction Stop
$script:InstallationPolicy = Get-LibertixInstallationPolicy
$script:BytesPerGiB = 1GB

function Get-LibertixPartitionAlignmentBytes {
    return [int64]$script:InstallationPolicy.storage.partitionAlignmentBytes
}

function Get-LibertixWindowsFreeSpaceBudget {
    param(
        [Parameter(Mandatory = $true)][int64]$AvailableBytes,
        [Parameter(Mandatory = $true)][int64]$AllocationBytes,
        [int64]$ReclaimableArtifactBytes = 0
    )

    if (
        $AvailableBytes -lt 0 -or
        $AllocationBytes -le 0 -or
        $ReclaimableArtifactBytes -lt 0
    ) {
        throw "Windows free-space budget values are outside the supported range."
    }
    [int64]$reserveBytes =
        [int]$script:InstallationPolicy.storage.targetWindowsFreeSpaceGiB *
        $script:BytesPerGiB
    [int64]$toleranceBytes =
        [int]$script:InstallationPolicy.storage.windowsFreeSpaceToleranceGiB *
        $script:BytesPerGiB
    if ($AllocationBytes -gt [int64]::MaxValue - $reserveBytes) {
        throw "Windows free-space budget exceeds the supported integer range."
    }
    if ($AvailableBytes -gt [int64]::MaxValue - $ReclaimableArtifactBytes) {
        throw "Windows reclaimable-space budget exceeds the supported integer range."
    }

    [int64]$requiredBytes = $AllocationBytes + $reserveBytes
    [int64]$acceptedFloorBytes = $requiredBytes - $toleranceBytes
    [int64]$effectiveAvailableBytes = $AvailableBytes + $ReclaimableArtifactBytes

    # Windows can grow its page file and other managed files after the wizard
    # measures free space. The tolerance keeps that bounded drift from making
    # a valid minimum-size installation fail. The wizard still targets the
    # configured reserve, while the execution-time tolerance stays bounded and
    # larger deficits fail closed. A verified transaction ISO is reclaimable
    # because every success and rollback path removes its owned download root.
    return [pscustomobject]@{
        Accepted = [bool]($effectiveAvailableBytes -ge $acceptedFloorBytes)
        WithinTolerance = [bool](
            $effectiveAvailableBytes -lt $requiredBytes -and
            $effectiveAvailableBytes -ge $acceptedFloorBytes
        )
        AvailableBytes = $AvailableBytes
        ReclaimableArtifactBytes = $ReclaimableArtifactBytes
        EffectiveAvailableBytes = $effectiveAvailableBytes
        AllocationBytes = $AllocationBytes
        RequiredBytes = $requiredBytes
        AcceptedFloorBytes = $acceptedFloorBytes
        ReserveBytes = $reserveBytes
        ToleranceBytes = $toleranceBytes
    }
}

function Wait-LibertixWindowsFreeSpaceBudget {
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z]$')]
        [string]$DriveLetter,
        [Parameter(Mandatory = $true)]
        [int64]$AllocationBytes,
        [int64]$ReclaimableArtifactBytes = 0,
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
            -AllocationBytes $AllocationBytes `
            -ReclaimableArtifactBytes $ReclaimableArtifactBytes
        if ($budget.Accepted) {
            return $budget
        }

        [int64]$deficitBytes =
            $budget.AcceptedFloorBytes - $budget.EffectiveAvailableBytes
        [int64]$retryWindowBytes =
            [int]$script:InstallationPolicy.storage.windowsFreeSpaceRetryWindowGiB *
            $script:BytesPerGiB
        if (
            $deficitBytes -gt $retryWindowBytes -or
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
    [int64]$alignmentBytes = Get-LibertixPartitionAlignmentBytes
    if ($alignmentBytes % $LogicalSectorSizeBytes -ne 0) {
        throw "Windows partition alignment is incompatible with the logical sector size."
    }
    if ($PartitionOffsetBytes -gt [int64]::MaxValue - $PartitionSizeBytes) {
        throw "Partition geometry exceeds the supported integer range."
    }

    $partitionEndBytes = $PartitionOffsetBytes + $PartitionSizeBytes
    return [int64]($partitionEndBytes % $alignmentBytes)
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
        AlignmentBytes = Get-LibertixPartitionAlignmentBytes
        PaddingBytes = [int64]$paddingBytes
        ShrinkBytes = [int64]$shrinkBytes
        TargetSizeBytes = [int64]($PartitionSizeBytes - $shrinkBytes)
        InstallerOffsetBytes = [int64](
            $PartitionOffsetBytes + $PartitionSizeBytes - $shrinkBytes
        )
    }
}

function Get-LibertixFreeDriveLetter {
    param([string[]]$ExcludedLetters = @())

    $used = @{}
    Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter } |
        ForEach-Object { $used[[string]$_.DriveLetter] = $true }
    Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^[A-Za-z]$' } |
        ForEach-Object { $used[[string]$_.Name] = $true }

    foreach ($candidate in @(
        "Z", "Y", "X", "W", "V", "U", "T", "S", "R", "Q", "P", "O",
        "N", "M", "L", "K", "J", "I", "H", "G", "F", "E", "D"
    )) {
        if (
            $candidate -notin $ExcludedLetters -and
            -not $used.ContainsKey($candidate) -and
            -not (Test-Path "${candidate}:\")
        ) {
            return $candidate
        }
    }

    throw "No free drive letter is available for Libertix."
}

Export-ModuleMember -Function @(
    "Get-LibertixPartitionAlignmentBytes",
    "Get-LibertixWindowsFreeSpaceBudget",
    "Wait-LibertixWindowsFreeSpaceBudget",
    "Get-LibertixPartitionEndAlignmentPadding",
    "Get-LibertixAlignedShrinkGeometry",
    "Get-LibertixFreeDriveLetter"
)
