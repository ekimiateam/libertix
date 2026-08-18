using System.Runtime.InteropServices;

namespace Libertix.Helpers
{
    internal enum SystemPowerState
    {
        Unknown,
        NoSystemBattery,
        AcConnected,
        OnBattery
    }

    internal sealed class SystemPowerSnapshot
    {
        internal SystemPowerSnapshot(
            SystemPowerState state,
            byte acLineStatus,
            byte batteryFlag,
            int nativeErrorCode)
        {
            State = state;
            AcLineStatus = acLineStatus;
            BatteryFlag = batteryFlag;
            NativeErrorCode = nativeErrorCode;
        }

        internal SystemPowerState State { get; }
        internal byte AcLineStatus { get; }
        internal byte BatteryFlag { get; }
        internal int NativeErrorCode { get; }
    }

    internal static class SystemPowerProbe
    {
        internal static SystemPowerSnapshot Read()
        {
            if (!GetSystemPowerStatus(out NativeSystemPowerStatus status))
            {
                return new SystemPowerSnapshot(
                    SystemPowerState.Unknown,
                    byte.MaxValue,
                    byte.MaxValue,
                    Marshal.GetLastWin32Error());
            }

            return new SystemPowerSnapshot(
                Classify(status.AcLineStatus, status.BatteryFlag),
                status.AcLineStatus,
                status.BatteryFlag,
                0);
        }

        internal static SystemPowerState Classify(byte acLineStatus, byte batteryFlag)
        {
            const byte noSystemBattery = 128;
            if (batteryFlag == byte.MaxValue)
                return SystemPowerState.Unknown;
            if ((batteryFlag & noSystemBattery) != 0)
                return SystemPowerState.NoSystemBattery;
            if (acLineStatus == 0)
                return SystemPowerState.OnBattery;
            if (acLineStatus == 1)
                return SystemPowerState.AcConnected;
            return SystemPowerState.Unknown;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetSystemPowerStatus(out NativeSystemPowerStatus status);

        [StructLayout(LayoutKind.Sequential)]
        private struct NativeSystemPowerStatus
        {
            internal byte AcLineStatus;
            internal byte BatteryFlag;
            internal byte BatteryLifePercent;
            internal byte SystemStatusFlag;
            internal uint BatteryLifeTime;
            internal uint BatteryFullLifeTime;
        }
    }
}
