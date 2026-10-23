using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
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

        /// <summary>
        /// Moves a verified distribution ISO left by an earlier run that no
        /// recovery owns any more into this plan's download directory. Returns
        /// the adopted source path, or null when no candidate qualifies.
        /// </summary>
        public static string MoveReusableDistributionIso(
            string systemDriveRoot,
            string planId,
            string installerIsoFileName,
            string expectedSha256,
            long maximumBytes,
            Func<string, bool> recoveryTaskExists)
        {
            string transactionDirectory = GetDownloadDirectory(systemDriveRoot, planId);
            string driveRoot = Path.GetPathRoot(transactionDirectory);
            return MoveReusableDistributionIso(
                Path.GetDirectoryName(transactionDirectory),
                Path.Combine(driveRoot, "ProgramData", "Libertix", "UefiRecovery"),
                Path.Combine(driveRoot, RuntimeNames.BiosRecoveryDirectory),
                planId,
                installerIsoFileName,
                expectedSha256,
                maximumBytes,
                recoveryTaskExists);
        }

        internal static string MoveReusableDistributionIso(
            string downloadsDirectory,
            string uefiRecoveryDirectory,
            string biosRecoveryDirectory,
            string planId,
            string installerIsoFileName,
            string expectedSha256,
            long maximumBytes,
            Func<string, bool> recoveryTaskExists)
        {
            if (!PlanIdPattern.IsMatch(planId ?? string.Empty))
                throw new ArgumentException("The installation plan identifier is invalid.", nameof(planId));
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
            if (string.IsNullOrWhiteSpace(expectedSha256) ||
                !Regex.IsMatch(expectedSha256, "^[0-9a-fA-F]{64}$"))
            {
                throw new ArgumentException(
                    "The distribution ISO hash must be a SHA256 hex digest.",
                    nameof(expectedSha256));
            }
            if (recoveryTaskExists == null)
                throw new ArgumentNullException(nameof(recoveryTaskExists));

            string transactionDirectory = Path.Combine(downloadsDirectory, planId);
            string destination = Path.Combine(transactionDirectory, installerIsoFileName);
            if (File.Exists(destination) || !Directory.Exists(downloadsDirectory))
                return null;

            foreach (string sibling in Directory.EnumerateDirectories(downloadsDirectory))
            {
                string siblingPlanId = Path.GetFileName(sibling);
                if (!PlanIdPattern.IsMatch(siblingPlanId) ||
                    string.Equals(siblingPlanId, planId, StringComparison.Ordinal) ||
                    (File.GetAttributes(sibling) & FileAttributes.ReparsePoint) != 0)
                {
                    continue;
                }

                string candidate = Path.Combine(sibling, installerIsoFileName);
                // aria2 keeps a control file next to an unfinished download.
                if (!File.Exists(candidate) || File.Exists(candidate + ".aria2"))
                    continue;
                var info = new FileInfo(candidate);
                if ((info.Attributes & FileAttributes.ReparsePoint) != 0 ||
                    info.Length == 0 ||
                    info.Length > maximumBytes)
                {
                    continue;
                }
                if (PlanHasRecoveryState(
                        uefiRecoveryDirectory,
                        biosRecoveryDirectory,
                        siblingPlanId,
                        recoveryTaskExists) ||
                    !string.Equals(ComputeSha256(candidate), expectedSha256, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                Directory.CreateDirectory(transactionDirectory);
                // Both directories live under the same ProgramData root, so this
                // is a rename: the reclaimable space now belongs to this plan only.
                File.Move(candidate, destination);
                return candidate;
            }

            return null;
        }

        private static bool PlanHasRecoveryState(
            string uefiRecoveryDirectory,
            string biosRecoveryDirectory,
            string planId,
            Func<string, bool> recoveryTaskExists)
        {
            // A UEFI run keeps its recovery payload and scheduled tasks under its
            // plan id until recovery completes; a BIOS run records its plan id in
            // the single recovery root. Either one means that run may still need
            // its downloads.
            if (Directory.Exists(Path.Combine(uefiRecoveryDirectory, planId)) ||
                recoveryTaskExists("LibertixUefiRecovery_" + planId) ||
                recoveryTaskExists("LibertixUefiRecoveryPrompt_" + planId))
            {
                return true;
            }

            if (!Directory.Exists(biosRecoveryDirectory))
                return false;
            string pendingPath = Path.Combine(biosRecoveryDirectory, "pending.env");
            if (!File.Exists(pendingPath))
                return true;
            string biosPlanId = File.ReadLines(pendingPath)
                .Where(line => line.StartsWith("PLAN_ID=", StringComparison.Ordinal))
                .Select(line => line.Substring("PLAN_ID=".Length).Trim())
                .FirstOrDefault();
            // An unreadable owner cannot prove that this plan is unrelated.
            return !PlanIdPattern.IsMatch(biosPlanId ?? string.Empty) ||
                string.Equals(biosPlanId, planId, StringComparison.Ordinal);
        }

        private static string ComputeSha256(string path)
        {
            using (var stream = File.OpenRead(path))
            using (var sha = SHA256.Create())
            {
                return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
            }
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
