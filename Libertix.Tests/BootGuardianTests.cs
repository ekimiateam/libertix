using System;
using System.IO;
using System.Text;
using Libertix.BootGuardian;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Libertix.Tests
{
    [TestClass]
    public sealed class BootGuardianTests
    {
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
