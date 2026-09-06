using System;
using System.IO;
using System.Text;
using System.Threading;
using Libertix.BootGuardian;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Libertix.Tests
{
    [TestClass]
    public sealed class BootGuardianTests
    {
        [TestMethod]
        public void PreferredWindowsUpdateResumesAtEveryCommitBoundary()
        {
            for (int interruptAt = 1; interruptAt <= 18; interruptAt++)
            {
                string root = Path.Combine(Path.GetTempPath(), "libertix-sync-test-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(root);
                try
                {
                    string efi = Path.Combine(root, @"EFI\Libertix");
                    string microsoft = Path.Combine(root, @"EFI\Microsoft\Boot");
                    string reference = Path.Combine(efi, "BootGuardianReference");
                    Directory.CreateDirectory(reference);
                    Directory.CreateDirectory(microsoft);
                    File.WriteAllText(Path.Combine(reference, ".libertix-owner"), new string('a', 32));
                    foreach (string name in new[] { "shimx64.efi", "grubx64.efi", "mmx64.efi", "grub.cfg" })
                        File.WriteAllText(Path.Combine(reference, name), name);
                    string active = Path.Combine(microsoft, "bootmgfw.efi");
                    string backup = Path.Combine(microsoft, "bootmgfw.libertix-windows.efi");
                    File.WriteAllText(active, "new-windows-loader");
                    File.WriteAllText(backup, "old-windows-loader");
                    string expectedWindows = Hashing.Sha256File(active);
                    var manifest = new PreferredManifest { Version = 1, RunId = new string('a', 32), Status = "installed",
                        WindowsLoader = new PreferredWindowsLoader { ActivePath = @"\EFI\Microsoft\Boot\bootmgfw.efi",
                            BackupPath = @"\EFI\Microsoft\Boot\bootmgfw.libertix-windows.efi", Sha256 = Hashing.Sha256File(backup) },
                        Preferred = new PreferredHashes { ShimSha256 = Hashing.Sha256File(Path.Combine(reference, "shimx64.efi")),
                            GrubSha256 = Hashing.Sha256File(Path.Combine(reference, "grubx64.efi")),
                            MokManagerSha256 = Hashing.Sha256File(Path.Combine(reference, "mmx64.efi")),
                            GrubConfigSha256 = Hashing.Sha256File(Path.Combine(reference, "grub.cfg")) } };
                    string manifestPath = Path.Combine(efi, "preferred-boot-path.json");
                    string json = manifest.ToJson();
                    File.WriteAllText(manifestPath, json.Substring(0, json.Length - 1) +
                        ",\"windowsBootEntry\":{\"name\":\"Boot0001\"},\"futureField\":{\"value\":42}}");
                    manifest = PreferredManifest.Read(manifestPath);
                    manifest.WindowsLoader.Sha256 = expectedWindows;
                    int calls = 0;
                    try
                    {
                        PreferredSynchronization.PublishWindowsLoaderUpdate(root, manifest, active, reference, () => {
                            if (++calls == interruptAt) throw new TimeoutException("simulated shutdown deadline");
                        });
                    }
                    catch (TimeoutException) { }
                    if (File.Exists(Path.Combine(efi, "preferred-boot-path.sync.json")))
                        PreferredSynchronization.Replay(root, manifest.RunId, () => { });
                    else
                        PreferredSynchronization.PublishWindowsLoaderUpdate(root, manifest, active, reference, () => { });
                    Assert.AreEqual(expectedWindows, Hashing.Sha256File(backup));
                    Assert.AreEqual(manifest.Preferred.ShimSha256, Hashing.Sha256File(active));
                    Assert.AreEqual(expectedWindows, PreferredManifest.Read(manifestPath).WindowsLoader.Sha256);
                    StringAssert.Contains(File.ReadAllText(manifestPath), "windowsBootEntry");
                    StringAssert.Contains(File.ReadAllText(manifestPath), "futureField");
                }
                finally { Directory.Delete(root, true); }
            }
        }

        [TestMethod]
        public void CurrentWindowsLoaderTrustRejectsUnrelatedFiles()
        {
            string candidate = typeof(BootGuardianTests).Assembly.Location;
            Assert.IsFalse(WindowsBootLoaderTrust.IsCurrentWindowsLoader(candidate, Hashing.Sha256File(candidate)));
        }

        [TestMethod]
        public void CurrentWindowsLoaderTrustAcceptsTheInstalledSignedLoader()
        {
            string candidate = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                @"Boot\EFI\bootmgfw.efi");
            Assert.IsTrue(File.Exists(candidate), "The Windows build host must expose its EFI boot loader.");
            Assert.IsTrue(WindowsBootLoaderTrust.IsCurrentWindowsLoader(candidate, Hashing.Sha256File(candidate)));
        }

        [TestMethod]
        public void BootOrderEncodingRoundTripsWithoutChangingOrder()
        {
            ushort[] expected = { 0x0007, 0x0001, 0xABCD };
            byte[] bytes = FirmwareEnvironment.EncodeBootOrder(expected);
            CollectionAssert.AreEqual(expected, FirmwareEnvironment.ParseBootOrder(bytes));
        }

        [TestMethod]
        public void BootOrderParsingRejectsOddByteLength()
        {
            Assert.ThrowsException<InvalidOperationException>(
                () => FirmwareEnvironment.ParseBootOrder(new byte[] { 1, 0, 2 }));
        }

        [TestMethod]
        public void DesiredBootOrderMakesOwnedEntryFirstAndRemovesDuplicates()
        {
            ushort[] desired = BootGuardianEngine.BuildDesiredBootOrder(
                0x0007,
                new ushort[] { 0x0001, 0x0007, 0x0001, 0x0002, 0x0007 });
            CollectionAssert.AreEqual(new ushort[] { 0x0007, 0x0001, 0x0002 }, desired);
        }

        [TestMethod]
        public void ConfigurationRejectsAHashThatDoesNotOwnTheEntry()
        {
            BootGuardianConfig config = NewBootOrderConfig();
            config.BootOrder.EntrySha256 = new string('0', 64);
            Assert.ThrowsException<InvalidDataException>(() => config.Validate());
        }

        [TestMethod]
        public void ConfigurationRequiresExactlyOneModeContract()
        {
            BootGuardianConfig config = NewBootOrderConfig();
            config.PreferredPath = new PreferredPathContract
            {
                ManifestPath = @"EFI\Libertix\preferred-boot-path.json",
                ReferenceRoot = @"EFI\Libertix\BootGuardianReference"
            };
            Assert.ThrowsException<InvalidDataException>(() => config.Validate());
        }

        [TestMethod]
        public void ConfigurationRejectsMalformedVolumeIdentity()
        {
            BootGuardianConfig config = NewBootOrderConfig();
            config.Esp.VolumePath = @"\\?\Volume{------------------------------------}\";
            Assert.ThrowsException<InvalidDataException>(() => config.Validate());
        }

        [TestMethod]
        public void ConfigurationRejectsAnInvalidServiceExecutableHash()
        {
            BootGuardianConfig config = NewBootOrderConfig();
            config.ServiceSha256 = "not-a-hash";
            Assert.ThrowsException<InvalidDataException>(() => config.Validate());
        }

        [TestMethod]
        public void RepairDeadlineUsesElapsedTimeAndExpires()
        {
            var deadline = new RepairDeadline(TimeSpan.FromMilliseconds(10));
            Assert.IsTrue(deadline.RemainingMilliseconds > 0);
            Thread.Sleep(30);
            Assert.ThrowsException<TimeoutException>(() => deadline.ThrowIfExpired());
        }

        [TestMethod]
        public void AttemptStateDetectsAndClearsAnInterruptedAttempt()
        {
            string root = Path.Combine(Path.GetTempPath(), "libertix-guardian-test-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            try
            {
                string configPath = Path.Combine(root, "config.json");
                BootGuardianConfig config = NewBootOrderConfig();
                GuardianAttemptState first = GuardianAttemptState.Begin(configPath, config);
                Assert.IsFalse(first.PreviousInterrupted);

                GuardianAttemptState resumed = GuardianAttemptState.Begin(configPath, config);
                Assert.IsTrue(resumed.PreviousInterrupted);
                resumed.Complete(false);

                GuardianAttemptState next = GuardianAttemptState.Begin(configPath, config);
                Assert.IsFalse(next.PreviousInterrupted);
                next.Complete(true);
                string state = File.ReadAllText(Path.Combine(root, "last-attempt.state"));
                StringAssert.Contains(state, "status=repaired");
                StringAssert.Contains(state, "runId=" + config.RunId);
            }
            finally
            {
                if (Directory.Exists(root))
                    Directory.Delete(root, true);
            }
        }

        [TestMethod]
        public void ConfigurationRejectsAlternateDataStreamInEfiPath()
        {
            BootGuardianConfig config = NewBootOrderConfig();
            config.Mode = "preferred-windows-path";
            config.BootOrder = null;
            config.PreferredPath = new PreferredPathContract
            {
                ManifestPath = @"EFI\Libertix\preferred-boot-path.json:extra",
                ReferenceRoot = @"EFI\Libertix\BootGuardianReference"
            };
            Assert.ThrowsException<InvalidDataException>(() => config.Validate());
        }

        [TestMethod]
        public void HealthyJournalDoesNotCreateALogDirectory()
        {
            string root = Path.Combine(Path.GetTempPath(), "libertix-guardian-test-" + Guid.NewGuid().ToString("N"));
            try
            {
                BootGuardianConfig config = NewBootOrderConfig();
                config.LogDirectory = Path.Combine(root, "logs");
                var journal = new RepairJournal(config);
                journal.Complete();
                Assert.IsFalse(Directory.Exists(config.LogDirectory));
            }
            finally
            {
                if (Directory.Exists(root))
                    Directory.Delete(root, true);
            }
        }

        [TestMethod]
        public void RepairJournalCreatesOneDetailedLog()
        {
            string root = Path.Combine(Path.GetTempPath(), "libertix-guardian-test-" + Guid.NewGuid().ToString("N"));
            try
            {
                BootGuardianConfig config = NewBootOrderConfig();
                config.LogDirectory = Path.Combine(root, "logs");
                var journal = new RepairJournal(config);
                journal.Repair("test repair");
                journal.Complete();
                string[] files = Directory.GetFiles(config.LogDirectory, "*.log");
                Assert.AreEqual(1, files.Length);
                string text = File.ReadAllText(files[0]);
                StringAssert.Contains(text, "REPAIR: test repair");
                StringAssert.Contains(text, "runId=" + config.RunId);
                StringAssert.Contains(text, "mode=firmware-boot-order");
            }
            finally
            {
                if (Directory.Exists(root))
                    Directory.Delete(root, true);
            }
        }

        [TestMethod]
        public void RecoveredInterruptedAttemptCreatesOneDetailedLogWithoutInventingARepair()
        {
            string root = Path.Combine(Path.GetTempPath(), "libertix-guardian-test-" + Guid.NewGuid().ToString("N"));
            try
            {
                BootGuardianConfig config = NewBootOrderConfig();
                config.LogDirectory = Path.Combine(root, "logs");
                var journal = new RepairJournal(config);
                journal.RecordInterruptedAttempt();
                journal.Complete();
                string[] files = Directory.GetFiles(config.LogDirectory, "*.log");
                Assert.AreEqual(1, files.Length);
                string text = File.ReadAllText(files[0]);
                StringAssert.Contains(text, "RECOVERY: the previous guardian attempt");
                Assert.IsFalse(text.Contains("REPAIR:"));
            }
            finally
            {
                if (Directory.Exists(root))
                    Directory.Delete(root, true);
            }
        }

        [TestMethod]
        public void AtomicRepairReplacesTheDestinationAndLeavesNoTemporaryFile()
        {
            string root = Path.Combine(Path.GetTempPath(), "libertix-guardian-test-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            try
            {
                string source = Path.Combine(root, "source.efi");
                string destination = Path.Combine(root, "destination.efi");
                File.WriteAllText(source, "verified");
                File.WriteAllText(destination, "changed");
                string hash = Hashing.Sha256File(source);

                AtomicFile.CopyVerified(source, destination, hash);

                Assert.AreEqual(hash, Hashing.Sha256File(destination));
                string[] files = Array.ConvertAll(Directory.GetFiles(root), Path.GetFileName);
                Array.Sort(files, StringComparer.Ordinal);
                CollectionAssert.AreEqual(new[] { "destination.efi", "source.efi" }, files);
            }
            finally
            {
                if (Directory.Exists(root))
                    Directory.Delete(root, true);
            }
        }

        [TestMethod]
        public void AtomicRepairRejectsAnInvalidSourceWithoutChangingDestination()
        {
            string root = Path.Combine(Path.GetTempPath(), "libertix-guardian-test-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            try
            {
                string source = Path.Combine(root, "source.efi");
                string destination = Path.Combine(root, "destination.efi");
                File.WriteAllText(source, "untrusted");
                File.WriteAllText(destination, "original");

                Assert.ThrowsException<InvalidDataException>(
                    () => AtomicFile.CopyVerified(source, destination, new string('0', 64)));
                Assert.AreEqual("original", File.ReadAllText(destination));
            }
            finally
            {
                if (Directory.Exists(root))
                    Directory.Delete(root, true);
            }
        }

        [TestMethod]
        public void AtomicRepairDoesNotCommitAfterItsDeadline()
        {
            string root = Path.Combine(Path.GetTempPath(), "libertix-guardian-test-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            try
            {
                string source = Path.Combine(root, "source.efi");
                string destination = Path.Combine(root, "destination.efi");
                File.WriteAllText(source, "verified");
                File.WriteAllText(destination, "original");
                string hash = Hashing.Sha256File(source);

                Assert.ThrowsException<TimeoutException>(() =>
                    AtomicFile.CopyVerified(
                        source,
                        destination,
                        hash,
                        () => { throw new TimeoutException("test deadline"); }));

                Assert.AreEqual("original", File.ReadAllText(destination));
                CollectionAssert.AreEquivalent(
                    new[] { "destination.efi", "source.efi" },
                    Array.ConvertAll(Directory.GetFiles(root), Path.GetFileName));
            }
            finally
            {
                if (Directory.Exists(root))
                    Directory.Delete(root, true);
            }
        }

        private static BootGuardianConfig NewBootOrderConfig()
        {
            byte[] entry = Encoding.ASCII.GetBytes("test-entry");
            return new BootGuardianConfig
            {
                Version = 1,
                RunId = new string('a', 32),
                Mode = "firmware-boot-order",
                Esp = new EspIdentity
                {
                    VolumePath = @"\\?\Volume{11111111-1111-1111-1111-111111111111}\",
                    PartitionNumber = 1,
                    PartitionGuid = "22222222-2222-2222-2222-222222222222",
                    OwnerMarker = "owner\n"
                },
                LogDirectory = @"C:\LibertixInstallLogs\Windows\test\BootGuardian",
                ArchiveDirectory = @"C:\ProgramData\Libertix\UefiRecovery\test\boot-guardian",
                ServiceSha256 = new string('f', 64),
                BootOrder = new BootOrderContract
                {
                    BootNumber = 7,
                    EntryBytesBase64 = Convert.ToBase64String(entry),
                    EntrySha256 = Hashing.Sha256(entry)
                }
            };
        }
    }
}
