namespace Libertix.Installation
{
    /// <summary>
    /// Names persisted across process and operating-system boundaries.
    /// Changing one requires the cross-runtime contract test to pass.
    /// </summary>
    public static class RuntimeNames
    {
        public const string InstallerVolumeLabel = "LIBERTIXEFI";
        public const string InstallationLogDirectory = "LibertixInstallLogs";
        public const string BiosRecoveryDirectory = "LibertixInstallRecovery";
        public const string BiosRecoveryTask = "LibertixInstallRecovery";
        public const string LinuxReadOnlyTask = "LibertixLinuxReadOnly";
    }
}
