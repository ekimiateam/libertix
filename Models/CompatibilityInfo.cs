namespace Libertix.Models
{
    public sealed class CompatibilityInfo
    {
        public string Firmware { get; set; }
        public string Architecture { get; set; }
        public long MemoryBytes { get; set; }
        public bool LowMemoryMode { get; set; }
        public int SystemDiskNumber { get; set; }
        public string SystemDiskUniqueId { get; set; }
        public long SystemDiskSize { get; set; }
        public string PartitionStyle { get; set; }
        public string StorageBusType { get; set; }
        public int LogicalSectorSize { get; set; }
        public int PhysicalSectorSize { get; set; }
        public long ShrinkAvailableBytes { get; set; }
        public bool BitLockerSafe { get; set; }
        public string BitLockerState { get; set; }
        public bool SecureBootEnabled { get; set; }
        public bool NvramProbePassed { get; set; }
        public string[] Warnings { get; set; } = new string[0];
    }
}
