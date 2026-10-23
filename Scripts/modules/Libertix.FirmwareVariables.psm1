Set-StrictMode -Version Latest

$script:FirmwareVariablePrivilegeEnabled = $false

function Initialize-LibertixFirmwareVariableApi {
    if (([System.Management.Automation.PSTypeName]"LibertixFirmwareVariableApi").Type) {
        return
    }

    Add-Type @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class LibertixFirmwareVariableApi {
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
        if (!OpenProcessToken(
            GetCurrentProcess(),
            TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY,
            out token
        )) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        try {
            LUID luid;
            if (!LookupPrivilegeValue(null, "SeSystemEnvironmentPrivilege", out luid)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            TOKEN_PRIVILEGES privileges = new TOKEN_PRIVILEGES();
            privileges.PrivilegeCount = 1;
            privileges.Luid = luid;
            privileges.Attributes = SE_PRIVILEGE_ENABLED;
            if (!AdjustTokenPrivileges(
                token,
                false,
                ref privileges,
                0,
                IntPtr.Zero,
                IntPtr.Zero
            )) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            int error = Marshal.GetLastWin32Error();
            if (error != 0) {
                throw new Win32Exception(error);
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

function Enable-LibertixFirmwareVariableAccess {
    if ($script:FirmwareVariablePrivilegeEnabled) {
        return
    }
    Initialize-LibertixFirmwareVariableApi
    [LibertixFirmwareVariableApi]::EnableSystemEnvironmentPrivilege()
    $script:FirmwareVariablePrivilegeEnabled = $true
}

function Get-LibertixFirmwareVariableBytes {
    param([Parameter(Mandatory = $true)][string]$Name)

    Enable-LibertixFirmwareVariableAccess
    $globalVariableGuid = "{8BE4DF61-93CA-11D2-AA0D-00E098032B8C}"
    $buffer = New-Object byte[] 65536
    $size = [LibertixFirmwareVariableApi]::GetFirmwareEnvironmentVariable(
        $Name,
        $globalVariableGuid,
        $buffer,
        [uint32]$buffer.Length
    )
    if ($size -eq 0) {
        $errorCode = [LibertixFirmwareVariableApi]::LastError()
        if ($errorCode -in @(2, 203)) {
            return $null
        }
        throw "GetFirmwareEnvironmentVariable failed for ${Name}: Win32 error ${errorCode}"
    }
    $result = New-Object byte[] $size
    [Array]::Copy($buffer, $result, $size)
    return [byte[]]$result
}

function Set-LibertixFirmwareVariableBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    if ($Bytes.Length -eq 0) {
        throw "Firmware variable value must not be empty."
    }
    Enable-LibertixFirmwareVariableAccess
    $globalVariableGuid = "{8BE4DF61-93CA-11D2-AA0D-00E098032B8C}"
    $attributes = [uint32]0x00000007
    if (-not [LibertixFirmwareVariableApi]::SetFirmwareEnvironmentVariableEx(
        $Name,
        $globalVariableGuid,
        $Bytes,
        [uint32]$Bytes.Length,
        $attributes
    )) {
        $errorCode = [LibertixFirmwareVariableApi]::LastError()
        throw "SetFirmwareEnvironmentVariableEx failed for ${Name}: Win32 error ${errorCode}"
    }
}

Export-ModuleMember -Function `
    Initialize-LibertixFirmwareVariableApi, `
    Get-LibertixFirmwareVariableBytes, `
    Set-LibertixFirmwareVariableBytes
