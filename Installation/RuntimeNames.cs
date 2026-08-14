namespace Libertix.Installation
{
    /// <summary>
    /// Names persisted across process and operating-system boundaries.
    /// Changing one requires the cross-runtime contract test to pass.
    /// </summary>
    public static class RuntimeNames
    {
        public static string InstallationMediaVolumeLabel =>
            InstallationPolicy.Current.VolumeLabels.InstallationMedia;
        public static string StagingVolumeLabel =>
            InstallationPolicy.Current.VolumeLabels.Staging;
        public const string InstallationLogDirectory = "LibertixInstallLogs";
        public const string WindowsLogDirectory = "Windows";
        public const string LinuxLogDirectory = "Linux";
        public const string BiosRecoveryDirectory = "LibertixInstallRecovery";
        public const string BiosRecoveryTask = "LibertixInstallRecovery";
        public const string BiosRecoveryPromptTask = "LibertixInstallRecoveryPrompt";
        public const string LinuxReadOnlyTask = "LibertixLinuxReadOnly";
    }
}
