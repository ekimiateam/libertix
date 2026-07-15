using System.Runtime.InteropServices;

namespace Libertix.Pages
{
    /// <summary>
    /// Internal data contracts used by the Windows storage preflight.
    /// They remain nested in ApplyChanges to preserve their original scope.
    /// </summary>
    public partial class ApplyChanges
    {
        private sealed class StoragePreflightInfo
        {
            public FirmwareType Firmware { get; set; }
            public string SystemDrive { get; set; }
            public int SystemDiskNumber { get; set; }
            public int SystemPartitionNumber { get; set; }
            public long SystemPartitionOffset { get; set; }
            public long SystemPartitionSize { get; set; }
            public int BootPartitionNumber { get; set; }
            public long BootPartitionOffset { get; set; }
            public long BootPartitionSize { get; set; }
            public string SystemDiskUniqueId { get; set; }
            public long SystemDiskSize { get; set; }
            public string PartitionStyle { get; set; }
            public int RecoveryPartitionNumber { get; set; }
            public long RecoveryPartitionOffset { get; set; }
            public long RecoveryPartitionSize { get; set; }
            public bool BitLockerSafe { get; set; }
            public string BitLockerState { get; set; }
            public int BitLockerConversionStatus { get; set; }
            public int BitLockerEncryptionPercentage { get; set; }
            public int BitLockerProtectionStatus { get; set; }
        }

        private enum FirmwareType
        {
            Unknown = 0,
            Bios = 1,
            Uefi = 2,
            Max = 3
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFirmwareType(out FirmwareType firmwareType);
    }
}
