using System.Runtime.InteropServices;

namespace Libertix.Installation
{
    internal static class FirmwareInterop
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFirmwareType(out FirmwareType firmwareType);

        internal static bool TryGetFirmwareType(out FirmwareType firmwareType)
        {
            return GetFirmwareType(out firmwareType);
        }
    }
}
