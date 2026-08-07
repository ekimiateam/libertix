using System;
using System.IO;
using Libertix.Helpers;
using Libertix.Installation;
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
        }

        [TestMethod]
        public void VersionedDistributionManifestHasAValidDetachedSignature()
        {
            string testData = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "TestData");
            byte[] manifest = File.ReadAllBytes(Path.Combine(testData, "distros.json"));
            string signature = File.ReadAllText(Path.Combine(testData, "distros.json.sig"));
            string publicKey = Path.Combine(testData, "Libertix.CatalogPublicKey.xml");

            DistributionCatalogTrust.Verify(manifest, signature, publicKey);
            manifest[0] ^= 1;
            Assert.ThrowsException<InvalidDataException>(
                () => DistributionCatalogTrust.Verify(manifest, signature, publicKey));
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
    }
}
