using System;
using System.IO;
using Libertix.Installation;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Libertix.Tests
{
    [TestClass]
    public class WindowsSharingPlanTests
    {
        private static WindowsSharingPlan Create()
        {
            return new WindowsSharingPlan
            {
                Version = 1,
                Volumes = new[] { new WindowsSharingVolume
                {
                    NtfsUuid = "0123456789ABCDEF", WindowsDrive = "D:",
                    WindowsVolumeId = @"\\?\Volume{11111111-1111-1111-1111-111111111111}\",
                    OffsetBytes = 1048576, SizeBytes = 64L * 1024 * 1024 * 1024,
                    Disk = new WindowsSharingDisk
                    {
                        PartitionStyle = "MBR", PartitionTableId = "mbr:12345678",
                        SizeBytes = 128L * 1024 * 1024 * 1024, LogicalSectorSizeBytes = 512
                    }
                } },
                Folders = new[] { new WindowsSharingFolder
                {
                    Shortcut = "User_Alice_Documents", ProfileSid = "S-1-5-21-1-2-3-1001",
                    NtfsUuid = "0123456789ABCDEF", RelativePath = "Data/Alice/Documents"
                } }
            };
        }

        [TestMethod]
        public void AcceptsRelatedDataVolumeAndItsFolder() => Create().Validate();

        [TestMethod]
        public void RetainsEmptyInventoryForNoInteractiveProfiles()
        {
            new WindowsSharingPlan { Version = 1, Volumes = Array.Empty<WindowsSharingVolume>(),
                Folders = Array.Empty<WindowsSharingFolder>() }.Validate();
        }

        [DataTestMethod]
        [DataRow("../Windows")]
        [DataRow("/Documents")]
        [DataRow("Data//Documents")]
        [DataRow("D:\\Documents")]
        [DataRow("Data\nDocuments")]
        public void RejectsEscapingOrAmbiguousRelativePaths(string path)
        {
            WindowsSharingPlan plan = Create();
            plan.Folders[0].RelativePath = path;
            Assert.ThrowsException<InvalidDataException>(() => plan.Validate());
        }

        [DataTestMethod]
        [DataRow("duplicate-volume")]
        [DataRow("duplicate-shortcut")]
        [DataRow("unknown-volume")]
        [DataRow("unrelated-volume")]
        [DataRow("wrong-table")]
        [DataRow("overflow")]
        [DataRow("zero-serial")]
        public void RejectsInvalidIdentities(string change)
        {
            WindowsSharingPlan plan = Create();
            switch (change)
            {
                case "duplicate-volume": plan.Volumes = new[] { plan.Volumes[0], plan.Volumes[0] }; break;
                case "duplicate-shortcut": plan.Folders = new[] { plan.Folders[0], plan.Folders[0] }; break;
                case "unknown-volume": plan.Folders[0].NtfsUuid = "FFFFFFFFFFFFFFFF"; break;
                case "unrelated-volume": plan.Folders = Array.Empty<WindowsSharingFolder>(); break;
                case "wrong-table": plan.Volumes[0].Disk.PartitionTableId = "gpt:12345678"; break;
                case "overflow": plan.Volumes[0].SizeBytes = long.MaxValue; break;
                case "zero-serial": plan.Volumes[0].NtfsUuid = "0000000000000000"; break;
            }
            Assert.ThrowsException<InvalidDataException>(() => plan.Validate());
        }
    }
}
