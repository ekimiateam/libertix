param(
    [ValidateSet("BIOS", "UEFI")]
    [string]$ExpectedFirmware,
    [switch]$DecryptBitLocker
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Result {
    param([string]$Name, [object]$Value)
    Write-Output ("{0}={1}" -f $Name, [string]$Value)
}

function Get-FirmwareMode {
    $signature = @"
using System;
using System.Runtime.InteropServices;
public static class LibertixFirmware {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetFirmwareType(out uint firmwareType);
}
"@
    if (-not ("LibertixFirmware" -as [type])) {
        Add-Type -TypeDefinition $signature
    }

    [uint32]$firmwareType = 0
    if (-not [LibertixFirmware]::GetFirmwareType([ref]$firmwareType)) {
        throw "GetFirmwareType failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())."
    }

    switch ($firmwareType) {
        1 { return "BIOS" }
        2 { return "UEFI" }
        default { throw "Unsupported or unknown firmware type: $firmwareType" }
    }
}

function Get-BitLockerState {
    param([string]$DriveLetter)

    $namespace = "root/CIMV2/Security/MicrosoftVolumeEncryption"
    $escaped = $DriveLetter.Replace("'", "''")
    try {
        $volume = Get-CimInstance `
            -Namespace $namespace `
            -ClassName Win32_EncryptableVolume `
            -Filter "DriveLetter='$escaped'" `
            -ErrorAction Stop
    } catch {
        throw "BitLocker state is unavailable for ${DriveLetter}: $($_.Exception.Message)"
    }

    if (-not $volume) {
        return [pscustomobject]@{
            Safe = $true
            State = "NotEncryptable"
            ConversionStatus = 0
            EncryptionPercentage = 0
            ProtectionStatus = 0
        }
    }

    $conversion = Invoke-CimMethod -InputObject $volume -MethodName GetConversionStatus -ErrorAction Stop
    $protection = Invoke-CimMethod -InputObject $volume -MethodName GetProtectionStatus -ErrorAction Stop
    if ($conversion.ReturnValue -ne 0 -or $protection.ReturnValue -ne 0) {
        throw "BitLocker status methods failed (conversion=$($conversion.ReturnValue), protection=$($protection.ReturnValue))."
    }

    $safe = (
        [int]$conversion.ConversionStatus -eq 0 -and
        [int]$conversion.EncryptionPercentage -eq 0 -and
        [int]$protection.ProtectionStatus -eq 0
    )
    return [pscustomobject]@{
        Safe = $safe
        State = if ($safe) { "FullyDecrypted" } else { "EncryptedOrProtected" }
        ConversionStatus = [int]$conversion.ConversionStatus
        EncryptionPercentage = [int]$conversion.EncryptionPercentage
        ProtectionStatus = [int]$protection.ProtectionStatus
    }
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Administrator privileges are required."
    }

    $firmware = Get-FirmwareMode
    if ($firmware -ne $ExpectedFirmware) {
        throw "Firmware mismatch: expected $ExpectedFirmware, detected $firmware."
    }

    $systemDrive = [Environment]::GetEnvironmentVariable("SystemDrive").TrimEnd("\")
    if ($systemDrive -notmatch "^[A-Za-z]:$") {
        throw "Invalid Windows system drive: $systemDrive"
    }

    $driveLetter = $systemDrive.Substring(0, 1)
    $partition = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
    $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
    if ($disk.IsOffline -or $disk.IsReadOnly) {
        throw "Windows system disk is offline or read-only."
    }
    if (@($partition).Count -ne 1) {
        throw "The Windows system volume does not resolve to exactly one partition."
    }

    $expectedStyle = if ($ExpectedFirmware -eq "UEFI") { "GPT" } else { "MBR" }
    if ([string]$disk.PartitionStyle -ne $expectedStyle) {
        throw "Partition style mismatch: expected $expectedStyle, detected $($disk.PartitionStyle)."
    }

    $bitLocker = Get-BitLockerState -DriveLetter $systemDrive
    if (-not $bitLocker.Safe -and $DecryptBitLocker) {
        Write-Output "BITLOCKER_ACTION=decrypting"
        $disableOutput = & manage-bde.exe -off $systemDrive 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "manage-bde could not start decryption: $($disableOutput -join ' ')"
        }
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $maximumWait = [TimeSpan]::FromHours(6)
        while ($timer.Elapsed -lt $maximumWait) {
            Start-Sleep -Seconds 10
            $bitLocker = Get-BitLockerState -DriveLetter $systemDrive
            Write-Output "BITLOCKER_PROGRESS=$($bitLocker.EncryptionPercentage)"
            if ($bitLocker.Safe) {
                break
            }
        }
        $timer.Stop()
        if (-not $bitLocker.Safe) {
            throw "Timed out waiting for BitLocker decryption."
        }
    }

    $recoveryPartitions = @(
        Get-Partition -DiskNumber $partition.DiskNumber -ErrorAction Stop |
            Where-Object {
                $_.GptType -eq "{de94bba4-06d1-4d40-a16a-bfd50179d6ac}" -or
                [int]$_.MbrType -eq 39 -or
                $_.Type -match "Recovery"
            }
    )
    if (@($recoveryPartitions).Count -ne 1) {
        throw "Exactly one Windows recovery partition is required; detected $(@($recoveryPartitions).Count)."
    }
    $recovery = $recoveryPartitions[0]

    if ($ExpectedFirmware -eq "UEFI") {
        $bootPartitions = @(
            Get-Partition -DiskNumber $partition.DiskNumber -ErrorAction Stop |
                Where-Object { $_.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" }
        )
    } else {
        $bootPartitions = @(
            Get-Partition -DiskNumber $partition.DiskNumber -ErrorAction Stop |
                Where-Object { $_.IsSystem }
        )
        if ($bootPartitions.Count -eq 0) {
            $bootPartitions = @(
                Get-Partition -DiskNumber $partition.DiskNumber -ErrorAction Stop |
                    Where-Object { $_.IsActive }
            )
        }
    }
    if ($bootPartitions.Count -ne 1) {
        throw "Exactly one Windows boot partition is required; detected $($bootPartitions.Count)."
    }
    $boot = $bootPartitions[0]

    Write-Result "PREFLIGHT_OK" "true"
    Write-Result "FIRMWARE" $firmware
    Write-Result "SYSTEM_DRIVE" $systemDrive
    Write-Result "SYSTEM_DISK_NUMBER" $partition.DiskNumber
    Write-Result "SYSTEM_PARTITION_NUMBER" $partition.PartitionNumber
    Write-Result "SYSTEM_PARTITION_OFFSET" $partition.Offset
    Write-Result "SYSTEM_PARTITION_SIZE" $partition.Size
    Write-Result "BOOT_PARTITION_NUMBER" $boot.PartitionNumber
    Write-Result "BOOT_PARTITION_OFFSET" $boot.Offset
    Write-Result "BOOT_PARTITION_SIZE" $boot.Size
    Write-Result "SYSTEM_DISK_UNIQUE_ID" $disk.UniqueId
    Write-Result "SYSTEM_DISK_SIZE" $disk.Size
    Write-Result "PARTITION_STYLE" $disk.PartitionStyle
    Write-Result "RECOVERY_PARTITION_NUMBER" $recovery.PartitionNumber
    Write-Result "RECOVERY_PARTITION_OFFSET" $recovery.Offset
    Write-Result "RECOVERY_PARTITION_SIZE" $recovery.Size
    Write-Result "BITLOCKER_SAFE" $bitLocker.Safe.ToString().ToLowerInvariant()
    Write-Result "BITLOCKER_STATE" $bitLocker.State
    Write-Result "BITLOCKER_CONVERSION_STATUS" $bitLocker.ConversionStatus
    Write-Result "BITLOCKER_ENCRYPTION_PERCENTAGE" $bitLocker.EncryptionPercentage
    Write-Result "BITLOCKER_PROTECTION_STATUS" $bitLocker.ProtectionStatus

    exit 0
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
