#requires -Version 5.1
param([Parameter(Mandatory = $true)][string]$ConfigPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$drive = ([string]$config.drive).ToUpperInvariant()
if ($drive -notmatch '^[A-Z]:$') {
    throw 'The fixture decryption target drive is invalid.'
}
$partition = Get-Partition -DriveLetter $drive.Substring(0, 1)
$disk = $partition | Get-Disk
if ([string]$disk.Path -cne [string]$config.disk_device_path -or $disk.IsOffline -or $disk.IsReadOnly) {
    throw 'The fixture decryption disk identity changed.'
}
$volume = Get-Volume -DriveLetter $drive.Substring(0, 1)
if ([string]$volume.FileSystemType -ne 'NTFS' -or [string]$volume.HealthStatus -ne 'Healthy') {
    throw 'The fixture decryption target is not a healthy NTFS volume.'
}
if ($config.require_system -eq $true) {
    if ($drive -cne [string]$env:SystemDrive) {
        throw 'The fixture decryption target is not the inspected Windows system volume.'
    }
} elseif (
    $drive -ceq [string]$env:SystemDrive -or $disk.IsBoot -or $disk.IsSystem -or
    [long]$partition.Offset -ne [long]$config.partition_offset -or
    [string]$volume.UniqueId -cne [string]$config.volume_id
) {
    throw 'The secondary fixture decryption target identity changed.'
}
if (@(Get-Process -Name Libertix -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'A product installation is already running; fixture decryption is refused.'
}
$before = Get-BitLockerVolume -MountPoint $drive
if ($config.begin -eq $true -and [string]$before.VolumeStatus -ne 'FullyDecrypted') {
    # The caller validates the read-only inventory first. The Windows module's
    # WhatIf propagates into its CIM reads and can fail before ShouldProcess.
    Disable-BitLocker -MountPoint $drive | Out-Null
}
$state = Get-BitLockerVolume -MountPoint $drive
Write-Output ('STORAGE_ENCRYPTION_JSON=' + (@{
    drive = $drive
    status = [string]$state.VolumeStatus
    percentage = [int]$state.EncryptionPercentage
    fully_decrypted = ([string]$state.VolumeStatus -eq 'FullyDecrypted' -and [int]$state.EncryptionPercentage -eq 0)
} | ConvertTo-Json -Compress))
