using System;
using System.Text.Json.Serialization;

namespace Libertix.Installation
{
    /// <summary>
    /// Immutable-in-practice description of one Libertix installation.
    ///
    /// The Windows application creates this plan before changing the disk. Every
    /// later component consumes the same values instead of recalculating them.
    /// </summary>
    public sealed class InstallationPlan
    {
        public const int CurrentSchemaVersion = 1;

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

    public static class InstallationPartitionStyle
    {
        public const string Mbr = "MBR";
        public const string Gpt = "GPT";
    }

    public sealed class InstallationDistribution
    {
        [JsonPropertyName("name")]
        public string Name { get; set; }

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

        [JsonPropertyName("keyboardModel")]
        public string KeyboardModel { get; set; }

        [JsonPropertyName("timezone")]
        public string Timezone { get; set; }
    }

    public sealed class InstallationAccount
    {
        [JsonPropertyName("username")]
        public string Username { get; set; }

        [JsonPropertyName("passwordHash")]
        public string PasswordHash { get; set; }

        [JsonPropertyName("computerName")]
        public string ComputerName { get; set; }
    }

    public sealed class InstallationDisk
    {
        [JsonPropertyName("number")]
        public int Number { get; set; }

        [JsonPropertyName("uniqueId")]
        public string UniqueId { get; set; }

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
    }

    public sealed class InstallationRuntime
    {
        [JsonPropertyName("lowMemoryMode")]
        public bool LowMemoryMode { get; set; }

        [JsonPropertyName("bootStrategy")]
        public string BootStrategy { get; set; }

        [JsonPropertyName("recoveryRootWindows")]
        public string RecoveryRootWindows { get; set; }

        [JsonPropertyName("recoveryRunId")]
        public string RecoveryRunId { get; set; }
    }
}
