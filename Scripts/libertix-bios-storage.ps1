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
    [int64]$SizeBytes = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

switch ($Action) {
    "QueryShrink" {
        $supported = Get-PartitionSupportedSize -DriveLetter $driveLetter -ErrorAction Stop
        Write-JsonResult @{
            CurrentSizeBytes = [int64]$windowsPartition.Size
            MinimumSizeBytes = [int64]$supported.SizeMin
            MaximumShrinkBytes = [int64]$windowsPartition.Size - [int64]$supported.SizeMin
        }
    }
    "Shrink" {
        if ($SizeBytes -le 0 -or $SizeBytes -ge [int64]$windowsPartition.Size) {
            throw "The requested shrink size is outside the Windows partition bounds."
        }
        $targetSize = [int64]$windowsPartition.Size - $SizeBytes
        $supported = Get-PartitionSupportedSize -DriveLetter $driveLetter -ErrorAction Stop
        if ($targetSize -lt [int64]$supported.SizeMin) {
            throw "Windows does not expose enough shrinkable space for the requested size."
        }
        Resize-Partition -DriveLetter $driveLetter -Size $targetSize -ErrorAction Stop
        $verified = Get-ValidatedWindowsPartition
        if ([int64]$verified.Size -ne $targetSize) {
            throw "Windows partition size does not match the requested post-shrink size."
        }
        Write-JsonResult @{ SizeBytes = [int64]$verified.Size }
    }
    "CreateStaging" {
        if ($SizeBytes -le 0) {
            throw "The staging partition size must be positive."
        }

        # Mount Manager selects an actually available access path. Fixed drive
        # letters can remain reserved by disconnected mappings that Get-Volume
        # does not report as local volumes.
        $partition = New-Partition `
            -DiskNumber $DiskNumber `
            -Size $SizeBytes `
            -AssignDriveLetter `
            -ErrorAction Stop
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
            [int64]$verifiedPartition.Offset -le [int64]$windowsPartition.Offset -or
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
