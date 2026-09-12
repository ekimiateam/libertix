param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Get-WindowsBootLoaderEvidence {
    $lines = @(& "$env:SystemRoot\System32\bcdedit.exe" /enum osloader /v)
    if ($LASTEXITCODE -ne 0 -or $lines.Count -eq 0) {
        throw 'The original Windows boot loader entries could not be read.'
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

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
    ConvertFrom-Json -ErrorAction Stop
$stagingVolumeLabels = @(
    $config.staging_volume_labels |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
if ($stagingVolumeLabels.Count -eq 0) {
    throw "Rollback inspection requires at least one staging volume label."
}

$systemPartition = Get-Partition -DriveLetter C -ErrorAction Stop
$systemDisk = $systemPartition | Get-Disk -ErrorAction Stop
$partitionLayout = @(Get-Partition -DiskNumber $systemDisk.Number -ErrorAction Stop |
    Sort-Object PartitionNumber | Select-Object PartitionNumber, Offset, Size, GptType, MbrType)
$storageLayout = @(Get-Disk -ErrorAction Stop | Where-Object Size -GT 0 | Sort-Object Number | ForEach-Object {
    [pscustomobject]@{
        Number = [int]$_.Number; UniqueId = [string]$_.UniqueId; Guid = [string]$_.Guid
        Signature = [string]$_.Signature; Size = [long]$_.Size
        PartitionStyle = [string]$_.PartitionStyle; LogicalSectorSize = [int]$_.LogicalSectorSize
        Partitions = @(Get-Partition -DiskNumber $_.Number -ErrorAction Stop |
            Sort-Object Offset | Select-Object Offset, Size, GptType, MbrType)
    }
})
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
$baselinePlanIds = @($ledgerPaths | ForEach-Object {
    [string](Get-Content -LiteralPath $_ -Raw | ConvertFrom-Json).planId
})
$bootLoaderEvidence = Get-WindowsBootLoaderEvidence
$installerPartitions = @()
foreach ($partition in @(Get-Partition -DiskNumber $systemDisk.Number -ErrorAction Stop)) {
    $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
    if (
        $null -ne $volume -and
        [string]$volume.FileSystemLabel -in $stagingVolumeLabels
    ) {
        $installerPartitions += $partition
    }
}

$libertixProcesses = @(
    Get-CimInstance Win32_Process -Filter "Name = 'Libertix.exe'" -ErrorAction Stop |
        Where-Object {
            [string]$_.CommandLine -match '(?i)--unattended-config\b'
        }
)
$recoveryTasks = @(
    Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object {
            $_.TaskName -like "LibertixUefiRecovery_*" -or
            $_.TaskName -like "LibertixUefiRecoveryPrompt_*"
        }
)

Write-Output ("SYSTEM_DISK_NUMBER={0}" -f [int]$systemDisk.Number)
Write-Output ("SYSTEM_PARTITION_NUMBER={0}" -f [int]$systemPartition.PartitionNumber)
Write-Output ("SYSTEM_PARTITION_OFFSET={0}" -f [int64]$systemPartition.Offset)
Write-Output ("SYSTEM_PARTITION_SIZE={0}" -f [int64]$systemPartition.Size)
Write-Output ("PARTITION_LAYOUT_JSON={0}" -f (ConvertTo-Json -InputObject $partitionLayout -Compress))
Write-Output ("STORAGE_LAYOUT_JSON={0}" -f (ConvertTo-Json -InputObject $storageLayout -Depth 6 -Compress))
Write-Output ("EXECUTION_PLAN_IDS_JSON={0}" -f (ConvertTo-Json -InputObject $baselinePlanIds -Compress))
Write-Output (
    "WINDOWS_BOOT_LOADERS_JSON={0}" -f `
    (ConvertTo-Json -InputObject @($bootLoaderEvidence.Lines) -Compress)
)
Write-Output (
    "WINDOWS_BOOT_LOADER_PARTITIONS_JSON={0}" -f `
    (ConvertTo-Json -InputObject @($bootLoaderEvidence.RamdiskPartitions) -Compress)
)
Write-Output ("INSTALLER_PARTITION_COUNT={0}" -f [int]$installerPartitions.Count)
Write-Output (
    "INSTALLER_PARTITION_NUMBERS={0}" -f `
    (($installerPartitions | ForEach-Object { [string]$_.PartitionNumber }) -join ",")
)
Write-Output ("LIBERTIX_PROCESS_COUNT={0}" -f [int]$libertixProcesses.Count)
Write-Output (
    "LIBERTIX_PROCESS_IDS={0}" -f `
    (($libertixProcesses | ForEach-Object { [string]$_.ProcessId }) -join ",")
)
Write-Output ("RECOVERY_TASK_COUNT={0}" -f [int]$recoveryTasks.Count)
Write-Output "RESULT=OK"
