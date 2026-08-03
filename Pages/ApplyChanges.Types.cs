using System.Runtime.InteropServices;
using Libertix.Installation;

namespace Libertix.Pages
{
    /// <summary>
    /// Native firmware interop kept with the ApplyChanges partial class. The
    /// managed storage contracts live in Installation/StoragePreflightInfo.cs.
    /// </summary>
    public partial class ApplyChanges
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFirmwareType(out FirmwareType firmwareType);
    }
}
