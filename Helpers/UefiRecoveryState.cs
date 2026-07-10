namespace Libertix.Helpers
{
    public sealed class UefiRecoveryState
    {
        public string RunId { get; set; }
        public string RecoveryRoot { get; set; }
        public string PayloadRoot { get; set; }
        public string ConfigPath { get; set; }
        public string TaskName { get; set; }
        public string PromptTaskName { get; set; }
        public string Phase { get; set; }
        public string CreatedUtc { get; set; }
        public string LastCheckedUtc { get; set; }
        public int SystemDiskNumber { get; set; }
        public long ExpectedLinuxPartitionSize { get; set; }
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
