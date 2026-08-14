using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;

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
        public InstallationVolumeLabelPolicy VolumeLabels { get; set; }
        public InstallationAccountPolicy Account { get; set; }

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
                policy.Download == null || policy.VolumeLabels == null || policy.Account == null)
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
                (storage.PartitionAlignmentBytes & (storage.PartitionAlignmentBytes - 1)) != 0 ||
                storage.RecommendedLinuxFractionOfFreeSpace <= 0 ||
                storage.RecommendedLinuxFractionOfFreeSpace > 1 ||
                storage.MaximumRecommendedLinuxSizeGiB < storage.MinimumFinalSizeGiB)
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
                policy.Download.Aria2MaximumConnections > 16 ||
                policy.Download.MaximumAttempts <= 0 ||
                policy.Download.MaximumAttempts > 20 ||
                policy.Download.RetryBaseDelaySeconds <= 0 ||
                policy.Download.RetryBaseDelaySeconds > 300)
            {
                throw new InvalidDataException("Installation download policy is invalid.");
            }

            InstallationVolumeLabelPolicy labels = policy.VolumeLabels;
            string[] allLabels = new[] { labels.InstallationMedia, labels.Staging }
                .Concat(labels.LegacyStagingForRecovery ?? Array.Empty<string>())
                .ToArray();
            if (allLabels.Any(label =>
                    string.IsNullOrWhiteSpace(label) ||
                    !Regex.IsMatch(label, "^[A-Z0-9]{1,11}$")) ||
                allLabels.Distinct(StringComparer.Ordinal).Count() != allLabels.Length)
            {
                throw new InvalidDataException("Installation volume-label policy is invalid.");
            }

            InstallationAccountPolicy account = policy.Account;
            string[] reservedUsernames = account.ReservedUsernames;
            if (!Uri.TryCreate(account.ReservedUsernamesSource, UriKind.Absolute, out Uri source) ||
                source.Scheme != Uri.UriSchemeHttps ||
                reservedUsernames == null || reservedUsernames.Length == 0 ||
                reservedUsernames.Any(name =>
                    string.IsNullOrWhiteSpace(name) ||
                    !Regex.IsMatch(name, "^[A-Za-z](?:[A-Za-z0-9-]{0,30}[A-Za-z0-9])?$")) ||
                reservedUsernames.Distinct(StringComparer.OrdinalIgnoreCase).Count() !=
                    reservedUsernames.Length)
            {
                throw new InvalidDataException("Installation account policy is invalid.");
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
        public double RecommendedLinuxFractionOfFreeSpace { get; set; }
        public int MaximumRecommendedLinuxSizeGiB { get; set; }
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
        public int MaximumAttempts { get; set; }
        public int RetryBaseDelaySeconds { get; set; }
    }

    public sealed class InstallationVolumeLabelPolicy
    {
        public string InstallationMedia { get; set; }
        public string Staging { get; set; }
        public string[] LegacyStagingForRecovery { get; set; }
    }

    public sealed class InstallationAccountPolicy
    {
        public string ReservedUsernamesSource { get; set; }
        public string[] ReservedUsernames { get; set; }
    }
}
