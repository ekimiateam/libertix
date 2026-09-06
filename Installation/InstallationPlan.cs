using System;
using System.Text.Json.Serialization;

namespace Libertix.Installation
{
    /// <summary>
    /// Validated, atomically published description of one Libertix installation.
    ///
    /// The Windows application creates this plan before changing the disk. Every
    /// later component consumes the same values instead of recalculating them.
    /// Runtime code may atomically record the observed staging-partition identity
    /// or a validated boot-strategy fallback after those values become known.
    /// </summary>
    public sealed class InstallationPlan
    {
        public const int CurrentSchemaVersion = 4;

        [JsonPropertyName("schemaVersion")]
        public int SchemaVersion { get; set; } = CurrentSchemaVersion;

        [JsonPropertyName("planId")]
        public string PlanId { get; set; }

        [JsonPropertyName("createdAtUtc")]
        public DateTimeOffset CreatedAtUtc { get; set; }

        [JsonPropertyName("firmware")]
        public string Firmware { get; set; }

        [JsonPropertyName("distribution")]
        public InstallationDistribution Distribution { get; set; }

        [JsonPropertyName("locale")]
        public InstallationLocale Locale { get; set; }

        [JsonPropertyName("account")]
        public InstallationAccount Account { get; set; }

        [JsonPropertyName("disk")]
        public InstallationDisk Disk { get; set; }

        [JsonPropertyName("features")]
        public InstallationFeatures Features { get; set; }

        [JsonPropertyName("runtime")]
        public InstallationRuntime Runtime { get; set; }

        [JsonPropertyName("development")]
        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
        public InstallationDevelopmentOptions Development { get; set; }
    }

    public static class InstallationFirmware
    {
        public const string Bios = "bios";
        public const string Uefi = "uefi";
    }

    public static class InstallationBootStrategy
    {
        public const string BiosGrub4Dos = "bios-grub4dos";
        public const string UefiBootNext = "uefi-boot-next";
        public const string UefiFirmwareBootOrder = "uefi-firmware-boot-order";
    }

    public static class InstallationResizeMode
    {
        public const string WindowsOnline = "windows-online";
        public const string LiveOffline = "live-offline";
    }

    public static class InstallationBitLockerState
    {
        public const string FullyDecrypted = "FullyDecrypted";
        public const string NotEncryptable = "NotEncryptable";
        public const string EncryptedOrProtected = "EncryptedOrProtected";
    }

    public static class InstallationPartitionStyle
    {
        public const string Mbr = "MBR";
        public const string Gpt = "GPT";
    }

    public sealed class InstallationDistribution
    {
        [JsonPropertyName("id")]
        public string Id { get; set; }

        [JsonPropertyName("name")]
        public string Name { get; set; }

        [JsonPropertyName("osReleaseId")]
        public string OsReleaseId { get; set; }

        [JsonPropertyName("grubDisplayName")]
        public string GrubDisplayName { get; set; }

        [JsonPropertyName("grubIcon")]
        public string GrubIcon { get; set; }

        [JsonPropertyName("secureBootMicrosoftAuthorities")]
        public string[] SecureBootMicrosoftAuthorities { get; set; }

        [JsonPropertyName("installerIsoFileName")]
        public string InstallerIsoFileName { get; set; }

        [JsonPropertyName("installerIsoUrl")]
        public string InstallerIsoUrl { get; set; }

        [JsonPropertyName("installerIsoWindowsPath")]
        public string InstallerIsoWindowsPath { get; set; }

        [JsonPropertyName("installerIsoSha256")]
        public string InstallerIsoSha256 { get; set; }

        [JsonPropertyName("liveIsoUrl")]
        public string LiveIsoUrl { get; set; }

        [JsonPropertyName("liveIsoSha256")]
        public string LiveIsoSha256 { get; set; }
    }

    public sealed class InstallationLocale
    {
        [JsonPropertyName("languageCode")]
        public string LanguageCode { get; set; }

        [JsonPropertyName("systemLanguage")]
        public string SystemLanguage { get; set; }

        [JsonPropertyName("keyboardLayout")]
        public string KeyboardLayout { get; set; }

        [JsonPropertyName("keyboardVariant")]
        public string KeyboardVariant { get; set; } = string.Empty;

        [JsonPropertyName("keyboardModel")]
        public string KeyboardModel { get; set; }

        [JsonPropertyName("timezone")]
        public string Timezone { get; set; }
    }

    public sealed class InstallationAccount
    {
        [JsonPropertyName("username")]
        public string Username { get; set; }

        [JsonPropertyName("passwordHashWindowsPath")]
        public string PasswordHashWindowsPath { get; set; }

        [JsonPropertyName("computerName")]
        public string ComputerName { get; set; }
    }

    public sealed class InstallationDisk
    {
        [JsonPropertyName("number")]
        public int Number { get; set; }

        [JsonPropertyName("uniqueId")]
        public string UniqueId { get; set; }

        [JsonPropertyName("partitionTableId")]
        public string PartitionTableId { get; set; }

        [JsonPropertyName("sizeBytes")]
        public long SizeBytes { get; set; }

        [JsonPropertyName("logicalSectorSizeBytes")]
        public int LogicalSectorSizeBytes { get; set; }

        [JsonPropertyName("partitionStyle")]
        public string PartitionStyle { get; set; }

        [JsonPropertyName("systemDrive")]
        public string SystemDrive { get; set; }

        [JsonPropertyName("windows")]
        public PartitionIdentity Windows { get; set; }

        [JsonPropertyName("boot")]
        public PartitionIdentity Boot { get; set; }

        [JsonPropertyName("recovery")]
        public PartitionIdentity Recovery { get; set; }

        [JsonPropertyName("installer")]
        public InstallerPartitionPlan Installer { get; set; }
    }

    public sealed class PartitionIdentity
    {
        [JsonPropertyName("number")]
        public int Number { get; set; }

        [JsonPropertyName("offsetBytes")]
        public long OffsetBytes { get; set; }

        [JsonPropertyName("sizeBytes")]
        public long SizeBytes { get; set; }
    }

    public sealed class InstallerPartitionPlan
    {
        [JsonPropertyName("number")]
        public int? Number { get; set; }

        [JsonPropertyName("offsetBytes")]
        public long? OffsetBytes { get; set; }

        [JsonPropertyName("finalOffsetBytes")]
        public long FinalOffsetBytes { get; set; }

        [JsonPropertyName("resizeMode")]
        public string ResizeMode { get; set; }

        [JsonPropertyName("finalSizeBytes")]
        public long FinalSizeBytes { get; set; }

        [JsonPropertyName("stagingSizeBytes")]
        public long StagingSizeBytes { get; set; }
    }

    public sealed class InstallationFeatures
    {
        [JsonPropertyName("shareWindowsFilesInLinux")]
        public bool ShareWindowsFilesInLinux { get; set; }

        [JsonPropertyName("shareLinuxFilesInWindows")]
        public bool ShareLinuxFilesInWindows { get; set; }

        [JsonPropertyName("windowsProfilesJsonBase64")]
        public string WindowsProfilesJsonBase64 { get; set; }

        [JsonPropertyName("windowsPreferenceMigration")]
        public InstallationPreferenceMigration WindowsPreferenceMigration { get; set; }
    }

    public sealed class InstallationPreferenceMigration
    {
        [JsonPropertyName("enabled")]
        public bool Enabled { get; set; }

        [JsonPropertyName("bundleFileName")]
        public string BundleFileName { get; set; }

        [JsonPropertyName("bundleSha256")]
        public string BundleSha256 { get; set; }

        [JsonPropertyName("bundleSizeBytes")]
        public long BundleSizeBytes { get; set; }

        [JsonPropertyName("wifiProfileCount")]
        public int WifiProfileCount { get; set; }
    }

    public sealed class InstallationRuntime
    {
        [JsonPropertyName("windowsBitLockerState")]
        public string WindowsBitLockerState { get; set; }

        [JsonPropertyName("lowMemoryMode")]
        public bool LowMemoryMode { get; set; }

        [JsonPropertyName("bootStrategy")]
        public string BootStrategy { get; set; }

        [JsonPropertyName("secureBootEnabled")]
        public bool SecureBootEnabled { get; set; }

        [JsonPropertyName("trustedMicrosoftUefiAuthorities")]
        public string[] TrustedMicrosoftUefiAuthorities { get; set; }

        [JsonPropertyName("recoveryRootWindows")]
        public string RecoveryRootWindows { get; set; }

        [JsonPropertyName("recoveryRunId")]
        public string RecoveryRunId { get; set; }
    }

    public sealed class InstallationDevelopmentOptions
    {
        [JsonPropertyName("enableSsh")]
        public bool EnableSsh { get; set; }

        [JsonPropertyName("staticIpv4Address")]
        public string StaticIpv4Address { get; set; }

        [JsonPropertyName("staticIpv4PrefixLength")]
        public int StaticIpv4PrefixLength { get; set; }

        [JsonPropertyName("staticIpv4Gateway")]
        public string StaticIpv4Gateway { get; set; }

        [JsonPropertyName("dnsServers")]
        public string[] DnsServers { get; set; }
    }
}
