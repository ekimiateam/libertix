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

$systemPartition = Get-Partition -DriveLetter C -ErrorAction Stop
$systemDisk = $systemPartition | Get-Disk -ErrorAction Stop
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
$recoveryTasks = @(
    Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object {
            $_.TaskName -like "LibertixUefiRecovery_*" -or
            $_.TaskName -like "LibertixUefiRecoveryPrompt_*"
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

$geometryMatches =
    [int]$systemDisk.Number -eq $expectedDiskNumber -and
    [int]$systemPartition.PartitionNumber -eq $expectedPartitionNumber -and
    [int64]$systemPartition.Offset -eq $expectedPartitionOffset -and
    [int64]$systemPartition.Size -eq $expectedPartitionSize
$rollbackVerified =
    $geometryMatches -and
    $installerPartitions.Count -eq 0 -and
    $recoveryTasks.Count -eq 0 -and
    $temporaryBootReferences.Count -eq 0

Write-Output ("ROLLBACK_GEOMETRY_MATCHES={0}" -f [bool]$geometryMatches)
Write-Output ("ROLLBACK_INSTALLER_PARTITION_COUNT={0}" -f [int]$installerPartitions.Count)
Write-Output ("ROLLBACK_RECOVERY_TASK_COUNT={0}" -f [int]$recoveryTasks.Count)
Write-Output (
    "ROLLBACK_TEMPORARY_BOOT_REFERENCE_COUNT={0}" -f `
    [int]$temporaryBootReferences.Count
)
Write-Output ("ROLLBACK_WINDOWS_BOOT_MANAGER_PRESENT={0}" -f [bool]($windowsBootManager.Count -gt 0))
Write-Output ("ROLLBACK_VERIFIED={0}" -f [bool]$rollbackVerified)
Write-Output "RESULT=OK"

if (-not $rollbackVerified) {
    throw "The Windows disk or boot state does not match the pre-installation baseline."
}
