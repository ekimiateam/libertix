$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$failed = $false
Write-Output 'LIBERTIX_DIAGNOSTICS_STARTED'

function Get-DiagnosticSessions {
    $native = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { 'Sysnative' } else { 'System32' }
    $quser = Join-Path $env:SystemRoot "$native\quser.exe"
    Write-Output "Session collector: nativeDirectory=$native is64BitProcess=$([Environment]::Is64BitProcess) quserPresent=$([IO.File]::Exists($quser))"
    if ([IO.File]::Exists($quser)) {
        & $quser
        if ($LASTEXITCODE -ne 0) { throw "quser exited with $LASTEXITCODE" }
        return
    }
    # WTS is available even on Windows images without the Remote Desktop CLI tools.
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class DiagnosticSessions {
    [StructLayout(LayoutKind.Sequential)]
    public struct Session { public int Id; public IntPtr Name; public int State; }
    [DllImport("wtsapi32.dll", EntryPoint="WTSEnumerateSessionsW", SetLastError=true)]
    public static extern bool Enumerate(IntPtr server, int reserved, int version, out IntPtr sessions, out int count);
    [DllImport("wtsapi32.dll", EntryPoint="WTSQuerySessionInformationW", SetLastError=true)]
    private static extern bool Query(IntPtr server, int id, int info, out IntPtr value, out int size);
    [DllImport("wtsapi32.dll", EntryPoint="WTSFreeMemory")]
    public static extern void Free(IntPtr memory);
    public static string User(int id) {
        IntPtr value; int size;
        if (!Query(IntPtr.Zero, id, 5, out value, out size)) throw new Win32Exception();
        try { return Marshal.PtrToStringUni(value); } finally { Free(value); }
    }
}
'@
    $buffer = [IntPtr]::Zero
    $count = 0
    if (-not [DiagnosticSessions]::Enumerate([IntPtr]::Zero, 0, 1, [ref]$buffer, [ref]$count)) {
        throw (New-Object ComponentModel.Win32Exception)
    }
    try {
        $size = [Runtime.InteropServices.Marshal]::SizeOf([type][DiagnosticSessions+Session])
        for ($index = 0; $index -lt $count; $index++) {
            $session = [Runtime.InteropServices.Marshal]::PtrToStructure([IntPtr]::Add($buffer, $index * $size), [type][DiagnosticSessions+Session])
            [pscustomobject]@{
                SessionId = $session.Id
                Station = [Runtime.InteropServices.Marshal]::PtrToStringUni($session.Name)
                State = $session.State
                UserName = [DiagnosticSessions]::User($session.Id)
            }
        }
    } finally { [DiagnosticSessions]::Free($buffer) }
}

$sections = [ordered]@{
    time = { Get-Date -Format o }
    operating_system = { Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, LastBootUpTime, FreePhysicalMemory, TotalVisibleMemorySize }
    sessions = { Get-DiagnosticSessions }
    processes = { Get-CimInstance Win32_Process | Select-Object Name, ProcessId, ParentProcessId, SessionId, CreationDate, KernelModeTime, UserModeTime, WorkingSetSize }
    services = {
        Get-CimInstance Win32_Service |
            Where-Object { $_.Name -match 'Libertix|sshd|Winmgmt|VSS|swprv|WinFsp|defragsvc|StorSvc|vds|wuauserv|UsoSvc|BITS' } |
            Select-Object Name, State, StartMode, ProcessId, CheckPoint, WaitHint, ExitCode, ServiceSpecificExitCode
    }
    tasks = { Get-ScheduledTask | Where-Object { $_.TaskName -like '*Libertix*' } | ForEach-Object { Get-ScheduledTaskInfo -InputObject $_ | Select-Object TaskName, LastRunTime, LastTaskResult, NextRunTime } }
    disks = { Get-Disk | Select-Object Number, FriendlyName, UniqueId, SerialNumber, Path, Guid, Signature, PartitionStyle, Size, OperationalStatus, HealthStatus, IsOffline, IsReadOnly }
    partitions = { Get-Partition | Select-Object DiskNumber, PartitionNumber, DriveLetter, Guid, GptType, MbrType, Offset, Size, Type }
    volumes = { Get-Volume | Select-Object DriveLetter, FileSystemLabel, FileSystem, Size, SizeRemaining, HealthStatus, OperationalStatus }
    encryption = {
        Get-CimInstance -Namespace 'root/CIMV2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume | ForEach-Object {
            $conversion = Invoke-CimMethod -InputObject $_ -MethodName GetConversionStatus
            [pscustomobject]@{
                DriveLetter = $_.DriveLetter
                ReturnValue = $conversion.ReturnValue
                ConversionStatus = $conversion.ConversionStatus
                EncryptionPercentage = $conversion.EncryptionPercentage
            }
        }
    }
    command_shell = {
        $shell = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\OpenSSH' -ErrorAction SilentlyContinue
        [pscustomobject]@{
            ComSpec = $env:ComSpec
            DefaultShell = $shell.DefaultShell
            PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        }
    }
    network = { Get-NetIPConfiguration | Format-List InterfaceAlias, IPv4Address, IPv4DefaultGateway, DNSServer }
    routes = { Get-NetRoute -AddressFamily IPv4 | Select-Object DestinationPrefix, NextHop, InterfaceAlias, RouteMetric }
    boot = { & bcdedit.exe /enum all; if ($LASTEXITCODE -ne 0) { throw "bcdedit exited with $LASTEXITCODE" } }
    system_events = {
        # Event metadata identifies failures without dumping payloads that may contain secrets.
        Get-WinEvent -LogName System -MaxEvents 100 | Select-Object TimeCreated, RecordId, Id, ActivityId, LevelDisplayName, ProviderName
    }
    windows_update_events = {
        # Restrict message payloads to the provider needed to diagnose servicing failures.
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient' } `
            -MaxEvents 30 -ErrorAction SilentlyContinue -ErrorVariable eventErrors)
        foreach ($eventError in $eventErrors) {
            if ($eventError.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { throw $eventError }
        }
        $events | Select-Object TimeCreated, RecordId, Id, LevelDisplayName, Message
    }
    servicing_restart = {
        foreach ($path in @(
            'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
            'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        )) {
            [pscustomobject]@{ Path = $path; Present = (Test-Path -LiteralPath $path) }
        }
    }
    application_events = {
        Get-WinEvent -LogName Application -MaxEvents 100 | Select-Object TimeCreated, RecordId, Id, ActivityId, LevelDisplayName, ProviderName
    }
}
foreach ($entry in $sections.GetEnumerator()) {
    Write-Output ("=== {0} ===" -f $entry.Key)
    try { & $entry.Value | Out-String -Width 240 | Write-Output }
    catch { $failed = $true; Write-Output ("COLLECTION_ERROR: {0}" -f $_.Exception.Message) }
}
Write-Output 'LIBERTIX_DIAGNOSTICS_COMPLETED'
if ($failed) { exit 1 }
