using System;
using System.IO;
using System.Text.RegularExpressions;

namespace Libertix.Installation
{
    /// <summary>
    /// Resolves and removes transaction-owned downloads without accepting an
    /// arbitrary path from a plan or caller.
    /// </summary>
    public static class InstallationTemporaryArtifacts
    {
        private static readonly Regex PlanIdPattern = new Regex(
            "^[0-9a-f]{32}$",
            RegexOptions.CultureInvariant);

        public static string GetDownloadDirectory(string systemDriveRoot, string planId)
        {
            if (string.IsNullOrWhiteSpace(systemDriveRoot))
                throw new ArgumentException("A Windows system drive root is required.", nameof(systemDriveRoot));
            if (!PlanIdPattern.IsMatch(planId ?? string.Empty))
                throw new ArgumentException("The installation plan identifier is invalid.", nameof(planId));

            string driveRoot = Path.GetPathRoot(Path.GetFullPath(systemDriveRoot));
            if (string.IsNullOrWhiteSpace(driveRoot))
                throw new ArgumentException("The Windows system drive root is invalid.", nameof(systemDriveRoot));

            return Path.Combine(
                driveRoot,
                "ProgramData",
                "Libertix",
                "Downloads",
                planId);
        }

        public static string GetDistributionIsoPath(
            string systemDriveRoot,
            string planId,
            string installerIsoFileName)
        {
            if (string.IsNullOrWhiteSpace(installerIsoFileName) ||
                !string.Equals(
                    installerIsoFileName,
                    Path.GetFileName(installerIsoFileName),
                    StringComparison.Ordinal))
            {
                throw new ArgumentException(
                    "The distribution ISO name must be a plain file name.",
                    nameof(installerIsoFileName));
            }

            return Path.Combine(
                GetDownloadDirectory(systemDriveRoot, planId),
                installerIsoFileName);
        }

        public static string GetLiveMediaDirectory(string systemDriveRoot, string planId)
        {
            return Path.Combine(
                GetDownloadDirectory(systemDriveRoot, planId),
                "live-media");
        }

        public static void DeleteDownloadDirectory(string systemDriveRoot, string planId)
        {
            string transactionDirectory = GetDownloadDirectory(systemDriveRoot, planId);
            if (Directory.Exists(transactionDirectory))
                Directory.Delete(transactionDirectory, recursive: true);

            string downloadsDirectory = Path.GetDirectoryName(transactionDirectory);
            if (!string.IsNullOrWhiteSpace(downloadsDirectory) &&
                Directory.Exists(downloadsDirectory) &&
                Directory.GetFileSystemEntries(downloadsDirectory).Length == 0)
            {
                Directory.Delete(downloadsDirectory);
            }

            string productDirectory = Path.GetDirectoryName(downloadsDirectory);
            if (!string.IsNullOrWhiteSpace(productDirectory) &&
                Directory.Exists(productDirectory) &&
                Directory.GetFileSystemEntries(productDirectory).Length == 0)
            {
                Directory.Delete(productDirectory);
            }
        }
    }
}
