namespace Libertix.Models
{
    /// <summary>
    /// Typed state shared by one installer navigation flow.
    /// Pages receive this instance explicitly instead of using Application.Properties.
    /// </summary>
    public sealed class InstallationState
    {
        public DistroInfo SelectedDistro { get; set; }
        public CompatibilityInfo Compatibility { get; set; }
        public SharingOptions Sharing { get; set; } = new SharingOptions();
        public AccountInfo Account { get; set; }
        public string UefiRecoveryStatePath { get; set; }
    }
}
