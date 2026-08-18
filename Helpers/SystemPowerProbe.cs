using System;
using System.Runtime.InteropServices;

namespace Libertix.Helpers
{
    internal enum SystemPowerState
    {
        Unknown,
        NoSystemBattery,
        AcConnected,
        AcDisconnected
    }

    internal sealed class SystemPowerSnapshot
    {
        internal SystemPowerSnapshot(
            SystemPowerState state,
            byte acLineStatus,
            byte batteryFlag,
            int getSystemPowerStatusErrorCode,
            int systemBatteryStateStatus,
            bool usedSystemBatteryState)
        {
            State = state;
            AcLineStatus = acLineStatus;
            BatteryFlag = batteryFlag;
            GetSystemPowerStatusErrorCode = getSystemPowerStatusErrorCode;
            SystemBatteryStateStatus = systemBatteryStateStatus;
            UsedSystemBatteryState = usedSystemBatteryState;
        }

        internal SystemPowerState State { get; }
        internal byte AcLineStatus { get; }
        internal byte BatteryFlag { get; }
        internal int GetSystemPowerStatusErrorCode { get; }
        internal int SystemBatteryStateStatus { get; }
        internal bool UsedSystemBatteryState { get; }
    }

    internal static class SystemPowerProbe
    {
        internal static SystemPowerSnapshot Read()
        {
            byte acLineStatus = byte.MaxValue;
            byte batteryFlag = byte.MaxValue;
            int getSystemPowerStatusErrorCode = 0;
            SystemPowerState state = SystemPowerState.Unknown;

            if (GetSystemPowerStatus(out NativeSystemPowerStatus status))
            {
                acLineStatus = status.AcLineStatus;
                batteryFlag = status.BatteryFlag;
                state = Classify(acLineStatus, batteryFlag);
                if (state != SystemPowerState.Unknown)
                    return new SystemPowerSnapshot(
                        state,
                        acLineStatus,
                        batteryFlag,
                        0,
                        0,
                        false);
            }
            else
            {
                getSystemPowerStatusErrorCode = Marshal.GetLastWin32Error();
            }

            int batteryStateStatus = ReadSystemBatteryState(out NativeSystemBatteryState batteryState);
            if (batteryStateStatus == 0)
                state = ClassifySystemBatteryState(
                    batteryState.AcOnline,
                    batteryState.BatteryPresent);

            return new SystemPowerSnapshot(
                state,
                acLineStatus,
                batteryFlag,
                getSystemPowerStatusErrorCode,
                batteryStateStatus,
                batteryStateStatus == 0);
        }

        internal static SystemPowerState Classify(byte acLineStatus, byte batteryFlag)
        {
            const byte noSystemBattery = 128;
            if (acLineStatus == 0)
                return SystemPowerState.AcDisconnected;
            if (acLineStatus == 1)
                return SystemPowerState.AcConnected;
            if (batteryFlag != byte.MaxValue && (batteryFlag & noSystemBattery) != 0)
                return SystemPowerState.NoSystemBattery;
            return SystemPowerState.Unknown;
        }

        internal static SystemPowerState ClassifySystemBatteryState(
            byte acOnline,
            byte batteryPresent)
        {
            if (acOnline != 0)
                return SystemPowerState.AcConnected;
            if (batteryPresent != 0)
                return SystemPowerState.AcDisconnected;
            return SystemPowerState.NoSystemBattery;
        }

        private static int ReadSystemBatteryState(out NativeSystemBatteryState status)
        {
            return CallNtPowerInformation(
                5,
                IntPtr.Zero,
                0,
                out status,
                (uint)Marshal.SizeOf(typeof(NativeSystemBatteryState)));
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetSystemPowerStatus(out NativeSystemPowerStatus status);

        [DllImport("PowrProf.dll")]
        private static extern int CallNtPowerInformation(
            int informationLevel,
            IntPtr inputBuffer,
            uint inputBufferLength,
            out NativeSystemBatteryState outputBuffer,
            uint outputBufferLength);

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

        [StructLayout(LayoutKind.Sequential)]
        private struct NativeSystemBatteryState
        {
            internal byte AcOnline;
            internal byte BatteryPresent;
            internal byte Charging;
            internal byte Discharging;
            internal byte Spare1;
            internal byte Spare2;
            internal byte Spare3;
            internal byte Tag;
            internal uint MaxCapacity;
            internal uint RemainingCapacity;
            internal uint Rate;
            internal uint EstimatedTime;
            internal uint DefaultAlert1;
            internal uint DefaultAlert2;
        }
    }
}
