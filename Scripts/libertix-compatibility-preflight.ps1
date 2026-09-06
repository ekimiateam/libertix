#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet("en", "fr", "es", "ko")]
    [string]$LanguageCode = "en",
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ConnectivityUrl,
    [switch]$SkipNvramWriteProbe
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
& "$env:SystemRoot\System32\chcp.com" 65001 > $null
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)

$policyModulePath = Join-Path `
    $PSScriptRoot `
    "modules\Libertix.InstallationPolicy.psm1"

function Stop-Compatibility {
    param([string]$Code, [object[]]$FormatArguments = @())
    $template = Get-LocalizedMessage "errorMessages" $Code
    if ([string]::IsNullOrWhiteSpace($template)) {
        throw "[$Code] $Code"
    }
    throw "[$Code] $($template -f $FormatArguments)"
}

$messageCatalog = $null
$englishMessageCatalog = $null
$warnings = New-Object System.Collections.Generic.List[string]

function Get-LocalizedMessage {
    param([string]$Section, [string]$Key)

    if ($null -eq $messageCatalog) {
        return $null
    }
    $sectionProperty = $messageCatalog.PSObject.Properties[$Section]
    if ($null -eq $sectionProperty) {
        return $null
    }
    $messageProperty = $sectionProperty.Value.PSObject.Properties[$Key]
    if ($null -eq $messageProperty -and $LanguageCode -ne "en") {
        $englishSection = $englishMessageCatalog.PSObject.Properties[$Section]
        if ($null -ne $englishSection) {
            $messageProperty = $englishSection.Value.PSObject.Properties[$Key]
        }
    }
    if ($null -eq $messageProperty) {
        return $null
    }
    return [string]$messageProperty.Value
}

function Write-Check {
    param([string]$Code)
    $message = Get-LocalizedMessage "checkMessages" $Code
    Write-Output ("CHECK={0}: {1}" -f $Code, $message)
}

function Write-LocalizedWarning {
    param([string]$Key, [object[]]$FormatArguments = @())
    $message = Get-LocalizedMessage "warningMessages" $Key
    $localized = $message -f $FormatArguments
    $warnings.Add($localized)
    Write-Output ("WARNING: {0}" -f $localized)
}

function Test-DownloadServiceAccess {
    param([string]$Url)

    try {
        $uri = New-Object Uri $Url
        if ($uri.Scheme -notin @("http", "https")) {
            Stop-Compatibility "COMPAT_E_NETWORK_UNAVAILABLE" @("unsupported URL scheme")
        }

        $request = [Net.HttpWebRequest]::Create($uri)
        $request.Method = "GET"
        $request.Timeout = 15000
        $request.ReadWriteTimeout = 15000
        $request.AllowAutoRedirect = $true
        $request.UserAgent = "Libertix-Compatibility"
        $request.AddRange(0, 0)

        $response = $request.GetResponse()
        try {
            $statusCode = [int]$response.StatusCode
            if ($statusCode -lt 200 -or $statusCode -ge 400) {
                Stop-Compatibility "COMPAT_E_NETWORK_UNAVAILABLE" @("HTTP $statusCode")
            }
            $stream = $response.GetResponseStream()
            if ($null -ne $stream) {
                try { $null = $stream.ReadByte() }
                finally { $stream.Dispose() }
            }
        } finally {
            $response.Dispose()
        }
    } catch {
        if ($_.Exception.Message -match "^\[COMPAT_") { throw }
        Stop-Compatibility "COMPAT_E_NETWORK_UNAVAILABLE" @($_.Exception.Message)
    }
}

function Get-FirmwareMode {
    if (-not ("LibertixCompatibilityFirmware" -as [type])) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class LibertixCompatibilityFirmware {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetFirmwareType(out uint firmwareType);
}
"@
    }
    [uint32]$type = 0
    if (-not [LibertixCompatibilityFirmware]::GetFirmwareType([ref]$type)) {
        Stop-Compatibility "COMPAT_E_FIRMWARE_UNKNOWN"
    }
    switch ($type) {
        1 { "BIOS" }
        2 { "UEFI" }
        default { Stop-Compatibility "COMPAT_E_FIRMWARE_NOT_SUPPORTED" }
    }
}

function Get-BitLockerState {
    param([string]$DriveLetter)
    $escaped = $DriveLetter.Replace("'", "''")
    try {
        $volume = Get-CimInstance `
            -Namespace "root/CIMV2/Security/MicrosoftVolumeEncryption" `
            -ClassName Win32_EncryptableVolume `
            -Filter "DriveLetter='$escaped'" `
            -ErrorAction Stop
    } catch {
        Stop-Compatibility "COMPAT_E_BITLOCKER_STATUS" @($_.Exception.Message)
    }
    if (-not $volume) {
        return [pscustomobject]@{ Safe = $true; State = "NotEncryptable" }
    }
    $conversion = Invoke-CimMethod -InputObject $volume -MethodName GetConversionStatus -ErrorAction Stop
    $protection = Invoke-CimMethod -InputObject $volume -MethodName GetProtectionStatus -ErrorAction Stop
    if ($conversion.ReturnValue -ne 0 -or $protection.ReturnValue -ne 0) {
        Stop-Compatibility "COMPAT_E_BITLOCKER_UNREADABLE"
    }
    $safe = (
        [int]$conversion.ConversionStatus -eq 0 -and
        [int]$conversion.EncryptionPercentage -eq 0 -and
        [int]$protection.ProtectionStatus -eq 0
    )
    [pscustomobject]@{
        Safe = $safe
        State = if ($safe) { "FullyDecrypted" } else { "EncryptedOrProtected" }
    }
}

function Format-DiskDescriptions {
    param([object[]]$Disks)
    ($Disks | ForEach-Object {
        if ([string]::IsNullOrWhiteSpace($_.FriendlyName)) { "#$($_.Number)" } else { [string]$_.FriendlyName }
    }) -join ", "
}

function Get-StorageControllerNames {
    $operationTimeoutSeconds = 15
    $names = @()
    foreach ($className in @("Win32_IDEController", "Win32_SCSIController")) {
        try {
            $names += @(
                Get-CimInstance `
                    -ClassName $className `
                    -OperationTimeoutSec $operationTimeoutSeconds `
                    -ErrorAction Stop |
                    ForEach-Object { $_.Name }
            )
        } catch {
            Stop-Compatibility `
                "COMPAT_E_STORAGE_CONTROLLER_QUERY" `
                @($className, $operationTimeoutSeconds, $_.Exception.Message)
        }
    }
    return @($names | Where-Object { $_ })
}

function Get-SecureBootDbCertificates {
    $db = Get-SecureBootUEFI -Name db -ErrorAction Stop
    [byte[]]$bytes = $db.Bytes
    $x509SignatureType = [Guid]"a5c059a1-94e4-4aa7-87b5-ab155c2bf072"
    $certificates = New-Object System.Collections.Generic.List[Security.Cryptography.X509Certificates.X509Certificate2]
    $offset = 0
    while ($offset + 28 -le $bytes.Length) {
        $guidBytes = New-Object byte[] 16
        [Array]::Copy($bytes, $offset, $guidBytes, 0, 16)
        $signatureType = New-Object Guid (,$guidBytes)
        $listSize = [BitConverter]::ToUInt32($bytes, $offset + 16)
        $headerSize = [BitConverter]::ToUInt32($bytes, $offset + 20)
        $signatureSize = [BitConverter]::ToUInt32($bytes, $offset + 24)
        if ($listSize -lt 28 -or $offset + $listSize -gt $bytes.Length -or $signatureSize -lt 16) {
            Stop-Compatibility "COMPAT_E_SECURE_BOOT_DB_INVALID"
        }
        if ($signatureType -eq $x509SignatureType) {
            $signatureOffset = $offset + 28 + $headerSize
            $listEnd = $offset + $listSize
            while ($signatureOffset + $signatureSize -le $listEnd) {
                $certificateBytes = New-Object byte[] ([int]$signatureSize - 16)
                [Array]::Copy($bytes, $signatureOffset + 16, $certificateBytes, 0, $certificateBytes.Length)
                try {
                    $certificates.Add((New-Object Security.Cryptography.X509Certificates.X509Certificate2 (,$certificateBytes)))
                } catch {
                    Stop-Compatibility "COMPAT_E_SECURE_BOOT_CERT_INVALID"
                }
                $signatureOffset += $signatureSize
            }
        }
        $offset += $listSize
    }
    return $certificates
}

function Initialize-NvramApi {
    if (([System.Management.Automation.PSTypeName]"LibertixCompatibilityNvram").Type) { return }
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class LibertixCompatibilityNvram {
    private const UInt32 TOKEN_ADJUST_PRIVILEGES = 0x20;
    private const UInt32 TOKEN_QUERY = 0x8;
    private const UInt32 SE_PRIVILEGE_ENABLED = 0x2;
    [StructLayout(LayoutKind.Sequential)] private struct LUID { public UInt32 LowPart; public Int32 HighPart; }
    [StructLayout(LayoutKind.Sequential)] private struct TOKEN_PRIVILEGES { public UInt32 Count; public LUID Luid; public UInt32 Attributes; }
    [DllImport("advapi32.dll", SetLastError=true)] private static extern bool OpenProcessToken(IntPtr p, UInt32 a, out IntPtr t);
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] private static extern bool LookupPrivilegeValue(string s, string n, out LUID l);
    [DllImport("advapi32.dll", SetLastError=true)] private static extern bool AdjustTokenPrivileges(IntPtr t, bool d, ref TOKEN_PRIVILEGES n, UInt32 b, IntPtr p, IntPtr r);
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern UInt32 GetFirmwareEnvironmentVariable(string n, string g, byte[] b, UInt32 s);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SetFirmwareEnvironmentVariableEx(string n, string g, byte[] b, UInt32 s, UInt32 a);
    public static int LastError() { return Marshal.GetLastWin32Error(); }
    public static void EnablePrivilege() {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        try {
            LUID luid;
            if (!LookupPrivilegeValue(null, "SeSystemEnvironmentPrivilege", out luid)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES(); tp.Count = 1; tp.Luid = luid; tp.Attributes = SE_PRIVILEGE_ENABLED;
            if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            int error = Marshal.GetLastWin32Error(); if (error != 0) throw new System.ComponentModel.Win32Exception(error);
        } finally { CloseHandle(token); }
    }
}
"@
}

function Get-NvramVariable {
    param([string]$Name, [string]$Guid)
    $buffer = New-Object byte[] 65536
    $size = [LibertixCompatibilityNvram]::GetFirmwareEnvironmentVariable($Name, $Guid, $buffer, [uint32]$buffer.Length)
    if ($size -eq 0) {
        $errorCode = [LibertixCompatibilityNvram]::LastError()
        if ($errorCode -ne 203) {
            throw "GetFirmwareEnvironmentVariable($Name) failed with Win32 error $errorCode."
        }
        return [pscustomobject]@{ Exists = $false; Bytes = $null; Error = $errorCode }
    }
    $result = New-Object byte[] $size
    [Array]::Copy($buffer, $result, $size)
    [pscustomobject]@{ Exists = $true; Bytes = $result; Error = 0 }
}

function Set-NvramVariable {
    param([string]$Name, [string]$Guid, [AllowNull()][byte[]]$Bytes)
    $size = if ($null -eq $Bytes) { 0 } else { $Bytes.Length }
    if (-not [LibertixCompatibilityNvram]::SetFirmwareEnvironmentVariableEx(
        $Name, $Guid, $Bytes, [uint32]$size, [uint32]7)) {
        throw "SetFirmwareEnvironmentVariableEx($Name) failed with Win32 error $([LibertixCompatibilityNvram]::LastError())."
    }
}

function Test-NvramAndBootNext {
    Initialize-NvramApi
    [LibertixCompatibilityNvram]::EnablePrivilege()
    $global = "{8BE4DF61-93CA-11D2-AA0D-00E098032B8C}"
    $originalBootNext = Get-NvramVariable -Name "BootNext" -Guid $global
    try {
        $bootCurrent = Get-NvramVariable -Name "BootCurrent" -Guid $global
        if (-not $bootCurrent.Exists -or $bootCurrent.Bytes.Length -ne 2) {
            Stop-Compatibility "COMPAT_E_BOOTCURRENT_READ"
        }
        Set-NvramVariable -Name "BootNext" -Guid $global -Bytes $bootCurrent.Bytes
        $bootNext = Get-NvramVariable -Name "BootNext" -Guid $global
        if (-not $bootNext.Exists -or [BitConverter]::ToUInt16($bootNext.Bytes, 0) -ne [BitConverter]::ToUInt16($bootCurrent.Bytes, 0)) {
            Stop-Compatibility "COMPAT_E_BOOTNEXT_WRITE"
        }
    } finally {
        if ($originalBootNext.Exists) { Set-NvramVariable -Name "BootNext" -Guid $global -Bytes $originalBootNext.Bytes }
        else { Set-NvramVariable -Name "BootNext" -Guid $global -Bytes $null }
    }
}

try {
    $messageCatalogPath = Join-Path `
        (Split-Path -Parent $PSScriptRoot) `
        "Resources\Libertix.Translations.json"
    if (-not (Test-Path -LiteralPath $messageCatalogPath -PathType Leaf)) {
        throw "Libertix compatibility message catalogue is missing: $messageCatalogPath"
    }
    $translationCatalog = Get-Content -LiteralPath $messageCatalogPath -Raw -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop
    $languageProperty = $translationCatalog.languages.PSObject.Properties[$LanguageCode]
    $englishProperty = $translationCatalog.languages.PSObject.Properties["en"]
    if ($null -eq $languageProperty -or $null -eq $englishProperty) {
        throw "Libertix compatibility translations are incomplete for '$LanguageCode'."
    }
    $messageCatalog = $languageProperty.Value.compatibility
    $englishMessageCatalog = $englishProperty.Value.compatibility

    $geometryModule = Join-Path $PSScriptRoot "modules\Libertix.StorageGeometry.psm1"
    if (-not (Test-Path -LiteralPath $geometryModule -PathType Leaf)) {
        throw "Libertix storage geometry module is missing: $geometryModule"
    }
    Import-Module -Name $geometryModule -Force -ErrorAction Stop
    Import-Module -Name $policyModulePath -Force -ErrorAction Stop
    $installationPolicy = Get-LibertixInstallationPolicy
    [int]$minimumMemoryMB = [int]$installationPolicy.memory.windowsMinimumMiB
    [int]$lowMemoryThresholdMB = [int]$installationPolicy.memory.lowMemoryThresholdMiB
    [int]$preflightShrinkSafetyGB = [int]$installationPolicy.storage.preflightShrinkSafetyGiB
    [int]$stagingSizeGB = [int]$installationPolicy.storage.stagingSizeGiB

    Write-Check "COMPAT_010_PRIVILEGES"
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Stop-Compatibility "COMPAT_E_ADMIN_REQUIRED"
    }

    Write-Check "COMPAT_015_NETWORK"
    Test-DownloadServiceAccess -Url $ConnectivityUrl

    Write-Check "COMPAT_020_PLATFORM"
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    if ([int]$os.ProductType -ne 1) {
        Stop-Compatibility "COMPAT_E_OS_UNSUPPORTED"
    }
    $architecture = [string]$os.OSArchitecture
    if ($architecture -notmatch "64" -or $env:PROCESSOR_ARCHITECTURE -notmatch "AMD64") {
        Stop-Compatibility "COMPAT_E_ARCH_UNSUPPORTED"
    }
    [long]$memoryBytes = [long]$os.TotalVisibleMemorySize * 1024L
    [long]$memoryMB = [math]::Floor($memoryBytes / 1MB)
    if ($memoryMB -lt $minimumMemoryMB) {
        Stop-Compatibility "COMPAT_E_RAM_TOO_LOW" @($minimumMemoryMB, $memoryMB)
    }
    $lowMemory = $memoryMB -lt $lowMemoryThresholdMB
    if ($lowMemory) {
        Write-LocalizedWarning "LOW_MEMORY" @($memoryMB)
    }

    Write-Check "COMPAT_030_FIRMWARE"
    $firmware = Get-FirmwareMode
    $secureBootEnabled = $false
    $trustedMicrosoftUefiAuthorities = @()
    $nvramPassed = $false
    $nvramSkipped = $false
    if ($firmware -eq "UEFI") {
        try { $secureBootEnabled = [bool](Confirm-SecureBootUEFI -ErrorAction Stop) }
        catch { Stop-Compatibility "COMPAT_E_SECURE_BOOT_STATE" @($_.Exception.Message) }
        try {
            $subjects = @(Get-SecureBootDbCertificates | ForEach-Object { $_.Subject })
            if (@($subjects | Where-Object {
                $_ -match "CN=Microsoft Corporation UEFI CA 2011(?:,|$)"
            }).Count -gt 0) {
                $trustedMicrosoftUefiAuthorities += "2011"
            }
            if (@($subjects | Where-Object {
                $_ -match "CN=Microsoft(?: Corporation)? UEFI CA 2023(?:,|$)"
            }).Count -gt 0) {
                $trustedMicrosoftUefiAuthorities += "2023"
            }
        }
        catch {
            if ($secureBootEnabled) {
                Stop-Compatibility "COMPAT_E_SECURE_BOOT_STATE" @($_.Exception.Message)
            }
        }
        if ($secureBootEnabled -and $trustedMicrosoftUefiAuthorities.Count -eq 0) {
            Stop-Compatibility "COMPAT_E_SECURE_BOOT_THIRD_PARTY_CA"
        }
        if ($SkipNvramWriteProbe) {
            $nvramSkipped = $true
            Write-LocalizedWarning "NVRAM_PROBE_SKIPPED"
        } else {
            try { Test-NvramAndBootNext; $nvramPassed = $true }
            catch {
                if ($_.Exception.Message -match "^\[(COMPAT_[A-Z0-9_]+)\]\s*(.*)$") { throw }
                Stop-Compatibility "COMPAT_E_NVRAM_TEST_FAILED" @($_.Exception.Message)
            }
        }
    }

    Write-Check "COMPAT_040_STORAGE"
    try {
        $visibleDisks = @(
            Get-Disk -ErrorAction Stop |
                Where-Object { [long]$_.Size -gt 0 }
        )
    } catch {
        Stop-Compatibility "COMPAT_E_DISK_INVENTORY" @($_.Exception.Message)
    }
    $usbDisks = @($visibleDisks | Where-Object { [string]$_.BusType -eq "USB" })
    if ($usbDisks.Count -ne 0) {
        Stop-Compatibility "COMPAT_E_USB_STORAGE" @($usbDisks.Count, (Format-DiskDescriptions $usbDisks))
    }
    if ($visibleDisks.Count -ne 1) {
        Stop-Compatibility "COMPAT_E_DISK_COUNT" @($visibleDisks.Count, (Format-DiskDescriptions $visibleDisks))
    }

    $systemDrive = [Environment]::GetEnvironmentVariable("SystemDrive").TrimEnd("\")
    if ($systemDrive -notmatch "^[A-Za-z]:$") {
        Stop-Compatibility "COMPAT_E_SYSTEM_DRIVE"
    }
    $systemPartition = @(Get-Partition -DriveLetter $systemDrive.Substring(0, 1) -ErrorAction Stop)
    if ($systemPartition.Count -ne 1) {
        Stop-Compatibility "COMPAT_E_SYSTEM_DISK_UNRESOLVED"
    }
    $partition = $systemPartition[0]
    $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
    if ($disk.IsOffline -or $disk.IsReadOnly) {
        Stop-Compatibility "COMPAT_E_DISK_NOT_WRITABLE"
    }
    $busType = [string]$disk.BusType
    if ($busType -match "RAID|iSCSI|USB|File Backed Virtual|Spaces") {
        Stop-Compatibility "COMPAT_E_STORAGE_BUS_UNSUPPORTED" @($busType)
    }
    if ($busType -notmatch "^(SATA|ATA|NVMe|SAS|SCSI|MMC)$") {
        Stop-Compatibility "COMPAT_E_STORAGE_BUS_UNKNOWN" @($busType)
    }

    $controllerNames = @(Get-StorageControllerNames)
    $controllerText = $controllerNames -join " | "
    if ($controllerText -match "(?i)Intel.*(RST|Rapid Storage|VMD|Volume Management|Optane|VROC|RAID)") {
        Stop-Compatibility "COMPAT_E_INTEL_RST_RAID"
    }
    if ($controllerText -match "(?i)AMD.*RAID") {
        Stop-Compatibility "COMPAT_E_AMD_RAID"
    }
    if ($controllerText -match "(?i)(MegaRAID|Smart Array|PERC|Adaptec|Broadcom.*RAID|LSI.*RAID)") {
        Stop-Compatibility "COMPAT_E_HARDWARE_RAID"
    }
    if (
        $disk.LogicalSectorSize -notin @(512, 4096) -or
        $disk.PhysicalSectorSize -notin @(512, 4096) -or
        $disk.PhysicalSectorSize -lt $disk.LogicalSectorSize -or
        $disk.PhysicalSectorSize % $disk.LogicalSectorSize -ne 0
    ) {
        Stop-Compatibility "COMPAT_E_SECTOR_SIZE_UNSUPPORTED" @($disk.LogicalSectorSize, $disk.PhysicalSectorSize)
    }
    $expectedStyle = if ($firmware -eq "UEFI") { "GPT" } else { "MBR" }
    if ([string]$disk.PartitionStyle -ne $expectedStyle) {
        Stop-Compatibility "COMPAT_E_PARTITION_STYLE" @($firmware, $expectedStyle, $disk.PartitionStyle)
    }

    $allPartitions = @(Get-Partition -DiskNumber $disk.Number -ErrorAction Stop)
    if (
        $firmware -eq "BIOS" -and
        @($allPartitions | Where-Object { [int]$_.MbrType -in @(5, 15, 133) }).Count -ne 0
    ) {
        Stop-Compatibility "COMPAT_E_MBR_EXTENDED_LAYOUT"
    }
    if ($firmware -eq "BIOS" -and $allPartitions.Count -ge 4) {
        Stop-Compatibility "COMPAT_E_MBR_PRIMARY_LIMIT"
    }
    $recovery = @($allPartitions | Where-Object {
        $_.GptType -eq "{de94bba4-06d1-4d40-a16a-bfd50179d6ac}" -or
        [int]$_.MbrType -eq 39 -or $_.Type -match "Recovery"
    })
    if ($recovery.Count -ne 1) {
        Stop-Compatibility "COMPAT_E_RECOVERY_LAYOUT" @($recovery.Count)
    }
    if (
        [int64]$recovery[0].Offset -le [int64]$partition.Offset -or
        [int64]$partition.Size -gt [int64]$recovery[0].Offset - [int64]$partition.Offset
    ) {
        Stop-Compatibility "COMPAT_E_RECOVERY_POSITION"
    }
    if ($firmware -eq "UEFI") {
        $esp = @($allPartitions | Where-Object { $_.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" })
        if ($esp.Count -ne 1) {
            Stop-Compatibility "COMPAT_E_ESP_LAYOUT" @($esp.Count)
        }
    }

    Write-Check "COMPAT_050_FILESYSTEM"
    $volume = Get-Volume -DriveLetter $systemDrive.Substring(0, 1) -ErrorAction Stop
    if ([string]$volume.FileSystem -ne "NTFS" -or [string]$volume.HealthStatus -ne "Healthy") {
        Stop-Compatibility "COMPAT_E_NTFS_HEALTH" @($volume.FileSystem, $volume.HealthStatus)
    }
    try {
        [uint32]$scanResult = Repair-Volume `
            -DriveLetter $systemDrive.Substring(0, 1) `
            -Scan `
            -ErrorAction Stop
        if ($scanResult -ne 0) {
            Stop-Compatibility "COMPAT_E_NTFS_SCAN" @($scanResult)
        }
    } catch {
        if ($_.Exception.Message -match "^\[COMPAT_") { throw }
        Stop-Compatibility "COMPAT_E_NTFS_SCAN_FAILED" @($_.Exception.Message)
    }
    $supportedSize = Get-PartitionSupportedSize -DriveLetter $systemDrive.Substring(0, 1) -ErrorAction Stop
    [long]$alignmentPadding = Get-LibertixPartitionEndAlignmentPadding `
        -PartitionOffsetBytes ([int64]$partition.Offset) `
        -PartitionSizeBytes ([int64]$partition.Size) `
        -LogicalSectorSizeBytes ([int64]$disk.LogicalSectorSize)
    [long]$shrinkAvailable = `
        [long]$partition.Size - [long]$supportedSize.SizeMin - $alignmentPadding
    if ($firmware -eq "BIOS") {
        # Windows normally represents a fourth MBR partition as a logical
        # partition inside an extended container. Reserve one alignment unit
        # for its EBR metadata so the wizard never offers an uncreatable size.
        $shrinkAvailable -= Get-LibertixPartitionAlignmentBytes
    }
    [long]$requiredShrink =
        ([long]$stagingSizeGB + [long]$preflightShrinkSafetyGB) * 1GB
    if ($shrinkAvailable -lt $requiredShrink) {
        Stop-Compatibility "COMPAT_E_SHRINK_SPACE" @([math]::Round($shrinkAvailable / 1GB, 1), [math]::Round($requiredShrink / 1GB, 1))
    }
    $bitLocker = Get-BitLockerState -DriveLetter $systemDrive
    if (-not $bitLocker.Safe) {
        Write-LocalizedWarning "BITLOCKER"
    }
    [ordered]@{
        preflightOk = $true
        firmware = $firmware
        architecture = "AMD64"
        memoryBytes = [long]$memoryBytes
        lowMemoryMode = [bool]$lowMemory
        systemDiskNumber = [int]$disk.Number
        systemDiskUniqueId = [string]$disk.UniqueId
        systemDiskSize = [long]$disk.Size
        partitionStyle = [string]$disk.PartitionStyle
        storageBusType = [string]$busType
        logicalSectorSize = [int]$disk.LogicalSectorSize
        physicalSectorSize = [int]$disk.PhysicalSectorSize
        shrinkAvailableBytes = [long]$shrinkAvailable
        bitLockerSafe = [bool]$bitLocker.Safe
        bitLockerState = [string]$bitLocker.State
        secureBootEnabled = [bool]$secureBootEnabled
        trustedMicrosoftUefiAuthorities = @($trustedMicrosoftUefiAuthorities)
        nvramProbePassed = [bool]$nvramPassed
        nvramProbeSkipped = [bool]$nvramSkipped
        warnings = @($warnings)
    } | ConvertTo-Json -Compress
    exit 0
} catch {
    $code = "COMPAT_E_UNEXPECTED"
    $message = $_.Exception.Message
    $compatibilityError = [regex]::Match(
        $message,
        "^\[(COMPAT_[A-Z0-9_]+)\]\s*(.*)$")
    if ($compatibilityError.Success) {
        $code = $compatibilityError.Groups[1].Value
        $message = $compatibilityError.Groups[2].Value
    }
    [ordered]@{
        preflightOk = $false
        errorCode = $code
        errorMessage = $message
        errorType = $_.Exception.GetType().FullName
        errorPosition = $_.InvocationInfo.PositionMessage
        errorStack = $_.ScriptStackTrace
        warnings = @($warnings)
    } | ConvertTo-Json -Compress
    exit 1
}
