using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace Libertix.Installation
{
    /// <summary>
    /// Enforces the cross-field invariants that JSON Schema cannot express
    /// portably, such as firmware/partition-style parity and staging size.
    /// </summary>
    public static class InstallationPlanValidator
    {
        private static readonly Regex HexIdPattern = new Regex(
            "^[0-9a-f]{32}$",
            RegexOptions.CultureInvariant);

        private static readonly Regex Sha256Pattern = new Regex(
            "^[0-9a-f]{64}$",
            RegexOptions.CultureInvariant);

        private static readonly Regex UsernamePattern = new Regex(
            "^[a-z](?:[a-z0-9-]{0,30}[a-z0-9])?$",
            RegexOptions.CultureInvariant);

        private static readonly Regex AbsoluteWindowsPathPattern = new Regex(
            "^[A-Za-z]:[\\\\/]",
            RegexOptions.CultureInvariant);

        public static void Validate(InstallationPlan plan)
        {
            if (plan == null)
                throw new ArgumentNullException(nameof(plan));

            var errors = new List<string>();

            Require(plan.SchemaVersion == InstallationPlan.CurrentSchemaVersion, errors,
                $"schemaVersion must be {InstallationPlan.CurrentSchemaVersion}.");
            Require(HexIdPattern.IsMatch(plan.PlanId ?? string.Empty), errors,
                "planId must contain exactly 32 lowercase hexadecimal characters.");
            Require(plan.CreatedAtUtc != default(DateTimeOffset), errors,
                "createdAtUtc is required.");
            Require(plan.CreatedAtUtc.Offset == TimeSpan.Zero, errors,
                "createdAtUtc must use UTC.");

            ValidateDistribution(plan.Distribution, errors);
            ValidateLocale(plan.Locale, errors);
            ValidateAccount(plan.Account, errors);
            ValidateDisk(plan.Firmware, plan.Disk, errors);
            ValidateFeatures(plan.Features, errors);
            ValidateRuntime(plan.Firmware, plan.Runtime, errors);

            if (errors.Count > 0)
                throw new InstallationPlanValidationException(errors);
        }

        private static void ValidateDistribution(
            InstallationDistribution distribution,
            ICollection<string> errors)
        {
            if (distribution == null)
            {
                errors.Add("distribution is required.");
                return;
            }

            RequireNotBlank(distribution.Name, "distribution.name", errors);
            RequireNotBlank(distribution.InstallerIsoFileName, "distribution.installerIsoFileName", errors);
            Require(
                !string.IsNullOrEmpty(distribution.InstallerIsoFileName) &&
                distribution.InstallerIsoFileName.IndexOfAny(new[] { '/', '\\' }) < 0,
                errors,
                "distribution.installerIsoFileName must be a file name, not a path.");
            RequireHttpUri(distribution.InstallerIsoUrl, "distribution.installerIsoUrl", errors);
            RequireNotBlank(
                distribution.InstallerIsoWindowsPath,
                "distribution.installerIsoWindowsPath",
                errors);
            Require(
                AbsoluteWindowsPathPattern.IsMatch(
                    distribution.InstallerIsoWindowsPath ?? string.Empty),
                errors,
                "distribution.installerIsoWindowsPath must be an absolute Windows drive path.");
            RequireSha256(
                distribution.InstallerIsoSha256,
                "distribution.installerIsoSha256",
                errors);
            RequireHttpUri(distribution.LiveIsoUrl, "distribution.liveIsoUrl", errors);
            RequireSha256(distribution.LiveIsoSha256, "distribution.liveIsoSha256", errors);
        }

        private static void ValidateLocale(
            InstallationLocale locale,
            ICollection<string> errors)
        {
            if (locale == null)
            {
                errors.Add("locale is required.");
                return;
            }

            Require(
                locale.LanguageCode == "en" ||
                locale.LanguageCode == "fr" ||
                locale.LanguageCode == "es" ||
                locale.LanguageCode == "ja",
                errors,
                "locale.languageCode must be one of: en, fr, es, ja.");
            RequireNotBlank(locale.SystemLanguage, "locale.systemLanguage", errors);
            RequireNotBlank(locale.KeyboardLayout, "locale.keyboardLayout", errors);
            RequireNotBlank(locale.KeyboardModel, "locale.keyboardModel", errors);
            RequireNotBlank(locale.Timezone, "locale.timezone", errors);
        }

        private static void ValidateAccount(
            InstallationAccount account,
            ICollection<string> errors)
        {
            if (account == null)
            {
                errors.Add("account is required.");
                return;
            }

            Require(UsernamePattern.IsMatch(account.Username ?? string.Empty), errors,
                "account.username is not a valid Linux username.");
            Require(
                !string.IsNullOrEmpty(account.PasswordHash) &&
                account.PasswordHash.StartsWith("$6$", StringComparison.Ordinal) &&
                account.PasswordHash.IndexOfAny(new[] { '\r', '\n', '\t' }) < 0,
                errors,
                "account.passwordHash must use SHA-512 crypt.");
            Require(
                !string.IsNullOrWhiteSpace(account.ComputerName) && account.ComputerName.Length <= 63,
                errors,
                "account.computerName must contain between 1 and 63 characters.");
        }

        private static void ValidateDisk(
            string firmware,
            InstallationDisk disk,
            ICollection<string> errors)
        {
            bool isBios = string.Equals(firmware, InstallationFirmware.Bios, StringComparison.Ordinal);
            bool isUefi = string.Equals(firmware, InstallationFirmware.Uefi, StringComparison.Ordinal);
            Require(isBios || isUefi, errors, "firmware must be either 'bios' or 'uefi'.");

            if (disk == null)
            {
                errors.Add("disk is required.");
                return;
            }

            Require(disk.Number >= 0, errors, "disk.number cannot be negative.");
            RequireNotBlank(disk.UniqueId, "disk.uniqueId", errors);
            RequirePositive(disk.SizeBytes, "disk.sizeBytes", errors);
            RequirePositive(disk.LogicalSectorSizeBytes, "disk.logicalSectorSizeBytes", errors);
            Require(
                !string.IsNullOrEmpty(disk.SystemDrive) &&
                disk.SystemDrive.Length == 2 &&
                disk.SystemDrive[0] >= 'A' && disk.SystemDrive[0] <= 'Z' &&
                disk.SystemDrive[1] == ':',
                errors,
                "disk.systemDrive must be an uppercase Windows drive such as C:.");

            if (isBios)
            {
                Require(string.Equals(disk.PartitionStyle, InstallationPartitionStyle.Mbr, StringComparison.Ordinal),
                    errors, "A BIOS plan requires an MBR disk.");
            }
            else if (isUefi)
            {
                Require(string.Equals(disk.PartitionStyle, InstallationPartitionStyle.Gpt, StringComparison.Ordinal),
                    errors, "A UEFI plan requires a GPT disk.");
            }

            ValidatePartition(disk.Windows, "disk.windows", errors);
            ValidatePartition(disk.Boot, "disk.boot", errors);
            ValidatePartition(disk.Recovery, "disk.recovery", errors);
            ValidateInstallerPartition(disk.Installer, errors);
        }

        private static void ValidatePartition(
            PartitionIdentity partition,
            string name,
            ICollection<string> errors)
        {
            if (partition == null)
            {
                errors.Add($"{name} is required.");
                return;
            }

            Require(partition.Number >= 1, errors, $"{name}.number must be positive.");
            RequirePositive(partition.OffsetBytes, $"{name}.offsetBytes", errors);
            RequirePositive(partition.SizeBytes, $"{name}.sizeBytes", errors);
        }

        private static void ValidateInstallerPartition(
            InstallerPartitionPlan installer,
            ICollection<string> errors)
        {
            if (installer == null)
            {
                errors.Add("disk.installer is required.");
                return;
            }

            Require(installer.Number.HasValue == installer.OffsetBytes.HasValue, errors,
                "disk.installer.number and offsetBytes must either both be set or both be null.");
            if (installer.Number.HasValue)
                Require(installer.Number.Value >= 1, errors, "disk.installer.number must be positive.");
            if (installer.OffsetBytes.HasValue)
                RequirePositive(installer.OffsetBytes.Value, "disk.installer.offsetBytes", errors);

            RequirePositive(installer.FinalSizeBytes, "disk.installer.finalSizeBytes", errors);
            RequirePositive(installer.StagingSizeBytes, "disk.installer.stagingSizeBytes", errors);
            bool finalSizeIsWholeGiB = installer.FinalSizeBytes > 0 &&
                installer.FinalSizeBytes % InstallationSizePolicy.BytesPerGiB == 0;
            bool stagingSizeIsWholeGiB = installer.StagingSizeBytes > 0 &&
                installer.StagingSizeBytes % InstallationSizePolicy.BytesPerGiB == 0;
            Require(finalSizeIsWholeGiB && stagingSizeIsWholeGiB, errors,
                "disk.installer sizes must be whole numbers of GiB.");

            if (finalSizeIsWholeGiB && stagingSizeIsWholeGiB)
            {
                long finalSizeGiB = installer.FinalSizeBytes / InstallationSizePolicy.BytesPerGiB;
                long expectedStagingSizeGiB = finalSizeGiB >
                    InstallationSizePolicy.MaximumDirectFat32SizeGiB
                    ? InstallationSizePolicy.LargeInstallationStagingSizeGiB
                    : finalSizeGiB;
                Require(finalSizeGiB >= InstallationSizePolicy.MinimumFinalSizeGiB, errors,
                    $"disk.installer.finalSizeBytes must be at least " +
                    $"{InstallationSizePolicy.MinimumFinalSizeGiB} GiB.");
                Require(
                    installer.StagingSizeBytes ==
                    expectedStagingSizeGiB * InstallationSizePolicy.BytesPerGiB,
                    errors,
                    "disk.installer.stagingSizeBytes does not match the shared FAT32 staging policy.");
            }
        }

        private static void ValidateFeatures(
            InstallationFeatures features,
            ICollection<string> errors)
        {
            if (features == null)
            {
                errors.Add("features is required.");
                return;
            }

            if (string.IsNullOrWhiteSpace(features.WindowsProfilesJsonBase64))
            {
                errors.Add("features.windowsProfilesJsonBase64 must be valid non-empty Base64.");
                return;
            }

            try
            {
                byte[] decoded = Convert.FromBase64String(features.WindowsProfilesJsonBase64);
                Require(decoded.Length > 0, errors,
                    "features.windowsProfilesJsonBase64 must not decode to an empty value.");
            }
            catch (FormatException)
            {
                errors.Add("features.windowsProfilesJsonBase64 must be valid Base64.");
            }
        }

        private static void ValidateRuntime(
            string firmware,
            InstallationRuntime runtime,
            ICollection<string> errors)
        {
            if (runtime == null)
            {
                errors.Add("runtime is required.");
                return;
            }

            if (string.Equals(firmware, InstallationFirmware.Bios, StringComparison.Ordinal))
            {
                Require(string.Equals(
                        runtime.BootStrategy,
                        InstallationBootStrategy.BiosGrub4Dos,
                        StringComparison.Ordinal),
                    errors,
                    "A BIOS plan requires the bios-grub4dos boot strategy.");
            }
            else if (string.Equals(firmware, InstallationFirmware.Uefi, StringComparison.Ordinal))
            {
                bool isSupportedUefiStrategy = string.Equals(
                        runtime.BootStrategy,
                        InstallationBootStrategy.UefiBootNext,
                        StringComparison.Ordinal) ||
                    string.Equals(
                        runtime.BootStrategy,
                        InstallationBootStrategy.UefiFirmwareBootOrder,
                        StringComparison.Ordinal);
                Require(isSupportedUefiStrategy, errors,
                    "A UEFI plan requires a supported UEFI boot strategy.");
            }

            bool hasRecoveryRoot = runtime.RecoveryRootWindows != null;
            bool hasRecoveryRunId = runtime.RecoveryRunId != null;
            Require(hasRecoveryRoot == hasRecoveryRunId, errors,
                "runtime recoveryRootWindows and recoveryRunId must either both be set or both be null.");
            if (hasRecoveryRoot)
                RequireNotBlank(runtime.RecoveryRootWindows, "runtime.recoveryRootWindows", errors);
            if (hasRecoveryRunId)
            {
                Require(HexIdPattern.IsMatch(runtime.RecoveryRunId), errors,
                    "runtime.recoveryRunId must contain exactly 32 lowercase hexadecimal characters.");
            }
        }

        private static void RequireHttpUri(
            string value,
            string name,
            ICollection<string> errors)
        {
            Uri uri;
            bool isValid = Uri.TryCreate(value, UriKind.Absolute, out uri) &&
                (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps);
            Require(isValid, errors, $"{name} must be an absolute HTTP(S) URL.");
        }

        private static void RequireSha256(
            string value,
            string name,
            ICollection<string> errors)
        {
            Require(Sha256Pattern.IsMatch(value ?? string.Empty), errors,
                $"{name} must contain exactly 64 lowercase hexadecimal characters.");
        }

        private static void RequireNotBlank(
            string value,
            string name,
            ICollection<string> errors)
        {
            Require(!string.IsNullOrWhiteSpace(value), errors, $"{name} is required.");
        }

        private static void RequirePositive(
            long value,
            string name,
            ICollection<string> errors)
        {
            Require(value > 0, errors, $"{name} must be positive.");
        }

        private static void Require(
            bool condition,
            ICollection<string> errors,
            string message)
        {
            if (!condition)
                errors.Add(message);
        }
    }

    public sealed class InstallationPlanValidationException : Exception
    {
        public InstallationPlanValidationException(IReadOnlyCollection<string> errors)
            : base("The installation plan is invalid: " + string.Join(" ", errors))
        {
            Errors = errors ?? throw new ArgumentNullException(nameof(errors));
        }

        public IReadOnlyCollection<string> Errors { get; }
    }
}
