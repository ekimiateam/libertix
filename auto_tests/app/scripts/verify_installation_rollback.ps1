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
$requireClosedPostInstallResult =
    $config.PSObject.Properties.Name -contains "require_closed_post_install_result" -and
    [bool]$config.require_closed_post_install_result

function Get-WindowsBootLoaderEvidence {
    $lines = @(& "$env:SystemRoot\System32\bcdedit.exe" /enum osloader /v)
    if ($LASTEXITCODE -ne 0 -or $lines.Count -eq 0) {
        throw 'Windows boot loader entries could not be read after rollback.'
    }
    # Windows renumbers the transient HarddiskVolume alias while a temporary
    # Linux partition exists. The qualified WMI identity below remains stable.
    $lines = @($lines | ForEach-Object {
        ([string]$_).TrimEnd() -replace '(?i)\\Device\\HarddiskVolume[0-9]+', '\Device\HarddiskVolume#'
    })

    $store = [wmi]"\\.\root\wmi:BcdStore.FilePath=''"
    $enumeration = $store.EnumerateObjects([uint32]0x10200003)
    $loaderObjects = @($enumeration.Objects)
    if (-not $enumeration.ReturnValue -or $loaderObjects.Count -eq 0) {
        throw 'The Windows boot loader objects could not be enumerated through WMI.'
    }
    $ramdiskPartitions = @()
    foreach ($rawLoader in @($loaderObjects | Sort-Object Id)) {
        $loader = [wmi](
            "\\.\root\wmi:BcdObject.Id='$([string]$rawLoader.Id)',StoreFilePath=''"
        )
        $deviceResult = $loader.GetElement([uint32]0x11000001)
        if (-not $deviceResult.ReturnValue) {
            throw "The boot device for loader '$([string]$rawLoader.Id)' could not be read."
        }
        $device = $deviceResult.Element.Device
        foreach ($elementType in @([uint32]0x11000001, [uint32]0x21000001)) {
            $elementResult = $loader.GetElement($elementType)
            if (-not $elementResult.ReturnValue) {
                throw "The device element $elementType for loader '$([string]$rawLoader.Id)' could not be read."
            }
            # Qualify direct partitions only; recovery ramdisks are checked through their options below.
            if ([int]$elementResult.Element.Device.DeviceType -notin @(2, 6)) { continue }
            $partitionResult = $loader.GetElementWithFlags($elementType, [uint32]1)
            if (-not $partitionResult.ReturnValue) {
                throw "The device element $elementType for loader '$([string]$rawLoader.Id)' could not be qualified."
            }
            $partitionDevice = $partitionResult.Element.Device
            if ([int]$partitionDevice.DeviceType -eq 6) {
                $ramdiskPartitions += [pscustomobject]@{
                    LoaderId = [string]$rawLoader.Id
                    OptionsId = "element:$elementType"
                    PartitionStyle = [int]$partitionDevice.PartitionStyle
                    DiskSignature = [string]$partitionDevice.DiskSignature
                    PartitionIdentifier = [string]$partitionDevice.PartitionIdentifier
                }
            } elseif ([int]$partitionDevice.DeviceType -eq 2) {
                throw 'A partition device remained unqualified; refusing an incomplete BCD comparison.'
            }
        }
        if ([int]$device.DeviceType -ne 4) { continue }
        $optionsId = [string]$device.AdditionalOptions
        if ($optionsId -notmatch '^\{[0-9a-fA-F-]{36}\}$') {
            throw "The recovery loader '$([string]$rawLoader.Id)' has invalid ramdisk options."
        }
        $options = [wmi]("\\.\root\wmi:BcdObject.Id='$optionsId',StoreFilePath=''")
        $qualifiedResult = $options.GetElementWithFlags(
            [uint32]0x31000003,
            [uint32]1
        )
        if (-not $qualifiedResult.ReturnValue) {
            throw "The recovery partition for loader '$([string]$rawLoader.Id)' could not be qualified."
        }
        $qualified = $qualifiedResult.Element.Device
        if ([int]$qualified.DeviceType -ne 6) {
            throw "The recovery partition for loader '$([string]$rawLoader.Id)' is not qualified."
        }
        $ramdiskPartitions += [pscustomobject]@{
            LoaderId = [string]$rawLoader.Id
            OptionsId = $optionsId
            PartitionStyle = [int]$qualified.PartitionStyle
            DiskSignature = [string]$qualified.DiskSignature
            PartitionIdentifier = [string]$qualified.PartitionIdentifier
        }
    }
    return [pscustomobject]@{
        Lines = $lines
        RamdiskPartitions = @($ramdiskPartitions | Sort-Object LoaderId, OptionsId)
    }
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
    $firmwareEntries = @(bcdedit.exe /enum firmware)
    if ($LASTEXITCODE -ne 0) {
        throw "bcdedit could not enumerate firmware entries after rollback."
    }
    $temporaryBootReferences = @(
        $firmwareEntries |
            Where-Object { [string]$_ -match '(?i)LibertixInstaller|libertix\.efi' }
    )
    $windowsBootManager = @(bcdedit.exe /enum "{bootmgr}")
    if ($LASTEXITCODE -ne 0 -or $windowsBootManager.Count -eq 0) {
        throw "Windows Boot Manager could not be enumerated after rollback."
    }
    $bootLoaderEvidence = Get-WindowsBootLoaderEvidence
    $bootLoadersMatch = (ConvertTo-Json -InputObject @($bootLoaderEvidence.Lines) -Compress) -ceq
        (ConvertTo-Json -InputObject @($config.windows_boot_loaders) -Compress)
    $bootLoaderPartitionsMatch = (
        ConvertTo-Json -InputObject @($bootLoaderEvidence.RamdiskPartitions) -Compress
    ) -ceq (
        ConvertTo-Json -InputObject @($config.windows_boot_loader_partitions) -Compress
    )
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
    $ledger = Get-RollbackLedgerEvidence `
        -Paths $ledgerPaths `
        -ExcludedPlanIds @($config.baseline_plan_ids) `
        -RequireClosedPostInstallResult $requireClosedPostInstallResult
    $geometryMatches =
        [int]$systemDisk.Number -eq $expectedDiskNumber -and
        [int]$systemPartition.PartitionNumber -eq $expectedPartitionNumber -and
        [int64]$systemPartition.Offset -eq $expectedPartitionOffset -and
        [int64]$systemPartition.Size -eq $expectedPartitionSize
    $verified =
        $geometryMatches -and
        $layoutMatches -and $storageMatches -and $bootLoadersMatch -and
        $bootLoaderPartitionsMatch -and $ledger.Verified -and
        $ledger.PostInstallResultVerified -and
        $installerPartitions.Count -eq 0 -and
        $recoveryTasks.Count -eq 0 -and
        $temporaryBootReferences.Count -eq 0 -and
        $null -eq $bootGuardian
    return [pscustomobject]@{
        GeometryMatches = [bool]$geometryMatches
        PartitionLayoutMatches = [bool]$layoutMatches
        StorageLayoutMatches = [bool]$storageMatches
        LedgerVerified = [bool]$ledger.Verified
        PostInstallResultVerified = [bool]$ledger.PostInstallResultVerified
        PlanId = [string]$ledger.PlanId
        InstallerPartitionCount = [int]$installerPartitions.Count
        RecoveryTaskCount = [int]$recoveryTasks.Count
        TemporaryBootReferenceCount = [int]$temporaryBootReferences.Count
        WindowsBootManagerPresent = [bool]($windowsBootManager.Count -gt 0)
        WindowsBootLoadersMatch = [bool]$bootLoadersMatch
        WindowsBootLoaderPartitionsMatch = [bool]$bootLoaderPartitionsMatch
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
        [AllowEmptyCollection()][string[]]$ExcludedPlanIds,
        [bool]$RequireClosedPostInstallResult = $false
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
    $resultVerified = $true
    if ($RequireClosedPostInstallResult) {
        $resultPath = Join-Path $directory "post-install-verification.json"
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            $resultVerified = $false
        } else {
            $result = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $resultVerified =
                [string]$result.planId -ceq [string]$state.planId -and
                [string]$result.status -ceq "rolled-back" -and
                $result.rollbackAvailable -eq $false -and
                [int]$result.rollbackExecutionRevision -eq [int]$state.revision -and
                -not [string]::IsNullOrWhiteSpace([string]$result.rolledBackAtUtc)
            $finalPath = Join-Path $directory 'uninstall-verification.json'
            if (-not (Test-Path -LiteralPath $finalPath -PathType Leaf)) {
                $resultVerified = $false
            } else {
                $final = Get-Content -LiteralPath $finalPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $expectedChecks = @('execution-ledger', 'restored-storage', 'boot-restored', 'maintenance-removed')
                $resultVerified = $resultVerified -and
                    [int]$final.schemaVersion -eq 1 -and
                    [string]$final.planId -ceq [string]$state.planId -and
                    [string]$final.status -ceq 'succeeded' -and
                    [int]$final.rollbackExecutionRevision -eq [int]$state.revision -and
                    @($final.checks).Count -eq $expectedChecks.Count
                foreach ($name in $expectedChecks) {
                    $check = @($final.checks | Where-Object { [string]$_.name -ceq $name })
                    if ($check.Count -ne 1 -or $check[0].passed -ne $true) { $resultVerified = $false }
                }
            }
        }
    }
    return [pscustomobject]@{
        Verified = ([string]$state.status -eq "rolled-back")
        PostInstallResultVerified = [bool]$resultVerified
        PlanId = [string]$state.planId
    }
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
Write-Output (
    "ROLLBACK_POST_INSTALL_RESULT_VERIFIED={0}" -f `
    $rollbackState.PostInstallResultVerified
)
Write-Output ("ROLLBACK_PLAN_ID={0}" -f $rollbackState.PlanId)
Write-Output ("ROLLBACK_INSTALLER_PARTITION_COUNT={0}" -f $rollbackState.InstallerPartitionCount)
Write-Output ("ROLLBACK_RECOVERY_TASK_COUNT={0}" -f $rollbackState.RecoveryTaskCount)
Write-Output (
    "ROLLBACK_TEMPORARY_BOOT_REFERENCE_COUNT={0}" -f `
    $rollbackState.TemporaryBootReferenceCount
)
Write-Output ("ROLLBACK_WINDOWS_BOOT_MANAGER_PRESENT={0}" -f $rollbackState.WindowsBootManagerPresent)
Write-Output ("ROLLBACK_WINDOWS_BOOT_LOADERS_MATCH={0}" -f $rollbackState.WindowsBootLoadersMatch)
Write-Output (
    "ROLLBACK_WINDOWS_BOOT_LOADER_PARTITIONS_MATCH={0}" -f `
    $rollbackState.WindowsBootLoaderPartitionsMatch
)
Write-Output ("ROLLBACK_BOOT_GUARDIAN_PRESENT={0}" -f $rollbackState.BootGuardianPresent)
Write-Output ("ROLLBACK_VERIFIED={0}" -f $rollbackState.Verified)
if (-not $rollbackState.Verified) {
    throw "The Windows disk or boot state does not match the pre-installation baseline."
}
Write-Output "RESULT=OK"
