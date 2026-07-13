#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ConfigPath = "",
    [switch]$Force = $false,
    [switch]$Revert = $false,
    [switch]$SkipInstaller = $false,
    [int]$InstallerPartitionSizeGB = 20,
    [string]$FilepoolBaseUrl = "",
    [string]$Aria2ExePath = "",
    [ValidateRange(1, 5)]
    [int]$Aria2Connections = 5,
    [string]$LinuxUsername = "",
    [string]$LinuxPasswordHash = "",
    [string]$LinuxComputerName = "",
    [string]$SystemLang = "en_US.UTF-8",
    [string]$KeyboardLayout = "us",
    [string]$KeyboardModel = "pc105",
    [string]$Timezone = "UTC",
    [ValidateSet("BootNext", "FirmwareBootOrder")]
    [string]$BootStrategy = "BootNext",
    [switch]$ReusePreparedInstaller = $false,
    [string]$RecoveryRoot = "",
    [string]$RecoveryRunId = "",
    [bool]$LowMemoryMode = $false,
    [bool]$ShareWindowsFilesInLinux = $true,
    [bool]$ShareLinuxFilesInWindows = $true,
    [string]$WindowsProfilesJsonBase64 = "W10=",
    [switch]$PreserveConfig = $false,
    [switch]$InsecureTls = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$bootStrategyWasSpecified = $PSBoundParameters.ContainsKey("BootStrategy")

$requiredModules = @(
    "Libertix.Process.psm1",
    "Libertix.Firmware.psm1",
    "Libertix.Download.psm1",
    "Libertix.Transaction.psm1",
    "Libertix.Rollback.psm1"
)
foreach ($moduleName in $requiredModules) {
    $modulePath = Join-Path $PSScriptRoot "modules\$moduleName"
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Libertix PowerShell module is missing: $modulePath"
    }
    Import-Module -Name $modulePath -Force -ErrorAction Stop
}

if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
    try {
        $config = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
        $InstallerPartitionSizeGB = [int]$config.InstallerPartitionSizeGB
        $FilepoolBaseUrl = [string]$config.FilepoolBaseUrl
        $Aria2ExePath = [string]$config.Aria2ExePath
        $Aria2Connections = [int]$config.Aria2Connections
        $LinuxUsername = [string]$config.LinuxUsername
        $LinuxPasswordHash = [string]$config.LinuxPasswordHash
        $LinuxComputerName = [string]$config.LinuxComputerName
        $SystemLang = [string]$config.SystemLang
        $KeyboardLayout = [string]$config.KeyboardLayout
        $KeyboardModel = [string]$config.KeyboardModel
        $Timezone = [string]$config.Timezone
        if (-not $bootStrategyWasSpecified -and $config.PSObject.Properties.Name -contains "BootStrategy") {
            $BootStrategy = [string]$config.BootStrategy
        }
        if ($config.PSObject.Properties.Name -contains "RecoveryRoot") {
            $RecoveryRoot = [string]$config.RecoveryRoot
        }
        if ($config.PSObject.Properties.Name -contains "RecoveryRunId") {
            $RecoveryRunId = [string]$config.RecoveryRunId
        }
        if ($config.PSObject.Properties.Name -contains "LowMemoryMode") {
            $LowMemoryMode = [bool]$config.LowMemoryMode
        }
        if ($config.PSObject.Properties.Name -contains "ShareWindowsFilesInLinux") {
            $ShareWindowsFilesInLinux = [bool]$config.ShareWindowsFilesInLinux
        }
        if ($config.PSObject.Properties.Name -contains "ShareLinuxFilesInWindows") {
            $ShareLinuxFilesInWindows = [bool]$config.ShareLinuxFilesInWindows
        }
        if ($config.PSObject.Properties.Name -contains "WindowsProfilesJsonBase64") {
            $WindowsProfilesJsonBase64 = [string]$config.WindowsProfilesJsonBase64
        }
    } finally {
        if (-not $PreserveConfig) {
            Remove-Item -LiteralPath $ConfigPath -Force -ErrorAction SilentlyContinue
        }
    }
}

$parsedFilepoolUri = $null
if (
    [string]::IsNullOrWhiteSpace($FilepoolBaseUrl) -or
    -not [Uri]::TryCreate($FilepoolBaseUrl, [UriKind]::Absolute, [ref]$parsedFilepoolUri) -or
    $parsedFilepoolUri.Scheme -notin @("http", "https")
) {
    throw "FilepoolBaseUrl is required and must be an absolute HTTP(S) URL supplied by Libertix."
}
$FilepoolBaseUrl = $FilepoolBaseUrl.TrimEnd("/")

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
$Aria2ZipName = "aria2-1.37.0-win-64bit-build1.zip"
$downloadUrls = New-LibertixDownloadUrls `
    -FilepoolBaseUrl $FilepoolBaseUrl `
    -Aria2ZipName $Aria2ZipName
$InstallerIsoUrl = $downloadUrls.InstallerIso
$InstallerIsoName = "libertix-installer-uefi.iso"
$InstallerIsoSha256 = "61d930b34d98a33c36f433117aca6bb61e0039081ee744f56b21bcda1f23ad05"
$MintIsoUrl = $downloadUrls.MintIso
$MintIsoPath = "$env:SystemDrive\mint.iso"
$MintIsoSha256 = "a081ab202cfda17f6924128dbd2de8b63518ac0531bcfe3f1a1b88097c459bd4"
$Aria2ZipUrl = $downloadUrls.Aria2Zip
$Aria2ZipSha256 = "67d015301eef0b612191212d564c5bb0a14b5b9c4796b76454276a4d28d9b288"
$Aria2ExeSha256 = "be2099c214f63a3cb4954b09a0becd6e2e34660b886d4c898d260febfe9d70c2"
$Aria2CacheDir = "$env:SystemDrive\LibertixTools\aria2"
$Aria2DownloadDir = "$env:SystemDrive\LibertixTools\downloads"
$LowMemoryIsoPath = "$env:SystemDrive\libertix-live.iso"

# Defaults
$EspLetter = "Y"
$InstallerLetter = "X"
$InstallerLabel = "LIBERTIXEFI"
$InstallerBootDescription = "Libertix UEFI Installer"
$InstallerEspDirectory = "EFI\LibertixInstaller"
$TransactionStatePath = "$env:SystemDrive\LibertixTools\uefi-transaction.json"

if ($BootStrategy -notin @("BootNext", "FirmwareBootOrder")) {
    throw "Unsupported UEFI boot strategy: $BootStrategy"
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("Gray", "Cyan", "Green", "Yellow", "Red", "White")]
        [string]$Color = "Gray"
    )

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
}

function Write-ExceptionDiagnostics {
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    Write-Log "Exception type: $($ErrorRecord.Exception.GetType().FullName)" "Red"
    if ($ErrorRecord.FullyQualifiedErrorId) {
        Write-Log "Error id: $($ErrorRecord.FullyQualifiedErrorId)" "Red"
    }
    if ($ErrorRecord.InvocationInfo.PositionMessage) {
        Write-Log "Error position: $($ErrorRecord.InvocationInfo.PositionMessage.Trim())" "Red"
    }
    if ($ErrorRecord.ScriptStackTrace) {
        Write-Log "PowerShell stack: $($ErrorRecord.ScriptStackTrace)" "Red"
    }
}

function ConvertTo-ShellQuotedValue {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        $Value = ""
    }
    if ($Value -match "[`r`n]") {
        throw "Config values cannot contain newlines."
    }

    return "'" + $Value.Replace("'", "'\''") + "'"
}

function Test-LibertixLiveConfig {
    foreach ($item in @(
        @{ Name = "LinuxUsername"; Value = $LinuxUsername },
        @{ Name = "LinuxPasswordHash"; Value = $LinuxPasswordHash },
        @{ Name = "LinuxComputerName"; Value = $LinuxComputerName },
        @{ Name = "SystemLang"; Value = $SystemLang },
        @{ Name = "KeyboardLayout"; Value = $KeyboardLayout },
        @{ Name = "Timezone"; Value = $Timezone }
    )) {
        if ([string]::IsNullOrWhiteSpace([string]$item.Value)) {
            throw "Missing live installer config value: $($item.Name)"
        }
    }
    if ($LinuxPasswordHash -notmatch '^\$6\$') {
        throw "LinuxPasswordHash must use SHA-512 crypt."
    }
}

function Write-LibertixLiveConfig {
    param(
        [Parameter(Mandatory = $true)][string]$PartitionDrive
    )

    if (-not (Test-Path "$PartitionDrive\")) {
        throw "Cannot write live config because partition is not mounted: $PartitionDrive"
    }

    $systemPartition = Get-Partition -DriveLetter C -ErrorAction Stop
    $systemDisk = Get-Disk -Number $systemPartition.DiskNumber -ErrorAction Stop
    $installerLetter = $PartitionDrive.TrimEnd(":\")
    $installerPartition = Get-Partition -DriveLetter $installerLetter -ErrorAction Stop
    if ($installerPartition.DiskNumber -ne $systemPartition.DiskNumber) {
        throw "Installer partition is not on the Windows system disk."
    }
    $recoveryPartitions = @(
        Get-Partition -DiskNumber $systemPartition.DiskNumber -ErrorAction Stop |
            Where-Object {
                $_.GptType -eq "{de94bba4-06d1-4d40-a16a-bfd50179d6ac}" -or
                [int]$_.MbrType -eq 39 -or
                $_.Type -match "Recovery"
            }
    )
    if (@($recoveryPartitions).Count -ne 1) {
        throw "Exactly one Windows recovery partition is required; detected $(@($recoveryPartitions).Count)."
    }
    $recoveryPartition = $recoveryPartitions[0]

    $configPath = Join-Path $PartitionDrive "config.txt"
    if (Test-Path $configPath) {
        attrib -R -S -H $configPath 2>$null
        Remove-Item -Path $configPath -Force
    }

    $configLines = @(
        "SYSTEM_LANG=$(ConvertTo-ShellQuotedValue $SystemLang)",
        "KEYBOARD_LAYOUT=$(ConvertTo-ShellQuotedValue $KeyboardLayout)",
        "KEYBOARD_MODEL=$(ConvertTo-ShellQuotedValue $KeyboardModel)",
        "TIMEZONE=$(ConvertTo-ShellQuotedValue $Timezone)",
        "USERNAME=$(ConvertTo-ShellQuotedValue $LinuxUsername)",
        "PASSWORD_HASH=$(ConvertTo-ShellQuotedValue $LinuxPasswordHash)",
        "COMPUTER_NAME=$(ConvertTo-ShellQuotedValue $LinuxComputerName)",
        "ISO_FILENAME=$(ConvertTo-ShellQuotedValue 'mint.iso')",
        "ISO_WINDOWS_PATH=$(ConvertTo-ShellQuotedValue $MintIsoPath)",
        "LINUX_SIZE_GB=$(ConvertTo-ShellQuotedValue ([string]$InstallerPartitionSizeGB))",
        "TARGET_DISK_SIZE_BYTES=$(ConvertTo-ShellQuotedValue ([string]$systemDisk.Size))",
        "WINDOWS_PARTITION_OFFSET_BYTES=$(ConvertTo-ShellQuotedValue ([string]$systemPartition.Offset))",
        "INSTALLER_PARTITION_OFFSET_BYTES=$(ConvertTo-ShellQuotedValue ([string]$installerPartition.Offset))",
        "EXPECTED_PARTITION_STYLE=$(ConvertTo-ShellQuotedValue ([string]$systemDisk.PartitionStyle))",
        "RECOVERY_PARTITION_OFFSET_BYTES=$(ConvertTo-ShellQuotedValue ([string]$recoveryPartition.Offset))",
        "RECOVERY_PARTITION_SIZE_BYTES=$(ConvertTo-ShellQuotedValue ([string]$recoveryPartition.Size))",
        "RECOVERY_ROOT_WINDOWS=$(ConvertTo-ShellQuotedValue $RecoveryRoot)",
        "RECOVERY_RUN_ID=$(ConvertTo-ShellQuotedValue $RecoveryRunId)",
        "LOW_MEMORY_MODE=$(ConvertTo-ShellQuotedValue $LowMemoryMode.ToString().ToLowerInvariant())",
        "SHARE_WINDOWS_FILES_IN_LINUX=$(ConvertTo-ShellQuotedValue $ShareWindowsFilesInLinux.ToString().ToLowerInvariant())",
        "SHARE_LINUX_FILES_IN_WINDOWS=$(ConvertTo-ShellQuotedValue $ShareLinuxFilesInWindows.ToString().ToLowerInvariant())",
        "WINDOWS_PROFILES_JSON_BASE64=$(ConvertTo-ShellQuotedValue $WindowsProfilesJsonBase64)"
    )

    Set-Content -Path $configPath -Value $configLines -Encoding ASCII

    $written = Get-Content -Path $configPath -Raw -ErrorAction Stop
    foreach ($requiredKey in @(
        "USERNAME=", "PASSWORD_HASH=", "COMPUTER_NAME=", "ISO_WINDOWS_PATH=", "LINUX_SIZE_GB=",
        "TARGET_DISK_SIZE_BYTES=", "WINDOWS_PARTITION_OFFSET_BYTES=",
        "INSTALLER_PARTITION_OFFSET_BYTES=", "EXPECTED_PARTITION_STYLE=",
        "RECOVERY_PARTITION_OFFSET_BYTES=", "RECOVERY_PARTITION_SIZE_BYTES=",
        "RECOVERY_ROOT_WINDOWS=", "RECOVERY_RUN_ID=", "LOW_MEMORY_MODE=",
        "SHARE_WINDOWS_FILES_IN_LINUX=", "SHARE_LINUX_FILES_IN_WINDOWS=",
        "WINDOWS_PROFILES_JSON_BASE64="
    )) {
        if ($written -notmatch [regex]::Escape($requiredKey)) {
            throw "Live config verification failed; missing $requiredKey in $configPath"
        }
    }

    Write-Log "Live config written to $configPath for user '$LinuxUsername'." "Green"
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Get-NativeSystemExecutable {
    param([Parameter(Mandatory = $true)][string]$FileName)

    foreach ($candidate in @(
        (Join-Path $env:SystemRoot "Sysnative\$FileName"),
        (Join-Path $env:SystemRoot "System32\$FileName")
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    $command = Get-Command $FileName -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    throw "$FileName is unavailable through Sysnative, System32, and PATH."
}

function Invoke-BcdeditCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $bcdedit = Get-NativeSystemExecutable -FileName "bcdedit.exe"
    $output = & $bcdedit @Arguments 2>&1
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

function Get-BcdFirmwareEntryIdsByDescription {
    param([Parameter(Mandatory = $true)][string[]]$Descriptions)

    $firmwareText = Invoke-BcdeditCommand -Arguments @("/enum", "firmware", "/v")
    $firmwareEntries = $firmwareText -split "`r?`n"
    $identifiers = New-Object System.Collections.Generic.List[string]
    $current = $null
    foreach ($line in $firmwareEntries) {
        if ($line -match "^(identificateur|identifier)\s+(\{[^}]+\})") {
            $current = $Matches[2]
            continue
        }

        foreach ($description in $Descriptions) {
            if ($line -match "^description\s+$([regex]::Escape($description))$" -and $current) {
                $identifiers.Add($current)
                $current = $null
                break
            }
        }
    }
    return @($identifiers)
}

function Remove-BcdFirmwareEntriesByDescription {
    param([Parameter(Mandatory = $true)][string[]]$Descriptions)

    try {
        $identifiers = @(Get-BcdFirmwareEntryIdsByDescription -Descriptions $Descriptions)
    } catch {
        Write-Log "BCD firmware enumeration failed during stale-entry cleanup; native Boot#### cleanup will continue: $($_.Exception.Message)" "Yellow"
        return
    }

    foreach ($identifier in $identifiers) {
        try {
            Invoke-BcdeditCommand -Arguments @("/delete", $identifier, "/f") | Out-Null
        } catch {
            Write-Log "BCD could not delete temporary firmware entry $identifier; native Boot#### cleanup will continue: $($_.Exception.Message)" "Yellow"
        }
    }
}

function Remove-NativeFirmwareEntriesByDescription {
    param([Parameter(Mandatory = $true)][string[]]$Descriptions)

    $knownNumbers = @(
        ConvertFrom-BootOrderBytes -Bytes (Get-FirmwareVariableBytes -Name "BootOrder")
        ConvertFrom-BootOrderBytes -Bytes (Get-FirmwareVariableBytes -Name "BootNext")
    ) | Sort-Object -Unique
    foreach ($candidate in $knownNumbers) {
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

    $bootNext = @(ConvertFrom-BootOrderBytes -Bytes (Get-FirmwareVariableBytes -Name "BootNext"))
    if ($bootNext.Count -eq 1) {
        $bootVariable = "Boot{0:X4}" -f [uint16]$bootNext[0]
        $bytes = Get-FirmwareVariableBytes -Name $bootVariable
        if ($bytes -and (Get-EfiLoadOptionDescription -Bytes $bytes) -eq $InstallerBootDescription) {
            Remove-FirmwareVariable -Name "BootNext"
        }
    }
}

function Remove-LibertixInstallerPartitionIfPresent {
    $partition = Get-VerifiedTransactionPartition
    if (-not $partition) {
        if (Test-LibertixInstallerPartitionPresent) {
            throw "$InstallerLabel exists without a matching transaction state; refusing removal."
        }
        Write-Log "No owned $InstallerLabel partition found." "Gray"
        return
    }

    Write-Log "Removing $InstallerLabel partition on disk $($partition.DiskNumber), partition $($partition.PartitionNumber)..." "Cyan"
    if ($partition.DriveLetter) {
        Dismount-Letter -Letter ([string]$partition.DriveLetter)
    }
    try {
        Remove-Partition `
            -DiskNumber $partition.DiskNumber `
            -PartitionNumber $partition.PartitionNumber `
            -Confirm:$false `
            -ErrorAction Stop
    } catch {
        Write-Log "PowerShell could not remove $InstallerLabel partition; trying diskpart fallback..." "Yellow"
        Invoke-DiskpartScript -ScriptText @"
select disk $($partition.DiskNumber)
select partition $($partition.PartitionNumber)
delete partition override
exit
"@
    }

    Assert-LibertixInstallerPartitionRemoved
}

function Test-LibertixInstallerPartitionPresent {
    $volume = Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.FileSystemLabel -eq $InstallerLabel } |
        Select-Object -First 1
    if ($volume) {
        return $true
    }

    $cim = Get-CimInstance Win32_Volume -Filter "Label='$InstallerLabel'" `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1
    return ($null -ne $cim)
}

function Assert-LibertixInstallerPartitionRemoved {
    Start-Sleep -Seconds 1
    if (Test-LibertixInstallerPartitionPresent) {
        throw "$InstallerLabel partition is still present after revert attempt."
    }
}

function Set-NativeUefiBootOrderOnce {
    param(
        [Parameter(Mandatory = $true)][string]$InstallerDrive,
        [Parameter(Mandatory = $true)][int]$InstallerDiskNumber,
        [Parameter(Mandatory = $true)][int]$InstallerPartitionNumber,
        [Parameter(Mandatory = $true)][string]$LoaderPath
    )

    $driveLetter = ""
    if (-not [string]::IsNullOrWhiteSpace($InstallerDrive)) {
        $driveLetter = $InstallerDrive.Substring(0, 1)
    }

    $partition = $null
    if (-not [string]::IsNullOrWhiteSpace($driveLetter)) {
        $partition = Get-Partition -DriveLetter $driveLetter -ErrorAction SilentlyContinue
    }
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

    return $bootVariable
}

function Get-FirmwareBootNumberByDescription {
    param([Parameter(Mandatory = $true)][string]$Description)

    $knownCandidates = @(
        ConvertFrom-BootOrderBytes -Bytes (Get-FirmwareVariableBytes -Name "BootOrder")
        ConvertFrom-BootOrderBytes -Bytes (Get-FirmwareVariableBytes -Name "BootNext")
    ) | Sort-Object -Unique
    foreach ($candidate in $knownCandidates) {
        $name = "Boot{0:X4}" -f $candidate
        $bytes = Get-FirmwareVariableBytes -Name $name
        if ($bytes -and (Get-EfiLoadOptionDescription -Bytes $bytes) -eq $Description) {
            return [uint16]$candidate
        }
    }

    return $null
}

function Restore-OriginalFirmwareBootOrder {
    $state = Get-TransactionPartitionState
    if (-not $state -or -not $state.OriginalBootOrder) {
        return
    }

    $rawOriginal = @($state.OriginalBootOrder)
    if (
        $rawOriginal.Count -eq 1 -and
        $rawOriginal[0] -is [pscustomobject] -and
        @($rawOriginal[0].PSObject.Properties).Count -eq 0
    ) {
        return
    }
    $original = @($rawOriginal | ForEach-Object { [Convert]::ToUInt16($_) })
    if ($original.Count -eq 0) {
        return
    }

    foreach ($bootNumber in $original) {
        if (-not (Test-FirmwareVariableExists -Name ("Boot{0:X4}" -f $bootNumber))) {
            throw ("Cannot restore the saved UEFI BootOrder because Boot{0:X4} no longer exists." -f $bootNumber)
        }
    }

    Set-FirmwareVariable -Name "BootOrder" -Value (ConvertTo-BootOrderBytes -Order $original)
    $verified = @(ConvertFrom-BootOrderBytes -Bytes (Get-FirmwareVariableBytes -Name "BootOrder"))
    if (($verified -join ",") -ne ($original -join ",")) {
        throw "UEFI BootOrder restore verification failed."
    }
    Write-Log "Original UEFI BootOrder restored." "Green"
}

function Assert-LibertixFirmwareEntry {
    param(
        [Parameter(Mandatory = $true)][uint16]$BootNumber,
        [Parameter(Mandatory = $true)][string]$LoaderPath
    )

    $bootVariable = "Boot{0:X4}" -f $BootNumber
    $bytes = Get-FirmwareVariableBytes -Name $bootVariable
    if (-not $bytes) {
        throw "$bootVariable cannot be read back after it was created."
    }
    if ((Get-EfiLoadOptionDescription -Bytes $bytes) -ne $InstallerBootDescription) {
        throw "$bootVariable description does not match '$InstallerBootDescription'."
    }

    $decoded = [Text.Encoding]::Unicode.GetString($bytes)
    if ($decoded -notmatch [regex]::Escape($LoaderPath)) {
        throw "$bootVariable does not contain the expected loader path $LoaderPath."
    }
}

function New-LibertixBcdFirmwareEntry {
    param(
        [Parameter(Mandatory = $true)][string]$EspDrive,
        [Parameter(Mandatory = $true)][string]$LoaderPath
    )

    $copyText = Invoke-BcdeditCommand -Arguments @("/copy", "{bootmgr}", "/d", $InstallerBootDescription)
    if ($copyText -notmatch "(\{[0-9a-fA-F-]+\})") {
        throw "Could not parse firmware entry identifier from bcdedit output: $copyText"
    }
    $entryId = $Matches[1]

    Invoke-BcdeditCommand -Arguments @("/set", $entryId, "device", "partition=$EspDrive") | Out-Null
    Invoke-BcdeditCommand -Arguments @("/set", $entryId, "path", $LoaderPath) | Out-Null
    foreach ($value in @("locale", "inherit", "default", "resumeobject", "toolsdisplayorder", "timeout")) {
        try {
            Invoke-BcdeditCommand -Arguments @("/deletevalue", $entryId, $value) | Out-Null
        } catch {
            # These values are inherited from the copied boot manager and are
            # optional for a firmware application entry.
        }
    }
    Invoke-BcdeditCommand -Arguments @("/set", "{fwbootmgr}", "displayorder", $entryId, "/addfirst") | Out-Null

    $bootNumber = $null
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        $bootNumber = Get-FirmwareBootNumberByDescription -Description $InstallerBootDescription
        if ($null -ne $bootNumber) {
            break
        }
        Start-Sleep -Seconds 1
    }
    if ($null -eq $bootNumber) {
        throw "BCD created a firmware entry but no matching UEFI Boot#### variable appeared."
    }

    $bootVariable = "Boot{0:X4}" -f $bootNumber
    $loadOption = Get-FirmwareVariableBytes -Name $bootVariable
    $optionalLength = Get-EfiLoadOptionOptionalDataLength -Bytes $loadOption
    if ($optionalLength -lt 0) {
        throw "Cannot parse the BCD-created $bootVariable load option."
    }
    if ($optionalLength -gt 0) {
        Set-FirmwareVariable -Name $bootVariable -Value (Remove-EfiLoadOptionOptionalData -Bytes $loadOption)
    }
    Assert-LibertixFirmwareEntry -BootNumber $bootNumber -LoaderPath $LoaderPath

    # bcdedit /copy creates a source BCD object. Updating the materialized
    # Boot#### load option through the firmware API leaves that source object
    # visible as a duplicate. Remove only the source and require one surviving
    # firmware entry with the expected description.
    Invoke-BcdeditCommand -Arguments @("/delete", $entryId, "/f") | Out-Null
    $survivingIds = @(
        Get-BcdFirmwareEntryIdsByDescription -Descriptions @($InstallerBootDescription)
    )
    if ($survivingIds.Count -ne 1) {
        throw "Expected one materialized Libertix firmware entry after BCD source cleanup; found $($survivingIds.Count)."
    }

    return [pscustomobject]@{
        EntryId = $survivingIds[0]
        BootNumber = [uint16]$bootNumber
        BootVariable = $bootVariable
    }
}

function Get-SecureBootDbCertificates {
    $db = Get-SecureBootUEFI -Name db
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
        if ($listSize -lt 28 -or $offset + $listSize -gt $bytes.Length) {
            throw "Secure Boot db contains an invalid EFI signature list."
        }
        if ($signatureSize -lt 16) {
            throw "Secure Boot db contains an invalid EFI signature size."
        }

        if ($signatureType -eq $x509SignatureType) {
            $signatureOffset = $offset + 28 + $headerSize
            $listEnd = $offset + $listSize
            while ($signatureOffset + $signatureSize -le $listEnd) {
                $certificateLength = [int]$signatureSize - 16
                $certificateBytes = New-Object byte[] $certificateLength
                [Array]::Copy($bytes, $signatureOffset + 16, $certificateBytes, 0, $certificateLength)
                try {
                    $certificates.Add((New-Object Security.Cryptography.X509Certificates.X509Certificate2 (,$certificateBytes)))
                } catch {
                    throw "Secure Boot db contains an invalid X.509 certificate: $($_.Exception.Message)"
                }
                $signatureOffset += $signatureSize
            }
        }
        $offset += $listSize
    }
    return $certificates
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

    $subjects = @(Get-SecureBootDbCertificates | ForEach-Object { $_.Subject })
    $has2011 = @($subjects | Where-Object { $_ -match "CN=Microsoft Corporation UEFI CA 2011(?:,|$)" }).Count -gt 0
    $has2023 = @($subjects | Where-Object { $_ -match "CN=Microsoft(?: Corporation)? UEFI CA 2023(?:,|$)" }).Count -gt 0
    $hasWindows2023 = @($subjects | Where-Object { $_ -match "CN=Windows UEFI CA 2023(?:,|$)" }).Count -gt 0

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
        $result = Invoke-LibertixNativeProcess `
            -FilePath "$env:SystemRoot\System32\diskpart.exe" `
            -Arguments ('/s "{0}"' -f $tmp) `
            -TimeoutSeconds 120
        $text = ($result.StandardOutput + [Environment]::NewLine + $result.StandardError).Trim()
        if ($result.ExitCode -ne 0 -or $text -match "(?i)(error|erreur|failed|échec)") {
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

function Get-WindowsEspPartition {
    $winPart = Get-Partition -DriveLetter C -ErrorAction Stop
    $espPart =
        Get-Partition -DiskNumber $winPart.DiskNumber -ErrorAction Stop |
        Where-Object {
            $_.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}"
        } |
        Select-Object -First 1

    if (-not $espPart) {
        throw "ESP not found on disk $($winPart.DiskNumber)."
    }

    return $espPart
}

function Remove-LibertixTemporaryEspFiles {
    param([Parameter(Mandatory = $true)][string]$EspDrive)

    $path = Join-Path $EspDrive $InstallerEspDirectory
    if (Test-Path $path) {
        Write-Log "Removing temporary ESP boot directory: $InstallerEspDirectory" "Cyan"
        Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
    }
}

function Install-LibertixTemporaryBootloaderOnEsp {
    param(
        [Parameter(Mandatory = $true)][string]$EspDrive,
        [Parameter(Mandatory = $true)][string]$InstallerDrive
    )

    if (-not (Test-Path "$EspDrive\")) {
        throw "Cannot install temporary bootloader; ESP is not mounted: $EspDrive"
    }
    if (-not (Test-Path "$InstallerDrive\")) {
        throw "Cannot install temporary bootloader; installer partition is not mounted: $InstallerDrive"
    }

    $destination = Join-Path $EspDrive $InstallerEspDirectory
    Remove-LibertixTemporaryEspFiles -EspDrive $EspDrive
    New-Item -ItemType Directory -Path $destination -Force | Out-Null

    $sourceBoot = Join-Path $InstallerDrive "EFI\BOOT"
    $bootx64 = Join-Path $sourceBoot "BOOTX64.EFI"
    $grubx64 = Join-Path $sourceBoot "grubx64.efi"
    $mmx64 = Join-Path $sourceBoot "mmx64.efi"
    foreach ($path in @($bootx64, $grubx64, $mmx64)) {
        if (-not (Test-Path $path)) {
            throw "Installer EFI file not found before ESP copy: $path"
        }
    }

    Copy-Item -LiteralPath $bootx64 -Destination (Join-Path $destination "BOOTX64.EFI") -Force
    Copy-Item -LiteralPath $grubx64 -Destination (Join-Path $destination "grubx64.efi") -Force
    Copy-Item -LiteralPath $mmx64 -Destination (Join-Path $destination "mmx64.efi") -Force

    $grubConfig = @"
set default=0
set timeout=0
set timeout_style=hidden
set hidden_timeout=0
set hidden_timeout_quiet=true

search --no-floppy --label $InstallerLabel --set=root

menuentry "Install Linux Mint (Automatic)" {
    linux /live/vmlinuz boot=live toram components quiet splash silent plymouth.ignore-serial-consoles loglevel=3 systemd.show_status=0 console=ttyS0,115200n8 console=tty1
    initrd /live/initrd.img
}
"@
    Set-Content -Path (Join-Path $destination "grub.cfg") -Value $grubConfig -Encoding ASCII

    $hashes = @{}
    foreach ($relativePath in @("BOOTX64.EFI", "grubx64.efi", "mmx64.efi", "grub.cfg")) {
        $fullPath = Join-Path $destination $relativePath
        if (-not (Test-Path $fullPath) -or (Get-Item $fullPath).Length -le 0) {
            throw "Temporary ESP bootloader verification failed: $fullPath"
        }
        $hashes[$relativePath] = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    }

    Write-Log "Temporary UEFI loader installed on Windows ESP: $InstallerEspDirectory" "Green"
    return $hashes
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
    if (-not [string]::IsNullOrWhiteSpace($Aria2ExePath)) {
        $resolved = [IO.Path]::GetFullPath($Aria2ExePath)
        if (-not (Test-Path -LiteralPath $resolved)) {
            throw "Provided aria2 executable was not found: $resolved"
        }
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolved).Hash.ToLowerInvariant()
        if ($actualHash -ne $Aria2ExeSha256) {
            throw "Provided aria2 executable hash mismatch. Expected $Aria2ExeSha256, got $actualHash"
        }
        return $resolved
    }

    $existing =
        if (Test-Path -LiteralPath $Aria2CacheDir) {
            Get-ChildItem -LiteralPath $Aria2CacheDir -Filter "aria2c.exe" `
                -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1
        } else {
            $null
        }
    if ($existing) {
        $existingHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $existing.FullName).Hash.ToLowerInvariant()
        if ($existingHash -eq $Aria2ExeSha256) {
            return $existing.FullName
        }
        Write-Log "Cached aria2 hash mismatch; replacing the cache." "Yellow"
        Remove-Item -LiteralPath $Aria2CacheDir -Recurse -Force
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

    $zipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
    if ($zipHash -ne $Aria2ZipSha256) {
        throw "aria2 archive hash mismatch. Expected $Aria2ZipSha256, got $zipHash"
    }

    Expand-Archive -LiteralPath $zipPath -DestinationPath $Aria2CacheDir -Force
    $aria2 = Get-ChildItem -LiteralPath $Aria2CacheDir -Filter "aria2c.exe" `
        -Recurse -ErrorAction Stop |
        Select-Object -First 1

    if (-not $aria2) {
        throw "aria2c.exe was not found after extraction."
    }

    $aria2Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $aria2.FullName).Hash.ToLowerInvariant()
    if ($aria2Hash -ne $Aria2ExeSha256) {
        throw "aria2 executable hash mismatch after extraction. Expected $Aria2ExeSha256, got $aria2Hash"
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
        "--max-connection-per-server=$Aria2Connections",
        "--split=$Aria2Connections",
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
        $existingHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $MintIsoPath).Hash.ToLowerInvariant()
        if ($existingHash -eq $MintIsoSha256) {
            Write-Log "Mint ISO already present and verified: $MintIsoPath" "Green"
            return
        }
        Write-Log "Existing Mint ISO hash mismatch; downloading a verified copy." "Yellow"
        Remove-Item -LiteralPath $MintIsoPath -Force
    }

    Write-Log "Downloading Mint ISO to $MintIsoPath..." "Cyan"
    Start-RobustDownload -Url $MintIsoUrl -Destination $MintIsoPath -Label "Mint ISO"

    $downloadedIso = Get-Item -LiteralPath $MintIsoPath -ErrorAction Stop
    if ($downloadedIso.Length -le 100MB) {
        throw "Mint ISO download is too small: $($downloadedIso.Length) bytes"
    }
    $downloadedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $MintIsoPath).Hash.ToLowerInvariant()
    if ($downloadedHash -ne $MintIsoSha256) {
        throw "Mint ISO hash mismatch. Expected $MintIsoSha256, got $downloadedHash"
    }
    Write-Log "Mint ISO ready: $MintIsoPath" "Green"
}

function Ensure-VolumeNotEncrypted {
    param([Parameter(Mandatory = $true)][string]$DriveLetter)

    $manageBde = Get-NativeSystemExecutable -FileName "manage-bde.exe"
    $out = & $manageBde -status "${DriveLetter}:" 2>&1 | Out-String

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
    & $manageBde -off "${DriveLetter}:" 2>&1 | Out-Null

    $timeoutSec = 600
    $elapsed = 0
    $interval = 3

    while ($elapsed -lt $timeoutSec) {
        Start-Sleep -Seconds $interval
        $elapsed += $interval

        $out = & $manageBde -status "${DriveLetter}:" 2>&1 | Out-String
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
    $manageBde = Get-NativeSystemExecutable -FileName "manage-bde.exe"

    try {
        $bitlockerVolume = Get-BitLockerVolume -MountPoint "C:" -ErrorAction Stop
    } catch {
        throw "Cannot establish the BitLocker state of C:. Refusing disk changes: $($_.Exception.Message)"
    }

    if (-not $bitlockerVolume) {
        throw "Get-BitLockerVolume returned no C: volume. Refusing disk changes."
    }

    if (Test-BitLockerVolumeReadable -Volume $bitlockerVolume) {
        Write-Log "Windows C: is already readable from Linux." "Green"
        return
    }

    Write-Log "Disabling BitLocker/device encryption on C: before Linux live boot..." "Cyan"
    Disable-BitLocker -MountPoint "C:" -ErrorAction Continue
    & $manageBde -off C: 2>&1 | Out-Null

    $maxDecryptionWait = [TimeSpan]::FromHours(6)
    $decryptionTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $attempt = 0
    $lastEncryptedPercent = $null
    $samePercentCount = 0
    while ($decryptionTimer.Elapsed -lt $maxDecryptionWait) {
        Start-Sleep -Seconds 10
        $attempt++
        $bitlockerVolume = Get-BitLockerVolume -MountPoint "C:" -ErrorAction Stop
        if (Test-BitLockerVolumeReadable -Volume $bitlockerVolume) {
            Write-Log "Windows C: decrypted." "Green"
            return
        }

        if ($null -ne $bitlockerVolume.EncryptionPercentage) {
            $encryptedPercent = [int]$bitlockerVolume.EncryptionPercentage
            if ($null -ne $lastEncryptedPercent -and $encryptedPercent -eq $lastEncryptedPercent) {
                $samePercentCount++
            } else {
                $samePercentCount = 0
                $lastEncryptedPercent = $encryptedPercent
            }
            Write-Log "Waiting for C: decryption... $encryptedPercent% encrypted, protection=$($bitlockerVolume.ProtectionStatus)" "Yellow"
        } else {
            Write-Log "Waiting for C: decryption... status=$($bitlockerVolume.VolumeStatus), protection=$($bitlockerVolume.ProtectionStatus)" "Yellow"
        }

        if (($attempt % 12) -eq 0 -or $samePercentCount -ge 12) {
            Write-Log "Reasserting BitLocker decryption request for C:..." "Yellow"
            Disable-BitLocker -MountPoint "C:" -ErrorAction Continue
            & $manageBde -off C: 2>&1 | Out-Null
            $samePercentCount = 0
        }

    }
    $decryptionTimer.Stop()
    $finalStatus = & $manageBde -status C: 2>&1 | Out-String
    throw "Timed out waiting for C: BitLocker decryption. Final status: $finalStatus"
}

function Save-TransactionPreparationState {
    param([Parameter(Mandatory = $true)]$SystemPartition)

    $disk = Get-Disk -Number $SystemPartition.DiskNumber -ErrorAction Stop
    $state = [ordered]@{
        Version = 1
        DiskNumber = [int]$SystemPartition.DiskNumber
        DiskUniqueId = [string]$disk.UniqueId
        OriginalCSize = [int64]$SystemPartition.Size
        PartitionNumber = 0
        PartitionOffset = 0
        PartitionSize = 0
        Label = $InstallerLabel
        BootStrategy = $BootStrategy
        RecoveryRoot = $RecoveryRoot
        RecoveryRunId = $RecoveryRunId
        OriginalBootOrder = @()
        InstallerBootNumber = $null
        InstallerBootVariable = ""
        FirmwareEntryId = ""
        EspLoaderSha256 = @{}
        InstallerFileSha256 = @{}
        CreatedUtc = [DateTime]::UtcNow.ToString("o")
    }
    $directory = Split-Path -Parent $TransactionStatePath
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $state | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $TransactionStatePath -Encoding UTF8
}

function Save-TransactionPartitionState {
    param([Parameter(Mandatory = $true)]$Partition)

    $disk = Get-Disk -Number $Partition.DiskNumber -ErrorAction Stop
    $existing = Get-TransactionPartitionState
    $originalCSize = if ($existing -and $existing.OriginalCSize) {
        [int64]$existing.OriginalCSize
    } else {
        [int64](Get-Partition -DriveLetter C -ErrorAction Stop).Size
    }
    $state = [ordered]@{
        Version = 1
        DiskNumber = [int]$Partition.DiskNumber
        DiskUniqueId = [string]$disk.UniqueId
        OriginalCSize = $originalCSize
        PartitionNumber = [int]$Partition.PartitionNumber
        PartitionOffset = [int64]$Partition.Offset
        PartitionSize = [int64]$Partition.Size
        Label = $InstallerLabel
        BootStrategy = if ($existing -and $existing.BootStrategy) { [string]$existing.BootStrategy } else { $BootStrategy }
        RecoveryRoot = if ($existing -and $existing.RecoveryRoot) { [string]$existing.RecoveryRoot } else { $RecoveryRoot }
        RecoveryRunId = if ($existing -and $existing.RecoveryRunId) { [string]$existing.RecoveryRunId } else { $RecoveryRunId }
        OriginalBootOrder = if ($existing -and $existing.OriginalBootOrder) { @($existing.OriginalBootOrder) } else { @() }
        InstallerBootNumber = if ($existing) { $existing.InstallerBootNumber } else { $null }
        InstallerBootVariable = if ($existing) { [string]$existing.InstallerBootVariable } else { "" }
        FirmwareEntryId = if ($existing) { [string]$existing.FirmwareEntryId } else { "" }
        EspLoaderSha256 = if ($existing -and $existing.EspLoaderSha256) { $existing.EspLoaderSha256 } else { @{} }
        InstallerFileSha256 = if ($existing -and $existing.InstallerFileSha256) { $existing.InstallerFileSha256 } else { @{} }
        CreatedUtc = [DateTime]::UtcNow.ToString("o")
    }
    $directory = Split-Path -Parent $TransactionStatePath
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $state | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $TransactionStatePath -Encoding UTF8
}

function Get-TransactionPartitionState {
    if (-not (Test-Path -LiteralPath $TransactionStatePath -PathType Leaf)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $TransactionStatePath -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Invalid UEFI transaction state file: $($_.Exception.Message)"
    }
}

function Save-PreparedInstallerManifest {
    param([Parameter(Mandatory = $true)][string]$InstallerDrive)

    $state = Get-TransactionPartitionState
    if (-not $state) {
        throw "Cannot save prepared installer manifest without transaction state."
    }
    $manifest = Get-FileHashManifest `
        -Root "$InstallerDrive\" `
        -RelativePaths (Get-InstallerManifestRelativePaths)
    $state | Add-Member -NotePropertyName InstallerFileSha256 -NotePropertyValue $manifest -Force
    $state | Add-Member -NotePropertyName InstallerManifestUtc -NotePropertyValue ([DateTime]::UtcNow.ToString("o")) -Force
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $TransactionStatePath -Encoding UTF8
    Write-Log "Prepared installer SHA256 manifest saved ($($manifest.Count) files)." "Green"
}

function Assert-PreparedInstallerManifest {
    param([Parameter(Mandatory = $true)][string]$InstallerDrive)

    $state = Get-TransactionPartitionState
    if (-not $state -or -not $state.InstallerFileSha256) {
        throw "Prepared installer SHA256 manifest is missing; refusing firmware fallback."
    }
    $expectedPaths = @(Get-InstallerManifestRelativePaths)
    $savedProperties = @($state.InstallerFileSha256.PSObject.Properties)
    if ($savedProperties.Count -ne $expectedPaths.Count) {
        throw "Prepared installer SHA256 manifest is incomplete; refusing firmware fallback."
    }
    foreach ($relativePath in $expectedPaths) {
        $saved = $state.InstallerFileSha256.PSObject.Properties[$relativePath]
        if (-not $saved -or [string]::IsNullOrWhiteSpace([string]$saved.Value)) {
            throw "Prepared installer SHA256 manifest has no hash for $relativePath"
        }
        $fullPath = Join-Path "$InstallerDrive\" $relativePath
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "Prepared installer verification failed; missing $relativePath"
        }
        $actual = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($actual -ne ([string]$saved.Value).ToLowerInvariant()) {
            throw "Prepared installer SHA256 mismatch: $relativePath"
        }
    }
    Write-Log "Prepared installer SHA256 manifest verified ($($expectedPaths.Count) files)." "Green"
}

function Update-TransactionFirmwareState {
    param(
        [Parameter(Mandatory = $true)][uint16]$BootNumber,
        [Parameter(Mandatory = $true)][string]$BootVariable,
        [string]$FirmwareEntryId = "",
        [hashtable]$EspLoaderSha256 = @{},
        [uint16[]]$OriginalBootOrder = @()
    )

    $state = Get-TransactionPartitionState
    if (-not $state) {
        throw "Cannot save UEFI firmware state without a transaction state file."
    }

    $state | Add-Member -NotePropertyName BootStrategy -NotePropertyValue $BootStrategy -Force
    $state | Add-Member -NotePropertyName InstallerBootNumber -NotePropertyValue ([int]$BootNumber) -Force
    $state | Add-Member -NotePropertyName InstallerBootVariable -NotePropertyValue $BootVariable -Force
    $state | Add-Member -NotePropertyName FirmwareEntryId -NotePropertyValue $FirmwareEntryId -Force
    $state | Add-Member -NotePropertyName EspLoaderSha256 -NotePropertyValue $EspLoaderSha256 -Force
    $state | Add-Member -NotePropertyName OriginalBootOrder -NotePropertyValue @($OriginalBootOrder | ForEach-Object { [int]$_ }) -Force
    $state | Add-Member -NotePropertyName BootPreparedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString("o")) -Force
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $TransactionStatePath -Encoding UTF8
}

function Get-VerifiedTransactionPartition {
    $state = Get-TransactionPartitionState
    if (-not $state) {
        return $null
    }
    if ([int]$state.PartitionNumber -le 0) {
        return $null
    }
    $diskNumber = [int]$state.DiskNumber
    $disk = Get-Disk -Number $diskNumber -ErrorAction Stop
    if (([string]$disk.UniqueId).Trim() -ne ([string]$state.DiskUniqueId).Trim()) {
        throw "UEFI transaction partition identity does not match the saved state."
    }

    $matches = @(
        Get-Partition -DiskNumber $diskNumber -ErrorAction Stop |
            Where-Object {
                [int64]$_.Offset -eq [int64]$state.PartitionOffset -and
                [int64]$_.Size -eq [int64]$state.PartitionSize
            }
    )
    if ($matches.Count -ne 1) {
        throw "UEFI transaction partition geometry does not resolve to exactly one partition."
    }
    $partition = $matches[0]
    if ([int]$state.PartitionNumber -ne [int]$partition.PartitionNumber) {
        Write-Log "Windows renumbered the transaction partition from $($state.PartitionNumber) to $($partition.PartitionNumber); updating saved state." "Yellow"
        $state.PartitionNumber = [int]$partition.PartitionNumber
        $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $TransactionStatePath -Encoding UTF8
    }
    return $partition
}

function Invoke-Revert {
    Write-Log "Reverting Libertix UEFI installer changes..." "Cyan"

    $esp = $null
    try {
        $esp = Mount-Esp -Letter $EspLetter

        foreach ($relativeDir in @("EFI\LibertixInstaller")) {
            $path = Join-Path $esp $relativeDir
            if (Test-Path $path) {
                Write-Log "Removing ESP directory: $relativeDir" "Cyan"
                Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
            }
        }

        Remove-LibertixTemporaryFirmwareEntries
        Restore-OriginalFirmwareBootOrder

    } finally {
        if ($esp) { Dismount-Letter -Letter $EspLetter }
    }

    Remove-LibertixInstallerPartitionIfPresent
    $rollbackState = Get-TransactionPartitionState
    if (-not $rollbackState) {
        throw "Cannot restore C: without the saved transaction state."
    }
    Restore-LibertixCDriveInitialSize -State $rollbackState
    Remove-Item -LiteralPath $TransactionStatePath -Force -ErrorAction SilentlyContinue

    Write-Log "Revert complete." "Green"
}

function New-OrReuseInstallerPartition {
    param([Parameter(Mandatory = $true)][int]$SizeGB)

    $existingPartition = Get-VerifiedTransactionPartition
    if ($existingPartition) {
        if (-not $existingPartition.DriveLetter) {
            Set-Partition `
                -DiskNumber $existingPartition.DiskNumber `
                -PartitionNumber $existingPartition.PartitionNumber `
                -NewDriveLetter $InstallerLetter `
                -ErrorAction Stop
            $existingPartition = Get-Partition `
                -DiskNumber $existingPartition.DiskNumber `
                -PartitionNumber $existingPartition.PartitionNumber `
                -ErrorAction Stop
        }
        $existingVolume = $existingPartition | Get-Volume -ErrorAction Stop
        if ($existingVolume.FileSystemLabel -ne $InstallerLabel) {
            throw "Saved transaction partition label changed; refusing reuse."
        }
        $existing = "$($existingPartition.DriveLetter):"
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
    if (Test-LibertixInstallerPartitionPresent) {
        throw "$InstallerLabel exists without an owned transaction state; refusing reuse."
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

    Write-Log "Creating ${SizeGB}GB FAT32 installer partition '$InstallerLabel'..." "Cyan"

    Save-TransactionPreparationState -SystemPartition $cPart
    Resize-Partition -DriveLetter C -Size ($cPart.Size - $shrinkBytes)
    Start-Sleep -Seconds 2

    $newPartition = New-Partition `
        -DiskNumber $cPart.DiskNumber `
        -Size $shrinkBytes `
        -DriveLetter $InstallerLetter

    Format-Volume `
        -DriveLetter $InstallerLetter `
        -FileSystem FAT32 `
        -NewFileSystemLabel $InstallerLabel `
        -Confirm:$false `
        -Force | Out-Null

    $tries = 0
    while (-not (Test-Path "${InstallerLetter}:\") -and $tries -lt 15) {
        Start-Sleep -Seconds 1
        $tries++
    }

    if (-not (Test-Path "${InstallerLetter}:\")) {
        throw "Failed to create/assign ${InstallerLetter}: for Libertix installer partition."
    }

    $verifiedPartition = Get-LibertixInstallerPartition -DriveLetter $InstallerLetter
    if (-not $verifiedPartition) {
        throw "Libertix installer partition was created, but its partition object could not be resolved."
    }
    # Formatting can cause Windows to renumber a GPT partition that was inserted
    # before WinRE. Persist the post-format object, not New-Partition's stale one.
    Save-TransactionPartitionState -Partition $verifiedPartition
    $guid = $null
    if ($verifiedPartition.Guid) {
        $guid = Get-GuidDLower -Guid $verifiedPartition.Guid
    }

    Ensure-VolumeNotEncrypted -DriveLetter $InstallerLetter

    return @{
        Drive = "${InstallerLetter}:"
        GuidD = $guid
        DiskNumber = $verifiedPartition.DiskNumber
        PartitionNumber = $verifiedPartition.PartitionNumber
    }
}

function Get-ReusablePreparedInstallerPartition {
    $partition = Get-VerifiedTransactionPartition
    if (-not $partition) {
        throw "Owned prepared installer partition is missing; refusing firmware fallback."
    }
    if (-not $partition.DriveLetter) {
        Set-Partition `
            -DiskNumber $partition.DiskNumber `
            -PartitionNumber $partition.PartitionNumber `
            -NewDriveLetter $InstallerLetter `
            -ErrorAction Stop
        $partition = Get-Partition `
            -DiskNumber $partition.DiskNumber `
            -PartitionNumber $partition.PartitionNumber `
            -ErrorAction Stop
    }
    $volume = $partition | Get-Volume -ErrorAction Stop
    if ($volume.FileSystem -ne "FAT32") {
        throw "Prepared installer partition is not FAT32; refusing firmware fallback."
    }
    if ($volume.FileSystemLabel -ne $InstallerLabel) {
        throw "Prepared installer partition label changed; refusing firmware fallback."
    }
    if ($volume.HealthStatus -ne "Healthy") {
        throw "Prepared installer partition is not healthy; refusing firmware fallback."
    }
    $drive = "$($partition.DriveLetter):"
    if (-not (Test-Path "$drive\")) {
        throw "Prepared installer partition is not accessible after drive-letter assignment."
    }
    return @{
        Drive = $drive
        DiskNumber = [int]$partition.DiskNumber
        PartitionNumber = [int]$partition.PartitionNumber
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

        if ($LowMemoryMode) {
            Copy-Item -LiteralPath $isoPath -Destination $LowMemoryIsoPath -Force
            $lowMemoryHash = (Get-FileHash -Algorithm SHA256 -Path $LowMemoryIsoPath).Hash.ToLowerInvariant()
            if ($lowMemoryHash -ne $InstallerIsoSha256) {
                throw "Low-memory ISO copy hash mismatch. Expected $InstallerIsoSha256, got $lowMemoryHash"
            }
            Write-Log "Low-memory ISO retained at $LowMemoryIsoPath." "Green"
        }

        Write-Log "Mounting ISO..." "Cyan"
        Mount-DiskImage -ImagePath $isoPath -PassThru | Out-Null
        $isoDrive = Get-MountedIsoDrive -ImagePath $isoPath

        $src = "$isoDrive\*"
        $dst = "$PartitionDrive\"

        Write-Log "Copying ISO contents to $PartitionDrive..." "Cyan"
        Copy-Item -Path $src -Destination $dst -Recurse -Force

        # live-boot discovers images with a case-sensitive *.squashfs glob.
        # Its toram copy also recreates directory names on a case-sensitive
        # tmpfs. Windows can expose ISO9660-only names in uppercase while
        # copying to FAT, so force the long VFAT names used by the initramfs.
        $expectedLiveDirectory = Join-Path $PartitionDrive "live"
        $actualLiveDirectories = @(
            Get-ChildItem -LiteralPath $PartitionDrive -Directory -ErrorAction Stop |
                Where-Object { $_.Name -ieq "live" }
        )
        if ($actualLiveDirectories.Count -ne 1) {
            throw "Expected exactly one copied live directory; found $($actualLiveDirectories.Count)."
        }
        if ($actualLiveDirectories[0].Name -cne "live") {
            $temporaryLiveDirectory = Join-Path $PartitionDrive ".libertix-live-case-$([Guid]::NewGuid().ToString('N'))"
            Move-Item -LiteralPath $actualLiveDirectories[0].FullName -Destination $temporaryLiveDirectory -Force
            Move-Item -LiteralPath $temporaryLiveDirectory -Destination $expectedLiveDirectory -Force
        }
        if ((Get-Item -LiteralPath $expectedLiveDirectory -ErrorAction Stop).Name -cne "live") {
            throw "Live directory name case normalization failed."
        }

        foreach ($relativePath in @(
            "live\filesystem.squashfs",
            "live\initrd.img",
            "live\vmlinuz"
        )) {
            $expectedPath = Join-Path $PartitionDrive $relativePath
            $parent = Split-Path -Parent $expectedPath
            $expectedName = Split-Path -Leaf $expectedPath
            $actual = @(
                Get-ChildItem -LiteralPath $parent -File -ErrorAction Stop |
                    Where-Object { $_.Name -ieq $expectedName }
            )
            if ($actual.Count -ne 1) {
                throw "Expected exactly one copied live file for $relativePath; found $($actual.Count)."
            }
            if ($actual[0].Name -cne $expectedName) {
                $temporaryPath = Join-Path $parent ".libertix-case-$([Guid]::NewGuid().ToString('N'))"
                Move-Item -LiteralPath $actual[0].FullName -Destination $temporaryPath -Force
                Move-Item -LiteralPath $temporaryPath -Destination $expectedPath -Force
            }
            $verifiedName = (Get-Item -LiteralPath $expectedPath -ErrorAction Stop).Name
            if ($verifiedName -cne $expectedName) {
                throw "Live file name case normalization failed: expected $expectedName, got $verifiedName."
            }
        }

        if ($LowMemoryMode) {
            $bootConfigs = @(Get-ChildItem -Path $PartitionDrive -Filter "*.cfg" -Recurse -File)
            if ($bootConfigs.Count -eq 0) {
                throw "No boot configuration was found for low-memory mode."
            }
            foreach ($bootConfig in $bootConfigs) {
                $content = Get-Content -LiteralPath $bootConfig.FullName -Raw
                $updated = $content -replace '(?i)(^|\s)toram(?=\s|$)', '$1findiso=/libertix-live.iso'
                if ($updated -eq $content -and $content -notmatch 'findiso=/libertix-live\.iso') {
                    continue
                }
                Set-Content -LiteralPath $bootConfig.FullName -Value $updated -Encoding ASCII -NoNewline
            }
            $configured = @(Get-ChildItem -Path $PartitionDrive -Filter "*.cfg" -Recurse -File | Where-Object {
                (Get-Content -LiteralPath $_.FullName -Raw) -match 'findiso=/libertix-live\.iso'
            })
            if ($configured.Count -eq 0) {
                throw "Low-memory boot configuration could not be applied."
            }
            Write-Log "Low-memory findiso boot configured in $($configured.Count) boot files." "Green"
        }

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
        [Parameter(Mandatory = $true)][int]$InstallerPartitionNumber,
        [switch]$ReusePreparedInstaller = $false
    )

    Write-Log "Configuring one-time UEFI boot entry..." "Cyan"

    if (-not (Test-Path "$InstallerDrive\")) {
        $InstallerDrive = Ensure-VolumeLetterByLabel -Label $InstallerLabel -Letter $InstallerLetter
        if (-not $InstallerDrive -or -not (Test-Path "$InstallerDrive\")) {
            throw "Cannot assign a drive letter to the Libertix installer partition before UEFI boot setup."
        }
    }

    $espDrive = $null
    $loaderHashes = @{}
    $espPartition = Get-WindowsEspPartition
    $loaderPath = "\$InstallerEspDirectory\BOOTX64.EFI"
    try {
        $espDrive = Mount-Esp -Letter $EspLetter
        if ($ReusePreparedInstaller) {
            $state = Get-TransactionPartitionState
            if (-not $state -or -not $state.EspLoaderSha256) {
                throw "Temporary ESP loader SHA256 state is missing; refusing firmware fallback."
            }
            $destination = Join-Path $espDrive $InstallerEspDirectory
            foreach ($relativePath in @("BOOTX64.EFI", "grubx64.efi", "mmx64.efi", "grub.cfg")) {
                $saved = $state.EspLoaderSha256.PSObject.Properties[$relativePath]
                if (-not $saved -or [string]::IsNullOrWhiteSpace([string]$saved.Value)) {
                    throw "Temporary ESP loader SHA256 state has no hash for $relativePath"
                }
                $fullPath = Join-Path $destination $relativePath
                if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
                    throw "Temporary ESP loader is missing: $relativePath"
                }
                $actual = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                if ($actual -ne ([string]$saved.Value).ToLowerInvariant()) {
                    throw "Temporary ESP loader SHA256 mismatch: $relativePath"
                }
                $loaderHashes[$relativePath] = $actual
            }
            Write-Log "Temporary ESP loader SHA256 verified ($($loaderHashes.Count) files)." "Green"
        } else {
            $loaderHashes = Install-LibertixTemporaryBootloaderOnEsp -EspDrive $espDrive -InstallerDrive $InstallerDrive
        }
    } finally {
        if ($espDrive) {
            Dismount-Letter -Letter ($espDrive.Substring(0, 1))
        }
    }

    if (-not $espPartition) {
        throw "Windows ESP partition could not be resolved for UEFI boot setup."
    }

    powercfg /h off 2>&1 | Out-Null

    if (-not $ReusePreparedInstaller) {
        $driveRoot = "$InstallerDrive\"
        $grubConfig = @"
set default=0
set timeout=0
set timeout_style=hidden
set hidden_timeout=0
set hidden_timeout_quiet=true

search --no-floppy --label $InstallerLabel --set=root

menuentry "Install Linux Mint (Automatic)" {
    linux /live/vmlinuz boot=live toram components quiet splash silent plymouth.ignore-serial-consoles loglevel=3 systemd.show_status=0 console=ttyS0,115200n8 console=tty1
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
    }

    Remove-LibertixTemporaryFirmwareEntries
    foreach ($identifier in @("{bootmgr}", "{fwbootmgr}")) {
        try {
            Invoke-BcdeditCommand -Arguments @("/deletevalue", $identifier, "bootsequence") | Out-Null
        } catch {
            # Missing one-shot sequences are the expected clean state.
        }
    }

    $transactionState = Get-TransactionPartitionState
    $originalBootOrder = if (
        $ReusePreparedInstaller -and $transactionState -and $transactionState.OriginalBootOrder
    ) {
        @($transactionState.OriginalBootOrder | ForEach-Object { [uint16]$_ })
    } else {
        @(ConvertFrom-BootOrderBytes -Bytes (Get-FirmwareVariableBytes -Name "BootOrder"))
    }
    if ($originalBootOrder.Count -eq 0) {
        throw "UEFI BootOrder is empty; refusing to prepare a temporary boot entry."
    }

    if ($BootStrategy -eq "BootNext") {
        $bootVariable = Set-NativeUefiBootOrderOnce `
            -InstallerDrive "${EspLetter}:" `
            -InstallerDiskNumber $espPartition.DiskNumber `
            -InstallerPartitionNumber $espPartition.PartitionNumber `
            -LoaderPath $loaderPath
        if ($bootVariable -notmatch "^Boot([0-9A-Fa-f]{4})$") {
            throw "Unexpected native UEFI boot variable name: $bootVariable"
        }

        $bootNumber = [Convert]::ToUInt16($Matches[1], 16)
        Assert-LibertixFirmwareEntry -BootNumber $bootNumber -LoaderPath $loaderPath
        Set-FirmwareVariable -Name "BootNext" -Value (ConvertTo-BootOrderBytes -Order @($bootNumber))
        $bootNext = @(ConvertFrom-BootOrderBytes -Bytes (Get-FirmwareVariableBytes -Name "BootNext"))
        if ($bootNext.Count -ne 1 -or [uint16]$bootNext[0] -ne $bootNumber) {
            throw "UEFI BootNext read-back does not point to $bootVariable."
        }
        Update-TransactionFirmwareState `
            -BootNumber $bootNumber `
            -BootVariable $bootVariable `
            -EspLoaderSha256 $loaderHashes `
            -OriginalBootOrder $originalBootOrder
        Write-Log "BootNext verified: $bootVariable -> ESP:$loaderPath" "Green"
        return
    }

    $fallbackEspDrive = $null
    try {
        $fallbackEspDrive = Mount-Esp -Letter $EspLetter
        $firmwareEntry = New-LibertixBcdFirmwareEntry `
            -EspDrive $fallbackEspDrive `
            -LoaderPath $loaderPath
    } finally {
        if ($fallbackEspDrive) {
            Dismount-Letter -Letter $EspLetter
        }
    }
    $fallbackOrder = @(
        ConvertFrom-BootOrderBytes -Bytes (Get-FirmwareVariableBytes -Name "BootOrder")
    )
    if ($fallbackOrder.Count -eq 0 -or [uint16]$fallbackOrder[0] -ne $firmwareEntry.BootNumber) {
        throw "BCD firmware fallback did not place $($firmwareEntry.BootVariable) first in UEFI BootOrder."
    }
    try { Remove-FirmwareVariable -Name "BootNext" } catch {}
    Update-TransactionFirmwareState `
        -BootNumber $firmwareEntry.BootNumber `
        -BootVariable $firmwareEntry.BootVariable `
        -FirmwareEntryId $firmwareEntry.EntryId `
        -EspLoaderSha256 $loaderHashes `
        -OriginalBootOrder $originalBootOrder
    Write-Log "Firmware BootOrder fallback verified: $($firmwareEntry.BootVariable) -> ESP:$loaderPath" "Green"
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
    $already = Invoke-BcdeditCommand -Arguments @("/enum", "firmware") |
        Select-String -Pattern "Libertix UEFI Installer"
    if ($already) {
        Write-Log "Libertix UEFI entry detected. Use -Force to recreate." "Yellow"
    }
}

try {
    if ($ReusePreparedInstaller) {
        if ($BootStrategy -ne "FirmwareBootOrder") {
            throw "Prepared installer reuse is only valid with FirmwareBootOrder."
        }
        Test-LibertixLiveConfig
        $info = Get-ReusablePreparedInstallerPartition
        $drive = $info["Drive"]
        Assert-PreparedInstallerManifest -InstallerDrive $drive
        Set-LibertixUefiBootEntry `
            -InstallerDrive $drive `
            -InstallerDiskNumber ([int]$info["DiskNumber"]) `
            -InstallerPartitionNumber ([int]$info["PartitionNumber"]) `
            -ReusePreparedInstaller
        Dismount-Letter -Letter ($drive.TrimEnd(":"))
        Write-Log "FALLBACK_REUSED_PREPARED_INSTALLER=true" "Green"
        Write-Log "Preparation complete; waiting for the user interface to confirm restart." "Cyan"
        exit 0
    }

    Test-LibertixLiveConfig
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
    Write-LibertixLiveConfig -PartitionDrive $drive

    Set-LibertixUefiBootEntry `
        -InstallerDrive $drive `
        -InstallerDiskNumber $installerDiskNumber `
        -InstallerPartitionNumber $installerPartitionNumber
    Save-PreparedInstallerManifest -InstallerDrive $drive

    Dismount-Letter -Letter ($drive.TrimEnd(":"))

    Write-Host ""
    Write-Log "Complete. Next boot should start Libertix UEFI installer once." "Green"
    Write-Host ""
    Write-Host "First boot: signed shim/GRUB should start the Libertix live installer." `
        -ForegroundColor Yellow

    Write-Log "Preparation complete; waiting for the user interface to confirm restart." "Cyan"
    exit 0
} catch {
    $preparationError = $_
    Write-Log $preparationError.Exception.Message "Red"
    Write-ExceptionDiagnostics -ErrorRecord $preparationError
    Write-Log "Error during preparation; running automatic revert..." "Yellow"
    try {
        Invoke-Revert
    } catch {
        $revertError = $_
        Write-Log "Automatic revert failed: $($revertError.Exception.Message)" "Red"
        Write-ExceptionDiagnostics -ErrorRecord $revertError
        Write-Log "Tip: you can run with -Revert to restore Windows boot." "Yellow"
    }
    exit 1
}
