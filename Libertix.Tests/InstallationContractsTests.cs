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
        public void DevelopmentSshOptionAcceptsOnlyTheTestSubnet()
        {
            bool parsed = StartupOptions.TryParse(
                new[] { "--dev-ssh-static-ip", "192.168.1.240" },
                out StartupOptions options,
                out string error);

            Assert.IsTrue(parsed, error);
            Assert.AreEqual("192.168.1.240", options.DevelopmentSshStaticIpv4Address);
        }

        [DataTestMethod]
        [DataRow("192.168.1.1")]
        [DataRow("192.168.1.255")]
        [DataRow("192.168.2.20")]
        [DataRow("not-an-address")]
        public void DevelopmentSshOptionRejectsUnsafeAddresses(string address)
        {
            bool parsed = StartupOptions.TryParse(
                new[] { "--dev-ssh-static-ip", address },
                out _,
                out string error);

            Assert.IsFalse(parsed);
            StringAssert.Contains(error, "192.168.1.0/24");
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

        [DataTestMethod]
        [DataRow(21474836480L, 21474836480L, true)]
        [DataRow(21474836480L, 21473787904L, true)]
        [DataRow(21474836480L, 21475885056L, true)]
        [DataRow(21474836480L, 21473787903L, false)]
        [DataRow(21474836480L, 21475885057L, false)]
        [DataRow(0L, 0L, false)]
        public void StagingSizeValidationAllowsOnlyOneAlignmentUnit(
            long expectedBytes,
            long observedBytes,
            bool expectedResult)
        {
            Assert.AreEqual(
                expectedResult,
                InstallationSizePolicy.IsObservedStagingSizeAcceptable(
                    expectedBytes,
                    observedBytes));
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
    }
}
