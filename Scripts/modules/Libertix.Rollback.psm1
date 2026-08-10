Set-StrictMode -Version Latest

function Test-BitLockerVolumeReadable {
    param([Parameter(Mandatory = $true)]$Volume)
    if ($Volume.VolumeStatus -eq "FullyDecrypted") { return $true }
    # Get-BitLockerVolume can report the previous VolumeStatus briefly after
    # decryption reaches zero percent. The percentage is the completed state
    # needed before Linux or rollback accesses the volume contents.
    if ($null -ne $Volume.EncryptionPercentage -and [int]$Volume.EncryptionPercentage -le 0) {
        return $true
    }
    return $false
}

function Wait-LibertixSystemDriveResizeCapacity {
    param(
        [Parameter(Mandatory = $true)][string]$DriveLetter,
        [Parameter(Mandatory = $true)][int]$DiskNumber,
        [Parameter(Mandatory = $true)][int64]$RequiredSize,
        [int]$TimeoutSeconds = 60
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        # Removing a partition updates the disk before every Storage CIM object
        # sees the new free extent. Refresh both caches before trusting SizeMax.
        Update-HostStorageCache -ErrorAction SilentlyContinue
        Update-Disk -Number $DiskNumber -ErrorAction SilentlyContinue | Out-Null

        $partition = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop
        $supported = Get-PartitionSupportedSize -DriveLetter $DriveLetter -ErrorAction Stop
        if ($partition.Size -ge $RequiredSize -or $supported.SizeMax -ge $RequiredSize) {
            return $supported
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            return $supported
        }
        Start-Sleep -Seconds 2
    } while ($true)
}

function Restore-LibertixSystemDriveInitialSize {
    param([Parameter(Mandatory = $true)]$State)
    if (-not $State.OriginalCSize) {
        throw "Cannot restore the Windows system volume without the saved initial size."
    }
    $hasSystemDrive = $State.PSObject.Properties.Name -contains "SystemDrive"
    $systemDrive = if ($hasSystemDrive -and $State.SystemDrive) {
        [string]$State.SystemDrive
    } else {
        [string]$env:SystemDrive
    }
    if ($systemDrive -notmatch "^[A-Za-z]:$") {
        throw "Invalid system drive in rollback state: $systemDrive"
    }
    $driveLetter = $systemDrive.TrimEnd(":")
    $partition = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
    $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
    if (
        $partition.DiskNumber -ne [int]$State.DiskNumber -or
        ([string]$disk.UniqueId).Trim() -ne ([string]$State.DiskUniqueId).Trim()
    ) {
        throw "$systemDrive disk identity changed; refusing rollback resize."
    }
    $initialSize = [int64]$State.OriginalCSize
    if ($partition.Size -ne $initialSize) {
        $supported = Wait-LibertixSystemDriveResizeCapacity `
            -DriveLetter $driveLetter `
            -DiskNumber ([int]$partition.DiskNumber) `
            -RequiredSize $initialSize
        if ($supported.SizeMin -gt $initialSize -or $supported.SizeMax -lt $initialSize) {
            throw (
                "$systemDrive cannot be restored to its initial size; " +
                "SizeMin=$($supported.SizeMin), SizeMax=$($supported.SizeMax)."
            )
        }
        Resize-Partition -DriveLetter $driveLetter -Size $initialSize -ErrorAction Stop
    }
    $verified = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
    if ($verified.Size -ne $initialSize) {
        throw "$systemDrive rollback size verification failed."
    }
}

Export-ModuleMember -Function Test-BitLockerVolumeReadable, Restore-LibertixSystemDriveInitialSize
