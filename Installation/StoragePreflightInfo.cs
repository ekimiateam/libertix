namespace Libertix.Installation
{
    internal enum FirmwareType
    {
        Unknown = 0,
        Bios = 1,
        Uefi = 2,
        Max = 3
    }

    /// <summary>
    /// Stable identity and geometry captured before any storage modification.
    /// </summary>
    internal sealed class StoragePreflightInfo
    {
        public FirmwareType Firmware { get; set; }
        public string SystemDrive { get; set; }
        public int SystemDiskNumber { get; set; }
        public string SystemDiskUniqueId { get; set; }
        public long SystemDiskSize { get; set; }
        public int LogicalSectorSize { get; set; }
        public string PartitionStyle { get; set; }
        public int SystemPartitionNumber { get; set; }
        public long SystemPartitionOffset { get; set; }
        public long SystemPartitionSize { get; set; }
        public int BootPartitionNumber { get; set; }
        public long BootPartitionOffset { get; set; }
        public long BootPartitionSize { get; set; }
        public int RecoveryPartitionNumber { get; set; }
        public long RecoveryPartitionOffset { get; set; }
        public long RecoveryPartitionSize { get; set; }
        public bool BitLockerSafe { get; set; }
        public string BitLockerState { get; set; }
        public int BitLockerConversionStatus { get; set; }
        public int BitLockerEncryptionPercentage { get; set; }
        public int BitLockerProtectionStatus { get; set; }

        public PartitionIdentity WindowsPartition => new PartitionIdentity
        {
            Number = SystemPartitionNumber,
            OffsetBytes = SystemPartitionOffset,
            SizeBytes = SystemPartitionSize
        };

        public PartitionIdentity BootPartition => new PartitionIdentity
        {
            Number = BootPartitionNumber,
            OffsetBytes = BootPartitionOffset,
            SizeBytes = BootPartitionSize
        };

        public PartitionIdentity RecoveryPartition => new PartitionIdentity
        {
            Number = RecoveryPartitionNumber,
            OffsetBytes = RecoveryPartitionOffset,
            SizeBytes = RecoveryPartitionSize
        };
    }
}
