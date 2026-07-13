Set-StrictMode -Version Latest

function Test-BitLockerVolumeReadable {
    param([Parameter(Mandatory = $true)]$Volume)
    if ($Volume.VolumeStatus -eq "FullyDecrypted") { return $true }
    if ($null -ne $Volume.EncryptionPercentage -and [int]$Volume.EncryptionPercentage -le 0) {
        return $true
    }
    return $false
}

function Restore-LibertixCDriveInitialSize {
    param([Parameter(Mandatory = $true)]$State)
    if (-not $State.OriginalCSize) {
        throw "Cannot restore C: without the saved initial size."
    }
    $partition = Get-Partition -DriveLetter C -ErrorAction Stop
    $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
    if (
        $partition.DiskNumber -ne [int]$State.DiskNumber -or
        ([string]$disk.UniqueId).Trim() -ne ([string]$State.DiskUniqueId).Trim()
    ) {
        throw "C: disk identity changed; refusing rollback resize."
    }
    $initialSize = [int64]$State.OriginalCSize
    if ($partition.Size -lt $initialSize) {
        $supported = Get-PartitionSupportedSize -DriveLetter C -ErrorAction Stop
        if ($supported.SizeMax -lt $initialSize) {
            throw "C: cannot be restored to its initial size."
        }
        Resize-Partition -DriveLetter C -Size $initialSize -ErrorAction Stop
    }
    $verified = Get-Partition -DriveLetter C -ErrorAction Stop
    if ($verified.Size -lt $initialSize) { throw "C: rollback size verification failed." }
}

Export-ModuleMember -Function Test-BitLockerVolumeReadable, Restore-LibertixCDriveInitialSize
