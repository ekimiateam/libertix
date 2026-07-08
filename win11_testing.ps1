#requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$Force = $false,
    [switch]$Revert = $false,
    [switch]$SkipInstaller = $false,
    [int]$InstallerPartitionSizeGB = 20,
    [string]$FilepoolBaseUrl = "http://192.168.1.170:8000/filepool",
    [switch]$InsecureTls = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Networking defaults
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($InsecureTls) {
    try {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) {
        return true;
    }
}
"@
    } catch {}

    [System.Net.ServicePointManager]::CertificatePolicy =
        New-Object TrustAllCertsPolicy

    if (
        -not (
            [System.Management.Automation.PSTypeName]`
                "ServerCertificateValidationCallback"
        ).Type
    ) {
        $certCallback = @"
using System;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public class ServerCertificateValidationCallback {
    public static void Ignore() {
        ServicePointManager.ServerCertificateValidationCallback +=
            delegate(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors sslPolicyErrors) { return true; };
    }
}
"@
        try { Add-Type $certCallback } catch {}
    }

    try { [ServerCertificateValidationCallback]::Ignore() } catch {}
}

# Downloads
$InstallerIsoUrl = "$($FilepoolBaseUrl.TrimEnd('/'))/libertix-installer-uefi.iso"
$InstallerIsoName = "libertix-installer-uefi.iso"
$InstallerIsoSha256 = "56920ded95e8bdda0210542e23a133f2040c2c6ac4b2112eb8c17c1abef4e9ad"
$MintIsoUrl = "$($FilepoolBaseUrl.TrimEnd('/'))/mint.iso"
$MintIsoPath = "$env:SystemDrive\mint.iso"
$Aria2ZipName = "aria2-1.37.0-win-64bit-build1.zip"
$Aria2ZipUrl = "$($FilepoolBaseUrl.TrimEnd('/'))/$Aria2ZipName"
$Aria2CacheDir = "$env:SystemDrive\LibertixTools\aria2"
$Aria2DownloadDir = "$env:SystemDrive\LibertixTools\downloads"

# Defaults
$EspLetter = "Y"
$InstallerLetter = "X"
$InstallerLabel = "LIBERTIXEFI"
$InstallerBootDescription = "Libertix UEFI Installer"

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("Gray", "Cyan", "Green", "Yellow", "Red", "White")]
        [string]$Color = "Gray"
    )

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Invoke-BcdeditCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & bcdedit @Arguments 2>&1
    $text = $output | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "bcdedit failed ($($Arguments -join ' ')): $text"
    }

    return $text
}

function Initialize-FirmwareApi {
    if (([System.Management.Automation.PSTypeName]"LibertixFirmwareApi").Type) {
        return
    }

    Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class LibertixFirmwareApi {
    private const UInt32 TOKEN_ADJUST_PRIVILEGES = 0x0020;
    private const UInt32 TOKEN_QUERY = 0x0008;
    private const UInt32 SE_PRIVILEGE_ENABLED = 0x00000002;

    [StructLayout(LayoutKind.Sequential)]
    private struct LUID {
        public UInt32 LowPart;
        public Int32 HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_PRIVILEGES {
        public UInt32 PrivilegeCount;
        public LUID Luid;
        public UInt32 Attributes;
    }

    [DllImport("advapi32.dll", SetLastError=true)]
    private static extern bool OpenProcessToken(
        IntPtr ProcessHandle,
        UInt32 DesiredAccess,
        out IntPtr TokenHandle
    );

    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    private static extern bool LookupPrivilegeValue(
        string lpSystemName,
        string lpName,
        out LUID lpLuid
    );

    [DllImport("advapi32.dll", SetLastError=true)]
    private static extern bool AdjustTokenPrivileges(
        IntPtr TokenHandle,
        bool DisableAllPrivileges,
        ref TOKEN_PRIVILEGES NewState,
        UInt32 BufferLength,
        IntPtr PreviousState,
        IntPtr ReturnLength
    );

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern UInt32 GetFirmwareEnvironmentVariable(
        string lpName,
        string lpGuid,
        byte[] pBuffer,
        UInt32 nSize
    );

    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool SetFirmwareEnvironmentVariableEx(
        string lpName,
        string lpGuid,
        byte[] pValue,
        UInt32 nSize,
        UInt32 dwAttributes
    );

    public static bool DeleteFirmwareEnvironmentVariable(
        string lpName,
        string lpGuid,
        UInt32 dwAttributes
    ) {
        return SetFirmwareEnvironmentVariableEx(lpName, lpGuid, null, 0, dwAttributes);
    }

    public static void EnableSystemEnvironmentPrivilege() {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token)) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }

        try {
            LUID luid;
            if (!LookupPrivilegeValue(null, "SeSystemEnvironmentPrivilege", out luid)) {
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }

            TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
            tp.PrivilegeCount = 1;
            tp.Luid = luid;
            tp.Attributes = SE_PRIVILEGE_ENABLED;

            if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) {
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }

            int error = Marshal.GetLastWin32Error();
            if (error != 0) {
                throw new System.ComponentModel.Win32Exception(error);
            }
        } finally {
            CloseHandle(token);
        }
    }

    public static int LastError() {
        return Marshal.GetLastWin32Error();
    }
}
"@
}

function Add-Bytes {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[byte]]$Buffer,
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    foreach ($byte in $Bytes) {
        $Buffer.Add($byte)
    }
}

function New-EfiFilePathNode {
    param([Parameter(Mandatory = $true)][string]$Path)

    $pathBytes = [Text.Encoding]::Unicode.GetBytes($Path + [char]0)
    $length = [uint16](4 + $pathBytes.Length)
    $buffer = [System.Collections.Generic.List[byte]]::new()
    Add-Bytes $buffer ([byte[]](0x04, 0x04))
    Add-Bytes $buffer ([BitConverter]::GetBytes($length))
    Add-Bytes $buffer $pathBytes
    return [byte[]]$buffer.ToArray()
}

function New-EfiHardDriveNode {
    param([Parameter(Mandatory = $true)]$Partition)

    $disk = Get-Disk -Number $Partition.DiskNumber -ErrorAction Stop
    $sectorSize = [uint64]$disk.LogicalSectorSize
    if ($sectorSize -eq 0) {
        $sectorSize = 512
    }

    $startLba = [uint64]($Partition.Offset / $sectorSize)
    $sizeLba = [uint64]($Partition.Size / $sectorSize)
    $partitionGuid = [Guid]$Partition.Guid

    $buffer = [System.Collections.Generic.List[byte]]::new()
    Add-Bytes $buffer ([byte[]](0x04, 0x01, 0x2A, 0x00))
    Add-Bytes $buffer ([BitConverter]::GetBytes([uint32]$Partition.PartitionNumber))
    Add-Bytes $buffer ([BitConverter]::GetBytes($startLba))
    Add-Bytes $buffer ([BitConverter]::GetBytes($sizeLba))
    Add-Bytes $buffer ($partitionGuid.ToByteArray())
    Add-Bytes $buffer ([byte[]](0x02, 0x02))
    return [byte[]]$buffer.ToArray()
}

function New-EfiEndNode {
    return [byte[]](0x7F, 0xFF, 0x04, 0x00)
}

function New-EfiLoadOption {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)]$Partition,
        [Parameter(Mandatory = $true)][string]$LoaderPath
    )

    $devicePath = [System.Collections.Generic.List[byte]]::new()
    Add-Bytes $devicePath (New-EfiHardDriveNode -Partition $Partition)
    Add-Bytes $devicePath (New-EfiFilePathNode -Path $LoaderPath)
    Add-Bytes $devicePath (New-EfiEndNode)

    $descriptionBytes = [Text.Encoding]::Unicode.GetBytes($Description + [char]0)
    $filePathBytes = [byte[]]$devicePath.ToArray()

    $buffer = [System.Collections.Generic.List[byte]]::new()
    Add-Bytes $buffer ([BitConverter]::GetBytes([uint32]1))
    Add-Bytes $buffer ([BitConverter]::GetBytes([uint16]$filePathBytes.Length))
    Add-Bytes $buffer $descriptionBytes
    Add-Bytes $buffer $filePathBytes

    return [byte[]]$buffer.ToArray()
}

function Test-FirmwareVariableExists {
    param([Parameter(Mandatory = $true)][string]$Name)

    Initialize-FirmwareApi
    [LibertixFirmwareApi]::EnableSystemEnvironmentPrivilege()
    $global = "{8BE4DF61-93CA-11D2-AA0D-00E098032B8C}"
    $buffer = New-Object byte[] 65536
    $size = [LibertixFirmwareApi]::GetFirmwareEnvironmentVariable($Name, $global, $buffer, [uint32]$buffer.Length)
    return $size -ne 0
}

function Get-FirmwareVariableBytes {
    param([Parameter(Mandatory = $true)][string]$Name)

    Initialize-FirmwareApi
    [LibertixFirmwareApi]::EnableSystemEnvironmentPrivilege()
    $global = "{8BE4DF61-93CA-11D2-AA0D-00E098032B8C}"
    $buffer = New-Object byte[] 65536
    $size = [LibertixFirmwareApi]::GetFirmwareEnvironmentVariable($Name, $global, $buffer, [uint32]$buffer.Length)
    if ($size -eq 0) {
        return $null
    }

    $result = New-Object byte[] $size
    [Array]::Copy($buffer, $result, $size)
    return $result
}

function Set-FirmwareVariable {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][byte[]]$Value
    )

    Initialize-FirmwareApi
    [LibertixFirmwareApi]::EnableSystemEnvironmentPrivilege()
    $global = "{8BE4DF61-93CA-11D2-AA0D-00E098032B8C}"
    $attributes = [uint32]0x00000007
    $ok = [LibertixFirmwareApi]::SetFirmwareEnvironmentVariableEx(
        $Name,
        $global,
        $Value,
        [uint32]$Value.Length,
        $attributes
    )

    if (-not $ok) {
        $err = [LibertixFirmwareApi]::LastError()
        throw "SetFirmwareEnvironmentVariableEx failed for ${Name}: Win32 error ${err}"
    }
}

function Remove-FirmwareVariable {
    param([Parameter(Mandatory = $true)][string]$Name)

    Initialize-FirmwareApi
    [LibertixFirmwareApi]::EnableSystemEnvironmentPrivilege()
    $global = "{8BE4DF61-93CA-11D2-AA0D-00E098032B8C}"
    $attributes = [uint32]0x00000007
    [LibertixFirmwareApi]::DeleteFirmwareEnvironmentVariable($Name, $global, $attributes) |
        Out-Null
}

function ConvertFrom-BootOrderBytes {
    param([byte[]]$Bytes)

    $order = New-Object System.Collections.Generic.List[uint16]
    if (-not $Bytes) {
        return $order
    }

    for ($offset = 0; $offset + 1 -lt $Bytes.Length; $offset += 2) {
        $order.Add([BitConverter]::ToUInt16($Bytes, $offset))
    }

    return $order
}

function ConvertTo-BootOrderBytes {
    param([Parameter(Mandatory = $true)]$Order)

    $buffer = [System.Collections.Generic.List[byte]]::new()
    foreach ($entry in $Order) {
        Add-Bytes $buffer ([BitConverter]::GetBytes([uint16]$entry))
    }

    return [byte[]]$buffer.ToArray()
}

function Get-EfiLoadOptionDescription {
    param([byte[]]$Bytes)

    if (-not $Bytes -or $Bytes.Length -lt 8) {
        return ""
    }

    $offset = 6
    $end = $offset
    while ($end + 1 -lt $Bytes.Length) {
        if ($Bytes[$end] -eq 0 -and $Bytes[$end + 1] -eq 0) {
            break
        }
        $end += 2
    }

    if ($end -le $offset) {
        return ""
    }

    return [Text.Encoding]::Unicode.GetString($Bytes, $offset, $end - $offset)
}

function Get-EfiLoadOptionOptionalDataLength {
    param([byte[]]$Bytes)

    if (-not $Bytes -or $Bytes.Length -lt 8) {
        return -1
    }

    $filePathListLength = [BitConverter]::ToUInt16($Bytes, 4)
    $offset = 6
    while ($offset + 1 -lt $Bytes.Length) {
        if ($Bytes[$offset] -eq 0 -and $Bytes[$offset + 1] -eq 0) {
            $offset += 2
            break
        }
        $offset += 2
    }

    $optionalStart = $offset + $filePathListLength
    if ($optionalStart -gt $Bytes.Length) {
        return -1
    }

    return ($Bytes.Length - $optionalStart)
}

function Remove-EfiLoadOptionOptionalData {
    param([byte[]]$Bytes)

    if (-not $Bytes -or $Bytes.Length -lt 8) {
        throw "Invalid EFI load option; too short."
    }

    $filePathListLength = [BitConverter]::ToUInt16($Bytes, 4)
    $offset = 6
    while ($offset + 1 -lt $Bytes.Length) {
        if ($Bytes[$offset] -eq 0 -and $Bytes[$offset + 1] -eq 0) {
            $offset += 2
            break
        }
        $offset += 2
    }

    $optionalStart = $offset + $filePathListLength
    if ($optionalStart -gt $Bytes.Length) {
        throw "Invalid EFI load option; file path list exceeds variable length."
    }

    $clean = New-Object byte[] $optionalStart
    [Array]::Copy($Bytes, $clean, $optionalStart)
    return $clean
}

function Get-FirmwareBootNumberByDescription {
    param([Parameter(Mandatory = $true)][string]$Description)

    for ($candidate = 0x0000; $candidate -le 0xFFFF; $candidate++) {
        $name = "Boot{0:X4}" -f $candidate
        $bytes = Get-FirmwareVariableBytes -Name $name
        if (-not $bytes) {
            continue
        }

        if ((Get-EfiLoadOptionDescription -Bytes $bytes) -eq $Description) {
            return [uint16]$candidate
        }
    }

    return $null
}

function Set-FirmwareBootNumberFirst {
    param([Parameter(Mandatory = $true)][uint16]$BootNumber)

    $currentOrder = ConvertFrom-BootOrderBytes -Bytes (Get-FirmwareVariableBytes -Name "BootOrder")
    $newOrder = New-Object System.Collections.Generic.List[uint16]
    $newOrder.Add([uint16]$BootNumber)
    foreach ($entry in $currentOrder) {
        if ([uint16]$entry -ne [uint16]$BootNumber) {
            $newOrder.Add([uint16]$entry)
        }
    }

    Set-FirmwareVariable -Name "BootOrder" -Value (ConvertTo-BootOrderBytes -Order $newOrder)
}

function Remove-FirmwareBootNumberFromOrder {
    param([Parameter(Mandatory = $true)][uint16]$BootNumber)

    $currentOrder = ConvertFrom-BootOrderBytes -Bytes (Get-FirmwareVariableBytes -Name "BootOrder")
    $newOrder = New-Object System.Collections.Generic.List[uint16]
    $changed = $false
    foreach ($entry in $currentOrder) {
        if ([uint16]$entry -eq [uint16]$BootNumber) {
            $changed = $true
            continue
        }
        $newOrder.Add([uint16]$entry)
    }

    if ($changed) {
        Set-FirmwareVariable -Name "BootOrder" -Value (ConvertTo-BootOrderBytes -Order $newOrder)
    }
}

function Remove-BcdFirmwareEntriesByDescription {
    param([Parameter(Mandatory = $true)][string[]]$Descriptions)

    $firmwareEntries = bcdedit /enum firmware /v 2>$null
    $current = $null
    foreach ($line in $firmwareEntries) {
        if ($line -match "^(identificateur|identifier)\s+(\{[^}]+\})") {
            $current = $Matches[2]
            continue
        }

        foreach ($description in $Descriptions) {
            if ($line -match "^description\s+$([regex]::Escape($description))$" -and $current) {
                bcdedit /delete $current /f 2>$null | Out-Null
                $current = $null
                break
            }
        }
    }
}

function Remove-NativeFirmwareEntriesByDescription {
    param([Parameter(Mandatory = $true)][string[]]$Descriptions)

    for ($candidate = 0x0000; $candidate -le 0xFFFF; $candidate++) {
        $name = "Boot{0:X4}" -f $candidate
        $bytes = Get-FirmwareVariableBytes -Name $name
        if (-not $bytes) {
            continue
        }

        $description = Get-EfiLoadOptionDescription -Bytes $bytes
        if ($Descriptions -contains $description) {
            Remove-FirmwareBootNumberFromOrder -BootNumber ([uint16]$candidate)
            Remove-FirmwareVariable -Name $name
        }
    }
}

function Remove-LibertixTemporaryFirmwareEntries {
    Remove-BcdFirmwareEntriesByDescription -Descriptions @($InstallerBootDescription)
    Remove-NativeFirmwareEntriesByDescription -Descriptions @($InstallerBootDescription)

    try {
        Remove-FirmwareVariable -Name "BootNext"
    } catch {
        # Best effort: BootNext may not exist, and stale BootNext cleanup must
        # not block a fresh installer entry.
    }
}

function Get-FirmwareEntryIdentifierByDescription {
    param([Parameter(Mandatory = $true)][string]$Description)

    $firmwareEntries = bcdedit /enum firmware /v 2>$null
    $current = $null
    foreach ($line in $firmwareEntries) {
        if ($line -match "^(identificateur|identifier)\s+(\{[^}]+\})") {
            $current = $Matches[2]
        } elseif ($line -match "^description\s+$([regex]::Escape($Description))$" -and $current) {
            return $current
        }
    }

    return $null
}

function Remove-LibertixInstallerPartitionIfPresent {
    $installerDrive = Ensure-VolumeLetterByLabel -Label $InstallerLabel -Letter $InstallerLetter
    if (-not $installerDrive) {
        Write-Log "No $InstallerLabel partition found." "Gray"
        return
    }

    $letter = $installerDrive.TrimEnd(":")
    $volume = Get-Volume -DriveLetter $letter -ErrorAction Stop
    if ($volume.FileSystemLabel -ne $InstallerLabel) {
        throw "Refusing to remove ${installerDrive}: label is '$($volume.FileSystemLabel)', expected '$InstallerLabel'."
    }

    $partition = Get-Partition -DriveLetter $letter -ErrorAction Stop
    if ($partition.Size -lt 1GB -or $partition.Size -gt 128GB) {
        throw "Refusing to remove ${installerDrive}: suspicious size $($partition.Size) bytes."
    }

    Write-Log "Removing $InstallerLabel partition on disk $($partition.DiskNumber), partition $($partition.PartitionNumber)..." "Cyan"
    Dismount-Letter -Letter $letter
    Remove-Partition `
        -DiskNumber $partition.DiskNumber `
        -PartitionNumber $partition.PartitionNumber `
        -Confirm:$false `
        -ErrorAction Stop

    try {
        $supported = Get-PartitionSupportedSize -DriveLetter C -ErrorAction Stop
        $cPartition = Get-Partition -DriveLetter C -ErrorAction Stop
        if ($supported.SizeMax -gt ($cPartition.Size + 64MB)) {
            Write-Log "Extending C: to reclaim free space..." "Cyan"
            Resize-Partition -DriveLetter C -Size $supported.SizeMax -ErrorAction Stop
        }
    } catch {
        Write-Log "Could not extend C: automatically: $($_.Exception.Message)" "Yellow"
    }
}

function Set-NativeUefiBootOrderOnce {
    param(
        [Parameter(Mandatory = $true)][string]$InstallerDrive,
        [Parameter(Mandatory = $true)][int]$InstallerDiskNumber,
        [Parameter(Mandatory = $true)][int]$InstallerPartitionNumber,
        [Parameter(Mandatory = $true)][string]$LoaderPath
    )

    $driveLetter = $InstallerDrive.TrimEnd(":")
    $partition = Get-Partition -DriveLetter $driveLetter -ErrorAction SilentlyContinue
    if (-not $partition) {
        $partition = Get-Partition `
            -DiskNumber $InstallerDiskNumber `
            -PartitionNumber $InstallerPartitionNumber `
            -ErrorAction SilentlyContinue
    }

    if (-not $partition) {
        throw "Cannot find Libertix installer partition by drive ${InstallerDrive} or disk $InstallerDiskNumber partition $InstallerPartitionNumber."
    }

    $bootNumber = $null
    for ($candidate = 0x0000; $candidate -le 0xFFFF; $candidate++) {
        $name = "Boot{0:X4}" -f $candidate
        if (-not (Test-FirmwareVariableExists -Name $name)) {
            $bootNumber = [uint16]$candidate
            break
        }
    }

    if ($null -eq $bootNumber) {
        throw "No free UEFI Boot#### slot found."
    }

    $loadOption = New-EfiLoadOption `
        -Description $InstallerBootDescription `
        -Partition $partition `
        -LoaderPath $LoaderPath

    $bootVariable = "Boot{0:X4}" -f $bootNumber
    Set-FirmwareVariable -Name $bootVariable -Value $loadOption

    $currentOrder = ConvertFrom-BootOrderBytes -Bytes (Get-FirmwareVariableBytes -Name "BootOrder")
    $newOrder = New-Object System.Collections.Generic.List[uint16]
    $newOrder.Add([uint16]$bootNumber)
    foreach ($entry in $currentOrder) {
        if ([uint16]$entry -ne [uint16]$bootNumber) {
            $newOrder.Add([uint16]$entry)
        }
    }

    Set-FirmwareVariable -Name "BootOrder" -Value (ConvertTo-BootOrderBytes -Order $newOrder)
    Remove-FirmwareVariable -Name "BootNext"

    return $bootVariable
}

function Get-SecureBootDbText {
    $db = Get-SecureBootUEFI -Name db
    $bytes = $db.Bytes

    return @(
        [Text.Encoding]::ASCII.GetString($bytes),
        [Text.Encoding]::Unicode.GetString($bytes),
        [BitConverter]::ToString($bytes)
    ) -join "`n"
}

function Test-LibertixSecureBootCompatibility {
    Write-Log "Checking Secure Boot certificate compatibility..." "Cyan"

    try {
        $secureBootEnabled = Confirm-SecureBootUEFI
    } catch {
        throw "Cannot read Secure Boot state. Refusing to continue on an unknown UEFI state: $($_.Exception.Message)"
    }

    if (-not $secureBootEnabled) {
        Write-Log "Secure Boot is disabled; signed-chain check is not required." "Yellow"
        return
    }

    $dbText = Get-SecureBootDbText
    $has2011 = $dbText -match "Microsoft Corporation UEFI CA 2011"
    $has2023 = (
        $dbText -match "Microsoft UEFI CA 2023" -or
        $dbText -match "Microsoft Corporation UEFI CA 2023"
    )
    $hasWindows2023 = $dbText -match "Windows UEFI CA 2023"

    if ($has2011 -and $has2023) {
        Write-Log "Secure Boot DB contains Microsoft UEFI CA 2011 and 2023; dual-signed installer chain is compatible." "Green"
        return
    }

    if ($has2023) {
        Write-Log "Secure Boot DB contains Microsoft UEFI CA 2023; dual-signed installer chain is compatible." "Green"
        return
    }

    if ($has2011) {
        Write-Log "Secure Boot DB contains Microsoft UEFI CA 2011; dual-signed installer chain is compatible." "Green"
        return
    }

    if ($hasWindows2023) {
        throw "Secure Boot DB contains Windows UEFI CA 2023, but not Microsoft UEFI CA 2023 for third-party bootloaders. Disable Secure Boot or enroll the Microsoft third-party UEFI CA before installing Libertix."
    }

    throw "Secure Boot is enabled but neither Microsoft Corporation UEFI CA 2011 nor Microsoft UEFI CA 2023 was detected in db. This looks like a custom/professional Secure Boot trust store. Disable Secure Boot or enroll the Microsoft third-party UEFI CA before installing Libertix."
}

function Invoke-DiskpartScript {
    param([Parameter(Mandatory = $true)][string]$ScriptText)

    $tmp = [IO.Path]::GetTempFileName()
    try {
        $ScriptText | Out-File $tmp -Encoding ASCII
        $output = diskpart /s $tmp 2>&1
        $text = $output | Out-String
        if ($LASTEXITCODE -ne 0 -or $text -match "(?i)(error|erreur|failed|échec)") {
            throw "diskpart failed: $text"
        }
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Get-GuidDLower {
    param([Parameter(Mandatory = $true)][Guid]$Guid)
    $Guid.ToString("D").ToLower()
}

function Mount-Esp {
    param([Parameter(Mandatory = $true)][string]$Letter)

    if (Test-Path "${Letter}:\") {
        Invoke-DiskpartScript -ScriptText @"
select volume $Letter
remove letter=$Letter
exit
"@
        Start-Sleep -Seconds 1
    }

    $winPart = Get-Partition -DriveLetter C
    $espPart =
        Get-Partition -DiskNumber $winPart.DiskNumber |
        Where-Object {
            $_.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}"
        } |
        Select-Object -First 1

    if (-not $espPart) {
        throw "ESP not found on disk $($winPart.DiskNumber)."
    }

    Invoke-DiskpartScript -ScriptText @"
select disk $($espPart.DiskNumber)
select partition $($espPart.PartitionNumber)
assign letter=$Letter
exit
"@

    $tries = 0
    while (-not (Test-Path "${Letter}:\") -and $tries -lt 10) {
        Start-Sleep -Seconds 1
        $tries++
    }

    if (-not (Test-Path "${Letter}:\")) {
        throw "Failed to mount ESP as ${Letter}:"
    }

    return "${Letter}:"
}

function Dismount-Letter {
    param([Parameter(Mandatory = $true)][string]$Letter)

    if (Test-Path "${Letter}:\") {
        try {
            $part = Get-Partition -DriveLetter $Letter -ErrorAction Stop
            Remove-PartitionAccessPath `
                -DiskNumber $part.DiskNumber `
                -PartitionNumber $part.PartitionNumber `
                -AccessPath "${Letter}:\" `
                -ErrorAction Stop
            return
        } catch {
            Write-Log "Could not remove ${Letter}: with PowerShell; trying diskpart best-effort..." "Yellow"
        }

        try {
            Invoke-DiskpartScript -ScriptText @"
select volume $Letter
remove letter=$Letter
exit
"@
        } catch {
            Write-Log "Could not remove drive letter ${Letter}:; continuing." "Yellow"
        }
    }
}

function Get-FreeDriveLetter {
    $used = @{}
    Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter } |
        ForEach-Object { $used[[string]$_.DriveLetter] = $true }

    foreach ($candidate in "X", "W", "V", "U", "T", "S", "R", "Q", "P", "O", "N", "M", "L", "K", "J", "I", "H", "G", "F", "E", "D") {
        if (-not $used.ContainsKey($candidate) -and -not (Test-Path "${candidate}:\")) {
            return $candidate
        }
    }

    throw "No free drive letter available for Libertix installer partition."
}

function Get-LibertixInstallerPartition {
    param([string]$DriveLetter = "")

    if ($DriveLetter) {
        $partition = Get-Partition -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
        if ($partition) {
            return $partition
        }
    }

    $volume = Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.FileSystemLabel -eq $InstallerLabel -and $_.DriveLetter } |
        Select-Object -First 1

    if ($volume) {
        $partition = Get-Partition -DriveLetter $volume.DriveLetter -ErrorAction SilentlyContinue
        if ($partition) {
            return $partition
        }
    }

    return Get-Partition |
        Where-Object {
            $_.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" -and
            $_.Size -gt 1GB
        } |
        Sort-Object DiskNumber,PartitionNumber -Descending |
        Select-Object -First 1
}

function Ensure-VolumeLetterByLabel {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Letter
    )

    $vol = Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.FileSystemLabel -eq $Label } |
        Select-Object -First 1

    if ($vol -and $vol.DriveLetter) {
        return "$($vol.DriveLetter):"
    }

    $cim = Get-CimInstance Win32_Volume -Filter "Label='$Label'" `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $cim) {
        return $null
    }

    if ($cim.DriveLetter) {
        return "$($cim.DriveLetter.TrimEnd(':')):"
    }

    $deviceId = $cim.DeviceID
    if (-not $deviceId.EndsWith("\")) {
        $deviceId = "$deviceId\"
    }

    # Assign letter using mountvol (works even if previously hidden)
    $letterToUse = $Letter
    if (Test-Path "${letterToUse}:\") {
        $letterToUse = Get-FreeDriveLetter
    }

    & mountvol "${letterToUse}:" $deviceId | Out-Null

    if (-not (Test-Path "${letterToUse}:\")) {
        throw "Failed to assign a drive letter to volume labeled '$Label'."
    }

    return "${letterToUse}:"
}

function Get-PartitionGuidForLetter {
    param([Parameter(Mandatory = $true)][string]$Letter)

    $p = Get-Partition -DriveLetter $Letter -ErrorAction SilentlyContinue
    if ($p -and $p.Guid) {
        return (Get-GuidDLower -Guid $p.Guid)
    }
    return $null
}

function Start-BitsDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $job = Start-BitsTransfer -Source $Url -Destination $Destination `
        -Asynchronous -DisplayName "Download: $([IO.Path]::GetFileName($Destination))" `
        -ErrorAction Stop

    $jobId = $job.JobId

    while ($true) {
        $j = Get-BitsTransfer -Id $jobId -ErrorAction SilentlyContinue
        if (-not $j) { break }

        if ($j.JobState -in @("Connecting", "Transferring")) {
            $pct = 0
            if ($j.BytesTotal -gt 0) {
                $pct = [math]::Round(($j.BytesTransferred / $j.BytesTotal) * 100, 1)
            }
            Write-Progress -Activity "Downloading ISO" -PercentComplete $pct `
                -Status "$pct% ($([math]::Round($j.BytesTransferred / 1MB, 1)) MB)"
            Start-Sleep -Seconds 2
            continue
        }

        if ($j.JobState -eq "Suspended") {
            Resume-BitsTransfer -BitsJob $j | Out-Null
            Start-Sleep -Seconds 1
            continue
        }

        if ($j.JobState -eq "Transferred") {
            Complete-BitsTransfer -BitsJob $j
            break
        }

        if ($j.JobState -eq "Error") {
            try { Remove-BitsTransfer -BitsJob $j } catch {}
            throw "BITS transfer failed."
        }

        if ($j.JobState -in @("Cancelled", "Acknowledged")) {
            throw "BITS ended unexpectedly (state=$($j.JobState))."
        }

        Start-Sleep -Seconds 1
    }

    Write-Progress -Activity "Downloading ISO" -Completed
}

function Get-Aria2Exe {
    $existing =
        if (Test-Path -LiteralPath $Aria2CacheDir) {
            Get-ChildItem -LiteralPath $Aria2CacheDir -Filter "aria2c.exe" `
                -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1
        } else {
            $null
        }
    if ($existing) {
        return $existing.FullName
    }

    [IO.Directory]::CreateDirectory($Aria2CacheDir) | Out-Null
    $zipPath = Join-Path $Aria2CacheDir "aria2.zip"

    Write-Log "Downloading aria2 download helper..." "Cyan"
    $ProgressPreference = "SilentlyContinue"
    try {
        Invoke-WebRequest -Uri $Aria2ZipUrl -OutFile $zipPath -UseBasicParsing
    } finally {
        $ProgressPreference = "Continue"
    }

    if (-not (Test-Path -LiteralPath $zipPath)) {
        throw "aria2 download helper was not downloaded."
    }

    Expand-Archive -LiteralPath $zipPath -DestinationPath $Aria2CacheDir -Force
    $aria2 = Get-ChildItem -LiteralPath $Aria2CacheDir -Filter "aria2c.exe" `
        -Recurse -ErrorAction Stop |
        Select-Object -First 1

    if (-not $aria2) {
        throw "aria2c.exe was not found after extraction."
    }

    return $aria2.FullName
}

function Start-Aria2Download {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $aria2 = Get-Aria2Exe
    $destinationFullPath = [IO.Path]::GetFullPath($Destination)
    $destinationDir = [IO.Path]::GetDirectoryName($destinationFullPath)
    $destinationName = [IO.Path]::GetFileName($destinationFullPath)

    if ([string]::IsNullOrWhiteSpace($destinationDir)) {
        throw "Cannot resolve download destination directory for: $Destination"
    }

    $downloadDir = $destinationDir
    $downloadPath = $destinationFullPath
    if ($destinationDir -match '^[A-Za-z]:\\?$') {
        # aria2 rejects drive-root output directories on some Windows setups.
        # Download to a normal directory first, then move atomically to C:\mint.iso.
        $downloadDir = $Aria2DownloadDir
        $downloadPath = Join-Path $downloadDir $destinationName
    }
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
    if (Test-Path -LiteralPath $downloadPath) {
        Remove-Item -LiteralPath $downloadPath -Force
    }

    Write-Log "Downloading with aria2: $destinationName" "Cyan"
    $args = @(
        "--allow-overwrite=true",
        "--auto-file-renaming=false",
        "--continue=true",
        "--max-connection-per-server=10",
        "--split=10",
        "--min-split-size=1M",
        "--summary-interval=5",
        "--console-log-level=warn",
        "--out=$destinationName",
        $Url
    )

    Push-Location -LiteralPath $downloadDir
    try {
        & $aria2 @args
        if ($LASTEXITCODE -ne 0) {
            throw "aria2 failed with exit code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }

    if (-not (Test-Path -LiteralPath $downloadPath)) {
        throw "aria2 completed but downloaded file is missing: $downloadPath"
    }

    if ($downloadPath -ne $destinationFullPath) {
        if (Test-Path -LiteralPath $destinationFullPath) {
            Remove-Item -LiteralPath $destinationFullPath -Force
        }
        Move-Item -LiteralPath $downloadPath -Destination $destinationFullPath -Force
    }
}

function Get-MountedIsoDrive {
    param([Parameter(Mandatory = $true)][string]$ImagePath)

    $resolvedImagePath = [IO.Path]::GetFullPath($ImagePath)
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        $letters = @()
        $image = Get-DiskImage -ImagePath $resolvedImagePath -ErrorAction SilentlyContinue
        if ($image) {
            try {
                $letters += @(
                    $image |
                        Get-Volume -ErrorAction SilentlyContinue |
                        Where-Object {
                            $_.PSObject.Properties.Name -contains "DriveLetter" -and
                            $_.DriveLetter
                        } |
                        Select-Object -ExpandProperty DriveLetter
                )
            } catch {}

            try {
                $letters += @(
                    $image |
                        Get-Disk -ErrorAction SilentlyContinue |
                        Get-Partition -ErrorAction SilentlyContinue |
                        Where-Object { $_.DriveLetter } |
                        Select-Object -ExpandProperty DriveLetter
                )
            } catch {}
        }

        $letter = $letters |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Select-Object -First 1
        if ($letter) {
            return "$letter`:"
        }

        Start-Sleep -Milliseconds 500
    }

    $diagnostic = Get-DiskImage -ImagePath $resolvedImagePath -ErrorAction SilentlyContinue |
        Format-List * |
        Out-String
    throw "ISO mounted, but no usable drive letter was found for $resolvedImagePath. DiskImage=$diagnostic"
}

function Start-RobustDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Label
    )

    try {
        Start-Aria2Download -Url $Url -Destination $Destination
        return
    } catch {
        Write-Log "aria2 failed for $Label; using BITS fallback: $($_.Exception.Message)" "Yellow"
    }

    try {
        Start-BitsDownload -Url $Url -Destination $Destination
        return
    } catch {
        Write-Log "BITS failed for $Label; using Invoke-WebRequest fallback: $($_.Exception.Message)" "Yellow"
    }

    $ProgressPreference = "SilentlyContinue"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    } finally {
        $ProgressPreference = "Continue"
    }
}

function Ensure-MintIsoOnWindows {
    $existing = Get-Item -LiteralPath $MintIsoPath -ErrorAction SilentlyContinue
    if ($existing -and $existing.Length -gt 100MB) {
        Write-Log "Mint ISO already present: $MintIsoPath" "Green"
        return
    }

    Write-Log "Downloading Mint ISO to $MintIsoPath..." "Cyan"
    Start-RobustDownload -Url $MintIsoUrl -Destination $MintIsoPath -Label "Mint ISO"

    $downloadedIso = Get-Item -LiteralPath $MintIsoPath -ErrorAction Stop
    if ($downloadedIso.Length -le 100MB) {
        throw "Mint ISO download is too small: $($downloadedIso.Length) bytes"
    }
    Write-Log "Mint ISO ready: $MintIsoPath" "Green"
}

function Ensure-VolumeNotEncrypted {
    param([Parameter(Mandatory = $true)][string]$DriveLetter)

    $out = manage-bde -status "${DriveLetter}:" 2>&1 | Out-String

    $needsDecryption = $false
    if ($out -match "Percentage Encrypted:\s*(\d+\.?\d*)%?") {
        if ([double]$matches[1] -gt 0) { $needsDecryption = $true }
    }

    if (
        $out -match "Conversion Status:\s*(Encryption in Progress|Used Space Only Encrypted|Fully Encrypted)" -or
        $out -match "Protection Status:\s*(Protection On)"
    ) {
        $needsDecryption = $true
    }

    if (-not $needsDecryption) {
        return
    }

    Write-Log "BitLocker detected on ${DriveLetter}:, disabling..." "Yellow"
    manage-bde -off "${DriveLetter}:" 2>&1 | Out-Null

    $timeoutSec = 600
    $elapsed = 0
    $interval = 3

    while ($elapsed -lt $timeoutSec) {
        Start-Sleep -Seconds $interval
        $elapsed += $interval

        $out = manage-bde -status "${DriveLetter}:" 2>&1 | Out-String
        if ($out -match "Percentage Encrypted:\s*(\d+\.?\d*)%?") {
            $enc = [double]$matches[1]
            $pct = [math]::Round(100 - $enc, 1)
            Write-Progress -Activity "Decrypting ${DriveLetter}:" `
                -PercentComplete $pct -Status "$pct% ($elapsed sec)"
            if ($enc -eq 0) { break }
        }

        if ($out -match "Conversion Status:\s*Fully Decrypted") { break }
        if ($out -match "État de la conversion:\s*Intégralement déchiffré") { break }
    }

    Write-Progress -Activity "Decrypting ${DriveLetter}:" -Completed
}

function Ensure-WindowsVolumeReadableFromLinux {
    $bitlockerVolume = $null
    try {
        $bitlockerVolume = Get-BitLockerVolume -MountPoint "C:" -ErrorAction Stop
    } catch {
        $bitlockerVolume = $null
    }

    if ($bitlockerVolume) {
        if ($bitlockerVolume.VolumeStatus -eq "FullyDecrypted") {
            Write-Log "Windows C: is already readable from Linux." "Green"
            return
        }

        Write-Log "Disabling BitLocker/device encryption on C: before Linux live boot..." "Cyan"
        Disable-BitLocker -MountPoint "C:" -ErrorAction Stop

        $deadline = (Get-Date).AddMinutes(90)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 10
            $bitlockerVolume = Get-BitLockerVolume -MountPoint "C:" -ErrorAction Stop
            if ($bitlockerVolume.VolumeStatus -eq "FullyDecrypted") {
                Write-Log "Windows C: decrypted." "Green"
                return
            }

            if ($null -ne $bitlockerVolume.EncryptionPercentage) {
                Write-Log "Waiting for C: decryption... $($bitlockerVolume.EncryptionPercentage)% encrypted" "Yellow"
            } else {
                Write-Log "Waiting for C: decryption... status=$($bitlockerVolume.VolumeStatus)" "Yellow"
            }

        }
        throw "Timed out waiting for C: BitLocker decryption."
    }

    $statusText = ""
    try {
        $statusText = manage-bde -status C: 2>&1 | Out-String
    } catch {
        Write-Log "BitLocker status unavailable; continuing." "Yellow"
        return
    }

    if ($statusText -match "(?i)(bitlocker|chiffrement|encrypted|chiffr)") {
        Write-Log "Disabling BitLocker/device encryption on C: before Linux live boot..." "Cyan"
        manage-bde -off C: 2>&1 | Out-Null
        Start-Sleep -Seconds 5
    }
}


function Invoke-Revert {
    Write-Log "Reverting Libertix UEFI installer changes..." "Cyan"

    $esp = $null
    try {
        $esp = Mount-Esp -Letter $EspLetter

        foreach ($relativeDir in @("EFI\refind", "EFI\Libertix", "EFI\LibertixInstaller")) {
            $path = Join-Path $esp $relativeDir
            if (Test-Path $path) {
                Write-Log "Removing ESP directory: $relativeDir" "Cyan"
                Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
            }
        }

        bcdedit /set "{bootmgr}" path \EFI\Microsoft\Boot\bootmgfw.efi 2>$null |
            Out-Null
        bcdedit /set "{bootmgr}" description "Windows Boot Manager" 2>$null |
            Out-Null

        Remove-BcdFirmwareEntriesByDescription -Descriptions @(
            $InstallerBootDescription,
            "Libertix"
        )
        Remove-NativeFirmwareEntriesByDescription -Descriptions @(
            $InstallerBootDescription,
            "Libertix"
        )
        try {
            Remove-FirmwareVariable -Name "BootNext"
        } catch {}

        bcdedit /set "{fwbootmgr}" default "{bootmgr}" 2>$null | Out-Null

    } finally {
        if ($esp) { Dismount-Letter -Letter $EspLetter }
    }

    Remove-LibertixInstallerPartitionIfPresent

    Write-Log "Revert complete." "Green"
}

function New-OrReuseInstallerPartition {
    param([Parameter(Mandatory = $true)][int]$SizeGB)

    # If it already exists (maybe hidden), bring it back as X:
    $existing = Ensure-VolumeLetterByLabel -Label $InstallerLabel -Letter $InstallerLetter
    if ($existing) {
        $existingLetter = $existing.TrimEnd(":")
        $existingPartition = Get-LibertixInstallerPartition -DriveLetter $existingLetter
        if (-not $existingPartition) {
            throw "Existing Libertix installer volume was found, but its partition could not be resolved."
        }
        $guid = $null
        if ($existingPartition.Guid) {
            $guid = Get-GuidDLower -Guid $existingPartition.Guid
        }
        return @{
            Drive = $existing
            GuidD = $guid
            DiskNumber = $existingPartition.DiskNumber
            PartitionNumber = $existingPartition.PartitionNumber
        }
    }

    $sizeMB = $SizeGB * 1024
    $cPart = Get-Partition -DriveLetter C
    $cVol = Get-Volume -DriveLetter C

    $minFree = 10GB
    $need = ($sizeMB * 1MB) + $minFree

    if ($cVol.SizeRemaining -lt $need) {
        throw "Not enough free space on C: (need ~$( [math]::Round($need / 1GB, 1) ) GB)."
    }

    $supported = $cPart | Get-PartitionSupportedSize
    $shrinkBytes = $sizeMB * 1MB
    $maxShrink = $supported.SizeMax - $supported.SizeMin

    if ($shrinkBytes -gt $maxShrink) {
        throw "Cannot shrink C: by ${SizeGB}GB (max ~$( [math]::Round($maxShrink / 1GB, 1) ) GB)."
    }

    Write-Log "Creating ${SizeGB}GB EFI FAT32 partition '$InstallerLabel'..." "Cyan"

    Resize-Partition -DriveLetter C -Size ($cPart.Size - $shrinkBytes)
    Start-Sleep -Seconds 2

    Invoke-DiskpartScript -ScriptText @"
select disk $($cPart.DiskNumber)
create partition efi size=$sizeMB
format fs=fat32 quick label=$InstallerLabel
assign letter=$InstallerLetter
exit
"@

    $tries = 0
    while (-not (Test-Path "${InstallerLetter}:\") -and $tries -lt 15) {
        Start-Sleep -Seconds 1
        $tries++
    }

    if (-not (Test-Path "${InstallerLetter}:\")) {
        throw "Failed to create/assign ${InstallerLetter}: for Libertix installer partition."
    }

    $newPartition = Get-LibertixInstallerPartition -DriveLetter $InstallerLetter
    if (-not $newPartition) {
        throw "Libertix installer partition was created, but its partition object could not be resolved."
    }
    $guid = $null
    if ($newPartition.Guid) {
        $guid = Get-GuidDLower -Guid $newPartition.Guid
    }

    Ensure-VolumeNotEncrypted -DriveLetter $InstallerLetter

    return @{
        Drive = "${InstallerLetter}:"
        GuidD = $guid
        DiskNumber = $newPartition.DiskNumber
        PartitionNumber = $newPartition.PartitionNumber
    }
}

function Install-LibertixIsoToPartition {
    param(
        [Parameter(Mandatory = $true)][string]$PartitionDrive
    )

    $tmpDir = Join-Path $env:TEMP "libertix-uefi-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    $isoPath = Join-Path $tmpDir $InstallerIsoName

    try {
        Write-Log "Downloading Libertix UEFI ISO..." "Cyan"
        $downloadUrl = "${InstallerIsoUrl}?cacheBust=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())-$([Guid]::NewGuid().ToString('N'))"

        Start-RobustDownload -Url $downloadUrl -Destination $isoPath -Label "Libertix UEFI ISO"

        if (-not (Test-Path $isoPath)) {
            throw "ISO download failed."
        }

        $actualIsoHash = (Get-FileHash -Algorithm SHA256 -Path $isoPath).Hash.ToLowerInvariant()
        Write-Log "Libertix UEFI ISO SHA256: $actualIsoHash" "Gray"
        if ($actualIsoHash -ne $InstallerIsoSha256) {
            throw "Downloaded Libertix UEFI ISO hash mismatch. Expected $InstallerIsoSha256, got $actualIsoHash"
        }

        Write-Log "Mounting ISO..." "Cyan"
        Mount-DiskImage -ImagePath $isoPath -PassThru | Out-Null
        $isoDrive = Get-MountedIsoDrive -ImagePath $isoPath

        $src = "$isoDrive\*"
        $dst = "$PartitionDrive\"

        Write-Log "Copying ISO contents to $PartitionDrive..." "Cyan"
        Copy-Item -Path $src -Destination $dst -Recurse -Force

        $requiredFiles = @(
            "EFI\debian\shimx64.efi",
            "EFI\debian\grubx64.efi",
            "EFI\debian\mmx64.efi",
            "EFI\debian\grub.cfg",
            "EFI\LibertixInstaller\shimx64.efi",
            "EFI\LibertixInstaller\grubx64.efi",
            "EFI\LibertixInstaller\mmx64.efi",
            "EFI\LibertixInstaller\grub.cfg",
            "live\vmlinuz",
            "live\initrd.img",
            "live\filesystem.squashfs"
        )
        foreach ($relativePath in $requiredFiles) {
            $fullPath = Join-Path $PartitionDrive $relativePath
            if (-not (Test-Path $fullPath)) {
                throw "Installer copy verification failed; missing $fullPath"
            }
            if ((Get-Item $fullPath).Length -le 0) {
                throw "Installer copy verification failed; empty file $fullPath"
            }
        }

        Dismount-DiskImage -ImagePath $isoPath | Out-Null
        Write-Log "Libertix UEFI installer copied." "Green"
    } finally {
        try {
            Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue |
                Out-Null
        } catch {}

        Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Set-LibertixUefiBootEntry {
    param(
        [Parameter(Mandatory = $true)][string]$InstallerDrive,
        [Parameter(Mandatory = $true)][int]$InstallerDiskNumber,
        [Parameter(Mandatory = $true)][int]$InstallerPartitionNumber
    )

    Write-Log "Configuring one-time UEFI boot entry..." "Cyan"

    if (-not (Test-Path "$InstallerDrive\")) {
        $InstallerDrive = Ensure-VolumeLetterByLabel -Label $InstallerLabel -Letter $InstallerLetter
        if (-not $InstallerDrive -or -not (Test-Path "$InstallerDrive\")) {
            throw "Cannot assign a drive letter to the Libertix installer partition before UEFI boot setup."
        }
    }

    $loaderPath = "\EFI\debian\shimx64.efi"
    $installerShim = Join-Path $InstallerDrive "EFI\debian\shimx64.efi"
    $installerGrub = Join-Path $InstallerDrive "EFI\debian\grubx64.efi"
    $installerMok = Join-Path $InstallerDrive "EFI\debian\mmx64.efi"
    foreach ($path in @($installerShim, $installerGrub, $installerMok)) {
        if (-not (Test-Path $path)) {
            throw "Installer EFI file not found: $path"
        }
    }

    powercfg /h off 2>&1 | Out-Null

    $driveRoot = "$InstallerDrive\"
    $grubConfig = @"
set default=0
set timeout=0
set timeout_style=hidden
set hidden_timeout=0
set hidden_timeout_quiet=true

menuentry "Install Linux Mint (Automatic)" {
    linux /live/vmlinuz boot=live toram components quiet silent loglevel=3 systemd.show_status=0 console=ttyS0,115200n8 console=tty1
    initrd /live/initrd.img
}
"@
    foreach ($grubConfigDir in @(
        (Join-Path $driveRoot "EFI\debian"),
        (Join-Path $driveRoot "EFI\LibertixInstaller"),
        (Join-Path $driveRoot "EFI\BOOT"),
        (Join-Path $driveRoot "boot\grub")
    )) {
        New-Item -ItemType Directory -Path $grubConfigDir -Force | Out-Null
        $grubConfigPath = Join-Path $grubConfigDir "grub.cfg"
        if (Test-Path $grubConfigPath) {
            attrib -R -S -H $grubConfigPath 2>$null
            Remove-Item -Path $grubConfigPath -Force
        }
        Set-Content -Path $grubConfigPath -Value $grubConfig -Encoding ASCII
    }

    Remove-LibertixTemporaryFirmwareEntries

    $copyText = Invoke-BcdeditCommand -Arguments @(
        "/copy",
        "{bootmgr}",
        "/d",
        $InstallerBootDescription
    )
    if ($copyText -notmatch "(\{[0-9a-fA-F-]+\})") {
        throw "Could not parse created firmware entry id from bcdedit output: $copyText"
    }
    $entryId = $Matches[1]

    Invoke-BcdeditCommand -Arguments @(
        "/set",
        $entryId,
        "device",
        "partition=$InstallerDrive"
    ) | Out-Null
    Invoke-BcdeditCommand -Arguments @(
        "/set",
        $entryId,
        "path",
        $loaderPath
    ) | Out-Null

    foreach ($value in @(
        "locale",
        "inherit",
        "default",
        "resumeobject",
        "toolsdisplayorder",
        "timeout"
    )) {
        bcdedit /deletevalue $entryId $value 2>$null | Out-Null
    }

    Invoke-BcdeditCommand -Arguments @(
        "/set",
        "{fwbootmgr}",
        "displayorder",
        $entryId,
        "/addfirst"
    ) | Out-Null

    $bootNumber = $null
    for ($i = 0; $i -lt 10; $i++) {
        $bootNumber = Get-FirmwareBootNumberByDescription -Description $InstallerBootDescription
        if ($null -ne $bootNumber) {
            break
        }
        Start-Sleep -Seconds 1
    }

    if ($null -eq $bootNumber) {
        throw "Windows created the BCD firmware entry, but no matching Boot#### variable was found."
    }

    $bootVariable = "Boot{0:X4}" -f $bootNumber
    $originalLoadOption = Get-FirmwareVariableBytes -Name $bootVariable
    if (-not $originalLoadOption) {
        throw "Cannot read $bootVariable after bcdedit created the firmware entry."
    }

    $optionalDataLengthBefore = Get-EfiLoadOptionOptionalDataLength -Bytes $originalLoadOption
    if ($optionalDataLengthBefore -lt 0) {
        throw "Cannot parse $bootVariable load option created by Windows."
    }

    if ($optionalDataLengthBefore -gt 0) {
        $cleanLoadOption = Remove-EfiLoadOptionOptionalData -Bytes $originalLoadOption
        Set-FirmwareVariable -Name $bootVariable -Value $cleanLoadOption
    }

    $writtenLoadOption = Get-FirmwareVariableBytes -Name $bootVariable
    $optionalDataLength = Get-EfiLoadOptionOptionalDataLength -Bytes $writtenLoadOption
    if ($optionalDataLength -ne 0) {
        throw "Clean UEFI load option verification failed for ${bootVariable}; optional data length is ${optionalDataLength}."
    }

    Set-FirmwareBootNumberFirst -BootNumber $bootNumber
    try {
        Remove-FirmwareVariable -Name "BootNext"
    } catch {
        # Best effort: BootNext may not exist.
    }

    Write-Log "One-time UEFI entry configured: $entryId / $bootVariable -> ${InstallerDrive}${loaderPath}" "Green"
}

if (-not (Test-Administrator)) {
    Write-Log "Run this script as Administrator." "Red"
    exit 1
}

if ($Revert) {
    Invoke-Revert
    exit 0
}

if (-not $Force) {
    $already = bcdedit /enum firmware 2>$null | Select-String -Pattern "Libertix UEFI Installer"
    if ($already) {
        Write-Log "Libertix UEFI entry detected. Use -Force to recreate." "Yellow"
    }
}

try {
    Test-LibertixSecureBootCompatibility
    Ensure-WindowsVolumeReadableFromLinux
    Ensure-MintIsoOnWindows

    if ($SkipInstaller) {
        Write-Log "Done (installer partition skipped)." "Green"
        exit 0
    }

    $info = New-OrReuseInstallerPartition -SizeGB $InstallerPartitionSizeGB
    $drive = $info["Drive"]
    $installerDiskNumber = [int]$info["DiskNumber"]
    $installerPartitionNumber = [int]$info["PartitionNumber"]

    Install-LibertixIsoToPartition -PartitionDrive $drive

    Set-LibertixUefiBootEntry `
        -InstallerDrive $drive `
        -InstallerDiskNumber $installerDiskNumber `
        -InstallerPartitionNumber $installerPartitionNumber

    Dismount-Letter -Letter ($drive.TrimEnd(":"))

    Write-Host ""
    Write-Log "Complete. Next boot should start Libertix UEFI installer once." "Green"
    Write-Host ""
    Write-Host "First boot: signed shim/GRUB should start the Libertix live installer." `
        -ForegroundColor Yellow

    Write-Log "Restarting now..." "Cyan"
    Restart-Computer -Force
} catch {
    Write-Log $_.Exception.Message "Red"
    Write-Log "Tip: you can run with -Revert to restore Windows boot." "Yellow"
    exit 1
}
