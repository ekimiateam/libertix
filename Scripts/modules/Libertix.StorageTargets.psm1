Set-StrictMode -Version Latest

function Get-LibertixStorageControllerNames {
    param(
        [Parameter(Mandatory = $true)][uint32]$DiskNumber,
        [switch]$RequireSupported
    )

    $operationTimeoutSeconds = 15
    $controllers = @()
    foreach ($className in @("Win32_IDEController", "Win32_SCSIController")) {
        try {
            $controllers += @(
                Get-CimInstance `
                    -ClassName $className `
                    -OperationTimeoutSec $operationTimeoutSeconds `
                    -ErrorAction Stop
            )
        } catch {
            throw "Storage controller query $className failed: $($_.Exception.Message)"
        }
    }
    $unsupportedPattern = '(?i)(Intel.*(RST|Rapid Storage|VMD|Volume Management|Optane|VROC|RAID)|AMD.*RAID|MegaRAID|Smart Array|PERC|Adaptec|Broadcom.*RAID|LSI.*RAID)'
    $unsupported = @($controllers | Where-Object { $_.Name -match $unsupportedPattern })
    if ($unsupported.Count -eq 0) {
        return @($controllers | ForEach-Object { $_.Name } | Where-Object { $_ })
    }

    try {
        # An unrelated RAID controller must not veto a supported selected disk.
        # Follow Windows' PnP parent relation instead of guessing from a model name.
        if (@($unsupported | Where-Object { [string]::IsNullOrWhiteSpace($_.PNPDeviceID) }).Count -gt 0) {
            throw 'A potentially unsupported controller has no PnP identity.'
        }
        $physicalDisks = @(Get-CimInstance -ClassName Win32_DiskDrive `
            -Filter "Index = $DiskNumber" -OperationTimeoutSec $operationTimeoutSeconds -ErrorAction Stop)
        if ($physicalDisks.Count -ne 1 -or
            [string]$physicalDisks[0].DeviceID -ne "\\.\PHYSICALDRIVE$DiskNumber" -or
            [string]::IsNullOrWhiteSpace($physicalDisks[0].PNPDeviceID)) {
            throw 'The selected physical disk has no unambiguous PnP identity.'
        }
        $parents = @{}
        $instanceId = [string]$physicalDisks[0].PNPDeviceID
        while ($instanceId -ne 'HTREE\ROOT\0') {
            if ($parents.ContainsKey($instanceId) -or $parents.Count -ge 16) {
                throw 'The selected disk has a cyclic or excessively deep PnP ancestry.'
            }
            $parents[$instanceId] = $true
            $parent = @(Get-PnpDeviceProperty -InstanceId $instanceId `
                -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop)
            if ($parent.Count -ne 1 -or $parent[0].Data -isnot [string] -or
                [string]::IsNullOrWhiteSpace($parent[0].Data)) {
                throw 'The selected disk has an incomplete PnP ancestry.'
            }
            $instanceId = [string]$parent[0].Data
        }
        $selectedNames = @($controllers | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.PNPDeviceID) -and $parents.ContainsKey($_.PNPDeviceID)
        } | ForEach-Object { $_.Name } | Where-Object { $_ })
        if ($RequireSupported -and @($selectedNames | Where-Object { $_ -match $unsupportedPattern }).Count -gt 0) {
            throw 'The selected disk uses an unsupported storage controller.'
        }
        return $selectedNames
    } catch {
        throw "Disk $DiskNumber controller verification failed: $($_.Exception.Message)"
    }
}

function Get-LibertixTargetDiskIdentity {
    param([Parameter(Mandatory = $true)][object]$Disk)

    $style = [string]$Disk.PartitionStyle
    if ($style -eq 'GPT') {
        $guid = [guid]$Disk.Guid
        if ($guid -eq [guid]::Empty) { throw 'The target disk has no GPT identity.' }
        return 'gpt:' + $guid.ToString('D').ToLowerInvariant()
    }
    if ($style -eq 'MBR') { return 'mbr:' + ([uint32]$Disk.Signature).ToString('x8') }
    throw 'The target disk is not a basic GPT or MBR disk.'
}

function Get-LibertixTargetVolumeEncryptionSnapshot {
    param([Parameter(Mandatory = $true)][ValidatePattern('^[A-Z]:$')][string]$Drive)

    $volumes = @(Get-CimInstance -Namespace 'root/CIMV2/Security/MicrosoftVolumeEncryption' `
        -ClassName Win32_EncryptableVolume -Filter "DriveLetter='$Drive'" -ErrorAction Stop)
    if ($volumes.Count -eq 0) {
        return [pscustomobject]@{
            state = 'NotEncryptable'; conversionStatus = 0; encryptionPercentage = 0; protectionStatus = 0
        }
    }
    if ($volumes.Count -ne 1) { throw 'The selected volume encryption identity is ambiguous.' }
    $conversion = Invoke-CimMethod -InputObject $volumes[0] -MethodName GetConversionStatus -ErrorAction Stop
    $protection = Invoke-CimMethod -InputObject $volumes[0] -MethodName GetProtectionStatus -ErrorAction Stop
    if ($conversion.ReturnValue -ne 0 -or $protection.ReturnValue -ne 0) {
        throw 'The selected volume encryption state is unavailable.'
    }
    if ($null -eq $conversion.ConversionStatus -or $null -eq $conversion.EncryptionPercentage -or
        $null -eq $protection.ProtectionStatus) {
        throw 'The selected volume encryption state is incomplete.'
    }
    if ([int]$conversion.ConversionStatus -notin @(0, 1, 2, 3, 4, 5) -or
        [int]$conversion.EncryptionPercentage -lt 0 -or [int]$conversion.EncryptionPercentage -gt 100 -or
        [int]$protection.ProtectionStatus -notin @(0, 1, 2)) {
        throw 'The selected volume encryption state is invalid.'
    }
    $decrypted = [int]$conversion.ConversionStatus -eq 0 -and [int]$conversion.EncryptionPercentage -eq 0 -and
        [int]$protection.ProtectionStatus -eq 0
    [pscustomobject]@{
        state = if ($decrypted) { 'FullyDecrypted' } else { 'EncryptedOrProtected' }
        conversionStatus = [int]$conversion.ConversionStatus
        encryptionPercentage = [int]$conversion.EncryptionPercentage
        protectionStatus = [int]$protection.ProtectionStatus
    }
}

function Get-LibertixTargetVolumeEncryptionState {
    param([Parameter(Mandatory = $true)][ValidatePattern('^[A-Z]:$')][string]$Drive)
    return (Get-LibertixTargetVolumeEncryptionSnapshot -Drive $Drive).state
}

function Get-LibertixNtfsVolumeSerial {
    param([Parameter(Mandatory = $true)][ValidatePattern('^[A-Z]:$')][string]$Drive)

    if (-not ('Libertix.Native.NtfsVolumeIdentity' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Libertix.Native
{
    public static class NtfsVolumeIdentity
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(string path, uint access, uint share,
            IntPtr security, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DeviceIoControl(SafeFileHandle device, uint code,
            IntPtr input, uint inputSize, [Out] byte[] output, uint outputSize,
            out uint bytesReturned, IntPtr overlapped);

        public static string ParseSerial(byte[] volumeData, uint bytesReturned)
        {
            if (volumeData == null || bytesReturned < 96 || bytesReturned > volumeData.Length)
                throw new InvalidDataException("NTFS volume data is incomplete.");
            ulong serial = BitConverter.ToUInt64(volumeData, 0);
            if (serial == 0)
                throw new InvalidDataException("NTFS volume serial is not usable as an identity.");
            return serial.ToString("X16", System.Globalization.CultureInfo.InvariantCulture);
        }

        public static string ReadSerial(string drive)
        {
            if (drive == null || drive.Length != 2 || drive[0] < 'A' || drive[0] > 'Z' || drive[1] != ':')
                throw new ArgumentException("A local volume drive letter is required.", "drive");
            using (SafeFileHandle handle = CreateFile(@"\\.\" + drive, 0x80000000, 3,
                IntPtr.Zero, 3, 0, IntPtr.Zero))
            {
                if (handle.IsInvalid)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot open the selected NTFS volume.");
                byte[] data = new byte[96];
                uint returned;
                // FSCTL_GET_NTFS_VOLUME_DATA exposes the same 64-bit serial that blkid formats as its NTFS UUID.
                if (!DeviceIoControl(handle, 0x00090064, IntPtr.Zero, 0, data,
                    (uint)data.Length, out returned, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot read the selected NTFS identity.");
                return ParseSerial(data, returned);
            }
        }
    }
}
'@ -ErrorAction Stop
    }
    return [Libertix.Native.NtfsVolumeIdentity]::ReadSerial($Drive)
}

function Test-LibertixTargetPartitionCandidate {
    param(
        [Parameter(Mandatory = $true)][object]$Disk,
        [Parameter(Mandatory = $true)][object]$Partition,
        [Parameter(Mandatory = $true)][object]$SystemPartition
    )

    if ([int]$Partition.DiskNumber -ne [int]$Disk.Number) { return $false }
    $isWindowsPartition = [int]$Partition.DiskNumber -eq [int]$SystemPartition.DiskNumber -and
        [int]$Partition.PartitionNumber -eq [int]$SystemPartition.PartitionNumber
    if (-not $isWindowsPartition -and [int]$Disk.Number -eq [int]$SystemPartition.DiskNumber) { return $false }
    if ($Disk.IsOffline -or $Disk.IsReadOnly -or [string]$Disk.HealthStatus -ne 'Healthy') { return $false }
    if ([string]$Disk.BusType -notin @('SATA', 'ATA', 'NVMe', 'SAS', 'SCSI', 'MMC')) { return $false }
    if (-not $isWindowsPartition -and ([string]$Disk.BusType -eq 'MMC' -or $Disk.IsBoot -or $Disk.IsSystem)) {
        return $false
    }
    if (([string]$Partition.DriveLetter).Trim([char]0) -notmatch '^[A-Za-z]$' -or
        $Partition.IsReadOnly -or $Partition.IsHidden -or $Partition.IsOffline) { return $false }
    if ([string]$Disk.PartitionStyle -eq 'GPT') {
        return [string]$Partition.GptType -eq '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
    }
    if ([string]$Disk.PartitionStyle -eq 'MBR') {
        return [int]$Partition.MbrType -eq 7 -and [int]$Partition.PartitionNumber -le 4
    }
    return $false
}

function Assert-LibertixUniqueTargetDiskIdentity {
    param(
        [Parameter(Mandatory = $true)][object]$Disk,
        [Parameter(Mandatory = $true)][object[]]$Disks
    )

    $identity = Get-LibertixTargetDiskIdentity -Disk $Disk
    foreach ($other in $Disks) {
        if ([int]$other.Number -eq [int]$Disk.Number -or
            [string]$other.PartitionStyle -notin @('GPT', 'MBR')) { continue }
        try { $otherIdentity = Get-LibertixTargetDiskIdentity -Disk $other } catch { continue }
        # Linux can see an offline Windows disk or a USB clone with the same table identity.
        if ($otherIdentity -ceq $identity) {
            throw 'Multiple disks have the selected partition-table identity.'
        }
    }
}

function Get-LibertixInstallationTargetInventory {
    param(
        [Parameter(Mandatory = $true)][object]$SystemPartition,
        [Parameter(Mandatory = $true)][object[]]$Disks
    )

    foreach ($disk in $Disks) {
        # Do not probe removable or remote volumes merely to offer another installation target.
        if ([string]$disk.BusType -notin @('SATA', 'ATA', 'NVMe', 'SAS', 'SCSI', 'MMC') -or
            $disk.IsOffline -or $disk.IsReadOnly) { continue }
        $isSystemDisk = [int]$disk.Number -eq [int]$SystemPartition.DiskNumber
        try {
            Assert-LibertixUniqueTargetDiskIdentity -Disk $disk -Disks $Disks
            if (-not $isSystemDisk) {
                Get-LibertixStorageControllerNames -DiskNumber $disk.Number -RequireSupported | Out-Null
            }
            $partitions = @(Get-Partition -DiskNumber $disk.Number -ErrorAction Stop)
            $tableId = Get-LibertixTargetDiskIdentity -Disk $disk
        } catch {
            if ($isSystemDisk) { throw }
            # An unavailable optional disk must not prevent using the proven Windows disk.
            continue
        }
        if (-not $isSystemDisk -and [string]$disk.PartitionStyle -eq 'MBR' -and ($partitions.Count -ge 4 -or
            @($partitions | Where-Object { [int]$_.MbrType -in @(5, 15, 133) }).Count -gt 0)) {
            continue
        }
        foreach ($partition in $partitions) {
            if (-not (Test-LibertixTargetPartitionCandidate -Disk $disk -Partition $partition `
                -SystemPartition $SystemPartition)) { continue }
            try {
                $volumes = @($partition | Get-Volume -ErrorAction Stop)
                $limits = Get-PartitionSupportedSize -DiskNumber $disk.Number `
                    -PartitionNumber $partition.PartitionNumber -ErrorAction Stop
            } catch {
                if ($isSystemDisk) { throw }
                continue
            }
            if ($volumes.Count -ne 1 -or [string]$volumes[0].FileSystemType -ne 'NTFS' -or
                [string]$volumes[0].HealthStatus -ne 'Healthy') { continue }
            $volume = $volumes[0]
            if ([long]$limits.SizeMin -le 0 -or [long]$limits.SizeMin -gt [long]$partition.Size) {
                continue
            }
            [pscustomobject][ordered]@{
                drive = ([string]$partition.DriveLetter).ToUpperInvariant() + ':'
                isWindows = [int]$disk.Number -eq [int]$SystemPartition.DiskNumber
                diskNumber = [int]$disk.Number
                diskUniqueId = ([string]$disk.UniqueId).Trim()
                diskDevicePath = [string]$disk.Path
                diskSerialNumber = ([string]$disk.SerialNumber).Trim()
                partitionTableId = $tableId
                diskSizeBytes = [long]$disk.Size
                logicalSectorSizeBytes = [int]$disk.LogicalSectorSize
                partitionStyle = [string]$disk.PartitionStyle
                friendlyName = [string]$disk.FriendlyName
                busType = [string]$disk.BusType
                partitionNumber = [int]$partition.PartitionNumber
                offsetBytes = [long]$partition.Offset
                sizeBytes = [long]$partition.Size
                minimumSizeBytes = [long]$limits.SizeMin
                freeBytes = [long]$volume.SizeRemaining
                volumeId = [string]$volume.UniqueId
            }
        }
    }
}

function Get-LibertixVerifiedInstallationTarget {
    param(
        [Parameter(Mandatory = $true)][object]$ExpectedTarget,
        [Parameter(Mandatory = $true)][object]$SystemPartition
    )

    $drive = [string]$ExpectedTarget.drive
    if ($drive -cnotmatch '^[A-Z]:$') { throw 'The selected installation drive is invalid.' }
    $partitions = @(Get-Partition -DriveLetter $drive.Substring(0, 1) -ErrorAction Stop)
    if ($partitions.Count -ne 1) { throw 'The selected installation volume is ambiguous.' }
    $partition = $partitions[0]
    $disks = @(Get-Disk -ErrorAction Stop)
    $diskMatches = @($disks | Where-Object { [int]$_.Number -eq [int]$partition.DiskNumber })
    if ($diskMatches.Count -ne 1) { throw 'The selected physical disk is ambiguous.' }
    $disk = $diskMatches[0]
    $identity = Get-LibertixTargetDiskIdentity -Disk $disk
    if ([int]$disk.Number -ne [int]$ExpectedTarget.diskNumber -or
        ([string]$disk.UniqueId).Trim() -cne ([string]$ExpectedTarget.diskUniqueId).Trim() -or
        $identity -cne [string]$ExpectedTarget.partitionTableId -or
        [long]$disk.Size -ne [long]$ExpectedTarget.diskSizeBytes -or
        [int]$disk.LogicalSectorSize -ne [int]$ExpectedTarget.logicalSectorSizeBytes -or
        [string]$disk.PartitionStyle -cne [string]$ExpectedTarget.partitionStyle -or
        [int]$partition.PartitionNumber -ne [int]$ExpectedTarget.partitionNumber -or
        [long]$partition.Offset -ne [long]$ExpectedTarget.offsetBytes -or
        [long]$partition.Size -ne [long]$ExpectedTarget.sizeBytes) {
        throw 'The selected installation target changed since compatibility verification.'
    }
    Assert-LibertixUniqueTargetDiskIdentity -Disk $disk -Disks $disks
    if (-not (Test-LibertixTargetPartitionCandidate -Disk $disk -Partition $partition `
                -SystemPartition $SystemPartition)) {
        throw 'The selected installation target is not a supported local data volume.'
    }
    Get-LibertixStorageControllerNames -DiskNumber $disk.Number -RequireSupported | Out-Null
    $diskPartitions = @(Get-Partition -DiskNumber $disk.Number -ErrorAction Stop)
    if ([string]$disk.PartitionStyle -eq 'MBR' -and ($diskPartitions.Count -ge 4 -or
        @($diskPartitions | Where-Object { [int]$_.MbrType -in @(5, 15, 133) }).Count -gt 0)) {
        throw 'The selected MBR disk has no supported partition slot available.'
    }
    $volumes = @($partition | Get-Volume -ErrorAction Stop)
    if ($volumes.Count -ne 1 -or [string]$volumes[0].FileSystemType -ne 'NTFS' -or
        [string]$volumes[0].HealthStatus -ne 'Healthy' -or
        [string]::IsNullOrWhiteSpace([string]$ExpectedTarget.volumeId) -or
        [string]$volumes[0].UniqueId -cne [string]$ExpectedTarget.volumeId) {
        throw 'The selected NTFS volume no longer matches its recorded identity.'
    }
    $limits = Get-PartitionSupportedSize -DiskNumber $disk.Number `
        -PartitionNumber $partition.PartitionNumber -ErrorAction Stop
    if ([long]$limits.SizeMin -le 0 -or [long]$limits.SizeMin -gt [long]$partition.Size) {
        throw 'The selected NTFS volume has no verified shrink limit.'
    }
    [pscustomobject]@{ Disk = $disk; Partition = $partition; Volume = $volumes[0]; Limits = $limits }
}

function Get-LibertixInstallationAllocation {
    param(
        [Parameter(Mandatory = $true)][object]$ExpectedTarget,
        [Parameter(Mandatory = $true)][object]$SystemPartition,
        [Parameter(Mandatory = $true)][ValidateSet('GPT', 'MBR')][string]$RequiredPartitionStyle
    )

    $verified = Get-LibertixVerifiedInstallationTarget -ExpectedTarget $ExpectedTarget `
        -SystemPartition $SystemPartition
    if ([int]$verified.Disk.Number -eq [int]$SystemPartition.DiskNumber) {
        if ([int]$verified.Partition.PartitionNumber -ne [int]$SystemPartition.PartitionNumber) {
            throw 'Another partition of the Windows disk is not a separate installation target.'
        }
        return $null
    }
    if ([string]$verified.Disk.PartitionStyle -ne $RequiredPartitionStyle) {
        throw 'The selected allocation disk partition style is not supported by this firmware workflow.'
    }
    $drive = ([string]$verified.Partition.DriveLetter).ToUpperInvariant() + ':'
    $encryptionState = Get-LibertixTargetVolumeEncryptionState -Drive $drive
    [pscustomobject][ordered]@{
        number = [int]$verified.Disk.Number
        uniqueId = ([string]$verified.Disk.UniqueId).Trim()
        partitionTableId = Get-LibertixTargetDiskIdentity -Disk $verified.Disk
        sizeBytes = [long]$verified.Disk.Size
        logicalSectorSizeBytes = [int]$verified.Disk.LogicalSectorSize
        partitionStyle = [string]$verified.Disk.PartitionStyle
        sourceDrive = $drive
        sourcePartition = [pscustomobject]@{
            number = [int]$verified.Partition.PartitionNumber
            offsetBytes = [long]$verified.Partition.Offset
            sizeBytes = [long]$verified.Partition.Size
        }
        sourceVolumeId = [string]$verified.Volume.UniqueId
        sourceNtfsUuid = Get-LibertixNtfsVolumeSerial -Drive $drive
        sourceBitLockerState = $encryptionState
    }
}

Export-ModuleMember -Function @(
    'Get-LibertixStorageControllerNames',
    'Get-LibertixTargetDiskIdentity',
    'Get-LibertixTargetVolumeEncryptionState',
    'Get-LibertixTargetVolumeEncryptionSnapshot',
    'Get-LibertixNtfsVolumeSerial',
    'Assert-LibertixUniqueTargetDiskIdentity',
    'Test-LibertixTargetPartitionCandidate',
    'Get-LibertixInstallationTargetInventory',
    'Get-LibertixVerifiedInstallationTarget',
    'Get-LibertixInstallationAllocation'
)
