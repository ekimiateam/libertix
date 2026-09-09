param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
    ConvertFrom-Json -ErrorAction Stop
$stagingVolumeLabels = @(
    $config.staging_volume_labels |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
if ($stagingVolumeLabels.Count -eq 0) {
    throw "Rollback verification requires at least one staging volume label."
}
$expectedDiskNumber = [int]$config.system_disk_number
$expectedPartitionNumber = [int]$config.system_partition_number
$expectedPartitionOffset = [int64]$config.system_partition_offset
$expectedPartitionSize = [int64]$config.system_partition_size
$waitTimeoutSeconds = if ($config.PSObject.Properties.Name -contains "wait_timeout_seconds") {
    [int]$config.wait_timeout_seconds
} else {
    0
}

function Test-RollbackPartitionLayout {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Actual,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Expected
    )
    if ($Actual.Count -eq 0 -or $Actual.Count -ne $Expected.Count) { return $false }
    # MSFT_Partition numbers can retain the pre-removal enumeration until reboot.
    # Compare every physical extent and type, not that volatile Windows identifier.
    $actualLayout = @($Actual | Sort-Object Offset | Select-Object Offset, Size, GptType, MbrType)
    $expectedLayout = @($Expected | Sort-Object Offset | Select-Object Offset, Size, GptType, MbrType)
    return (ConvertTo-Json -InputObject $actualLayout -Compress) -ceq
        (ConvertTo-Json -InputObject $expectedLayout -Compress)
}

function Get-RollbackState {
    $systemPartition = Get-Partition -DriveLetter C -ErrorAction Stop
    $systemDisk = $systemPartition | Get-Disk -ErrorAction Stop
    $installerPartitions = @()
    foreach ($partition in @(Get-Partition -DiskNumber $systemDisk.Number -ErrorAction Stop)) {
        $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
        if ($null -ne $volume -and [string]$volume.FileSystemLabel -in $stagingVolumeLabels) {
            $installerPartitions += $partition
        }
    }
    $recoveryTasks = @(
        Get-ScheduledTask -ErrorAction Stop |
            Where-Object {
                $_.TaskName -like "LibertixUefiRecovery_*" -or
                $_.TaskName -like "LibertixUefiRecoveryPrompt_*" -or
                $_.TaskName -in @("LibertixInstallRecovery", "LibertixInstallRecoveryPrompt", "LibertixLinuxReadOnly") -or
                $_.TaskName -like "LibertixLinuxReadOnlyPin_*"
            }
    )
    $firmwareEntries = @(bcdedit.exe /enum firmware 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "bcdedit could not enumerate firmware entries after rollback."
    }
    $temporaryBootReferences = @(
        $firmwareEntries |
            Where-Object { [string]$_ -match '(?i)LibertixInstaller|libertix\.efi' }
    )
    $windowsBootManager = @(bcdedit.exe /enum "{bootmgr}" 2>&1)
    if ($LASTEXITCODE -ne 0 -or $windowsBootManager.Count -eq 0) {
        throw "Windows Boot Manager could not be enumerated after rollback."
    }
    $bootGuardian = Get-Service -Name "LibertixBootGuardian" -ErrorAction SilentlyContinue
    $layout = @(Get-Partition -DiskNumber $systemDisk.Number -ErrorAction Stop |
        Sort-Object PartitionNumber | Select-Object PartitionNumber, Offset, Size, GptType, MbrType)
    $expectedLayout = @($config.partition_layout | Sort-Object PartitionNumber |
        Select-Object PartitionNumber, Offset, Size, GptType, MbrType)
    $layoutMatches = Test-RollbackPartitionLayout -Actual $layout -Expected $expectedLayout
    $storageMatches = Test-RollbackStorageLayout -Expected @($config.storage_layout)
    $ledgerPaths = @()
    $biosLedger = Join-Path $env:SystemDrive "LibertixInstallRecovery\installation-state.json"
    if (Test-Path -LiteralPath $biosLedger) { $ledgerPaths += $biosLedger }
    $uefiRoot = Join-Path $env:ProgramData "Libertix\UefiRecovery"
    if (Test-Path -LiteralPath $uefiRoot) {
        foreach ($directory in @(Get-ChildItem -LiteralPath $uefiRoot -Directory -ErrorAction Stop)) {
            $path = Join-Path $directory.FullName "installation-state.json"
            if (Test-Path -LiteralPath $path) { $ledgerPaths += $path }
        }
    }
    $ledger = Get-RollbackLedgerEvidence -Paths $ledgerPaths -ExcludedPlanIds @($config.baseline_plan_ids)
    $geometryMatches =
        [int]$systemDisk.Number -eq $expectedDiskNumber -and
        [int]$systemPartition.PartitionNumber -eq $expectedPartitionNumber -and
        [int64]$systemPartition.Offset -eq $expectedPartitionOffset -and
        [int64]$systemPartition.Size -eq $expectedPartitionSize
    $verified =
        $geometryMatches -and
        $layoutMatches -and $storageMatches -and $ledger.Verified -and
        $installerPartitions.Count -eq 0 -and
        $recoveryTasks.Count -eq 0 -and
        $temporaryBootReferences.Count -eq 0 -and
        $null -eq $bootGuardian
    return [pscustomobject]@{
        GeometryMatches = [bool]$geometryMatches
        PartitionLayoutMatches = [bool]$layoutMatches
        StorageLayoutMatches = [bool]$storageMatches
        LedgerVerified = [bool]$ledger.Verified
        PlanId = [string]$ledger.PlanId
        InstallerPartitionCount = [int]$installerPartitions.Count
        RecoveryTaskCount = [int]$recoveryTasks.Count
        TemporaryBootReferenceCount = [int]$temporaryBootReferences.Count
        WindowsBootManagerPresent = [bool]($windowsBootManager.Count -gt 0)
        BootGuardianPresent = [bool]($null -ne $bootGuardian)
        Verified = [bool]$verified
    }
}

function Test-RollbackStorageLayout {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Expected)
    $disks = @(Get-Disk -ErrorAction Stop | Where-Object Size -GT 0)
    if ($Expected.Count -eq 0 -or $disks.Count -ne $Expected.Count) { return $false }
    foreach ($saved in $Expected) {
        $diskMatches = @($disks | Where-Object Number -EQ $saved.Number)
        if ($diskMatches.Count -ne 1) { return $false }
        $disk = $diskMatches[0]
        foreach ($field in @('UniqueId', 'Guid', 'Signature', 'Size', 'PartitionStyle', 'LogicalSectorSize')) {
            if ([string]$disk.$field -cne [string]$saved.$field) { return $false }
        }
        $partitions = @(Get-Partition -DiskNumber $disk.Number -ErrorAction Stop)
        if (@($saved.Partitions).Count -eq 0) {
            if ($partitions.Count -ne 0) { return $false }
        } elseif (-not (Test-RollbackPartitionLayout -Actual $partitions -Expected @($saved.Partitions))) {
            return $false
        }
    }
    return $true
}

function Get-RollbackLedgerEvidence {
    param(
        [AllowEmptyCollection()][string[]]$Paths,
        [AllowEmptyCollection()][string[]]$ExcludedPlanIds
    )
    $candidates = @($Paths | Where-Object {
        $document = Get-Content -LiteralPath $_ -Raw -Encoding UTF8 | ConvertFrom-Json
        [string]$document.planId -notin $ExcludedPlanIds
    })
    if ($candidates.Count -ne 1) {
        throw "Exactly one new installation ledger is required to prove this rollback."
    }
    $directory = Split-Path -Parent $candidates[0]
    $modulePaths = @(@(
        (Join-Path $directory "Libertix.InstallationState.psm1"),
        (Join-Path $directory "payload\Scripts\modules\Libertix.InstallationState.psm1")
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if (@($modulePaths).Count -ne 1) { throw "The rollback ledger validator is missing or ambiguous." }
    Import-Module -Name $modulePaths[0] -Force -ErrorAction Stop
    $state = Read-LibertixExecutionState -Path $candidates[0]
    return [pscustomobject]@{ Verified = ([string]$state.status -eq "rolled-back"); PlanId = [string]$state.planId }
}

$deadline = [DateTime]::UtcNow.AddSeconds($waitTimeoutSeconds)
do {
    $rollbackState = Get-RollbackState
    if ($rollbackState.Verified -or [DateTime]::UtcNow -ge $deadline) {
        break
    }
    Start-Sleep -Seconds 2
} while ($true)

Write-Output ("ROLLBACK_GEOMETRY_MATCHES={0}" -f $rollbackState.GeometryMatches)
Write-Output ("ROLLBACK_PARTITION_LAYOUT_MATCHES={0}" -f $rollbackState.PartitionLayoutMatches)
Write-Output ("ROLLBACK_STORAGE_LAYOUT_MATCHES={0}" -f $rollbackState.StorageLayoutMatches)
Write-Output ("ROLLBACK_LEDGER_VERIFIED={0}" -f $rollbackState.LedgerVerified)
Write-Output ("ROLLBACK_PLAN_ID={0}" -f $rollbackState.PlanId)
Write-Output ("ROLLBACK_INSTALLER_PARTITION_COUNT={0}" -f $rollbackState.InstallerPartitionCount)
Write-Output ("ROLLBACK_RECOVERY_TASK_COUNT={0}" -f $rollbackState.RecoveryTaskCount)
Write-Output (
    "ROLLBACK_TEMPORARY_BOOT_REFERENCE_COUNT={0}" -f `
    $rollbackState.TemporaryBootReferenceCount
)
Write-Output ("ROLLBACK_WINDOWS_BOOT_MANAGER_PRESENT={0}" -f $rollbackState.WindowsBootManagerPresent)
Write-Output ("ROLLBACK_BOOT_GUARDIAN_PRESENT={0}" -f $rollbackState.BootGuardianPresent)
Write-Output ("ROLLBACK_VERIFIED={0}" -f $rollbackState.Verified)
if (-not $rollbackState.Verified) {
    throw "The Windows disk or boot state does not match the pre-installation baseline."
}
Write-Output "RESULT=OK"
