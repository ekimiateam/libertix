param(
    [ValidateSet("BIOS", "UEFI")]
    [string]$ExpectedFirmware,
    [switch]$DecryptBitLocker,
    [string]$ExpectedPlanPath = "",
    [string]$ExpectedTargetJsonBase64 = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
Import-Module `
    (Join-Path $PSScriptRoot "modules\Libertix.Process.psm1") `
    -Force `
    -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'modules\Libertix.StorageGeometry.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'modules\Libertix.StorageTargets.psm1') -Force -ErrorAction Stop
& "$env:SystemRoot\System32\chcp.com" 65001 > $null
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)

function Get-PartitionTableIdentity {
    param([Parameter(Mandatory = $true)][object]$Disk)

    if ([string]$Disk.PartitionStyle -eq "GPT") {
        [guid]$guid = [guid]$Disk.Guid
        if ($guid -eq [guid]::Empty) {
            throw "The GPT disk does not expose a partition-table GUID."
        }
        return "gpt:$($guid.ToString('D').ToLowerInvariant())"
    }
    if ([string]$Disk.PartitionStyle -eq "MBR") {
        return "mbr:$(([uint32]$Disk.Signature).ToString('x8'))"
    }
    throw "Unsupported partition style for disk identity: $($Disk.PartitionStyle)."
}

function Get-FirmwareMode {
    $signature = @"
using System;
using System.Runtime.InteropServices;
public static class LibertixFirmware {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetFirmwareType(out uint firmwareType);
}
"@
    if (-not ("LibertixFirmware" -as [type])) {
        Add-Type -TypeDefinition $signature
    }

    [uint32]$firmwareType = 0
    if (-not [LibertixFirmware]::GetFirmwareType([ref]$firmwareType)) {
        throw "GetFirmwareType failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())."
    }

    switch ($firmwareType) {
        1 { return "BIOS" }
        2 { return "UEFI" }
        default { throw "Unsupported or unknown firmware type: $firmwareType" }
    }
}

function Get-BitLockerState {
    param([string]$DriveLetter)
    $snapshot = Get-LibertixTargetVolumeEncryptionSnapshot -Drive $DriveLetter.ToUpperInvariant()
    return [pscustomobject]@{
        Safe = $snapshot.state -in @('FullyDecrypted', 'NotEncryptable')
        State = $snapshot.state
        ConversionStatus = $snapshot.conversionStatus
        EncryptionPercentage = $snapshot.encryptionPercentage
        ProtectionStatus = $snapshot.protectionStatus
    }
}

function Set-PreflightVolumeReadable {
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Z]:$')][string]$Drive,
        [Parameter(Mandatory = $true)][scriptblock]$VerifyIdentity
    )
    & $VerifyIdentity
    if ((Get-BitLockerState -DriveLetter $Drive).Safe) { return }
    $manageBde = Get-Command manage-bde.exe -CommandType Application -ErrorAction Stop
    & $VerifyIdentity
    $result = Invoke-LibertixNativeCommand -FilePath $manageBde.Source `
        -ArgumentList @('-off', $Drive) -TimeoutSeconds 120
    if ($result.ExitCode -ne 0) {
        throw "manage-bde could not start decryption of $Drive (rc=$($result.ExitCode))."
    }
    Write-Output "BITLOCKER_ACTION=decrypting $Drive"
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed -lt [TimeSpan]::FromHours(6)) {
        Start-Sleep -Seconds 10
        & $VerifyIdentity
        $state = Get-BitLockerState -DriveLetter $Drive
        Write-Output "BITLOCKER_PROGRESS=$($state.EncryptionPercentage) DRIVE=$Drive"
        if ($state.Safe) { return }
    }
    throw "Timed out waiting for BitLocker decryption of $Drive."
}

function Assert-PreflightStorageStillMatchesPlan {
    $currentSystem = Get-Partition -DriveLetter $systemDrive.TrimEnd(':') -ErrorAction Stop
    $currentDisk = Get-Disk -Number $currentSystem.DiskNumber -ErrorAction Stop
    $currentBoot = Get-Partition -DiskNumber $currentDisk.Number -PartitionNumber $boot.PartitionNumber -ErrorAction Stop
    $currentRecovery = Get-Partition -DiskNumber $currentDisk.Number -PartitionNumber $recovery.PartitionNumber -ErrorAction Stop
    Assert-StorageMatchesExpectedPlan -PlanPath $ExpectedPlanPath -Disk $currentDisk `
        -SystemPartition $currentSystem -BootPartition $currentBoot -RecoveryPartition $currentRecovery
    if ($null -ne $allocation) {
        $current = Get-LibertixInstallationAllocation -ExpectedTarget $expectedTarget `
            -SystemPartition $currentSystem -RequiredPartitionStyle $expectedStyle
        $plan = Get-Content -LiteralPath $ExpectedPlanPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $current -or $plan.PSObject.Properties.Name -notcontains 'allocation' -or
            $null -eq $plan.allocation) { throw 'The armed allocation plan is missing.' }
        foreach ($field in @('number', 'uniqueId', 'partitionTableId', 'sizeBytes',
            'logicalSectorSizeBytes', 'partitionStyle', 'sourceDrive', 'sourceVolumeId', 'sourceNtfsUuid')) {
            if ([string]$current.$field -cne [string]$plan.allocation.$field) {
                throw "The source volume no longer matches its armed plan: $field."
            }
        }
        foreach ($field in @('number', 'offsetBytes', 'sizeBytes')) {
            if ([long]$current.sourcePartition.$field -ne [long]$plan.allocation.sourcePartition.$field) {
                throw "The source partition no longer matches its armed plan: $field."
            }
        }
    }
}

function Assert-PartitionMatchesExpectedPlan {
    param(
        [Parameter(Mandatory = $true)][object]$Actual,
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (
        [int]$Actual.PartitionNumber -ne [int]$Expected.number -or
        [int64]$Actual.Offset -ne [int64]$Expected.offsetBytes -or
        [int64]$Actual.Size -ne [int64]$Expected.sizeBytes
    ) {
        throw "Windows $Label partition no longer matches the armed recovery plan."
    }
}

function Assert-StorageMatchesExpectedPlan {
    param(
        [Parameter(Mandatory = $true)][string]$PlanPath,
        [Parameter(Mandatory = $true)][object]$Disk,
        [Parameter(Mandatory = $true)][object]$SystemPartition,
        [Parameter(Mandatory = $true)][object]$BootPartition,
        [Parameter(Mandatory = $true)][object]$RecoveryPartition
    )

    if (-not (Test-Path -LiteralPath $PlanPath -PathType Leaf)) {
        throw "Expected installation plan is missing: $PlanPath"
    }
    $plan = Get-Content -LiteralPath $PlanPath -Raw -ErrorAction Stop | ConvertFrom-Json
    $expectedFirmwareName = $ExpectedFirmware.ToLowerInvariant()
    if ([string]$plan.firmware -ne $expectedFirmwareName) {
        throw "Installation plan firmware does not match the requested preflight."
    }

    if (
        [int]$Disk.Number -ne [int]$plan.disk.number -or
        ([string]$Disk.UniqueId).Trim() -ne ([string]$plan.disk.uniqueId).Trim() -or
        (Get-PartitionTableIdentity -Disk $Disk) -ne [string]$plan.disk.partitionTableId -or
        [string]$Disk.PartitionStyle -ne [string]$plan.disk.partitionStyle -or
        [int64]$Disk.Size -ne [int64]$plan.disk.sizeBytes -or
        [int]$Disk.LogicalSectorSize -ne [int]$plan.disk.logicalSectorSizeBytes
    ) {
        throw "Windows system disk no longer matches the armed recovery plan."
    }

    Assert-PartitionMatchesExpectedPlan `
        -Actual $SystemPartition -Expected $plan.disk.windows -Label "system"
    Assert-PartitionMatchesExpectedPlan `
        -Actual $BootPartition -Expected $plan.disk.boot -Label "boot"
    Assert-PartitionMatchesExpectedPlan `
        -Actual $RecoveryPartition -Expected $plan.disk.recovery -Label "recovery"
    Assert-LibertixUniqueTargetDiskIdentity -Disk $Disk -Disks @(Get-Disk -ErrorAction Stop)
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Administrator privileges are required."
    }

    $firmware = Get-FirmwareMode
    if ($firmware -ne $ExpectedFirmware) {
        throw "Firmware mismatch: expected $ExpectedFirmware, detected $firmware."
    }

    $systemDrive = [Environment]::GetEnvironmentVariable("SystemDrive").TrimEnd("\")
    if ($systemDrive -notmatch "^[A-Za-z]:$") {
        throw "Invalid Windows system drive: $systemDrive"
    }

    $driveLetter = $systemDrive.Substring(0, 1)
    $partition = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
    $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
    if ($disk.IsOffline -or $disk.IsReadOnly) {
        throw "Windows system disk is offline or read-only."
    }
    if (@($partition).Count -ne 1) {
        throw "The Windows system volume does not resolve to exactly one partition."
    }
    Assert-LibertixUniqueTargetDiskIdentity -Disk $disk -Disks @(Get-Disk -ErrorAction Stop)

    $expectedStyle = if ($ExpectedFirmware -eq "UEFI") { "GPT" } else { "MBR" }
    if ([string]$disk.PartitionStyle -ne $expectedStyle) {
        throw "Partition style mismatch: expected $expectedStyle, detected $($disk.PartitionStyle)."
    }
    if (
        $ExpectedFirmware -eq "BIOS" -and
        @(
            Get-Partition -DiskNumber $partition.DiskNumber -ErrorAction Stop |
                Where-Object { [int]$_.MbrType -in @(5, 15, 133) }
        ).Count -ne 0
    ) {
        throw "An existing MBR extended partition makes this BIOS layout unsafe to modify."
    }

    $allPartitions = @(Get-Partition -DiskNumber $partition.DiskNumber -ErrorAction Stop)
    $recovery = Resolve-LibertixWindowsRecoveryPartition -Partitions $allPartitions `
        -WindowsPartition $partition -PartitionStyle ([string]$disk.PartitionStyle)
    if (
        ($ExpectedFirmware -eq 'BIOS' -and [int64]$recovery.Offset -le [int64]$partition.Offset) -or
        ([int64]$recovery.Offset -lt ([int64]$partition.Offset + [int64]$partition.Size) -and
            [int64]$partition.Offset -lt ([int64]$recovery.Offset + [int64]$recovery.Size))
    ) {
        throw "The Windows recovery partition must follow the Windows system partition."
    }

    if ($ExpectedFirmware -eq "UEFI") {
        $bootPartitions = @(
            Get-Partition -DiskNumber $partition.DiskNumber -ErrorAction Stop |
                Where-Object { $_.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" }
        )
    } else {
        $bootPartitions = @(
            Get-Partition -DiskNumber $partition.DiskNumber -ErrorAction Stop |
                Where-Object { $_.IsSystem }
        )
        if ($bootPartitions.Count -eq 0) {
            $bootPartitions = @(
                Get-Partition -DiskNumber $partition.DiskNumber -ErrorAction Stop |
                    Where-Object { $_.IsActive }
            )
        }
    }
    if ($bootPartitions.Count -ne 1) {
        throw "Exactly one Windows boot partition is required; detected $($bootPartitions.Count)."
    }
    $boot = $bootPartitions[0]

    $allocation = $null
    $allocationEncryption = $null
    if (-not [string]::IsNullOrWhiteSpace($ExpectedTargetJsonBase64)) {
        if ($ExpectedTargetJsonBase64.Length -gt 16384) {
            throw 'The requested target identity is excessively large.'
        }
        $targetJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ExpectedTargetJsonBase64))
        $expectedTarget = $targetJson | ConvertFrom-Json -ErrorAction Stop
        $allocation = Get-LibertixInstallationAllocation -ExpectedTarget $expectedTarget `
            -SystemPartition $partition -RequiredPartitionStyle $expectedStyle
        if ($null -ne $allocation) {
            $allocationEncryption = Get-LibertixTargetVolumeEncryptionSnapshot -Drive $allocation.sourceDrive
        }
    }

    if ($null -eq $allocation -and $ExpectedFirmware -eq 'BIOS' -and $allPartitions.Count -ge 4) {
        throw 'The selected Windows MBR disk has no supported partition slot available.'
    }

    if ($DecryptBitLocker) {
        if ([string]::IsNullOrWhiteSpace($ExpectedPlanPath)) {
            throw "ExpectedPlanPath is required before BitLocker can be modified."
        }
        Assert-StorageMatchesExpectedPlan `
            -PlanPath $ExpectedPlanPath `
            -Disk $disk `
            -SystemPartition $partition `
            -BootPartition $boot `
            -RecoveryPartition $recovery
    }

    $secondaryBootPreflight = $null
    if ($null -ne $allocation) {
        Import-Module (Join-Path $PSScriptRoot 'modules\Libertix.SecondaryBootPreflight.psm1') -ErrorAction Stop
        $secondaryBootPreflight = Assert-LibertixSecondaryBootPreflight -Firmware $ExpectedFirmware `
            -WindowsDisk $disk -BootPartition $boot -Allocation $allocation
    }

    # Validate the complete disk topology before starting decryption. The
    # caller has armed recovery, but a rejected Recovery or boot layout must
    # still leave BitLocker untouched.
    $bitLocker = Get-BitLockerState -DriveLetter $systemDrive
    $initialBitLocker = $bitLocker
    if ($DecryptBitLocker) {
        Set-PreflightVolumeReadable -Drive $systemDrive -VerifyIdentity { Assert-PreflightStorageStillMatchesPlan }
        if ($null -ne $allocation) {
            Set-PreflightVolumeReadable -Drive $allocation.sourceDrive -VerifyIdentity { Assert-PreflightStorageStillMatchesPlan }
            $allocation.sourceBitLockerState = Get-LibertixTargetVolumeEncryptionState -Drive $allocation.sourceDrive
        }
        Assert-PreflightStorageStillMatchesPlan
        $bitLocker = Get-BitLockerState -DriveLetter $systemDrive
    }

    [ordered]@{
        preflightOk = $true
        firmware = $firmware
        systemDrive = $systemDrive
        systemDiskNumber = [int]$partition.DiskNumber
        systemPartitionNumber = [int]$partition.PartitionNumber
        systemPartitionOffset = [long]$partition.Offset
        systemPartitionSize = [long]$partition.Size
        bootPartitionNumber = [int]$boot.PartitionNumber
        bootPartitionOffset = [long]$boot.Offset
        bootPartitionSize = [long]$boot.Size
        systemDiskUniqueId = [string]$disk.UniqueId
        systemDiskPartitionTableId = Get-PartitionTableIdentity -Disk $disk
        systemDiskSize = [long]$disk.Size
        logicalSectorSize = [int]$disk.LogicalSectorSize
        partitionStyle = [string]$disk.PartitionStyle
        recoveryPartitionNumber = [int]$recovery.PartitionNumber
        recoveryPartitionOffset = [long]$recovery.Offset
        recoveryPartitionSize = [long]$recovery.Size
        bitLockerSafe = [bool]$bitLocker.Safe
        bitLockerState = [string]$bitLocker.State
        bitLockerConversionStatus = [int]$bitLocker.ConversionStatus
        bitLockerEncryptionPercentage = [int]$bitLocker.EncryptionPercentage
        bitLockerProtectionStatus = [int]$bitLocker.ProtectionStatus
        initialBitLockerConversionStatus = [int]$initialBitLocker.ConversionStatus
        initialBitLockerEncryptionPercentage = [int]$initialBitLocker.EncryptionPercentage
        initialBitLockerProtectionStatus = [int]$initialBitLocker.ProtectionStatus
        allocation = $allocation
        allocationEncryption = $allocationEncryption
        secondaryBootPreflight = $secondaryBootPreflight
    } | ConvertTo-Json -Depth 5 -Compress

    exit 0
} catch {
    $failure = $_
    [ordered]@{
        preflightOk = $false
        errorMessage = $_.Exception.Message
        errorType = $_.Exception.GetType().FullName
        errorPosition = $_.InvocationInfo.PositionMessage
        errorStack = $_.ScriptStackTrace
    } | ConvertTo-Json -Compress
    if ($failure.Exception.Message -like "*PROCESS_TREE_NOT_STOPPED*") { exit 173 }
    exit 1
}
