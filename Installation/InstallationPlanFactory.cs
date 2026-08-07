using System;
using System.IO;
using System.Linq;
using Libertix.Helpers;
using Libertix.Models;

namespace Libertix.Installation
{
    public sealed class InstallationPlanCreationOptions
    {
        public string PlanId { get; set; }
        public FirmwareType Firmware { get; set; }
        public DistroInfo Distribution { get; set; }
        public AccountInfo Account { get; set; }
        public SharingOptions Sharing { get; set; }
        public CompatibilityInfo Compatibility { get; set; }
        public StoragePreflightInfo Storage { get; set; }
        public InstallationSizes Sizes { get; set; }
        public LinuxKeyboardConfiguration Keyboard { get; set; }
        public StartupOptions StartupOptions { get; set; }
        public string LanguageCode { get; set; }
        public string SystemLanguage { get; set; }
        public string Timezone { get; set; }
        public string SystemDriveRoot { get; set; }
        public string PasswordHashWindowsPath { get; set; }
        public string WindowsProfilesJsonBase64 { get; set; }
        public string RecoveryRootWindows { get; set; }
        public string RecoveryRunId { get; set; }
    }

    /// <summary>
    /// Creates the immutable cross-runtime intent from validated Windows inputs.
    /// </summary>
    public static class InstallationPlanFactory
    {
        public static InstallationPlan Create(InstallationPlanCreationOptions options)
        {
            if (options == null)
                throw new ArgumentNullException(nameof(options));
            if (options.Distribution == null || options.Account == null ||
                options.Sharing == null || options.Storage == null ||
                options.Sizes == null || options.Keyboard == null ||
                options.StartupOptions == null)
            {
                throw new ArgumentException("Installation plan inputs are incomplete.", nameof(options));
            }

            bool isUefi = options.Firmware == FirmwareType.Uefi;
            string developmentIpv4 = options.StartupOptions.DevelopmentSshStaticIpv4Address;
            var plan = new InstallationPlan
            {
                PlanId = options.PlanId,
                CreatedAtUtc = DateTimeOffset.UtcNow,
                Firmware = isUefi ? InstallationFirmware.Uefi : InstallationFirmware.Bios,
                Distribution = new InstallationDistribution
                {
                    Name = options.Distribution.Name,
                    InstallerIsoFileName = options.Distribution.IsoInstallerFileName,
                    InstallerIsoUrl = options.Distribution.IsoInstaller,
                    InstallerIsoWindowsPath = isUefi
                        ? Path.Combine(options.SystemDriveRoot, options.Distribution.IsoInstallerFileName)
                        : Path.Combine(
                            Path.GetTempPath(),
                            "Libertix",
                            options.Distribution.IsoInstallerFileName),
                    InstallerIsoSha256 = options.Distribution.IsoInstallerSha256.ToLowerInvariant(),
                    LiveIsoUrl = isUefi
                        ? options.Distribution.UefiIsoUrl
                        : options.Distribution.IsoUrl,
                    LiveIsoSha256 = (isUefi
                        ? options.Distribution.UefiIsoSha256
                        : options.Distribution.IsoSha256).ToLowerInvariant()
                },
                Locale = new InstallationLocale
                {
                    LanguageCode = options.LanguageCode,
                    SystemLanguage = options.SystemLanguage,
                    KeyboardLayout = options.Keyboard.Layout,
                    KeyboardVariant = options.Keyboard.Variant,
                    KeyboardModel = "pc105",
                    Timezone = options.Timezone
                },
                Account = new InstallationAccount
                {
                    Username = options.Account.Username,
                    PasswordHashWindowsPath = options.PasswordHashWindowsPath,
                    ComputerName = options.Account.ComputerName
                },
                Disk = new InstallationDisk
                {
                    Number = options.Storage.SystemDiskNumber,
                    UniqueId = options.Storage.SystemDiskUniqueId.Trim(),
                    SizeBytes = options.Storage.SystemDiskSize,
                    LogicalSectorSizeBytes = options.Storage.LogicalSectorSize,
                    PartitionStyle = options.Storage.PartitionStyle,
                    SystemDrive = options.Storage.SystemDrive.ToUpperInvariant(),
                    Windows = options.Storage.WindowsPartition,
                    Boot = options.Storage.BootPartition,
                    Recovery = options.Storage.RecoveryPartition,
                    Installer = new InstallerPartitionPlan
                    {
                        FinalSizeBytes = options.Sizes.FinalSizeBytes,
                        StagingSizeBytes = options.Sizes.StagingSizeBytes
                    }
                },
                Features = new InstallationFeatures
                {
                    ShareWindowsFilesInLinux = options.Sharing.ShareWindowsFilesInLinux,
                    ShareLinuxFilesInWindows = options.Sharing.ShareLinuxFilesInWindows,
                    WindowsProfilesJsonBase64 = options.WindowsProfilesJsonBase64
                },
                Runtime = new InstallationRuntime
                {
                    LowMemoryMode = options.Compatibility?.LowMemoryMode == true,
                    BootStrategy = isUefi
                        ? InstallationBootStrategy.UefiBootNext
                        : InstallationBootStrategy.BiosGrub4Dos,
                    RecoveryRootWindows = options.RecoveryRootWindows,
                    RecoveryRunId = options.RecoveryRunId
                },
                Development = string.IsNullOrEmpty(developmentIpv4)
                    ? null
                    : new InstallationDevelopmentOptions
                    {
                        EnableSsh = true,
                        StaticIpv4Address = developmentIpv4,
                        StaticIpv4PrefixLength =
                            options.StartupOptions.DevelopmentSshStaticIpv4PrefixLength.Value,
                        StaticIpv4Gateway = options.StartupOptions.DevelopmentSshStaticIpv4Gateway,
                        DnsServers = options.StartupOptions.DevelopmentSshDnsServers.ToArray()
                    }
            };

            InstallationPlanValidator.Validate(plan);
            return plan;
        }
    }
}
