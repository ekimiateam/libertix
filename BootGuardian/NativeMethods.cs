using System;
using System.Runtime.InteropServices;

namespace Libertix.BootGuardian
{
    internal static class NativeMethods
    {
        internal const int ErrorInsufficientBuffer = 122;
        internal const int ErrorEnvVarNotFound = 203;
        internal const int ErrorNotAllAssigned = 1300;
        internal const uint MoveFileReplaceExisting = 0x00000001;
        internal const uint MoveFileWriteThrough = 0x00000008;
        internal const uint ServiceWin32OwnProcess = 0x00000010;
        internal const uint ServiceAutoStart = 0x00000002;
        internal const uint ServiceErrorNormal = 0x00000001;
        internal const uint ServiceAllAccess = 0x000F01FF;
        internal const uint ScManagerConnect = 0x0001;
        internal const uint ScManagerCreateService = 0x0002;
        internal const uint Delete = 0x00010000;
        internal const uint ServiceControlStop = 0x00000001;
        internal const uint ServiceControlShutdown = 0x00000005;
        internal const uint ServiceControlPreshutdown = 0x0000000F;
        internal const uint ServiceStopped = 0x00000001;
        internal const uint ServiceStartPending = 0x00000002;
        internal const uint ServiceStopPending = 0x00000003;
        internal const uint ServiceRunning = 0x00000004;
        internal const uint ServiceAcceptStop = 0x00000001;
        internal const uint ServiceAcceptShutdown = 0x00000004;
        internal const uint ServiceAcceptPreshutdown = 0x00000100;
        internal const uint ServiceConfigRequiredPrivilegesInfo = 6;
        internal const uint ServiceConfigPreshutdownInfo = 7;
        internal const uint TokenAdjustPrivileges = 0x0020;
        internal const uint TokenQuery = 0x0008;
        internal const uint SePrivilegeEnabled = 0x00000002;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        internal struct ServiceTableEntry
        {
            internal string ServiceName;
            internal ServiceMainFunction ServiceMain;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct ServiceStatus
        {
            internal uint ServiceType;
            internal uint CurrentState;
            internal uint ControlsAccepted;
            internal uint Win32ExitCode;
            internal uint ServiceSpecificExitCode;
            internal uint CheckPoint;
            internal uint WaitHint;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct ServicePreshutdownInfo
        {
            internal uint PreshutdownTimeout;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct ServiceRequiredPrivilegesInfo
        {
            internal IntPtr RequiredPrivileges;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct Luid
        {
            internal uint LowPart;
            internal int HighPart;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct TokenPrivileges
        {
            internal uint PrivilegeCount;
            internal Luid Luid;
            internal uint Attributes;
        }

        internal delegate void ServiceMainFunction(uint argumentCount, IntPtr arguments);
        internal delegate uint HandlerExFunction(uint control, uint eventType, IntPtr eventData, IntPtr context);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool StartServiceCtrlDispatcher(ServiceTableEntry[] table);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern IntPtr RegisterServiceCtrlHandlerEx(
            string serviceName,
            HandlerExFunction handler,
            IntPtr context);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetServiceStatus(IntPtr statusHandle, ref ServiceStatus status);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern IntPtr OpenSCManager(string machineName, string databaseName, uint access);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern IntPtr CreateService(
            IntPtr manager,
            string serviceName,
            string displayName,
            uint desiredAccess,
            uint serviceType,
            uint startType,
            uint errorControl,
            string binaryPath,
            string loadOrderGroup,
            IntPtr tagId,
            string dependencies,
            string serviceStartName,
            string password);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern IntPtr OpenService(IntPtr manager, string serviceName, uint access);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool ChangeServiceConfig(
            IntPtr service,
            uint serviceType,
            uint startType,
            uint errorControl,
            string binaryPath,
            string loadOrderGroup,
            IntPtr tagId,
            string dependencies,
            string serviceStartName,
            string password,
            string displayName);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool ChangeServiceConfig2(IntPtr service, uint infoLevel, IntPtr info);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool StartService(IntPtr service, uint argumentCount, IntPtr arguments);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool ControlService(IntPtr service, uint control, ref ServiceStatus status);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool DeleteService(IntPtr service);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CloseServiceHandle(IntPtr handle);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool LookupPrivilegeValue(string systemName, string name, out Luid luid);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool OpenProcessToken(IntPtr process, uint desiredAccess, out IntPtr token);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool AdjustTokenPrivileges(
            IntPtr token,
            [MarshalAs(UnmanagedType.Bool)] bool disableAll,
            ref TokenPrivileges newState,
            uint bufferLength,
            IntPtr previousState,
            IntPtr returnLength);

        [DllImport("kernel32.dll")]
        internal static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll")]
        internal static extern void SetLastError(uint errorCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern uint GetFirmwareEnvironmentVariableEx(
            string name,
            string guid,
            byte[] buffer,
            uint size,
            out uint attributes);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetFirmwareEnvironmentVariableEx(
            string name,
            string guid,
            byte[] value,
            uint size,
            uint attributes);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetVolumeMountPoint(string mountPoint, string volumeName);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool DeleteVolumeMountPoint(string mountPoint);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetVolumeNameForVolumeMountPoint(
            string mountPoint,
            System.Text.StringBuilder volumeName,
            uint bufferLength);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool MoveFileEx(string existingName, string newName, uint flags);
    }
}
