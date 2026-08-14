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
    throw "Rollback inspection requires at least one staging volume label."
}

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
