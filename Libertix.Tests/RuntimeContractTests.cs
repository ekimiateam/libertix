using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using Libertix.Helpers;
using Libertix.Installation;
using Libertix.Models;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Libertix.Tests
{
    [TestClass]
    public sealed class RuntimeContractTests
    {
        [TestMethod]
        public void ProductionFilepoolUsesThePublishedEkimiaEndpoint()
        {
            Assert.AreEqual(
                "https://ekimia.fr/libertix/distros.json",
                FilepoolConfig.Production.DistrosUrl);
            Assert.IsTrue(FilepoolConfig.Production.RequiresCatalogSignature);
            Assert.IsFalse(FilepoolConfig.Production.IsDevelopmentMode);
            Assert.AreEqual(
                "https://ekimia.fr/libertix/distros.json.sig",
                FilepoolConfig.Production.DistrosSignatureUrl);
        }

        [TestMethod]
        public void RelativeArtifactUrlStaysOnConfiguredFilepool()
        {
            Assert.IsTrue(FilepoolConfig.TryCreate(
                "http://192.0.2.10:8000/filepool",
                out FilepoolConfig filepool,
                out string error), error);

            Assert.AreEqual(
                "http://192.0.2.10:8000/filepool/live.iso",
                filepool.ResolveUrl("live.iso"));
            Assert.IsFalse(filepool.RequiresCatalogSignature);
            Assert.IsTrue(filepool.IsDevelopmentMode);
        }

        [TestMethod]
        public void VersionedDistributionManifestHasAValidDetachedSignature()
        {
            string testData = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "TestData");
            byte[] manifest = File.ReadAllBytes(Path.Combine(testData, "distros.json"));
            string signature = File.ReadAllText(Path.Combine(testData, "distros.json.sig"));
            string publicKey = Path.Combine(testData, "Libertix.CatalogPublicKey.xml");

            DistributionCatalogTrust.Verify(manifest, signature, publicKey);
            DistributionCatalogTrust.VerifyWithApplicationKey(manifest, signature);
            manifest[0] ^= 1;
            Assert.ThrowsException<InvalidDataException>(
                () => DistributionCatalogTrust.Verify(manifest, signature, publicKey));
        }

        [TestMethod]
        public void VersionedDistributionManifestIncludesTheInstallerByteSize()
        {
            string testData = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "TestData");
            string manifest = File.ReadAllText(Path.Combine(testData, "distros.json"));
            var distributions = JsonSerializer.Deserialize<List<DistroInfoJson>>(manifest);

            Assert.IsNotNull(distributions);
            Assert.AreEqual(2, distributions.Count);
            Assert.AreEqual("mint", distributions[0].Id);
            Assert.AreEqual(3091660800L, distributions[0].IsoInstallerSizeBytes);
            Assert.AreEqual(20d, distributions[0].SizeInGB);
            Assert.AreEqual("zorin", distributions[1].Id);
            Assert.AreEqual(3909091328L, distributions[1].IsoInstallerSizeBytes);
            Assert.AreEqual(20d, distributions[1].SizeInGB);
        }

        [TestMethod]
        public void PublicHttpsArtifactUrlIsAccepted()
        {
            Assert.AreEqual(
                "https://pub.linuxmint.io/stable/mint.iso",
                FilepoolConfig.Production.ResolveUrl(
                    "https://pub.linuxmint.io/stable/mint.iso"));
        }

        [DataTestMethod]
        [DataRow("file:///C:/Windows/System32/calc.exe")]
        [DataRow("ftp://example.test/mint.iso")]
        [DataRow("https://user:secret@example.test/mint.iso")]
        [DataRow("https://example.test/mint.iso?token=secret")]
        [DataRow("https://example.test/mint.iso#fragment")]
        public void UnsafeAbsoluteArtifactUrlIsRejected(string value)
        {
            Assert.ThrowsException<ArgumentException>(
                () => FilepoolConfig.Production.ResolveUrl(value));
        }

        [TestMethod]
        public void PersistedRuntimeNamesRemainStable()
        {
            Assert.AreEqual("LIBERTIXEFI", RuntimeNames.InstallerVolumeLabel);
            Assert.AreEqual("LibertixInstallLogs", RuntimeNames.InstallationLogDirectory);
            Assert.AreEqual("LibertixInstallRecovery", RuntimeNames.BiosRecoveryDirectory);
            Assert.AreEqual("LibertixInstallRecovery", RuntimeNames.BiosRecoveryTask);
            Assert.AreEqual("LibertixLinuxReadOnly", RuntimeNames.LinuxReadOnlyTask);
        }

        [TestMethod]
        public void UnknownWindowsTimezoneFallsBackToAValidIanaIdentifier()
        {
            var mappings = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                { "Romance Standard Time", "Europe/Paris" }
            };

            Assert.AreEqual(
                "Europe/Paris",
                Localization.ResolveWindowsTimezoneAsLinux("Romance Standard Time", mappings));
            Assert.AreEqual(
                "Etc/UTC",
                Localization.ResolveWindowsTimezoneAsLinux("Unknown Test Zone", mappings));
        }

        [TestMethod]
        public void AccountPasswordReferenceCanBeReleasedAfterPlanCreation()
        {
            var account = new AccountInfo
            {
                Username = "test",
                Password = "test-passphrase",
                ComputerName = "test-machine"
            };

            account.ClearPassword();

            Assert.IsNull(account.Password);
            Assert.AreEqual("test", account.Username);
            Assert.AreEqual("test-machine", account.ComputerName);
        }
    }
}
