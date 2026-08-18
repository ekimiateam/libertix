using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Text.Json;
using Libertix.Helpers;
using Libertix.Installation;
using Libertix.Models;
using Libertix.Pages;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Libertix.Tests
{
    [TestClass]
    public sealed class InstallationContractsTests
    {
        private const string PlanId = "0123456789abcdef0123456789abcdef";

        [TestMethod]
        public void Aria2UsesOneNonResumableConnectionWithoutByteRangeSupport()
        {
            string[] arguments = ApplyChanges.CreateAria2DownloadArguments(
                "https://example.test/live.iso",
                @"C:\LibertixTools\downloads",
                "live.iso",
                supportsByteRanges: false,
                maximumConnections: 5);

            CollectionAssert.Contains(arguments, "--continue=false");
            CollectionAssert.Contains(arguments, "--max-connection-per-server=1");
            CollectionAssert.Contains(arguments, "--split=1");
        }

        [TestMethod]
        public void RangeProbeRequiresAnExactOneBytePartialResponse()
        {
            Assert.IsTrue(ApplyChanges.IsExactSingleByteRangeResponse(
                HttpStatusCode.PartialContent,
                ContentRangeHeaderValue.Parse("bytes 0-0/524288000")));
            Assert.IsFalse(ApplyChanges.IsExactSingleByteRangeResponse(
                HttpStatusCode.OK,
                null));
            Assert.IsFalse(ApplyChanges.IsExactSingleByteRangeResponse(
                HttpStatusCode.PartialContent,
                ContentRangeHeaderValue.Parse("bytes 0-524287999/524288000")));
        }

        [TestMethod]
        public void TerminalDiagnosticsRemoveAnsiFormattingWithoutDamagingUnicode()
        {
            string diagnostic = "[\u001b[1;31mERROR\u001b[0m] Problème réseau";

            Assert.AreEqual(
                "[ERROR] Problème réseau",
                WindowsProcessRunner.NormalizeTerminalText(diagnostic));
        }

        [TestMethod]
        public void UefiRecoveryPayloadIncludesOnlyRequiredRuntimeFiles()
        {
            string root = Path.Combine(
                Path.GetTempPath(),
                "libertix-recovery-payload-" + Guid.NewGuid().ToString("N"));
            try
            {
                Directory.CreateDirectory(Path.Combine(root, "Scripts", "modules"));
                Directory.CreateDirectory(Path.Combine(root, "Tools", "aria2"));
                Directory.CreateDirectory(Path.Combine(root, "Resources"));
                Directory.CreateDirectory(Path.Combine(root, "Unrelated"));
                string[] included =
                {
                    "Libertix.exe",
                    "Libertix.exe.config",
                    "System.Text.Json.dll",
                    Path.Combine("Scripts", "libertix-uefi-install.ps1"),
                    Path.Combine("Scripts", "modules", "Libertix.Process.psm1"),
                    Path.Combine("Scripts", "modules", "Libertix.FirmwareRead.psm1"),
                    Path.Combine("Scripts", "modules", "Libertix.PreferredBootPath.psm1"),
                    Path.Combine("Scripts", "modules", "Libertix.StorageGeometry.psm1"),
                    Path.Combine("Tools", "aria2", "aria2c.exe"),
                    Path.Combine("Resources", "Libertix.Translations.json"),
                    Path.Combine("Resources", "Images", "icon.ico")
                };
                foreach (string relativePath in included)
                {
                    string path = Path.Combine(root, relativePath);
                    Directory.CreateDirectory(Path.GetDirectoryName(path));
                    File.WriteAllText(path, relativePath);
                }
                foreach (string relativePath in new[]
                {
                    "libertix-installer-uefi.iso",
                    "Libertix.pdb",
                    "catalog.json",
                    Path.Combine("Unrelated", "debug.log")
                })
                {
                    string path = Path.Combine(root, relativePath);
                    Directory.CreateDirectory(Path.GetDirectoryName(path));
                    File.WriteAllText(path, relativePath);
                }

                string[] selected = ApplyChanges
                    .EnumerateUefiRecoveryPayloadFiles(root)
                    .Select(path => path.Substring(root.Length).TrimStart(
                        Path.DirectorySeparatorChar,
                        Path.AltDirectorySeparatorChar))
                    .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
                    .ToArray();

                CollectionAssert.AreEqual(
                    included.OrderBy(path => path, StringComparer.OrdinalIgnoreCase).ToArray(),
                    selected);
            }
            finally
            {
                if (Directory.Exists(root))
                    Directory.Delete(root, true);
            }
        }

        [TestMethod]
        public void PowerShellJsonResultUsesOnlyTheFinalCompleteObject()
        {
            PowerShellJsonResult result = PowerShellJsonResult.ParseFinalObject(
                "CHECK=storage{diagnostic}\r\n" +
                "{not-json}\r\n" +
                "{\"preflightOk\":true,\"size\":42,\"warnings\":[\"one\",\"two\"]}\r\n");

            Assert.IsTrue(result.GetBoolean("preflightOk"));
            Assert.AreEqual(42, result.GetInt32("size"));
            CollectionAssert.AreEqual(
                new[] { "one", "two" },
                result.GetStringArray("warnings"));
        }

        [TestMethod]
        public void PowerShellJsonResultRejectsMissingFinalObject()
        {
            Assert.ThrowsException<InvalidOperationException>(
                () => PowerShellJsonResult.ParseFinalObject("CHECK=storage\r\nnot json\r\n"));
        }

        [TestMethod]
        public void RedirectedStreamDrainRefusesAnUnclosedPipe()
        {
            var incomplete = new TaskCompletionSource<bool>();

            Assert.ThrowsException<InvalidOperationException>(() =>
                WindowsProcessRunner.WaitForRedirectedStreams(
                    TimeSpan.FromMilliseconds(20),
                    incomplete.Task));
        }

        [TestMethod]
        public void UefiRecoveryStatePreservesFieldsOwnedByANewerAgent()
        {
            const string json = "{\"RunId\":\"0123456789abcdef0123456789abcdef\"," +
                "\"Phase\":\"Preparing\",\"FutureCheckpoint\":{\"revision\":7}}";

            UefiRecoveryState state = JsonSerializer.Deserialize<UefiRecoveryState>(json);
            state.Phase = "FallbackNeeded";
            string rewritten = JsonSerializer.Serialize(state);
            using (JsonDocument document = JsonDocument.Parse(rewritten))
            {
                Assert.AreEqual(
                    7,
                    document.RootElement
                        .GetProperty("FutureCheckpoint")
                        .GetProperty("revision")
                        .GetInt32());
            }
        }

        [TestMethod]
        public void DevelopmentSshOptionsAcceptACompleteNetworkProfile()
        {
            bool parsed = StartupOptions.TryParse(
                new[]
                {
                    "--dev-ssh-static-ip", "198.51.100.20",
                    "--dev-ssh-prefix-length", "23",
                    "--dev-ssh-gateway", "198.51.100.1",
                    "--dev-ssh-dns", "9.9.9.9",
                    "--dev-ssh-dns", "1.1.1.1"
                },
                out StartupOptions options,
                out string error);

            Assert.IsTrue(parsed, error);
            Assert.AreEqual("198.51.100.20", options.DevelopmentSshStaticIpv4Address);
            Assert.AreEqual(23, options.DevelopmentSshStaticIpv4PrefixLength);
            Assert.AreEqual("198.51.100.1", options.DevelopmentSshStaticIpv4Gateway);
            CollectionAssert.AreEqual(
                new[] { "9.9.9.9", "1.1.1.1" },
                new System.Collections.Generic.List<string>(
                    options.DevelopmentSshDnsServers));
        }

        [DataTestMethod]
        [DataRow("198.51.100.0", "23", "198.51.100.1", "9.9.9.9")]
        [DataRow("198.51.101.255", "23", "198.51.100.1", "9.9.9.9")]
        [DataRow("198.51.100.20", "23", "203.0.113.1", "9.9.9.9")]
        [DataRow("198.51.100.20", "31", "198.51.100.21", "9.9.9.9")]
        [DataRow("not-an-address", "24", "198.51.100.1", "9.9.9.9")]
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
                new[] { "--dev-ssh-static-ip", "198.51.100.20" },
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
                    "--UEFI-BOOTNEXT-FAILED",
                    "--UEFI-RECOVERY-STATE",
                    @"C:\ProgramData\Libertix\UefiRecovery\state.json"
                },
                out StartupOptions options,
                out string error);

            Assert.IsTrue(parsed, error);
            Assert.IsTrue(options.UefiBootNextFailed);
            Assert.AreEqual(
                @"C:\ProgramData\Libertix\UefiRecovery\state.json",
                options.UefiRecoveryStatePath);
        }

        [DataTestMethod]
        [DataRow("--unattended")]
        [DataRow("--unattended-config")]
        public void UnattendedStartupOptionsRequireThePairedArguments(string option)
        {
            string[] arguments = option == "--unattended"
                ? new[] { option }
                : new[] { option, @"C:\ProgramData\Libertix\Automation\missing.json" };

            bool parsed = StartupOptions.TryParse(arguments, out _, out string error);

            Assert.IsFalse(parsed);
            StringAssert.Contains(error, "must be specified together");
        }

        [TestMethod]
        public void UnattendedStartupOptionsLoadValidatedValuesAndConsumeTheSecretFile()
        {
            string configPath = WriteUnattendedConfig(
                "{\"schemaVersion\":1,\"distribution\":\"zorin\"," +
                "\"linuxSizeGiB\":120,\"linuxUsername\":\"test\"," +
                "\"linuxPassword\":\"pass\",\"computerName\":\"test-linux\"," +
                "\"shareWindowsFilesInLinux\":true," +
                "\"shareLinuxFilesInWindows\":false}");

            bool parsed = StartupOptions.TryParse(
                new[] { "--unattended", "--unattended-config", configPath },
                out StartupOptions options,
                out string error);

            Assert.IsTrue(parsed, error);
            Assert.IsFalse(File.Exists(configPath));
            Assert.AreEqual("zorin", options.Unattended.Distribution);
            Assert.AreEqual(120, options.Unattended.LinuxSizeGiB);
            Assert.AreEqual("test", options.Unattended.LinuxUsername);
            Assert.AreEqual("pass", options.Unattended.LinuxPassword);
            Assert.AreEqual("test-linux", options.Unattended.ComputerName);
            Assert.IsTrue(options.Unattended.ShareWindowsFilesInLinux);
            Assert.IsFalse(options.Unattended.ShareLinuxFilesInWindows);
            StringAssert.EndsWith(options.Unattended.StatusPath, ".status.json");
            StringAssert.EndsWith(options.Unattended.AcknowledgementPath, ".ack");
        }

        [TestMethod]
        public void UnattendedStartupOptionsRejectAReservedLinuxAccountAndConsumeTheFile()
        {
            string configPath = WriteUnattendedConfig(
                "{\"schemaVersion\":1,\"distribution\":\"mint\"," +
                "\"linuxSizeGiB\":100,\"linuxUsername\":\"root\"," +
                "\"linuxPassword\":\"pass\",\"computerName\":\"test-linux\"," +
                "\"shareWindowsFilesInLinux\":true," +
                "\"shareLinuxFilesInWindows\":true}");

            bool parsed = StartupOptions.TryParse(
                new[] { "--unattended", "--unattended-config", configPath },
                out _,
                out string error);

            Assert.IsFalse(parsed);
            StringAssert.Contains(error, "invalid or reserved");
            Assert.IsFalse(File.Exists(configPath));
        }

        private static string WriteUnattendedConfig(string json)
        {
            string directory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                "Libertix",
                "Automation");
            Directory.CreateDirectory(directory);
            string path = Path.Combine(directory, "unattended-test-" + Guid.NewGuid() + ".json");
            File.WriteAllText(path, json);
            return path;
        }

        [TestMethod]
        public void SharedInstallationPolicyDefinesTheAria2ConnectionLimit()
        {
            Assert.AreEqual(5, InstallationPolicy.Current.Download.Aria2MaximumConnections);
            Assert.AreEqual(6, InstallationPolicy.Current.Download.MaximumAttempts);
            Assert.AreEqual(10, InstallationPolicy.Current.Download.RetryBaseDelaySeconds);
        }

        [TestMethod]
        public void SharedInstallationPolicyDefinesDistinctMediaAndStagingLabels()
        {
            InstallationVolumeLabelPolicy labels = InstallationPolicy.Current.VolumeLabels;

            Assert.AreEqual("LIBERTIXISO", labels.InstallationMedia);
            Assert.AreEqual("LIBERTIXSTG", labels.Staging);
            CollectionAssert.AreEqual(
                new[] { "LIBERTIX", "LIBERTIXEFI" },
                labels.LegacyStagingForRecovery);
        }

        [TestMethod]
        public void SharedInstallationPolicyDefinesTheRecommendedLinuxSize()
        {
            Assert.AreEqual(
                0.4,
                InstallationSizePolicy.RecommendedLinuxFractionOfFreeSpace,
                0.0001);
            Assert.AreEqual(100, InstallationSizePolicy.MaximumRecommendedLinuxSizeGiB);
        }

        [TestMethod]
        public void SharedInstallationPolicyDefinesDebianReservedAccountNames()
        {
            string[] names = InstallationPolicy.Current.Account.ReservedUsernames;

            Assert.AreEqual(108, names.Length);
            CollectionAssert.Contains(names, "root");
            CollectionAssert.Contains(names, "admin");
            CollectionAssert.Contains(names, "Debian-exim");
            CollectionAssert.Contains(names, "input");
            CollectionAssert.Contains(names, "kvm");
            CollectionAssert.Contains(names, "render");
            Assert.AreEqual(
                "https://sources.debian.org/src/user-setup/1.107/reserved-usernames",
                InstallationPolicy.Current.Account.ReservedUsernamesSource);
        }

        [DataTestMethod]
        [DataRow("root")]
        [DataRow("admin")]
        [DataRow("debian-exim")]
        public void AccountPolicyRejectsReservedLinuxUsernames(string username)
        {
            Assert.IsTrue(AccountPolicy.IsValidUsernameSyntax(username));
            Assert.IsTrue(AccountPolicy.IsReservedUsername(username));
            Assert.IsFalse(AccountPolicy.IsValidUsername(username));
        }

        [DataTestMethod]
        [DataRow("admin", "admin-linux")]
        [DataRow("root", "root-linux")]
        [DataRow("Alice Smith", "alicesmith")]
        [DataRow("123", "user")]
        public void AccountPolicyCreatesAValidDefaultUsername(
            string windowsUsername,
            string expected)
        {
            string result = AccountPolicy.CreateDefaultUsername(windowsUsername);

            Assert.AreEqual(expected, result);
            Assert.IsTrue(AccountPolicy.IsValidUsername(result));
        }

        [TestMethod]
        public void AccountPolicyUsesFourCharacterMinimumPassword()
        {
            Assert.AreEqual(4, AccountPolicy.MinimumPasswordLength);
        }

        [TestMethod]
        public void AccountPolicyTruncatesTheDefaultUsernameSafely()
        {
            string result = AccountPolicy.CreateDefaultUsername(new string('a', 40));

            Assert.AreEqual(32, result.Length);
            Assert.IsTrue(AccountPolicy.IsValidUsername(result));
        }

        [TestMethod]
        public void InstallationPlanValidatorRejectsReservedLinuxUsername()
        {
            InstallationPlan plan = CreateValidPlan();
            plan.Account.Username = "admin";

            InstallationPlanValidationException exception =
                Assert.ThrowsException<InstallationPlanValidationException>(
                    () => InstallationPlanValidator.Validate(plan));

            StringAssert.Contains(exception.Message, "not a valid Linux username");
        }

        [TestMethod]
        public void InstallationPlanValidatorAcceptsCanonicalUefiPlan()
        {
            InstallationPlanValidator.Validate(CreateValidPlan());
        }

        [TestMethod]
        public void InstallationPlanValidatorAcceptsPendingUefiBitLockerDecryption()
        {
            InstallationPlan plan = CreateValidPlan();
            plan.Runtime.WindowsBitLockerState =
                InstallationBitLockerState.EncryptedOrProtected;

            InstallationPlanValidator.Validate(plan);
        }

        [TestMethod]
        public void InstallationPlanValidatorRejectsPendingBiosBitLockerDecryption()
        {
            InstallationPlan plan = CreateValidPlan();
            plan.Firmware = InstallationFirmware.Bios;
            plan.Disk.PartitionStyle = InstallationPartitionStyle.Mbr;
            plan.Disk.PartitionTableId = "mbr:12345678";
            plan.Runtime.BootStrategy = InstallationBootStrategy.BiosGrub4Dos;
            plan.Runtime.SecureBootEnabled = false;
            plan.Runtime.TrustedMicrosoftUefiAuthorities = new string[0];
            plan.Runtime.WindowsBitLockerState =
                InstallationBitLockerState.EncryptedOrProtected;

            InstallationPlanValidationException exception =
                Assert.ThrowsException<InstallationPlanValidationException>(
                    () => InstallationPlanValidator.Validate(plan));

            StringAssert.Contains(exception.Message, "windowsBitLockerState is invalid");
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
        public async Task BoundedHttpContentRejectsDeclaredAndChunkedOversizePayloads()
        {
            using (var accepted = new ByteArrayContent(new byte[16]))
            {
                byte[] result = await BoundedHttpContent.ReadAsync(
                    accepted,
                    16,
                    CancellationToken.None);
                Assert.AreEqual(16, result.Length);
            }

            using (var declaredOversize = new ByteArrayContent(new byte[17]))
            {
                await Assert.ThrowsExceptionAsync<InvalidDataException>(() =>
                    BoundedHttpContent.ReadAsync(
                        declaredOversize,
                        16,
                        CancellationToken.None));
            }

            using (var chunkedOversize = new ByteArrayContent(new byte[17]))
            {
                chunkedOversize.Headers.ContentLength = null;
                await Assert.ThrowsExceptionAsync<InvalidDataException>(() =>
                    BoundedHttpContent.ReadAsync(
                        chunkedOversize,
                        16,
                        CancellationToken.None));
            }
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

        [TestMethod]
        public void AtomicJsonFileRetriesATransientWindowsSharingViolation()
        {
            string directory = Path.Combine(Path.GetTempPath(), "libertix-tests-" + Guid.NewGuid());
            string path = Path.Combine(directory, "state.json");
            try
            {
                AtomicJsonFile.Write(path, "{\"revision\":1}");
                var locked = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
                Task release = Task.Run(() =>
                {
                    Thread.Sleep(150);
                    locked.Dispose();
                });

                AtomicJsonFile.Write(path, "{\"revision\":2}");
                release.Wait();

                Assert.AreEqual("{\"revision\":2}\n", File.ReadAllText(path));
            }
            finally
            {
                if (Directory.Exists(directory))
                    Directory.Delete(directory, true);
            }
        }

        [DataTestMethod]
        [DataRow(20.0, 20, 8)]
        [DataRow(31.0, 31, 8)]
        [DataRow(32.0, 32, 8)]
        [DataRow(72.0, 72, 8)]
        public void SizePolicyUsesOneBoundedFat32StagingSize(
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
            foreach (string step in new[]
            {
                InstallationStep.WindowsPreflightVerified,
                InstallationStep.WindowsArtifactsVerified,
                InstallationStep.WindowsRecoveryArmed,
                InstallationStep.WindowsSystemVolumeShrunk,
                InstallationStep.WindowsInstallerPartitionCreated,
                InstallationStep.WindowsLiveMediaPrepared,
                InstallationStep.WindowsTemporaryBootPrepared,
                InstallationStep.LivePreflightVerified,
                InstallationStep.LiveInstallerPartitionExpanded,
                InstallationStep.LiveTargetFilesystemCreated,
                InstallationStep.LiveDistributionExtracted,
                InstallationStep.TargetSystemConfigured,
                InstallationStep.TargetBootloaderInstalled,
                InstallationStep.TargetInstallationVerified
            })
            {
                machine.StartStep(step);
                machine.CompleteStep(step);
            }
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
        public void StateMachineRejectsOutOfOrderAndIncompleteSuccess()
        {
            InstallationStateMachine machine = InstallationStateMachine.Create(PlanId);

            Assert.ThrowsException<InvalidOperationException>(
                () => machine.StartStep(InstallationStep.WindowsRecoveryArmed));

            machine.StartStep(InstallationStep.WindowsPreflightVerified);
            machine.CompleteStep(InstallationStep.WindowsPreflightVerified);

            Assert.ThrowsException<InvalidOperationException>(
                () => machine.CompleteInstallation());
        }

        [TestMethod]
        public void LinuxAllocationReservesTheInstallerIsoAndWindowsMinimum()
        {
            Assert.AreEqual(
                30d,
                InstallationSizePolicy.AvailableLinuxSizeGiB(41d, 35d, 3d));
            Assert.AreEqual(
                10d,
                InstallationSizePolicy.RemainingWindowsFreeSpaceGiB(41d, 3d, 28d));
            Assert.AreEqual(
                8d,
                InstallationSizePolicy.RemainingWindowsFreeSpaceGiB(41d, 3d, 30d));
            Assert.AreEqual(
                0d,
                InstallationSizePolicy.AvailableLinuxSizeGiB(10d, 35d, 3d));
            Assert.AreEqual(10, InstallationSizePolicy.TargetWindowsFreeSpaceGiB);
            Assert.AreEqual(2, InstallationSizePolicy.WindowsFreeSpaceToleranceGiB);
            Assert.AreEqual(8, InstallationSizePolicy.MinimumWindowsFreeSpaceGiB);
        }

        [TestMethod]
        public void StateValidatorRejectsForgedIncompleteTerminalStates()
        {
            InstallationStateMachine succeeded = InstallationStateMachine.Create(PlanId);
            succeeded.StartStep(InstallationStep.WindowsPreflightVerified);
            succeeded.CompleteStep(InstallationStep.WindowsPreflightVerified);
            succeeded.State.Status = InstallationStatus.Succeeded;
            succeeded.State.Phase = InstallationPhase.Complete;

            Assert.ThrowsException<InvalidOperationException>(
                () => InstallationStateMachine.ValidateState(succeeded.State));

            InstallationStateMachine rolledBack = InstallationStateMachine.Create(PlanId);
            rolledBack.StartStep(InstallationStep.WindowsPreflightVerified);
            rolledBack.CompleteStep(InstallationStep.WindowsPreflightVerified);
            rolledBack.StartStep(InstallationStep.WindowsArtifactsVerified);
            rolledBack.CompleteStep(InstallationStep.WindowsArtifactsVerified);
            rolledBack.StartStep(InstallationStep.WindowsRecoveryArmed);
            rolledBack.CompleteStep(InstallationStep.WindowsRecoveryArmed);
            rolledBack.State.Status = InstallationStatus.RolledBack;
            rolledBack.State.Phase = InstallationPhase.Complete;
            rolledBack.State.Failure = new InstallationFailure
            {
                Code = "failure",
                Message = "failure",
                Component = InstallationPhase.Windows
            };

            Assert.ThrowsException<InvalidOperationException>(
                () => InstallationStateMachine.ValidateState(rolledBack.State));
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
        public void SuccessfulInstallationCanBeginExplicitRollback()
        {
            InstallationStateMachine machine = InstallationStateMachine.Create(PlanId);
            foreach (string step in new[]
            {
                InstallationStep.WindowsPreflightVerified,
                InstallationStep.WindowsArtifactsVerified,
                InstallationStep.WindowsRecoveryArmed,
                InstallationStep.WindowsSystemVolumeShrunk,
                InstallationStep.WindowsInstallerPartitionCreated,
                InstallationStep.WindowsLiveMediaPrepared,
                InstallationStep.WindowsTemporaryBootPrepared,
                InstallationStep.LivePreflightVerified,
                InstallationStep.LiveInstallerPartitionExpanded,
                InstallationStep.LiveTargetFilesystemCreated,
                InstallationStep.LiveDistributionExtracted,
                InstallationStep.TargetSystemConfigured,
                InstallationStep.TargetBootloaderInstalled,
                InstallationStep.TargetInstallationVerified
            })
            {
                machine.StartStep(step);
                machine.CompleteStep(step);
            }
            machine.CompleteInstallation();

            machine.BeginRollback();

            Assert.AreEqual(InstallationStatus.RollbackRunning, machine.State.Status);
            Assert.AreEqual(InstallationPhase.Rollback, machine.State.Phase);
        }

        [TestMethod]
        public void ExecutionLedgerPersistsRollbackStartedAfterSuccessfulInstallation()
        {
            string directory = Path.Combine(
                Path.GetTempPath(),
                "libertix-ledger-success-rollback-" + Guid.NewGuid().ToString("N"));
            string statePath = Path.Combine(directory, "installation-state.json");
            try
            {
                InstallationStateMachine machine = InstallationStateMachine.Create(PlanId);
                foreach (string step in new[]
                {
                    InstallationStep.WindowsPreflightVerified,
                    InstallationStep.WindowsArtifactsVerified,
                    InstallationStep.WindowsRecoveryArmed,
                    InstallationStep.WindowsSystemVolumeShrunk,
                    InstallationStep.WindowsInstallerPartitionCreated,
                    InstallationStep.WindowsLiveMediaPrepared,
                    InstallationStep.WindowsTemporaryBootPrepared,
                    InstallationStep.LivePreflightVerified,
                    InstallationStep.LiveInstallerPartitionExpanded,
                    InstallationStep.LiveTargetFilesystemCreated,
                    InstallationStep.LiveDistributionExtracted,
                    InstallationStep.TargetSystemConfigured,
                    InstallationStep.TargetBootloaderInstalled,
                    InstallationStep.TargetInstallationVerified
                })
                {
                    machine.StartStep(step);
                    machine.CompleteStep(step);
                }
                machine.CompleteInstallation();
                InstallationStateStore.WriteAtomic(statePath, machine.State);

                InstallationExecutionLedger ledger =
                    InstallationExecutionLedger.Open(statePath);
                ledger.BeginRollback();

                InstallationExecutionState persisted = InstallationStateStore.Read(statePath);
                Assert.AreEqual(InstallationStatus.RollbackRunning, persisted.Status);
                Assert.AreEqual(InstallationPhase.Rollback, persisted.Phase);
            }
            finally
            {
                if (Directory.Exists(directory))
                    Directory.Delete(directory, true);
            }
        }

        [TestMethod]
        public void ExecutionLedgerPersistsPrimaryAndMirroredTransitions()
        {
            string directory = Path.Combine(
                Path.GetTempPath(),
                "libertix-ledger-" + Guid.NewGuid().ToString("N"));
            string statePath = Path.Combine(directory, "installation-state.json");
            string mirrorPath = Path.Combine(directory, "live", "installation-state.json");
            try
            {
                InstallationExecutionLedger ledger =
                    InstallationExecutionLedger.Create(PlanId, statePath);
                ledger.SetMirrorPath(mirrorPath);
                ledger.StartStep(InstallationStep.WindowsPreflightVerified);
                ledger.CompleteStep(InstallationStep.WindowsPreflightVerified);

                InstallationExecutionState primary = InstallationStateStore.Read(statePath);
                InstallationExecutionState mirror = InstallationStateStore.Read(mirrorPath);

                Assert.AreEqual(primary.Revision, mirror.Revision);
                CollectionAssert.AreEqual(
                    primary.CompletedSteps.ToArray(),
                    mirror.CompletedSteps.ToArray());
            }
            finally
            {
                if (Directory.Exists(directory))
                    Directory.Delete(directory, true);
            }
        }

        [TestMethod]
        public void ExecutionLedgerStopsUpdatingDetachedMirror()
        {
            string directory = Path.Combine(
                Path.GetTempPath(),
                "libertix-ledger-detach-" + Guid.NewGuid().ToString("N"));
            string statePath = Path.Combine(directory, "installation-state.json");
            string mirrorPath = Path.Combine(directory, "live", "installation-state.json");
            try
            {
                InstallationExecutionLedger ledger =
                    InstallationExecutionLedger.Create(PlanId, statePath);
                ledger.SetMirrorPath(mirrorPath);
                ledger.StartStep(InstallationStep.WindowsPreflightVerified);
                ledger.CompleteStep(InstallationStep.WindowsPreflightVerified);

                ledger.SetMirrorPath(null);
                ledger.RecordFailure(
                    "WINDOWS_ONLY_FAILURE",
                    "The live handoff is already durable.",
                    InstallationPhase.Windows);

                InstallationExecutionState primary = InstallationStateStore.Read(statePath);
                InstallationExecutionState mirror = InstallationStateStore.Read(mirrorPath);

                Assert.AreEqual(InstallationStatus.Failed, primary.Status);
                Assert.AreEqual(InstallationStatus.Running, mirror.Status);
                CollectionAssert.Contains(
                    mirror.CompletedSteps.ToArray(),
                    InstallationStep.WindowsPreflightVerified);
            }
            finally
            {
                if (Directory.Exists(directory))
                    Directory.Delete(directory, true);
            }
        }

        [TestMethod]
        public void PlanFactoryBuildsValidatedUefiIntentFromWindowsInputs()
        {
            const long GiB = InstallationSizePolicy.BytesPerGiB;
            Assert.IsTrue(StartupOptions.TryParse(
                Array.Empty<string>(),
                out StartupOptions startupOptions,
                out string startupError), startupError);

            InstallationPlan plan = InstallationPlanFactory.Create(
                new InstallationPlanCreationOptions
                {
                    PlanId = PlanId,
                    Firmware = FirmwareType.Uefi,
                    Distribution = new DistroInfo
                    {
                        Id = "mint",
                        Name = "Linux Mint",
                        OsReleaseId = "linuxmint",
                        GrubDisplayName = "Linux Mint 22.3 Cinnamon",
                        GrubIcon = "linuxmint",
                        SecureBootMicrosoftAuthorities =
                            new System.Collections.Generic.List<string> { "2011" },
                        IsoInstallerFileName = "mint.iso",
                        IsoInstaller = "https://example.test/mint.iso",
                        IsoInstallerSha256 = new string('a', 64),
                        IsoUrl = "https://example.test/bios.iso",
                        IsoSha256 = new string('b', 64),
                        UefiIsoUrl = "https://example.test/uefi.iso",
                        UefiIsoSha256 = new string('c', 64)
                    },
                    Account = new AccountInfo
                    {
                        Username = "test",
                        ComputerName = "libertix-test"
                    },
                    Sharing = new SharingOptions(),
                    Compatibility = new CompatibilityInfo
                    {
                        SecureBootEnabled = true,
                        TrustedMicrosoftUefiAuthorities = new[] { "2011" }
                    },
                    Storage = new StoragePreflightInfo
                    {
                        SystemDiskNumber = 0,
                        SystemDiskUniqueId = "test-disk",
                        SystemDiskPartitionTableId = "gpt:12345678-1234-1234-1234-123456789abc",
                        SystemDiskSize = 256L * GiB,
                        LogicalSectorSize = 512,
                        PartitionStyle = InstallationPartitionStyle.Gpt,
                        SystemDrive = "C:",
                        SystemPartitionNumber = 3,
                        SystemPartitionOffset = 2L * GiB,
                        SystemPartitionSize = 180L * GiB,
                        BootPartitionNumber = 1,
                        BootPartitionOffset = 1024L * 1024L,
                        BootPartitionSize = 100L * 1024L * 1024L,
                        RecoveryPartitionNumber = 4,
                        RecoveryPartitionOffset = 240L * GiB,
                        RecoveryPartitionSize = 1L * GiB,
                        BitLockerState = "FullyDecrypted"
                    },
                    Sizes = InstallationSizePolicy.FromRequestedGigabytes(40),
                    Keyboard = WindowsKeyboardLayout.ResolveIdentifier("00000409", "us"),
                    StartupOptions = startupOptions,
                    LanguageCode = "en",
                    SystemLanguage = "en_US.UTF-8",
                    Timezone = "Etc/UTC",
                    SystemDriveRoot = @"C:\",
                    PasswordHashWindowsPath = @"C:\ProgramData\Libertix\account-secret.env",
                    WindowsProfilesJsonBase64 = "W10=",
                    RecoveryRootWindows = @"C:\ProgramData\Libertix\Recovery",
                    RecoveryRunId = new string('d', 32)
                });

            Assert.AreEqual(InstallationFirmware.Uefi, plan.Firmware);
            CollectionAssert.AreEqual(
                new[] { "2011" },
                plan.Distribution.SecureBootMicrosoftAuthorities);
            CollectionAssert.AreEqual(
                new[] { "2011" },
                plan.Runtime.TrustedMicrosoftUefiAuthorities);
            Assert.IsTrue(plan.Runtime.SecureBootEnabled);
            Assert.AreEqual(40L * GiB, plan.Disk.Installer.FinalSizeBytes);
            Assert.AreEqual(8L * GiB, plan.Disk.Installer.StagingSizeBytes);
            Assert.IsNull(plan.Development);
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
            Assert.AreEqual(2426708L, catalogue.Ext4Driver.AttachedContainerSize);
            Assert.AreEqual("a0", catalogue.Ext4Driver.WinFspPayloadName);
            Assert.AreEqual("a1", catalogue.Ext4Driver.DriverPayloadName);
            Assert.AreEqual("grldr", catalogue.Grub4Dos.LoaderFileName);
            Assert.AreEqual("grldr.mbr", catalogue.Grub4Dos.MbrLoaderFileName);
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
        [DataRow("A000040C", "fr", "", true)]
        [DataRow("not-a-klid", "us", "", true)]
        public void WindowsKeyboardIdentifiersResolveToExpectedXkbConfiguration(
            string identifier,
            string expectedLayout,
            string expectedVariant,
            bool expectedFallback)
        {
            LinuxKeyboardConfiguration resolved = WindowsKeyboardLayout.ResolveIdentifier(
                identifier,
                "us");

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
        public void InstallationPlanRejectsWindowsPathsOnAnotherDrive()
        {
            InstallationPlan plan = CreateValidPlan();
            plan.Account.PasswordHashWindowsPath = @"D:\ProgramData\Libertix\account-secret.env";

            Assert.ThrowsException<InstallationPlanValidationException>(
                () => InstallationPlanValidator.Validate(plan));
        }

        [TestMethod]
        public void InstallationPlanAcceptsConsistentNonCSystemDrivePaths()
        {
            InstallationPlan plan = CreateValidPlan();
            plan.Disk.SystemDrive = "D:";
            plan.Distribution.InstallerIsoWindowsPath =
                @"D:\ProgramData\Libertix\Downloads\" + PlanId + @"\mint.iso";
            plan.Account.PasswordHashWindowsPath = @"D:\ProgramData\Libertix\account-secret.env";
            plan.Runtime.RecoveryRootWindows = @"D:\ProgramData\Libertix\Recovery";

            InstallationPlanValidator.Validate(plan);
        }

        [TestMethod]
        public void InstallationPlanAcceptsReservedPrimaryMbrOffset()
        {
            InstallationPlan plan = CreateValidPlan();
            plan.Firmware = InstallationFirmware.Bios;
            plan.Disk.PartitionStyle = InstallationPartitionStyle.Mbr;
            plan.Disk.PartitionTableId = "mbr:12345678";
            plan.Runtime.BootStrategy = InstallationBootStrategy.BiosGrub4Dos;
            plan.Runtime.SecureBootEnabled = false;
            plan.Runtime.TrustedMicrosoftUefiAuthorities = new string[0];
            plan.Disk.Installer.OffsetBytes -= 1024L * 1024L;

            InstallationPlanValidator.Validate(plan);
        }

        [TestMethod]
        public void TemporaryArtifactsUseThePlanOwnedProgramDataDirectory()
        {
            string isoPath = InstallationTemporaryArtifacts.GetDistributionIsoPath(
                @"C:\",
                PlanId,
                "linux.iso");
            string liveMediaDirectory = InstallationTemporaryArtifacts.GetLiveMediaDirectory(
                @"C:\",
                PlanId);

            Assert.AreEqual(
                @"C:\ProgramData\Libertix\Downloads\" + PlanId + @"\linux.iso",
                isoPath);
            Assert.AreEqual(
                @"C:\ProgramData\Libertix\Downloads\" + PlanId + @"\live-media",
                liveMediaDirectory);
            Assert.AreNotEqual(Path.GetDirectoryName(isoPath), liveMediaDirectory);
        }

        [TestMethod]
        public void InstallationPlanRejectsReservedMbrOffsetForUefi()
        {
            InstallationPlan plan = CreateValidPlan();
            plan.Disk.Installer.OffsetBytes -= 1024L * 1024L;

            Assert.ThrowsException<InstallationPlanValidationException>(
                () => InstallationPlanValidator.Validate(plan));
        }

        [TestMethod]
        public void InstallationPlanRejectsUnknownSecureBootAuthority()
        {
            InstallationPlan plan = CreateValidPlan();
            plan.Distribution.SecureBootMicrosoftAuthorities = new[] { "2040" };

            InstallationPlanValidationException exception =
                Assert.ThrowsException<InstallationPlanValidationException>(
                    () => InstallationPlanValidator.Validate(plan));

            StringAssert.Contains(
                exception.Message,
                "distribution.secureBootMicrosoftAuthorities");
        }

        [TestMethod]
        public void InstallationPlanRejectsTrustedUefiAuthorityInBiosPlan()
        {
            InstallationPlan plan = CreateValidPlan();
            plan.Firmware = InstallationFirmware.Bios;
            plan.Disk.PartitionStyle = InstallationPartitionStyle.Mbr;
            plan.Disk.PartitionTableId = "mbr:12345678";
            plan.Runtime.BootStrategy = InstallationBootStrategy.BiosGrub4Dos;

            InstallationPlanValidationException exception =
                Assert.ThrowsException<InstallationPlanValidationException>(
                    () => InstallationPlanValidator.Validate(plan));

            StringAssert.Contains(
                exception.Message,
                "BIOS plan must not contain trusted Microsoft UEFI authorities");
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
                    Id = "mint",
                    Name = "Linux Mint",
                    OsReleaseId = "linuxmint",
                    GrubDisplayName = "Linux Mint 22.3 Cinnamon",
                    GrubIcon = "linuxmint",
                    SecureBootMicrosoftAuthorities = new[] { "2011" },
                    InstallerIsoFileName = "mint.iso",
                    InstallerIsoUrl = "https://example.test/mint.iso",
                    InstallerIsoWindowsPath =
                        @"C:\ProgramData\Libertix\Downloads\" + PlanId + @"\mint.iso",
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
                    PasswordHashWindowsPath = @"C:\ProgramData\Libertix\Recovery\account-secret.env",
                    ComputerName = "libertix-test"
                },
                Disk = new InstallationDisk
                {
                    Number = 0,
                    UniqueId = "test-disk",
                    PartitionTableId = "gpt:12345678-1234-1234-1234-123456789abc",
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
                        FinalOffsetBytes = 142L * GiB,
                        FinalSizeBytes = 40L * GiB,
                        StagingSizeBytes = 8L * GiB,
                        ResizeMode = InstallationResizeMode.WindowsOnline
                    }
                },
                Features = new InstallationFeatures
                {
                    WindowsProfilesJsonBase64 = "W10="
                },
                Runtime = new InstallationRuntime
                {
                    BootStrategy = InstallationBootStrategy.UefiBootNext,
                    SecureBootEnabled = true,
                    TrustedMicrosoftUefiAuthorities = new[] { "2011" },
                    WindowsBitLockerState = "FullyDecrypted",
                    RecoveryRootWindows = @"C:\ProgramData\Libertix\Recovery",
                    RecoveryRunId = new string('d', 32)
                }
            };
        }
    }
}
