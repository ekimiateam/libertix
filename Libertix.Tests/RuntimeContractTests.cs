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
        public void StableBuildUsesTheSignedMainPagesChannel()
        {
            ApplicationBuild build = ApplicationBuild.Parse("0.1");
            FilepoolConfig filepool = FilepoolConfig.ForBuild(build);

            Assert.AreEqual(
                "https://ekimiateam.github.io/libertix/main/catalog.json",
                filepool.CatalogUrl);
            Assert.AreEqual(
                "https://ekimiateam.github.io/libertix/main/releases.json",
                filepool.ReleasesUrl);
            Assert.IsTrue(filepool.RequiresCatalogSignature);
            Assert.IsFalse(filepool.IsDevelopmentMode);
            Assert.AreEqual(
                "https://ekimiateam.github.io/libertix/main/catalog.json.sig",
                filepool.CatalogSignatureUrl);
            Assert.IsTrue(build.RequiresPublishedVersionCheck);
            Assert.IsFalse(build.AllowsDevelopmentFilepoolOverride);
        }

        [TestMethod]
        public void DevelopmentBuildUsesItsSignedDevPagesChannelWithoutFreshnessCheck()
        {
            ApplicationBuild build = ApplicationBuild.Parse("dev_a881918");
            FilepoolConfig filepool = FilepoolConfig.ForBuild(build);

            Assert.AreEqual("dev", build.Channel);
            Assert.AreEqual("a881918", build.ReleaseTag);
            Assert.AreEqual(
                "https://ekimiateam.github.io/libertix/dev/catalog.json",
                filepool.CatalogUrl);
            Assert.IsTrue(filepool.RequiresCatalogSignature);
            Assert.IsFalse(filepool.IsDevelopmentMode);
            Assert.IsFalse(build.RequiresPublishedVersionCheck);
            Assert.IsTrue(build.AllowsDevelopmentFilepoolOverride);
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
            byte[] manifest = File.ReadAllBytes(Path.Combine(testData, "catalog.json"));
            string signature = File.ReadAllText(Path.Combine(testData, "catalog.json.sig"));
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
            string manifest = File.ReadAllText(Path.Combine(testData, "catalog.json"));
            var catalog = JsonSerializer.Deserialize<DistributionCatalogJson>(manifest);

            Assert.IsNotNull(catalog);
            Assert.AreEqual(1, catalog.SchemaVersion);
            Assert.AreEqual(2, catalog.Distributions.Count);
            Assert.AreEqual("mint", catalog.Distributions[0].Id);
            Assert.AreEqual(3091660800L, catalog.Distributions[0].IsoInstallerSizeBytes);
            Assert.AreEqual(20d, catalog.Distributions[0].SizeInGB);
            Assert.AreEqual("zorin", catalog.Distributions[1].Id);
            Assert.AreEqual(3909091328L, catalog.Distributions[1].IsoInstallerSizeBytes);
            Assert.AreEqual(20d, catalog.Distributions[1].SizeInGB);
            Assert.AreEqual(
                "libertix-installer-bios.iso",
                catalog.Artifacts.MiniIso.Bios.FileName);
            Assert.AreEqual("aria2-64.zip", catalog.Artifacts.Support.Aria2Archive.FileName);
        }

        [TestMethod]
        public void PublicHttpsArtifactUrlIsAccepted()
        {
            Assert.AreEqual(
                "https://pub.linuxmint.io/stable/mint.iso",
                FilepoolConfig.ForBuild(ApplicationBuild.Parse("0.1")).ResolveUrl(
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
                () => FilepoolConfig.ForBuild(ApplicationBuild.Parse("0.1")).ResolveUrl(value));
        }

        [TestMethod]
        public void PublishedStableMetadataRejectsAnUntrustedDownloadPage()
        {
            string json = "{\"schemaVersion\":1,\"channel\":\"main\",\"latest\":{" +
                "\"version\":\"0.1\",\"tag\":\"0.1\"," +
                "\"commit\":\"" + new string('a', 40) + "\"," +
                "\"releaseUrl\":\"https://example.test/fake\"}}";

            Assert.ThrowsException<InvalidDataException>(() =>
                ReleaseMetadataClient.ParseAndValidate(System.Text.Encoding.UTF8.GetBytes(json)));
        }

        [TestMethod]
        public void PublishedStableMetadataAcceptsTheMatchingGitHubRelease()
        {
            string json = "{\"schemaVersion\":1,\"channel\":\"main\",\"latest\":{" +
                "\"version\":\"0.1\",\"tag\":\"0.1\"," +
                "\"commit\":\"" + new string('a', 40) + "\"," +
                "\"releaseUrl\":\"https://github.com/ekimiateam/libertix/releases/tag/0.1\"}}";

            ReleaseMetadata metadata = ReleaseMetadataClient.ParseAndValidate(
                System.Text.Encoding.UTF8.GetBytes(json));

            Assert.AreEqual("0.1", metadata.Latest.Version);
        }

        [TestMethod]
        public void PersistedRuntimeNamesRemainStable()
        {
            Assert.AreEqual("LIBERTIXISO", RuntimeNames.InstallationMediaVolumeLabel);
            Assert.AreEqual("LIBERTIXSTG", RuntimeNames.StagingVolumeLabel);
            Assert.AreEqual("LibertixInstallLogs", RuntimeNames.InstallationLogDirectory);
            Assert.AreEqual("Windows", RuntimeNames.WindowsLogDirectory);
            Assert.AreEqual("Linux", RuntimeNames.LinuxLogDirectory);
            Assert.AreEqual("LibertixInstallRecovery", RuntimeNames.BiosRecoveryDirectory);
            Assert.AreEqual("LibertixInstallRecovery", RuntimeNames.BiosRecoveryTask);
            Assert.AreEqual("LibertixInstallRecoveryPrompt", RuntimeNames.BiosRecoveryPromptTask);
            Assert.AreEqual("LibertixLinuxReadOnly", RuntimeNames.LinuxReadOnlyTask);
        }

        [TestMethod]
        public void WindowsShareConfigurationPublishesObservedPartitionIdentityAtomically()
        {
            string root = Path.Combine(Path.GetTempPath(), "Libertix-tests", Guid.NewGuid().ToString("N"));
            string path = Path.Combine(root, "config.json");
            try
            {
                WindowsShareConfigurationStore.WriteAtomic(
                    path,
                    new WindowsShareConfiguration
                    {
                        Enabled = true,
                        SystemDiskNumber = 2,
                        SystemDiskUniqueId = "disk-id",
                        ExpectedLinuxPartitionOffset = 1024,
                        ExpectedLinuxPartitionSize = 2048,
                        PartitionSizeToleranceBytes = 512,
                        LinuxUsername = "test",
                        ShortcutDescription = "Linux files",
                        SetupPath = @"C:\setup.exe",
                        SetupSha256 = new string('a', 64),
                        SetupAttachedContainerSize = 4096,
                        WinFspPayloadName = "a0",
                        WinFspPayloadSha256 = new string('b', 64),
                        DriverPayloadName = "a1",
                        DriverPayloadSha256 = new string('c', 64)
                    });

                WindowsShareConfiguration configuration =
                    WindowsShareConfigurationStore.Read(path);
                configuration.ExpectedLinuxPartitionOffset = 4096;
                WindowsShareConfigurationStore.WriteAtomic(path, configuration);

                WindowsShareConfiguration observed = WindowsShareConfigurationStore.Read(path);
                Assert.AreEqual(4096L, observed.ExpectedLinuxPartitionOffset);
                Assert.AreEqual(2048L, observed.ExpectedLinuxPartitionSize);
                Assert.AreEqual(512L, observed.PartitionSizeToleranceBytes);
                Assert.IsFalse(File.Exists(Path.Combine(root, ".config.json.tmp")));
            }
            finally
            {
                if (Directory.Exists(root))
                    Directory.Delete(root, true);
            }
        }

        [TestMethod]
        public void WindowsShareConfigurationRejectsMissingPartitionTolerance()
        {
            string root = Path.Combine(Path.GetTempPath(), "Libertix-tests", Guid.NewGuid().ToString("N"));
            string path = Path.Combine(root, "config.json");
            try
            {
                Assert.ThrowsException<InvalidOperationException>(() =>
                    WindowsShareConfigurationStore.WriteAtomic(
                        path,
                        new WindowsShareConfiguration
                        {
                            SystemDiskNumber = 0,
                            SystemDiskUniqueId = "disk-id",
                            ExpectedLinuxPartitionOffset = 1024,
                            ExpectedLinuxPartitionSize = 2048,
                            PartitionSizeToleranceBytes = 0
                        }));
                Assert.IsFalse(File.Exists(path));
            }
            finally
            {
                if (Directory.Exists(root))
                    Directory.Delete(root, true);
            }
        }

        [TestMethod]
        public void ClearedAccountSecretRequiresEntryBeforeRetry()
        {
            var account = new AccountInfo
            {
                Username = "test",
                Password = "test-passphrase",
                ComputerName = "test-linux"
            };

            Assert.IsTrue(account.HasPassword);
            account.ClearPassword();
            Assert.IsFalse(account.HasPassword);
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
