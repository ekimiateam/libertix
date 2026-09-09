using System;
using Libertix.Installation;
using Libertix.Models;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Libertix.Tests
{
    [TestClass]
    public sealed class InstallationTargetTests
    {
        private const string WindowsTableId = "gpt:12345678-1234-1234-1234-123456789abc";
        private const string DataTableId = "gpt:87654321-1234-1234-1234-123456789abc";

        [DataTestMethod]
        [DataRow(0.0)]
        [DataRow(18.20)]
        [DataRow(18.96)]
        public void InsufficientAllocationIsNotPresentedAsAnInvertedValidRange(double availableGiB)
        {
            var error = Assert.ThrowsException<InvalidOperationException>(() =>
                UnattendedInstallationConfigurator.ValidateAvailableLinuxSize(20, availableGiB));
            StringAssert.Contains(error.Message, "Insufficient space on the selected installation volume");
            StringAssert.Contains(error.Message, availableGiB.ToString("F2", System.Globalization.CultureInfo.InvariantCulture));
            StringAssert.Contains(error.Message, "at least 20 GiB is required");
            Assert.IsFalse(error.Message.Contains("valid range"));
        }

        [DataTestMethod]
        [DataRow(20, 20.0, true)]
        [DataRow(20, 20.99, true)]
        [DataRow(19, 20.0, false)]
        [DataRow(21, 20.99, false)]
        public void AllocationDiagnosticPreservesMinimumAndMaximumBoundaries(
            int requestedGiB, double availableGiB, bool accepted)
        {
            if (accepted)
                UnattendedInstallationConfigurator.ValidateAvailableLinuxSize(requestedGiB, availableGiB);
            else
                Assert.ThrowsException<InvalidOperationException>(() =>
                    UnattendedInstallationConfigurator.ValidateAvailableLinuxSize(requestedGiB, availableGiB));
        }

        [TestMethod]
        public void OldUnattendedConfigurationKeepsWindowsAndUnknownTargetsAreRejected()
        {
            var options = System.Text.Json.JsonSerializer.Deserialize<Libertix.Helpers.UnattendedOptions>(
                "{\"SchemaVersion\":1,\"Distribution\":\"mint\",\"LinuxSizeGiB\":20," +
                "\"LinuxUsername\":\"test-linux\",\"LinuxPassword\":\"test-only\",\"ComputerName\":\"test-pc\"}");
            Assert.AreEqual("windows", options.InstallationTarget);
            var validate = typeof(Libertix.Helpers.UnattendedOptions).GetMethod("Validate",
                System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance);
            foreach (string target in new[] { "windows", "secondary", "J:", "usb", "", null })
            {
                options.InstallationTarget = target;
                var arguments = new object[] { null };
                bool valid = (bool)validate.Invoke(options, arguments);
                Assert.AreEqual(target == "windows" || target == "secondary", valid, target ?? "null");
                if (!valid) StringAssert.Contains((string)arguments[0], "installation target");
            }
        }

        [TestMethod]
        public void UnattendedSecondarySelectionRequiresOneVerifiedCompatibleVolume()
        {
            var windows = CreateTarget(true);
            var data = CreateTarget(false);
            var state = new InstallationState
            {
                Compatibility = new CompatibilityInfo
                {
                    Firmware = "UEFI", InstallationTargets = Validate(windows, data)
                }
            };
            UnattendedInstallationConfigurator.SelectInstallationTarget(state, "secondary");
            Assert.AreSame(data, state.SelectedInstallationTarget);
            UnattendedInstallationConfigurator.SelectInstallationTarget(state, "windows");
            Assert.IsNull(state.SelectedInstallationTarget);
            Assert.ThrowsException<InvalidOperationException>(() =>
                UnattendedInstallationConfigurator.SelectInstallationTarget(state, "usb"));
            state.Compatibility.InstallationTargets = Validate(windows);
            Assert.ThrowsException<InvalidOperationException>(() =>
                UnattendedInstallationConfigurator.SelectInstallationTarget(state, "secondary"));
            var other = CreateTarget(false);
            other.Drive = "L:";
            other.PartitionNumber = 3;
            other.OffsetBytes = 61L << 30;
            other.SizeBytes = 1L << 30;
            other.MinimumSizeBytes = 1L << 29;
            other.FreeBytes = 1L << 29;
            state.Compatibility.InstallationTargets = Validate(windows, data, other);
            Assert.ThrowsException<InvalidOperationException>(() =>
                UnattendedInstallationConfigurator.SelectInstallationTarget(state, "secondary"));
            state.Compatibility.Firmware = "BIOS";
            Assert.ThrowsException<InvalidOperationException>(() =>
                UnattendedInstallationConfigurator.SelectInstallationTarget(state, "secondary"));
        }

        [TestMethod]
        public void EncryptionRollbackComparisonRejectsLossOfEncryptionAndUnknownEvidence()
        {
            var original = new VolumeEncryptionSnapshot
            {
                State = InstallationBitLockerState.EncryptedOrProtected,
                ConversionStatus = 1, EncryptionPercentage = 100, ProtectionStatus = 0
            };
            var current = new VolumeEncryptionSnapshot
            {
                State = InstallationBitLockerState.EncryptedOrProtected,
                ConversionStatus = 1, EncryptionPercentage = 100, ProtectionStatus = 0
            };
            Assert.IsTrue(original.Matches(current));
            current.ProtectionStatus = 1;
            Assert.IsFalse(original.Matches(current));
            current.State = InstallationBitLockerState.FullyDecrypted;
            current.ConversionStatus = 0;
            current.EncryptionPercentage = 0;
            current.ProtectionStatus = 0;
            Assert.IsFalse(original.Matches(current));
            Assert.IsFalse(original.Matches(null));
            Assert.IsFalse(new VolumeEncryptionSnapshot().Matches(new VolumeEncryptionSnapshot()));
        }

        private static InstallationTargetInfo CreateTarget(bool windows)
        {
            return new InstallationTargetInfo
            {
                Drive = windows ? "C:" : "J:", IsWindows = windows,
                DiskNumber = windows ? 3 : 0, DiskUniqueId = "repeated-vendor-id",
                DiskDevicePath = windows ? "disk-3" : "disk-0", VolumeId = windows ? "volume-c" : "volume-j",
                PartitionTableId = windows ? WindowsTableId : DataTableId,
                DiskSizeBytes = 64L << 30, LogicalSectorSizeBytes = 512,
                PartitionStyle = "GPT", BusType = "SATA", PartitionNumber = 2,
                OffsetBytes = 1L << 20, SizeBytes = 60L << 30, MinimumSizeBytes = 24L << 30,
                FreeBytes = 32L << 30
            };
        }

        private static InstallationTargetInfo[] Validate(params InstallationTargetInfo[] targets)
        {
            return InstallationTargetSelection.ValidateInventory(targets, "C:", 3, WindowsTableId);
        }

        [TestMethod]
        public void DefaultsToWindowsEvenWhenAnotherPhysicalDiskIsEnumeratedFirst()
        {
            InstallationTargetInfo data = CreateTarget(false);
            InstallationTargetInfo windows = CreateTarget(true);
            InstallationTargetInfo[] targets = Validate(data, windows);
            Assert.AreSame(windows, targets[0]);
            Assert.AreSame(windows, InstallationTargetSelection.Select(targets));
            Assert.AreSame(data, InstallationTargetSelection.Select(targets, "j:"));
        }

        [TestMethod]
        public void RetainsTheSingleDiskDefault()
        {
            InstallationTargetInfo windows = CreateTarget(true);
            Assert.AreSame(windows, InstallationTargetSelection.Select(Validate(windows)));
        }

        [TestMethod]
        public void DoesNotOfferAnAllocationDiskUnsupportedByTheFirmwareWorkflow()
        {
            InstallationTargetInfo windows = CreateTarget(true);
            InstallationTargetInfo data = CreateTarget(false);
            data.PartitionStyle = "MBR";
            data.PartitionTableId = "mbr:12345678";
            InstallationTargetInfo[] targets = Validate(windows, data);
            CollectionAssert.AreEqual(new[] { windows }, InstallationTargetSelection.ForFirmware(targets, "UEFI"));
            CollectionAssert.AreEqual(new[] { data }, InstallationTargetSelection.ForFirmware(targets, "BIOS"));
            Assert.ThrowsException<InvalidOperationException>(() => InstallationTargetSelection.ForFirmware(targets, "unknown"));
        }

        [DataTestMethod]
        [DataRow(0L)]
        [DataRow(512L)]
        public void FinalInstallerOffsetUsesTheSelectedSourceEndAndAlignment(long trailingPadding)
        {
            var source = new PartitionIdentity
            {
                Number = 2, OffsetBytes = 1L << 20, SizeBytes = (60L << 30) + trailingPadding
            };
            Assert.AreEqual((40L << 30) + (1L << 20),
                InstallationSizePolicy.GetFinalInstallerOffset(source, 20L << 30));
        }

        [DataTestMethod]
        [DataRow(0L, 64424509440L, 21474836480L)]
        [DataRow(long.MaxValue, 64424509440L, 21474836480L)]
        [DataRow(1048576L, 0L, 21474836480L)]
        [DataRow(1048576L, 64424509440L, 64424509440L)]
        [DataRow(1048576L, 64424509440L, 0L)]
        [DataRow(1048576L, 64424509440L, 21474836481L)]
        public void FinalInstallerOffsetRejectsInvalidOrOverflowingGeometry(long offset, long size, long linuxSize)
        {
            var source = new PartitionIdentity { Number = 2, OffsetBytes = offset, SizeBytes = size };
            Assert.ThrowsException<ArgumentOutOfRangeException>(() =>
                InstallationSizePolicy.GetFinalInstallerOffset(source, linuxSize));
        }

        [TestMethod]
        public void RejectsAnotherPartitionOnTheWindowsPhysicalDisk()
        {
            InstallationTargetInfo data = CreateTarget(false);
            data.DiskNumber = 3;
            data.PartitionNumber = 4;
            data.PartitionTableId = WindowsTableId;
            Assert.ThrowsException<InvalidOperationException>(() => Validate(CreateTarget(true), data));
        }

        [TestMethod]
        public void RejectsAnExtraPartitionFalselyMarkedAsWindows()
        {
            InstallationTargetInfo data = CreateTarget(false);
            data.IsWindows = true;
            Assert.ThrowsException<InvalidOperationException>(() => Validate(CreateTarget(true), data));
        }

        [TestMethod]
        public void RejectsClonedPartitionTableIdentitiesButNotRepeatedHardwareVendorIds()
        {
            InstallationTargetInfo data = CreateTarget(false);
            Assert.AreEqual(2, Validate(CreateTarget(true), data).Length);
            data.PartitionTableId = WindowsTableId;
            Assert.ThrowsException<InvalidOperationException>(() => Validate(CreateTarget(true), data));
        }

        [DataTestMethod]
        [DataRow("USB")]
        [DataRow("SD")]
        [DataRow("MMC")]
        [DataRow("RAID")]
        [DataRow("iSCSI")]
        [DataRow("File Backed Virtual")]
        public void RejectsSecondaryTargetsOnUnsupportedBuses(string bus)
        {
            InstallationTargetInfo data = CreateTarget(false);
            data.BusType = bus;
            Assert.ThrowsException<InvalidOperationException>(() => Validate(CreateTarget(true), data));
        }

        [TestMethod]
        public void RejectsMissingWindowsAndUnavailableRequestedDrive()
        {
            Assert.ThrowsException<InvalidOperationException>(() => Validate(CreateTarget(false)));
            Assert.ThrowsException<InvalidOperationException>(() =>
                InstallationTargetSelection.Select(Validate(CreateTarget(true)), "D:"));
        }

        [TestMethod]
        public void RejectsDuplicateDriveLetters()
        {
            InstallationTargetInfo data = CreateTarget(false);
            data.Drive = "C:";
            Assert.ThrowsException<InvalidOperationException>(() => Validate(CreateTarget(true), data));
        }

        [DataTestMethod]
        [DataRow(0L, 1024L)]
        [DataRow(1048576L, 0L)]
        [DataRow(1048577L, 1073741824L)]
        [DataRow(1048576L, long.MaxValue)]
        public void RejectsUnsafeGeometryWithoutIntegerOverflow(long offset, long size)
        {
            InstallationTargetInfo data = CreateTarget(false);
            data.OffsetBytes = offset;
            data.SizeBytes = size;
            Assert.ThrowsException<InvalidOperationException>(() => Validate(CreateTarget(true), data));
        }

        [TestMethod]
        public void RejectsDiskSizeNotAlignedToItsLogicalSector()
        {
            InstallationTargetInfo data = CreateTarget(false);
            data.DiskSizeBytes += 1;
            Assert.ThrowsException<InvalidOperationException>(() => Validate(CreateTarget(true), data));
        }

        [TestMethod]
        public void RejectsNonexistentResizeCapacityAndImpossibleFreeSpace()
        {
            InstallationTargetInfo data = CreateTarget(false);
            data.MinimumSizeBytes = 0;
            Assert.ThrowsException<InvalidOperationException>(() => Validate(CreateTarget(true), data));
            data.MinimumSizeBytes = data.SizeBytes;
            data.FreeBytes = data.SizeBytes + 1;
            Assert.ThrowsException<InvalidOperationException>(() => Validate(CreateTarget(true), data));
        }
    }
}
