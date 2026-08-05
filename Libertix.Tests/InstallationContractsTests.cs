using System;
using System.IO;
using Libertix.Helpers;
using Libertix.Installation;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Libertix.Tests
{
    [TestClass]
    public sealed class InstallationContractsTests
    {
        private const string PlanId = "0123456789abcdef0123456789abcdef";

        [TestMethod]
        public void DevelopmentSshOptionsAcceptACompleteNetworkProfile()
        {
            bool parsed = StartupOptions.TryParse(
                new[]
                {
                    "--dev-ssh-static-ip", "10.42.7.20",
                    "--dev-ssh-prefix-length", "23",
                    "--dev-ssh-gateway", "10.42.6.1",
                    "--dev-ssh-dns", "9.9.9.9",
                    "--dev-ssh-dns", "1.1.1.1"
                },
                out StartupOptions options,
                out string error);

            Assert.IsTrue(parsed, error);
            Assert.AreEqual("10.42.7.20", options.DevelopmentSshStaticIpv4Address);
            Assert.AreEqual(23, options.DevelopmentSshStaticIpv4PrefixLength);
            Assert.AreEqual("10.42.6.1", options.DevelopmentSshStaticIpv4Gateway);
            CollectionAssert.AreEqual(
                new[] { "9.9.9.9", "1.1.1.1" },
                new System.Collections.Generic.List<string>(
                    options.DevelopmentSshDnsServers));
        }

        [DataTestMethod]
        [DataRow("10.42.6.0", "23", "10.42.6.1", "9.9.9.9")]
        [DataRow("10.42.7.255", "23", "10.42.6.1", "9.9.9.9")]
        [DataRow("10.42.7.20", "23", "10.43.0.1", "9.9.9.9")]
        [DataRow("10.42.7.20", "31", "10.42.7.21", "9.9.9.9")]
        [DataRow("not-an-address", "24", "10.42.7.1", "9.9.9.9")]
        [DataRow("127.0.0.2", "24", "127.0.0.1", "9.9.9.9")]
        [DataRow("169.254.10.2", "24", "169.254.10.1", "9.9.9.9")]
        [DataRow("224.0.0.2", "24", "224.0.0.1", "9.9.9.9")]
        public void DevelopmentSshOptionsRejectUnsafeProfiles(
            string address,
            string prefix,
            string gateway,
            string dns)
        {
            bool parsed = StartupOptions.TryParse(
                new[]
                {
                    "--dev-ssh-static-ip", address,
                    "--dev-ssh-prefix-length", prefix,
                    "--dev-ssh-gateway", gateway,
                    "--dev-ssh-dns", dns
                },
                out _,
                out _);

            Assert.IsFalse(parsed);
        }

        [TestMethod]
        public void DevelopmentSshOptionsRequireTheCompleteProfile()
        {
            bool parsed = StartupOptions.TryParse(
                new[] { "--dev-ssh-static-ip", "10.42.7.20" },
                out _,
                out string error);

            Assert.IsFalse(parsed);
            StringAssert.Contains(error, "requires");
        }

        [TestMethod]
        public void NvramWriteProbeCanBeSkippedOnlyByExplicitOption()
        {
            Assert.IsTrue(StartupOptions.TryParse(
                Array.Empty<string>(),
                out StartupOptions defaults,
                out string defaultError), defaultError);
            Assert.IsFalse(defaults.SkipNvramWriteProbe);

            Assert.IsTrue(StartupOptions.TryParse(
                new[] { "--skip-nvram-write-probe" },
                out StartupOptions optedOut,
                out string optOutError), optOutError);
            Assert.IsTrue(optedOut.SkipNvramWriteProbe);
        }

        [TestMethod]
        public void NvramWriteProbeSkipOptionCannotBeRepeated()
        {
            bool parsed = StartupOptions.TryParse(
                new[] { "--skip-nvram-write-probe", "--skip-nvram-write-probe" },
                out _,
                out string error);

            Assert.IsFalse(parsed);
            StringAssert.Contains(error, "can only be specified once");
        }

        [TestMethod]
        public void StartupOptionsRejectUnknownArguments()
        {
            bool parsed = StartupOptions.TryParse(
                new[] { "--dev-ssh-dsn", "9.9.9.9" },
                out _,
                out string error);

            Assert.IsFalse(parsed);
            StringAssert.Contains(error, "Unknown Libertix option");
        }

        [TestMethod]
        public void StartupOptionsAcceptInternalUefiRecoveryArguments()
        {
            bool parsed = StartupOptions.TryParse(
                new[]
                {
                    "--uefi-bootnext-failed",
                    "--uefi-recovery-state",
                    @"C:\ProgramData\Libertix\UefiRecovery\state.json"
                },
                out _,
                out string error);

            Assert.IsTrue(parsed, error);
        }

        [TestMethod]
        public void InstallationPlanValidatorAcceptsCanonicalUefiPlan()
        {
            InstallationPlanValidator.Validate(CreateValidPlan());
        }

        [TestMethod]
        public void InstallationPlanValidatorRejectsFirmwarePartitionMismatch()
        {
            InstallationPlan plan = CreateValidPlan();
            plan.Disk.PartitionStyle = InstallationPartitionStyle.Mbr;

            InstallationPlanValidationException exception =
                Assert.ThrowsException<InstallationPlanValidationException>(
                    () => InstallationPlanValidator.Validate(plan));

            StringAssert.Contains(exception.Message, "UEFI plan requires a GPT disk");
        }

        [TestMethod]
        public void InstallationPlanValidatorRejectsNoncanonicalStagingSize()
        {
            InstallationPlan plan = CreateValidPlan();
            plan.Disk.Installer.StagingSizeBytes = 9L * InstallationSizePolicy.BytesPerGiB;

            InstallationPlanValidationException exception =
                Assert.ThrowsException<InstallationPlanValidationException>(
                    () => InstallationPlanValidator.Validate(plan));

            StringAssert.Contains(exception.Message, "shared FAT32 staging policy");
        }

        [TestMethod]
        public void InstallationPlanValidatorAcceptsAlignedFourKnGeometry()
        {
            InstallationPlan plan = CreateValidPlan();
            plan.Disk.LogicalSectorSizeBytes = 4096;

            InstallationPlanValidator.Validate(plan);
        }

        [TestMethod]
        public void InstallationPlanValidatorRejectsUnsupportedLogicalSectorSize()
        {
            InstallationPlan plan = CreateValidPlan();
            plan.Disk.LogicalSectorSizeBytes = 1024;

            InstallationPlanValidationException exception =
                Assert.ThrowsException<InstallationPlanValidationException>(
                    () => InstallationPlanValidator.Validate(plan));

            StringAssert.Contains(exception.Message, "must be either 512 or 4096");
        }

        [TestMethod]
        public void InstallationPlanValidatorRejectsPartitionOffsetOutsideLogicalSectors()
        {
            InstallationPlan plan = CreateValidPlan();
            plan.Disk.LogicalSectorSizeBytes = 4096;
            plan.Disk.Windows.OffsetBytes += 512;

            InstallationPlanValidationException exception =
                Assert.ThrowsException<InstallationPlanValidationException>(
                    () => InstallationPlanValidator.Validate(plan));

            StringAssert.Contains(exception.Message, "disk.windows.offsetBytes must align");
        }

        [TestMethod]
        public void AtomicJsonFileReplacesCompleteUtf8DocumentWithoutTemporaryResidue()
        {
            string directory = Path.Combine(Path.GetTempPath(), "libertix-tests-" + Guid.NewGuid());
            string path = Path.Combine(directory, "state.json");
            try
            {
                AtomicJsonFile.Write(path, "{\"revision\":1}");
                AtomicJsonFile.Write(path, "{\"revision\":2,\"label\":\"été\"}");

                byte[] bytes = File.ReadAllBytes(path);
                CollectionAssert.AreEqual(
                    System.Text.Encoding.UTF8.GetBytes("{\"revision\":2,\"label\":\"été\"}\n"),
                    bytes);
                CollectionAssert.AreEqual(
                    Array.Empty<string>(),
                    Directory.GetFiles(directory, "*.tmp"));
            }
            finally
            {
                if (Directory.Exists(directory))
                    Directory.Delete(directory, true);
            }
        }

        [DataTestMethod]
        [DataRow(20.0, 20, 20)]
        [DataRow(31.0, 31, 31)]
        [DataRow(32.0, 32, 8)]
        [DataRow(72.0, 72, 8)]
        public void SizePolicyUsesSmallFat32StagingOnlyForLargeInstallations(
            double requestedGiB,
            int expectedFinalGiB,
            int expectedStagingGiB)
        {
            InstallationSizes sizes = InstallationSizePolicy.FromRequestedGigabytes(requestedGiB);

            Assert.AreEqual(expectedFinalGiB, sizes.FinalSizeGiB);
            Assert.AreEqual(expectedStagingGiB, sizes.StagingSizeGiB);
        }

        [TestMethod]
        public void SuccessfulStateCannotRetainFailureDetails()
        {
            InstallationStateMachine machine = InstallationStateMachine.Create(PlanId);
            machine.StartStep(InstallationStep.WindowsPreflightVerified);
            machine.CompleteStep(InstallationStep.WindowsPreflightVerified);
            machine.CompleteInstallation();
            machine.State.Failure = new InstallationFailure
            {
                Code = "stale",
                Message = "stale failure",
                Component = InstallationPhase.Windows
            };

            Assert.ThrowsException<InvalidOperationException>(
                () => InstallationStateMachine.ValidateState(machine.State));
        }

        [TestMethod]
        public void ProgressIsStoredAsValidatedStructuredState()
        {
            InstallationStateMachine machine = InstallationStateMachine.Create(PlanId);

            machine.SetProgress("installer-iso-download", 37, 48);

            Assert.AreEqual("installer-iso-download", machine.State.Progress.Stage);
            Assert.AreEqual(37, machine.State.Progress.OverallPercent);
            Assert.AreEqual(48, machine.State.Progress.DetailPercent);
            InstallationStateMachine.ValidateState(machine.State);
        }

        [TestMethod]
        public void RollbackCompensatesOnlyCompletedSteps()
        {
            InstallationStateMachine machine = InstallationStateMachine.Create(PlanId);
            machine.StartStep(InstallationStep.WindowsPreflightVerified);
            machine.Fail("cancelled", "Cancelled by the user.", InstallationPhase.Windows);
            machine.BeginRollback();

            Assert.ThrowsException<InvalidOperationException>(
                () => machine.CompleteCompensation(InstallationStep.WindowsPreflightVerified));
        }

        [TestMethod]
        public void VersionedArtifactCataloguePassesValidation()
        {
            string path = Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory,
                "TestData",
                "Libertix.Artifacts.json");

            ArtifactCatalog catalogue = ArtifactCatalog.Load(path);

            Assert.AreEqual("aria2-64.zip", catalogue.Aria2.ArchiveFileName);
            Assert.AreEqual("ext4-win-driver.exe", catalogue.Ext4Driver.FileName);
        }

        [TestMethod]
        public void Grub4DosMenuFindsThePreparedVolumeWithoutPartitionNumberConversion()
        {
            string path = Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory,
                "TestData",
                "Libertix.BootArguments.json");
            LiveBootArguments arguments = LiveBootArguments.Load(path);

            string menu = arguments.CreateGrub4DosMenu();

            StringAssert.Contains(menu, "find --set-root /installation-plan.json");
            Assert.IsFalse(menu.Contains("root (hd0,"));
            StringAssert.Contains(menu, $"kernel /live/vmlinuz {arguments.Normal}");
        }

        [DataTestMethod]
        [DataRow("00000409", "us", "", false)]
        [DataRow("00020409", "us", "intl", false)]
        [DataRow("0000040C", "fr", "", false)]
        [DataRow("0000080C", "be", "", false)]
        [DataRow("00000C0C", "ca", "fr-legacy", false)]
        [DataRow("00011009", "ca", "multix", false)]
        [DataRow("0000100C", "ch", "fr", false)]
        [DataRow("0000040A", "es", "winkeys", false)]
        [DataRow("0000080A", "latam", "", false)]
        [DataRow("00000411", "jp", "", false)]
        [DataRow("A000040C", "fr", "", true)]
        [DataRow("not-a-klid", "jp", "", true)]
        public void WindowsKeyboardIdentifiersResolveToExpectedXkbConfiguration(
            string identifier,
            string expectedLayout,
            string expectedVariant,
            bool expectedFallback)
        {
            LinuxKeyboardConfiguration resolved = WindowsKeyboardLayout.ResolveIdentifier(
                identifier,
                "jp");

            Assert.AreEqual(expectedLayout, resolved.Layout);
            Assert.AreEqual(expectedVariant, resolved.Variant);
            Assert.AreEqual(expectedFallback, resolved.UsedFallback);
        }

        [TestMethod]
        public void InstallationPlanAcceptsClonedWindowsGeometryWithPreservedGap()
        {
            InstallationPlan plan = CreateValidPlan();
            plan.Disk.Windows.SizeBytes += 256L * 1024L;

            InstallationPlanValidator.Validate(plan);
        }

        [TestMethod]
        public void InstallationPlanRejectsUnexpectedInstallerOffset()
        {
            InstallationPlan plan = CreateValidPlan();
            plan.Disk.Installer.OffsetBytes += 1024L * 1024L;

            Assert.ThrowsException<InstallationPlanValidationException>(
                () => InstallationPlanValidator.Validate(plan));
        }

        [TestMethod]
        public void InstallationPlanAcceptsReservedPrimaryMbrOffset()
        {
            InstallationPlan plan = CreateValidPlan();
            plan.Firmware = InstallationFirmware.Bios;
            plan.Disk.PartitionStyle = InstallationPartitionStyle.Mbr;
            plan.Runtime.BootStrategy = InstallationBootStrategy.BiosGrub4Dos;
            plan.Disk.Installer.OffsetBytes -= 1024L * 1024L;

            InstallationPlanValidator.Validate(plan);
        }

        [TestMethod]
        public void InstallationPlanRejectsReservedMbrOffsetForUefi()
        {
            InstallationPlan plan = CreateValidPlan();
            plan.Disk.Installer.OffsetBytes -= 1024L * 1024L;

            Assert.ThrowsException<InstallationPlanValidationException>(
                () => InstallationPlanValidator.Validate(plan));
        }

        private static InstallationPlan CreateValidPlan()
        {
            const long GiB = InstallationSizePolicy.BytesPerGiB;
            return new InstallationPlan
            {
                PlanId = PlanId,
                CreatedAtUtc = DateTimeOffset.Parse("2026-08-05T12:00:00Z"),
                Firmware = InstallationFirmware.Uefi,
                Distribution = new InstallationDistribution
                {
                    Name = "Linux Mint",
                    InstallerIsoFileName = "mint.iso",
                    InstallerIsoUrl = "https://example.test/mint.iso",
                    InstallerIsoWindowsPath = @"C:\mint.iso",
                    InstallerIsoSha256 = new string('b', 64),
                    LiveIsoUrl = "https://example.test/libertix-installer-uefi.iso",
                    LiveIsoSha256 = new string('c', 64)
                },
                Locale = new InstallationLocale
                {
                    LanguageCode = "en",
                    SystemLanguage = "en_US.UTF-8",
                    KeyboardLayout = "us",
                    KeyboardModel = "pc105",
                    Timezone = "Etc/UTC"
                },
                Account = new InstallationAccount
                {
                    Username = "test",
                    PasswordHash = "$6$salt$hash",
                    ComputerName = "libertix-test"
                },
                Disk = new InstallationDisk
                {
                    Number = 0,
                    UniqueId = "test-disk",
                    SizeBytes = 256L * GiB,
                    LogicalSectorSizeBytes = 512,
                    PartitionStyle = InstallationPartitionStyle.Gpt,
                    SystemDrive = "C:",
                    Windows = new PartitionIdentity
                    {
                        Number = 3,
                        OffsetBytes = 2L * GiB,
                        SizeBytes = 180L * GiB
                    },
                    Boot = new PartitionIdentity
                    {
                        Number = 1,
                        OffsetBytes = 1L * 1024 * 1024,
                        SizeBytes = 100L * 1024 * 1024
                    },
                    Recovery = new PartitionIdentity
                    {
                        Number = 4,
                        OffsetBytes = 240L * GiB,
                        SizeBytes = 1L * GiB
                    },
                    Installer = new InstallerPartitionPlan
                    {
                        Number = 5,
                        OffsetBytes = 142L * GiB,
                        FinalSizeBytes = 40L * GiB,
                        StagingSizeBytes = 8L * GiB
                    }
                },
                Features = new InstallationFeatures
                {
                    WindowsProfilesJsonBase64 = "W10="
                },
                Runtime = new InstallationRuntime
                {
                    BootStrategy = InstallationBootStrategy.UefiBootNext,
                    RecoveryRootWindows = @"C:\ProgramData\Libertix\Recovery",
                    RecoveryRunId = new string('d', 32)
                }
            };
        }
    }
}
