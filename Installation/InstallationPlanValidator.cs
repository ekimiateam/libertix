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

        private static readonly Regex ComputerNamePattern = new Regex(
            "^[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$",
            RegexOptions.CultureInvariant);

        private static readonly Regex AbsoluteWindowsPathPattern = new Regex(
            "^[A-Za-z]:[\\\\/]",
            RegexOptions.CultureInvariant);

        private static readonly Regex XkbNamePattern = new Regex(
            "^[a-z0-9_-]+$",
            RegexOptions.CultureInvariant);

        private static readonly Regex SafeIdentifierPattern = new Regex(
            "^[a-z0-9](?:[a-z0-9._-]{0,62}[a-z0-9])?$",
            RegexOptions.CultureInvariant);

        private static readonly Regex SafeGrubLabelPattern = new Regex(
            "^[A-Za-z0-9][A-Za-z0-9 ._()+-]{0,79}$",
            RegexOptions.CultureInvariant);

        private static readonly Regex TimezonePattern = new Regex(
            "^[A-Za-z0-9._+-]+(?:/[A-Za-z0-9._+-]+)+$",
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
            ValidateDevelopment(plan.Development, errors);
            ValidateWindowsPathDrives(plan, errors);

            if (errors.Count > 0)
                throw new InstallationPlanValidationException(errors);
        }

        private static void ValidateWindowsPathDrives(
            InstallationPlan plan,
            ICollection<string> errors)
        {
            string systemDrive = plan.Disk?.SystemDrive;
            if (string.IsNullOrEmpty(systemDrive) || systemDrive.Length != 2)
                return;

            ValidateWindowsPathDrive(
                plan.Distribution?.InstallerIsoWindowsPath,
                "distribution.installerIsoWindowsPath",
                systemDrive,
                errors);
            ValidateWindowsPathDrive(
                plan.Account?.PasswordHashWindowsPath,
                "account.passwordHashWindowsPath",
                systemDrive,
                errors);
            if (plan.Runtime?.RecoveryRootWindows != null)
            {
                ValidateWindowsPathDrive(
                    plan.Runtime.RecoveryRootWindows,
                    "runtime.recoveryRootWindows",
                    systemDrive,
                    errors);
            }
        }

        private static void ValidateWindowsPathDrive(
            string path,
            string pathName,
            string systemDrive,
            ICollection<string> errors)
        {
            if (!AbsoluteWindowsPathPattern.IsMatch(path ?? string.Empty))
                return;

            Require(
                string.Equals(path.Substring(0, 2), systemDrive, StringComparison.OrdinalIgnoreCase),
                errors,
                $"{pathName} must be located on disk.systemDrive.");
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

            RequireSafeIdentifier(distribution.Id, "distribution.id", errors);
            RequireNotBlank(distribution.Name, "distribution.name", errors);
            RequireSafeIdentifier(
                distribution.OsReleaseId,
                "distribution.osReleaseId",
                errors);
            RequireSafeGrubLabel(
                distribution.GrubDisplayName,
                "distribution.grubDisplayName",
                errors);
            RequireSafeIdentifier(
                distribution.GrubIcon,
                "distribution.grubIcon",
                errors);
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
            Require(XkbNamePattern.IsMatch(locale.KeyboardLayout ?? string.Empty), errors,
                "locale.keyboardLayout is not a valid XKB layout name.");
            Require(XkbNamePattern.IsMatch(locale.KeyboardModel ?? string.Empty), errors,
                "locale.keyboardModel is not a valid XKB model name.");
            Require(
                string.IsNullOrEmpty(locale.KeyboardVariant) ||
                XkbNamePattern.IsMatch(locale.KeyboardVariant),
                errors,
                "locale.keyboardVariant is not a valid XKB variant name.");
            RequireNotBlank(locale.Timezone, "locale.timezone", errors);
            Require(TimezonePattern.IsMatch(locale.Timezone ?? string.Empty), errors,
                "locale.timezone is not a safe IANA timezone name.");
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
                !string.IsNullOrWhiteSpace(account.PasswordHashWindowsPath) &&
                Regex.IsMatch(
                    account.PasswordHashWindowsPath,
                    @"^[A-Za-z]:\\(?!.*(?:^|\\)\.\.(?:\\|$)).+$",
                    RegexOptions.CultureInvariant),
                errors,
                "account.passwordHashWindowsPath must be an absolute safe Windows path.");
            Require(ComputerNamePattern.IsMatch(account.ComputerName ?? string.Empty), errors,
                "account.computerName is not a valid Linux hostname.");
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
            string expectedPartitionTablePrefix = isBios ? "mbr:" : "gpt:";
            Require(
                !string.IsNullOrWhiteSpace(disk.PartitionTableId) &&
                disk.PartitionTableId.StartsWith(
                    expectedPartitionTablePrefix,
                    StringComparison.Ordinal) &&
                Regex.IsMatch(
                    disk.PartitionTableId,
                    isBios
                        ? "^mbr:[0-9a-f]{8}$"
                        : "^gpt:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"),
                errors,
                $"disk.partitionTableId must be a canonical " +
                $"{expectedPartitionTablePrefix.TrimEnd(':').ToUpperInvariant()} identifier.");
            RequirePositive(disk.SizeBytes, "disk.sizeBytes", errors);
            bool sectorSizeIsSupported =
                disk.LogicalSectorSizeBytes == 512 || disk.LogicalSectorSizeBytes == 4096;
            Require(sectorSizeIsSupported, errors,
                "disk.logicalSectorSizeBytes must be either 512 or 4096.");
            if (sectorSizeIsSupported)
            {
                Require(disk.SizeBytes % disk.LogicalSectorSizeBytes == 0, errors,
                    "disk.sizeBytes must align to disk.logicalSectorSizeBytes.");
            }
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

            ValidatePartition(disk.Windows, "disk.windows", disk.LogicalSectorSizeBytes, errors);
            ValidatePartition(disk.Boot, "disk.boot", disk.LogicalSectorSizeBytes, errors);
            ValidatePartition(disk.Recovery, "disk.recovery", disk.LogicalSectorSizeBytes, errors);
            ValidateInstallerPartition(disk.Installer, disk.LogicalSectorSizeBytes, errors);
            ValidateDiskGeometry(disk, errors);
        }

        private static void ValidateDiskGeometry(
            InstallationDisk disk,
            ICollection<string> errors)
        {
            if (disk.Windows == null || disk.Boot == null || disk.Recovery == null ||
                disk.Installer == null || disk.SizeBytes <= 0)
            {
                return;
            }

            PartitionIdentity[] fixedPartitions = { disk.Windows, disk.Boot, disk.Recovery };
            string[] fixedPartitionNames = { "disk.windows", "disk.boot", "disk.recovery" };
            var ends = new long[fixedPartitions.Length];
            for (int index = 0; index < fixedPartitions.Length; index++)
            {
                PartitionIdentity partition = fixedPartitions[index];
                if (partition.OffsetBytes <= 0 || partition.SizeBytes <= 0 ||
                    partition.SizeBytes > disk.SizeBytes ||
                    partition.OffsetBytes > disk.SizeBytes - partition.SizeBytes)
                {
                    errors.Add($"{fixedPartitionNames[index]} must fit within disk.sizeBytes.");
                    return;
                }
                ends[index] = partition.OffsetBytes + partition.SizeBytes;
            }

            for (int left = 0; left < fixedPartitions.Length; left++)
            {
                for (int right = left + 1; right < fixedPartitions.Length; right++)
                {
                    bool overlap =
                        fixedPartitions[left].OffsetBytes < ends[right] &&
                        fixedPartitions[right].OffsetBytes < ends[left];
                    Require(!overlap, errors,
                        $"{fixedPartitionNames[left]} and {fixedPartitionNames[right]} overlap.");
                }
            }

            long windowsEnd = ends[0];
            Require(windowsEnd <= disk.Recovery.OffsetBytes, errors,
                "disk.recovery must start at or after the original Windows partition end.");

            if (!disk.Installer.OffsetBytes.HasValue ||
                disk.Installer.FinalSizeBytes <= 0 ||
                disk.LogicalSectorSizeBytes <= 0)
            {
                return;
            }

            const long partitionAlignmentBytes = 1024L * 1024L;
            // Windows preserves the partition end modulo 1 MiB when it shrinks C:.
            // Reconstructing the expected start from the original extent rejects a
            // staging partition silently created in another free extent of the disk.
            long alignmentPadding = windowsEnd % partitionAlignmentBytes;
            if (disk.Installer.FinalSizeBytes > windowsEnd - alignmentPadding)
            {
                errors.Add("disk.installer.finalSizeBytes exceeds the original Windows extent.");
                return;
            }
            long expectedOffset = windowsEnd - alignmentPadding - disk.Installer.FinalSizeBytes;
            // Converting an MBR logical partition into a primary partition may consume
            // the adjacent alignment unit that previously held the extended container.
            long primaryMbrOffset = expectedOffset - partitionAlignmentBytes;
            bool offsetMatches = disk.Installer.OffsetBytes.Value == expectedOffset ||
                (string.Equals(
                    disk.PartitionStyle,
                    InstallationPartitionStyle.Mbr,
                    StringComparison.Ordinal) &&
                 disk.Installer.OffsetBytes.Value == primaryMbrOffset);
            Require(offsetMatches, errors,
                "disk.installer.offsetBytes does not match the aligned Windows shrink geometry.");
            Require(
                disk.Installer.FinalSizeBytes <= disk.Recovery.OffsetBytes &&
                disk.Installer.OffsetBytes.Value <=
                    disk.Recovery.OffsetBytes - disk.Installer.FinalSizeBytes,
                errors,
                "disk.installer final extent would overlap disk.recovery.");
        }

        private static void ValidatePartition(
            PartitionIdentity partition,
            string name,
            int logicalSectorSizeBytes,
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
            if (logicalSectorSizeBytes == 512 || logicalSectorSizeBytes == 4096)
            {
                Require(partition.OffsetBytes % logicalSectorSizeBytes == 0, errors,
                    $"{name}.offsetBytes must align to disk.logicalSectorSizeBytes.");
                Require(partition.SizeBytes % logicalSectorSizeBytes == 0, errors,
                    $"{name}.sizeBytes must align to disk.logicalSectorSizeBytes.");
            }
        }

        private static void ValidateInstallerPartition(
            InstallerPartitionPlan installer,
            int logicalSectorSizeBytes,
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
            {
                RequirePositive(installer.OffsetBytes.Value, "disk.installer.offsetBytes", errors);
                if (logicalSectorSizeBytes == 512 || logicalSectorSizeBytes == 4096)
                {
                    Require(installer.OffsetBytes.Value % logicalSectorSizeBytes == 0, errors,
                        "disk.installer.offsetBytes must align to disk.logicalSectorSizeBytes.");
                }
            }

            RequirePositive(installer.FinalSizeBytes, "disk.installer.finalSizeBytes", errors);
            RequirePositive(installer.StagingSizeBytes, "disk.installer.stagingSizeBytes", errors);
            bool finalSizeIsWholeGiB = installer.FinalSizeBytes > 0 &&
                installer.FinalSizeBytes % InstallationSizePolicy.BytesPerGiB == 0;
            bool stagingSizeIsWholeGiB = installer.StagingSizeBytes > 0 &&
                installer.StagingSizeBytes % InstallationSizePolicy.BytesPerGiB == 0;
            // The UI records GiB policy choices, while observed partition geometry is
            // tracked separately. Accepting rounded policy values here would make the
            // plan describe a different allocation from the one the user approved.
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
            {
                RequireNotBlank(runtime.RecoveryRootWindows, "runtime.recoveryRootWindows", errors);
                Require(
                    !string.IsNullOrWhiteSpace(runtime.RecoveryRootWindows) &&
                    Regex.IsMatch(
                        runtime.RecoveryRootWindows,
                        @"^[A-Za-z]:\\(?!.*(?:^|\\)\.\.(?:\\|$)).+$",
                        RegexOptions.CultureInvariant),
                    errors,
                    "runtime.recoveryRootWindows must be an absolute safe Windows path.");
            }
            if (hasRecoveryRunId)
            {
                Require(HexIdPattern.IsMatch(runtime.RecoveryRunId), errors,
                    "runtime.recoveryRunId must contain exactly 32 lowercase hexadecimal characters.");
            }
        }

        private static void ValidateDevelopment(
            InstallationDevelopmentOptions development,
            ICollection<string> errors)
        {
            if (development == null)
                return;

            Require(development.EnableSsh, errors,
                "development.enableSsh must be true when development options are present.");
            if (!Ipv4NetworkPolicy.TryValidate(
                development.StaticIpv4Address,
                development.StaticIpv4PrefixLength,
                development.StaticIpv4Gateway,
                development.DnsServers,
                out _,
                out _,
                out _,
                out string networkError))
            {
                errors.Add("development network is invalid: " + networkError);
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

        private static void RequireSafeIdentifier(
            string value,
            string name,
            ICollection<string> errors)
        {
            Require(SafeIdentifierPattern.IsMatch(value ?? string.Empty), errors,
                $"{name} must be a safe lowercase identifier.");
        }

        private static void RequireSafeGrubLabel(
            string value,
            string name,
            ICollection<string> errors)
        {
            Require(SafeGrubLabelPattern.IsMatch(value ?? string.Empty), errors,
                $"{name} contains unsupported GRUB label characters.");
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
