namespace Libertix.Helpers
{
    public sealed class UefiRecoveryState
    {
        public string RunId { get; set; }
        public string PlanId { get; set; }
        public string RecoveryRoot { get; set; }
        public string PayloadRoot { get; set; }
        public string ConfigPath { get; set; }
        public string TaskName { get; set; }
        public string PromptTaskName { get; set; }
        public string Phase { get; set; }
        public string CreatedUtc { get; set; }
        public string LastCheckedUtc { get; set; }
        public int SystemDiskNumber { get; set; }
        public string SystemDiskUniqueId { get; set; }
        public string SystemDiskPartitionTableId { get; set; }
        public long SystemDiskSize { get; set; }
        public int BootPartitionNumber { get; set; }
        public long BootPartitionOffset { get; set; }
        public long BootPartitionSize { get; set; }
        public long ExpectedLinuxPartitionOffset { get; set; }
        public long ExpectedLinuxPartitionSize { get; set; }
        public bool SecureBootEnabled { get; set; }
    }

    public sealed class UefiRecoveryManifestFile
    {
        public string RelativePath { get; set; }
        public long Length { get; set; }
        public string Sha256 { get; set; }
    }

    public sealed class UefiRecoveryManifest
    {
        public UefiRecoveryManifestFile[] Files { get; set; }
    }
}
