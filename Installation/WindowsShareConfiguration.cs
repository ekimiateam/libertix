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
        public string LinuxUsername { get; set; }
        public string ShortcutDescription { get; set; }
        public string SetupPath { get; set; }
        public string SetupSha256 { get; set; }
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
                configuration.ExpectedLinuxPartitionSize <= 0)
            {
                throw new InvalidOperationException(
                    "Windows share configuration has invalid partition identity.");
            }

            AtomicJsonFile.Write(
                path,
                JsonSerializer.Serialize(configuration, SerializerOptions));
        }
    }
}
