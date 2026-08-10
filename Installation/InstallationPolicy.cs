using System;
using System.IO;
using System.Text.Json;

namespace Libertix.Installation
{
    /// <summary>
    /// Loads the single cross-runtime storage and memory policy document.
    /// </summary>
    public sealed class InstallationPolicy
    {
        private const int CurrentSchemaVersion = 1;
        private const string RelativePolicyPath = @"Scripts\config\Libertix.InstallationPolicy.json";
        private static readonly Lazy<InstallationPolicy> LazyCurrent =
            new Lazy<InstallationPolicy>(LoadCurrent);

        public int SchemaVersion { get; set; }
        public InstallationStoragePolicy Storage { get; set; }
        public InstallationMemoryPolicy Memory { get; set; }
        public InstallationDownloadPolicy Download { get; set; }

        public static InstallationPolicy Current => LazyCurrent.Value;

        private static InstallationPolicy LoadCurrent()
        {
            string path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, RelativePolicyPath);
            InstallationPolicy policy = JsonSerializer.Deserialize<InstallationPolicy>(
                File.ReadAllText(path),
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            Validate(policy, path);
            return policy;
        }

        private static void Validate(InstallationPolicy policy, string path)
        {
            if (policy == null || policy.Storage == null || policy.Memory == null ||
                policy.Download == null)
                throw new InvalidDataException($"Installation policy is incomplete: {path}");
            if (policy.SchemaVersion != CurrentSchemaVersion)
                throw new InvalidDataException(
                    $"Unsupported installation policy schemaVersion: {policy.SchemaVersion}.");

            InstallationStoragePolicy storage = policy.Storage;
            InstallationMemoryPolicy memory = policy.Memory;
            if (storage.MinimumFinalSizeGiB <= 0 ||
                storage.TargetWindowsFreeSpaceGiB <= 0 ||
                storage.WindowsFreeSpaceToleranceGiB < 0 ||
                storage.WindowsFreeSpaceToleranceGiB >= storage.TargetWindowsFreeSpaceGiB ||
                storage.WindowsFreeSpaceRetryWindowGiB < 0 ||
                storage.PreflightShrinkSafetyGiB < 0 ||
                storage.MaximumDirectFat32SizeGiB < storage.MinimumFinalSizeGiB ||
                storage.LargeInstallationStagingSizeGiB <= 0 ||
                storage.LargeInstallationStagingSizeGiB > storage.MaximumDirectFat32SizeGiB ||
                storage.PartitionAlignmentBytes <= 0 ||
                (storage.PartitionAlignmentBytes & (storage.PartitionAlignmentBytes - 1)) != 0)
            {
                throw new InvalidDataException("Installation storage policy is invalid.");
            }
            if (memory.LiveMinimumMiB <= 0 ||
                memory.WindowsMinimumMiB < memory.LiveMinimumMiB ||
                memory.LowMemoryThresholdMiB <= memory.WindowsMinimumMiB)
            {
                throw new InvalidDataException("Installation memory policy is invalid.");
            }
            if (policy.Download.Aria2MaximumConnections <= 0 ||
                policy.Download.Aria2MaximumConnections > 16)
            {
                throw new InvalidDataException("Installation download policy is invalid.");
            }
        }
    }

    public sealed class InstallationStoragePolicy
    {
        public int MinimumFinalSizeGiB { get; set; }
        public int TargetWindowsFreeSpaceGiB { get; set; }
        public int WindowsFreeSpaceToleranceGiB { get; set; }
        public int WindowsFreeSpaceRetryWindowGiB { get; set; }
        public int PreflightShrinkSafetyGiB { get; set; }
        public int MaximumDirectFat32SizeGiB { get; set; }
        public int LargeInstallationStagingSizeGiB { get; set; }
        public long PartitionAlignmentBytes { get; set; }
    }

    public sealed class InstallationMemoryPolicy
    {
        public int WindowsMinimumMiB { get; set; }
        public int LowMemoryThresholdMiB { get; set; }
        public int LiveMinimumMiB { get; set; }
    }

    public sealed class InstallationDownloadPolicy
    {
        public int Aria2MaximumConnections { get; set; }
    }
}
