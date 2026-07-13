#requires -Version 5.1

[CmdletBinding()]
param(
    [int]$MinimumLinuxSizeGB = 20,
    [int]$MinimumMemoryMB = 2048,
    [int]$LowMemoryThresholdMB = 4096
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
& "$env:SystemRoot\System32\chcp.com" 65001 > $null
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)

function Write-Result {
    param([string]$Name, [object]$Value)
    $text = [string]$Value
    $text = $text.Replace("`r", " ").Replace("`n", " ")
    Write-Output ("{0}={1}" -f $Name, $text)
}

function Stop-Compatibility {
    param([string]$Code, [string]$Message)
    throw "[$Code] $Message"
}

function Write-Check {
    param([string]$Code, [string]$Message)
    Write-Output ("CHECK={0}: {1}" -f $Code, $Message)
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
        Stop-Compatibility "COMPAT_E_FIRMWARE_UNKNOWN" "Windows ne peut pas déterminer le type de firmware."
    }
    switch ($type) {
        1 { "BIOS" }
        2 { "UEFI" }
        default { Stop-Compatibility "COMPAT_E_FIRMWARE_UNKNOWN" "Le firmware détecté n'est ni BIOS ni UEFI." }
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
        Stop-Compatibility "COMPAT_E_BITLOCKER_STATUS" "L'état BitLocker est illisible: $($_.Exception.Message)"
    }
    if (-not $volume) {
        return [pscustomobject]@{ Safe = $true; State = "NotEncryptable" }
    }
    $conversion = Invoke-CimMethod -InputObject $volume -MethodName GetConversionStatus -ErrorAction Stop
    $protection = Invoke-CimMethod -InputObject $volume -MethodName GetProtectionStatus -ErrorAction Stop
    if ($conversion.ReturnValue -ne 0 -or $protection.ReturnValue -ne 0) {
        Stop-Compatibility "COMPAT_E_BITLOCKER_STATUS" "Windows n'a pas pu lire complètement l'état BitLocker."
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
            Stop-Compatibility "COMPAT_E_SECURE_BOOT_DB_INVALID" "La base de certificats Secure Boot est invalide."
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
                    Stop-Compatibility "COMPAT_E_SECURE_BOOT_DB_INVALID" "Un certificat Secure Boot ne peut pas être décodé."
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
        return [pscustomobject]@{ Exists = $false; Bytes = $null; Error = [LibertixCompatibilityNvram]::LastError() }
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
    $probeGuid = "{E68B6B91-06D7-47A1-AE68-550B498FEE24}"
    $probeName = "LibertixCompatibilityProbe"
    $originalProbe = Get-NvramVariable -Name $probeName -Guid $probeGuid
    $originalBootNext = Get-NvramVariable -Name "BootNext" -Guid $global
    try {
        [byte[]]$probeBytes = [Text.Encoding]::ASCII.GetBytes("libertix-nvram-probe")
        Set-NvramVariable -Name $probeName -Guid $probeGuid -Bytes $probeBytes
        $readBack = Get-NvramVariable -Name $probeName -Guid $probeGuid
        if (-not $readBack.Exists -or [Convert]::ToBase64String($readBack.Bytes) -ne [Convert]::ToBase64String($probeBytes)) {
            Stop-Compatibility "COMPAT_E_NVRAM_WRITE" "Le firmware n'a pas relu correctement une variable NVRAM temporaire."
        }

        $bootCurrent = Get-NvramVariable -Name "BootCurrent" -Guid $global
        if (-not $bootCurrent.Exists -or $bootCurrent.Bytes.Length -ne 2) {
            Stop-Compatibility "COMPAT_E_BOOTCURRENT_READ" "Le firmware n'expose pas une valeur BootCurrent valide."
        }
        Set-NvramVariable -Name "BootNext" -Guid $global -Bytes $bootCurrent.Bytes
        $bootNext = Get-NvramVariable -Name "BootNext" -Guid $global
        if (-not $bootNext.Exists -or [BitConverter]::ToUInt16($bootNext.Bytes, 0) -ne [BitConverter]::ToUInt16($bootCurrent.Bytes, 0)) {
            Stop-Compatibility "COMPAT_E_BOOTNEXT_WRITE" "Le firmware refuse ou altère BootNext."
        }
    } finally {
        if ($originalProbe.Exists) { Set-NvramVariable -Name $probeName -Guid $probeGuid -Bytes $originalProbe.Bytes }
        else { Set-NvramVariable -Name $probeName -Guid $probeGuid -Bytes $null }
        if ($originalBootNext.Exists) { Set-NvramVariable -Name "BootNext" -Guid $global -Bytes $originalBootNext.Bytes }
        else { Set-NvramVariable -Name "BootNext" -Guid $global -Bytes $null }
    }
}

try {
    Write-Check "COMPAT_010_PRIVILEGES" "Vérification des droits administrateur"
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Stop-Compatibility "COMPAT_E_ADMIN_REQUIRED" "Libertix doit être lancé en administrateur."
    }

    Write-Check "COMPAT_020_PLATFORM" "Vérification de Windows, de l'architecture et de la mémoire"
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    if ([int]$os.ProductType -ne 1) {
        Stop-Compatibility "COMPAT_E_OS_UNSUPPORTED" "Seules les éditions clientes de Windows sont prises en charge."
    }
    $architecture = [string]$os.OSArchitecture
    if ($architecture -notmatch "64" -or $env:PROCESSOR_ARCHITECTURE -notmatch "AMD64") {
        Stop-Compatibility "COMPAT_E_ARCH_UNSUPPORTED" "Cette version de Libertix nécessite Windows x86-64 (AMD64); ARM64 et x86 ne sont pas pris en charge."
    }
    [long]$memoryBytes = [long]$os.TotalVisibleMemorySize * 1024L
    [long]$memoryMB = [math]::Floor($memoryBytes / 1MB)
    if ($memoryMB -lt $MinimumMemoryMB) {
        Stop-Compatibility "COMPAT_E_RAM_TOO_LOW" "Au moins $MinimumMemoryMB Mio de RAM sont nécessaires; $memoryMB Mio ont été détectés."
    }
    $lowMemory = $memoryMB -lt $LowMemoryThresholdMB
    if ($lowMemory) {
        Write-Result "WARNING" "Mémoire limitée ($memoryMB Mio): Libertix utilisera le mode faible mémoire sans copie intégrale du live en RAM."
    }

    Write-Check "COMPAT_030_FIRMWARE" "Vérification du firmware et du démarrage sécurisé"
    $firmware = Get-FirmwareMode
    $secureBootEnabled = $false
    $nvramPassed = $false
    if ($firmware -eq "UEFI") {
        try { $secureBootEnabled = [bool](Confirm-SecureBootUEFI -ErrorAction Stop) }
        catch { Stop-Compatibility "COMPAT_E_SECURE_BOOT_STATE" "L'état Secure Boot ne peut pas être lu: $($_.Exception.Message)" }
        if ($secureBootEnabled) {
            $subjects = @(Get-SecureBootDbCertificates | ForEach-Object { $_.Subject })
            $thirdPartyCa = @($subjects | Where-Object {
                $_ -match "CN=Microsoft Corporation UEFI CA 2011(?:,|$)" -or
                $_ -match "CN=Microsoft(?: Corporation)? UEFI CA 2023(?:,|$)"
            }).Count -gt 0
            if (-not $thirdPartyCa) {
                Stop-Compatibility "COMPAT_E_SECURE_BOOT_THIRD_PARTY_CA" "Secure Boot est actif mais aucune autorité Microsoft UEFI tierce compatible n'est inscrite."
            }
        }
        try { Test-NvramAndBootNext; $nvramPassed = $true }
        catch {
            if ($_.Exception.Message -match "^\[(COMPAT_[A-Z0-9_]+)\]\s*(.*)$") { throw }
            Stop-Compatibility "COMPAT_E_NVRAM_WRITE" "Le test NVRAM/BootNext a échoué et a été restauré: $($_.Exception.Message)"
        }
    }

    Write-Check "COMPAT_040_STORAGE" "Vérification du disque système et du contrôleur"
    $systemDrive = [Environment]::GetEnvironmentVariable("SystemDrive").TrimEnd("\")
    if ($systemDrive -notmatch "^[A-Za-z]:$") {
        Stop-Compatibility "COMPAT_E_SYSTEM_DRIVE" "Le volume système Windows est invalide."
    }
    $systemPartition = @(Get-Partition -DriveLetter $systemDrive.Substring(0, 1) -ErrorAction Stop)
    if ($systemPartition.Count -ne 1) {
        Stop-Compatibility "COMPAT_E_SYSTEM_DISK_UNRESOLVED" "Le volume Windows ne correspond pas à une partition simple unique."
    }
    $partition = $systemPartition[0]
    $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
    if ($disk.IsOffline -or $disk.IsReadOnly) {
        Stop-Compatibility "COMPAT_E_DISK_NOT_WRITABLE" "Le disque système est hors ligne ou en lecture seule."
    }
    $busType = [string]$disk.BusType
    if ($busType -match "RAID|iSCSI|USB|File Backed Virtual|Spaces") {
        Stop-Compatibility "COMPAT_E_STORAGE_BUS_UNSUPPORTED" "Le disque système utilise le bus '$busType', qui n'est pas pris en charge de manière fiable par le live Libertix."
    }
    if ($busType -notmatch "^(SATA|ATA|NVMe|SAS|SCSI|MMC)$") {
        Stop-Compatibility "COMPAT_E_STORAGE_BUS_UNKNOWN" "Le bus de stockage '$busType' n'est pas dans la liste testée par Libertix."
    }

    $controllerNames = @(
        Get-CimInstance Win32_IDEController -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }
        Get-CimInstance Win32_SCSIController -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }
    ) | Where-Object { $_ }
    $controllerText = $controllerNames -join " | "
    if ($controllerText -match "(?i)Intel.*(RST|Rapid Storage|VMD|Volume Management|Optane|VROC|RAID)") {
        Stop-Compatibility "COMPAT_E_INTEL_RST_RAID" "Intel RST/VMD/Optane/VROC est actif. Le live Linux peut ne pas voir le disque; passez le contrôleur en AHCI selon la procédure du constructeur sans casser Windows."
    }
    if ($controllerText -match "(?i)AMD.*RAID") {
        Stop-Compatibility "COMPAT_E_AMD_RAID" "Un contrôleur AMD RAID est actif et n'est pas pris en charge par ce live Libertix."
    }
    if ($controllerText -match "(?i)(MegaRAID|Smart Array|PERC|Adaptec|Broadcom.*RAID|LSI.*RAID)") {
        Stop-Compatibility "COMPAT_E_HARDWARE_RAID" "Un contrôleur RAID matériel a été détecté; sa géométrie Linux n'est pas garantie par Libertix."
    }
    if ($disk.LogicalSectorSize -notin @(512, 4096) -or $disk.PhysicalSectorSize -notin @(512, 4096)) {
        Stop-Compatibility "COMPAT_E_SECTOR_SIZE_UNSUPPORTED" "Les secteurs $($disk.LogicalSectorSize)/$($disk.PhysicalSectorSize) octets ne sont pas pris en charge."
    }
    $expectedStyle = if ($firmware -eq "UEFI") { "GPT" } else { "MBR" }
    if ([string]$disk.PartitionStyle -ne $expectedStyle) {
        Stop-Compatibility "COMPAT_E_PARTITION_STYLE" "Le firmware $firmware nécessite un disque $expectedStyle; le disque est $($disk.PartitionStyle)."
    }

    $allPartitions = @(Get-Partition -DiskNumber $disk.Number -ErrorAction Stop)
    if ($firmware -eq "BIOS" -and $allPartitions.Count -ge 4) {
        Stop-Compatibility "COMPAT_E_MBR_PRIMARY_LIMIT" "Le disque MBR possède déjà quatre partitions; aucune partition primaire Linux ne peut être ajoutée."
    }
    $recovery = @($allPartitions | Where-Object {
        $_.GptType -eq "{de94bba4-06d1-4d40-a16a-bfd50179d6ac}" -or
        [int]$_.MbrType -eq 39 -or $_.Type -match "Recovery"
    })
    if ($recovery.Count -ne 1) {
        Stop-Compatibility "COMPAT_E_RECOVERY_LAYOUT" "Une partition de récupération Windows unique est requise; $($recovery.Count) ont été détectées."
    }
    if ($firmware -eq "UEFI") {
        $esp = @($allPartitions | Where-Object { $_.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" })
        if ($esp.Count -ne 1) {
            Stop-Compatibility "COMPAT_E_ESP_LAYOUT" "Une partition système EFI unique est requise; $($esp.Count) ont été détectées."
        }
    }

    Write-Check "COMPAT_050_FILESYSTEM" "Vérification de NTFS, BitLocker et de l'espace réductible"
    $volume = Get-Volume -DriveLetter $systemDrive.Substring(0, 1) -ErrorAction Stop
    if ([string]$volume.FileSystem -ne "NTFS" -or [string]$volume.HealthStatus -ne "Healthy") {
        Stop-Compatibility "COMPAT_E_NTFS_HEALTH" "Le volume Windows doit être un NTFS sain; état détecté: $($volume.FileSystem)/$($volume.HealthStatus)."
    }
    try {
        $scan = Repair-Volume -DriveLetter $systemDrive.Substring(0, 1) -Scan -ErrorAction Stop
        if ($null -ne $scan -and [string]$scan -notmatch "NoErrorsFound|No Error|Aucune") {
            Stop-Compatibility "COMPAT_E_NTFS_SCAN" "L'analyse NTFS n'a pas confirmé un système de fichiers sain: $scan"
        }
    } catch {
        if ($_.Exception.Message -match "^\[COMPAT_") { throw }
        Stop-Compatibility "COMPAT_E_NTFS_SCAN" "L'analyse NTFS a échoué: $($_.Exception.Message)"
    }
    $supportedSize = Get-PartitionSupportedSize -DriveLetter $systemDrive.Substring(0, 1) -ErrorAction Stop
    [long]$shrinkAvailable = [long]$partition.Size - [long]$supportedSize.SizeMin
    [long]$requiredShrink = ([long]$MinimumLinuxSizeGB + 2L) * 1GB
    if ($shrinkAvailable -lt $requiredShrink) {
        Stop-Compatibility "COMPAT_E_SHRINK_SPACE" "Windows ne peut libérer que $([math]::Round($shrinkAvailable / 1GB, 1)) Gio; au moins $([math]::Round($requiredShrink / 1GB, 1)) Gio sont requis."
    }
    $bitLocker = Get-BitLockerState -DriveLetter $systemDrive
    if (-not $bitLocker.Safe) {
        Write-Result "WARNING" "BitLocker est actif; Libertix le déchiffrera uniquement après votre confirmation finale."
    }
    $fixedDisks = @(Get-Disk | Where-Object { $_.BusType -notin @("USB", "File Backed Virtual") })
    if ($fixedDisks.Count -gt 1) {
        Write-Result "WARNING" "$($fixedDisks.Count) disques internes sont visibles; le live exigera une correspondance exacte avec le disque Windows."
    }

    Write-Result "PREFLIGHT_OK" "true"
    Write-Result "FIRMWARE" $firmware
    Write-Result "ARCHITECTURE" "AMD64"
    Write-Result "MEMORY_BYTES" $memoryBytes
    Write-Result "LOW_MEMORY_MODE" $lowMemory.ToString().ToLowerInvariant()
    Write-Result "SYSTEM_DISK_NUMBER" $disk.Number
    Write-Result "SYSTEM_DISK_UNIQUE_ID" $disk.UniqueId
    Write-Result "SYSTEM_DISK_SIZE" $disk.Size
    Write-Result "PARTITION_STYLE" $disk.PartitionStyle
    Write-Result "STORAGE_BUS_TYPE" $busType
    Write-Result "LOGICAL_SECTOR_SIZE" $disk.LogicalSectorSize
    Write-Result "PHYSICAL_SECTOR_SIZE" $disk.PhysicalSectorSize
    Write-Result "SHRINK_AVAILABLE_BYTES" $shrinkAvailable
    Write-Result "BITLOCKER_SAFE" $bitLocker.Safe.ToString().ToLowerInvariant()
    Write-Result "BITLOCKER_STATE" $bitLocker.State
    Write-Result "SECURE_BOOT_ENABLED" $secureBootEnabled.ToString().ToLowerInvariant()
    Write-Result "NVRAM_PROBE_PASSED" $nvramPassed.ToString().ToLowerInvariant()
    exit 0
} catch {
    $code = "COMPAT_E_UNEXPECTED"
    $message = $_.Exception.Message
    if ($message -match "^\[(COMPAT_[A-Z0-9_]+)\]\s*(.*)$") {
        $code = $Matches[1]
        $message = $Matches[2]
    }
    Write-Result "PREFLIGHT_OK" "false"
    Write-Result "ERROR_CODE" $code
    Write-Result "ERROR_MESSAGE" $message
    Write-Result "ERROR_TYPE" $_.Exception.GetType().FullName
    Write-Result "ERROR_POSITION" $_.InvocationInfo.PositionMessage
    Write-Result "ERROR_STACK" $_.ScriptStackTrace
    exit 1
}
