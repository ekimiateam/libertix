using System;
using System.IO;
using System.Text.Json;

namespace Libertix.Installation
{
    /// <summary>
    /// Describes the exact Linux partition that the Windows read-only sharing
    /// task is allowed to mount after installation.
    /// </summary>
    internal sealed class WindowsShareConfiguration
    {
        public bool Enabled { get; set; }
        public int SystemDiskNumber { get; set; }
        public string SystemDiskUniqueId { get; set; }
        public long ExpectedLinuxPartitionOffset { get; set; }
        public long ExpectedLinuxPartitionSize { get; set; }
        public long PartitionSizeToleranceBytes { get; set; }
        public string LinuxUsername { get; set; }
        public string ShortcutDescription { get; set; }
        public string SetupPath { get; set; }
        public string SetupSha256 { get; set; }
        public long SetupAttachedContainerSize { get; set; }
        public string WinFspPayloadName { get; set; }
        public string WinFspPayloadSha256 { get; set; }
        public string DriverPayloadName { get; set; }
        public string DriverPayloadSha256 { get; set; }
    }

    internal static class WindowsShareConfigurationStore
    {
        private static readonly JsonSerializerOptions SerializerOptions =
            new JsonSerializerOptions { WriteIndented = true };

        public static WindowsShareConfiguration Read(string path)
        {
            WindowsShareConfiguration configuration =
                JsonSerializer.Deserialize<WindowsShareConfiguration>(File.ReadAllText(path));
            if (configuration == null)
                throw new InvalidOperationException("Windows share configuration is empty.");
            return configuration;
        }

        public static void WriteAtomic(string path, WindowsShareConfiguration configuration)
        {
            if (configuration == null)
                throw new ArgumentNullException(nameof(configuration));
            if (configuration.SystemDiskNumber < 0 ||
                string.IsNullOrWhiteSpace(configuration.SystemDiskUniqueId) ||
                configuration.ExpectedLinuxPartitionOffset <= 0 ||
                configuration.ExpectedLinuxPartitionSize <= 0 ||
                configuration.PartitionSizeToleranceBytes <= 0 ||
                configuration.PartitionSizeToleranceBytes >
                    configuration.ExpectedLinuxPartitionSize ||
                configuration.SetupAttachedContainerSize <= 0 ||
                !IsSha256(configuration.SetupSha256) ||
                !IsFileName(configuration.WinFspPayloadName) ||
                !IsSha256(configuration.WinFspPayloadSha256) ||
                !IsFileName(configuration.DriverPayloadName) ||
                !IsSha256(configuration.DriverPayloadSha256))
            {
                throw new InvalidOperationException(
                    "Windows share configuration has invalid partition identity.");
            }

            AtomicJsonFile.Write(
                path,
                JsonSerializer.Serialize(configuration, SerializerOptions));
        }

        private static bool IsFileName(string value)
        {
            return !string.IsNullOrWhiteSpace(value) &&
                string.Equals(Path.GetFileName(value), value, StringComparison.Ordinal);
        }

        private static bool IsSha256(string value)
        {
            if (string.IsNullOrWhiteSpace(value) || value.Length != 64)
                return false;
            foreach (char character in value)
            {
                if (!Uri.IsHexDigit(character))
                    return false;
            }
            return true;
        }
    }
}
