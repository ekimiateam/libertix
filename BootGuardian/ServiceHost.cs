using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace Libertix.BootGuardian
{
    internal static class ServiceHost
    {
        internal const string ServiceName = "LibertixBootGuardian";
        private const uint NoChange = 0xFFFFFFFF;
        private const int ErrorServiceAlreadyRunning = 1056;
        private const int ErrorServiceDoesNotExist = 1060;
        private const int ErrorServiceNotActive = 1062;
        private static readonly NativeMethods.ServiceMainFunction ServiceMainDelegate = ServiceMain;
        private static readonly NativeMethods.HandlerExFunction HandlerDelegate = Handler;
        private static readonly ManualResetEvent StopEvent = new ManualResetEvent(false);
        private static IntPtr _statusHandle;
        private static int _stopping;
        private static int _checkpoint;

        internal static string ConfigPath => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "Libertix",
            "BootGuardian",
            "config.json");

        internal static void Run()
        {
            var table = new[]
            {
                new NativeMethods.ServiceTableEntry
                {
                    ServiceName = ServiceName,
                    ServiceMain = ServiceMainDelegate
                },
                new NativeMethods.ServiceTableEntry()
            };
            if (!NativeMethods.StartServiceCtrlDispatcher(table))
                throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        internal static void Install(string executablePath)
        {
            if (!Path.IsPathRooted(executablePath) || !File.Exists(executablePath))
                throw new FileNotFoundException("Boot guardian service executable is missing.", executablePath);
            IntPtr manager = NativeMethods.OpenSCManager(
                null,
                null,
                NativeMethods.ScManagerConnect | NativeMethods.ScManagerCreateService);
            if (manager == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error());
            IntPtr service = IntPtr.Zero;
            try
            {
                string command = "\"" + Path.GetFullPath(executablePath) + "\"";
                service = NativeMethods.OpenService(manager, ServiceName, NativeMethods.ServiceAllAccess);
                if (service == IntPtr.Zero)
                {
                    int openError = Marshal.GetLastWin32Error();
                    if (openError != ErrorServiceDoesNotExist)
                        throw new Win32Exception(openError);
                    service = NativeMethods.CreateService(
                        manager,
                        ServiceName,
                        "Libertix boot integrity guardian",
                        NativeMethods.ServiceAllAccess,
                        NativeMethods.ServiceWin32OwnProcess,
                        NativeMethods.ServiceAutoStart,
                        NativeMethods.ServiceErrorNormal,
                        command,
                        null,
                        IntPtr.Zero,
                        null,
                        "LocalSystem",
                        null);
                    if (service == IntPtr.Zero)
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                else if (!NativeMethods.ChangeServiceConfig(
                    service,
                    NativeMethods.ServiceWin32OwnProcess,
                    NativeMethods.ServiceAutoStart,
                    NativeMethods.ServiceErrorNormal,
                    command,
                    null,
                    IntPtr.Zero,
                    null,
                    "LocalSystem",
                    null,
                    "Libertix boot integrity guardian"))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }

                ConfigurePreshutdown(service);
                ConfigureRequiredPrivileges(service);
                if (!NativeMethods.StartService(service, 0, IntPtr.Zero))
                {
                    int error = Marshal.GetLastWin32Error();
                    if (error != ErrorServiceAlreadyRunning)
                        throw new Win32Exception(error);
                }
            }
            finally
            {
                if (service != IntPtr.Zero)
                    NativeMethods.CloseServiceHandle(service);
                NativeMethods.CloseServiceHandle(manager);
            }
        }

        internal static void Uninstall()
        {
            IntPtr manager = NativeMethods.OpenSCManager(null, null, NativeMethods.ScManagerConnect);
            if (manager == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error());
            IntPtr service = IntPtr.Zero;
            try
            {
                service = NativeMethods.OpenService(
                    manager,
                    ServiceName,
                    NativeMethods.ServiceAllAccess | NativeMethods.Delete);
                if (service == IntPtr.Zero)
                {
                    int error = Marshal.GetLastWin32Error();
                    if (error == ErrorServiceDoesNotExist)
                        return;
                    throw new Win32Exception(error);
                }
                var status = new NativeMethods.ServiceStatus();
                if (!NativeMethods.ControlService(service, NativeMethods.ServiceControlStop, ref status))
                {
                    int error = Marshal.GetLastWin32Error();
                    if (error != ErrorServiceNotActive)
                        throw new Win32Exception(error);
                }
                if (!NativeMethods.DeleteService(service))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            finally
            {
                if (service != IntPtr.Zero)
                    NativeMethods.CloseServiceHandle(service);
                NativeMethods.CloseServiceHandle(manager);
            }
        }

        private static void ConfigurePreshutdown(IntPtr service)
        {
            var info = new NativeMethods.ServicePreshutdownInfo { PreshutdownTimeout = 10000 };
            IntPtr pointer = Marshal.AllocHGlobal(Marshal.SizeOf(info));
            try
            {
                Marshal.StructureToPtr(info, pointer, false);
                if (!NativeMethods.ChangeServiceConfig2(
                    service, NativeMethods.ServiceConfigPreshutdownInfo, pointer))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            finally { Marshal.FreeHGlobal(pointer); }
        }

        private static void ConfigureRequiredPrivileges(IntPtr service)
        {
            IntPtr names = Marshal.StringToHGlobalUni("SeSystemEnvironmentPrivilege\0");
            IntPtr infoPointer = IntPtr.Zero;
            try
            {
                var info = new NativeMethods.ServiceRequiredPrivilegesInfo { RequiredPrivileges = names };
                infoPointer = Marshal.AllocHGlobal(Marshal.SizeOf(info));
                Marshal.StructureToPtr(info, infoPointer, false);
                if (!NativeMethods.ChangeServiceConfig2(
                    service, NativeMethods.ServiceConfigRequiredPrivilegesInfo, infoPointer))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            finally
            {
                if (infoPointer != IntPtr.Zero)
                    Marshal.FreeHGlobal(infoPointer);
                Marshal.FreeHGlobal(names);
            }
        }

        private static void ServiceMain(uint argumentCount, IntPtr arguments)
        {
            Interlocked.Exchange(ref _stopping, 0);
            Interlocked.Exchange(ref _checkpoint, 1);
            StopEvent.Reset();
            _statusHandle = NativeMethods.RegisterServiceCtrlHandlerEx(
                ServiceName, HandlerDelegate, IntPtr.Zero);
            if (_statusHandle == IntPtr.Zero)
            {
                LogServiceStatusFailure("register control handler", Marshal.GetLastWin32Error());
                return;
            }
            if (!SetStatus(NativeMethods.ServiceStartPending, 0, 0, 3000) || !SetStatus(
                NativeMethods.ServiceRunning,
                NativeMethods.ServiceAcceptStop |
                NativeMethods.ServiceAcceptShutdown |
                NativeMethods.ServiceAcceptPreshutdown,
                0,
                0))
            {
                StopEvent.Set();
                return;
            }
            StopEvent.WaitOne();
        }

        private static uint Handler(uint control, uint eventType, IntPtr eventData, IntPtr context)
        {
            if (control == NativeMethods.ServiceControlPreshutdown)
            {
                if (Interlocked.Exchange(ref _stopping, 1) == 0)
                {
                    SetStatus(NativeMethods.ServiceStopPending, 0, (uint)_checkpoint, 10000);
                    var worker = new Thread(RunPreshutdown) { IsBackground = false };
                    worker.Start();
                }
                return 0;
            }
            if (control == NativeMethods.ServiceControlStop || control == NativeMethods.ServiceControlShutdown)
            {
                if (Interlocked.Exchange(ref _stopping, 1) == 0)
                {
                    SetStatus(NativeMethods.ServiceStopped, 0, 0, 0);
                    StopEvent.Set();
                }
                return 0;
            }
            return 0;
        }

        private static void RunPreshutdown()
        {
            bool succeeded = new BootGuardianEngine().Execute(
                ConfigPath,
                TimeSpan.FromMilliseconds(8500),
                remainingMilliseconds =>
                {
                    uint checkpoint = (uint)Interlocked.Increment(ref _checkpoint);
                    uint waitHint = (uint)Math.Max(1, Math.Min(10000, remainingMilliseconds));
                    SetStatus(NativeMethods.ServiceStopPending, 0, checkpoint, waitHint);
                });
            SetStatus(NativeMethods.ServiceStopped, 0, 0, 0, succeeded ? 0u : 1u);
            StopEvent.Set();
        }

        private static bool SetStatus(
            uint state,
            uint accepted,
            uint checkpoint,
            uint waitHint,
            uint exitCode = 0)
        {
            var status = new NativeMethods.ServiceStatus
            {
                ServiceType = NativeMethods.ServiceWin32OwnProcess,
                CurrentState = state,
                ControlsAccepted = accepted,
                Win32ExitCode = exitCode,
                ServiceSpecificExitCode = 0,
                CheckPoint = checkpoint,
                WaitHint = waitHint
            };
            if (NativeMethods.SetServiceStatus(_statusHandle, ref status))
                return true;
            LogServiceStatusFailure("publish service state " + state, Marshal.GetLastWin32Error());
            return false;
        }

        private static void LogServiceStatusFailure(string operation, int error)
        {
            try
            {
                RepairJournal.WriteUncorrelatedError(
                    new Win32Exception(error, "Boot guardian could not " + operation + "."));
            }
            catch { }
        }
    }
}
