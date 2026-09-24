using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Libertix.Helpers;
using Libertix.Models;

namespace Libertix.Installation
{
    public static class DistributionCatalogLoader
    {
        private const long MaximumCatalogBytes = 1024 * 1024;
        private const long MaximumCatalogSignatureBytes = 16 * 1024;
        private static readonly HttpClient SharedHttpClient = new HttpClient
        {
            Timeout = Timeout.InfiniteTimeSpan
        };

        public static async Task<IReadOnlyList<DistroInfo>> LoadAsync(
            FilepoolConfig filepool)
        {
            if (filepool == null)
                throw new ArgumentNullException(nameof(filepool));

            byte[] manifest = filepool.LocalDirectory == null
                ? await DownloadCatalogAsync(filepool)
                : ReadLocalCatalog(filepool.LocalDirectory);
            DistributionCatalogJson catalog = ParseCatalog(manifest);
            return CreateDistributions(catalog, filepool);
        }

        public static async Task VerifyLocalFilepoolAsync(
            FilepoolConfig filepool,
            Action<string> onProgress)
        {
            if (filepool == null || filepool.LocalDirectory == null)
                throw new ArgumentException("A local filepool must be selected.", nameof(filepool));

            byte[] localManifest = ReadLocalCatalog(filepool.LocalDirectory);
            DistributionCatalogJson catalog = ParseCatalog(localManifest);
            if (!filepool.SkipWebCatalogComparison)
            {
                byte[] onlineManifest = await DownloadCatalogAsync(filepool);
                if (!localManifest.SequenceEqual(onlineManifest))
                    throw new InvalidDataException(
                        "The local catalog.json differs from the signed online catalog.json.");
            }

            var artifacts = new List<CatalogArtifactJson>
            {
                catalog.Artifacts.Wpf,
                catalog.Artifacts.MiniIso.Bios,
                catalog.Artifacts.MiniIso.Uefi,
                catalog.Artifacts.Support.Aria2Archive,
                catalog.Artifacts.Support.Ext4Driver,
                catalog.Artifacts.Support.Grub4DosLoader,
                catalog.Artifacts.Support.Grub4DosMbr
            };
            foreach (DistroInfoJson distribution in catalog.Distributions)
            {
                ValidateDistribution(distribution);
                artifacts.Add(new CatalogArtifactJson
                {
                    FileName = distribution.IsoInstallerFileName,
                    Sha256 = distribution.IsoInstallerSha256,
                    SizeBytes = distribution.IsoInstallerSizeBytes
                });
            }

            await Task.Run(() =>
            {
                foreach (CatalogArtifactJson artifact in artifacts)
                {
                    if (!Regex.IsMatch(
                        artifact.FileName ?? string.Empty,
                        "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))
                        throw new InvalidDataException("A local artifact filename is invalid.");

                    string path = Path.Combine(filepool.LocalDirectory, artifact.FileName);
                    var file = new FileInfo(path);
                    if (!file.Exists || file.Length != artifact.SizeBytes ||
                        (file.Attributes & FileAttributes.ReparsePoint) != 0)
                        throw new InvalidDataException(
                            "A local filepool artifact is missing or has the wrong size: " +
                            artifact.FileName);

                    onProgress?.Invoke("CHECK=LOCAL_FILEPOOL: " + artifact.FileName);
                    using (var stream = file.OpenRead())
                    using (var sha256 = SHA256.Create())
                    {
                        string actual = BitConverter.ToString(sha256.ComputeHash(stream))
                            .Replace("-", string.Empty);
                        if (!string.Equals(
                            actual, artifact.Sha256, StringComparison.OrdinalIgnoreCase))
                            throw new InvalidDataException(
                                "A local filepool artifact has the wrong SHA-256: " +
                                artifact.FileName);
                    }
                }
            });
        }

        private static byte[] ReadLocalCatalog(string directory)
        {
            string manifestPath = Path.Combine(directory, "catalog.json");
            string signaturePath = manifestPath + ".sig";
            var manifest = new FileInfo(manifestPath);
            var signature = new FileInfo(signaturePath);
            if (!manifest.Exists || manifest.Length > MaximumCatalogBytes ||
                (manifest.Attributes & FileAttributes.ReparsePoint) != 0 ||
                !signature.Exists || signature.Length > MaximumCatalogSignatureBytes ||
                (signature.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new InvalidDataException(
                    "The local catalog.json or catalog.json.sig is missing or too large.");
            byte[] bytes = File.ReadAllBytes(manifestPath);
            DistributionCatalogTrust.VerifyWithApplicationKey(
                bytes,
                File.ReadAllText(signaturePath, Encoding.UTF8));
            return bytes;
        }

        private static async Task<byte[]> DownloadCatalogAsync(FilepoolConfig filepool)
        {
            using (var timeoutCancellation =
                new CancellationTokenSource(TimeSpan.FromSeconds(30)))
            using (var response = await SharedHttpClient.GetAsync(
                filepool.CatalogUrl,
                HttpCompletionOption.ResponseHeadersRead,
                timeoutCancellation.Token))
            {
                response.EnsureSuccessStatusCode();
                byte[] manifest = await BoundedHttpContent.ReadAsync(
                    response.Content,
                    MaximumCatalogBytes,
                    timeoutCancellation.Token);
                if (filepool.RequiresCatalogSignature)
                {
                    using (var signatureResponse = await SharedHttpClient.GetAsync(
                        filepool.CatalogSignatureUrl,
                        HttpCompletionOption.ResponseHeadersRead,
                        timeoutCancellation.Token))
                    {
                        signatureResponse.EnsureSuccessStatusCode();
                        byte[] signatureBytes = await BoundedHttpContent.ReadAsync(
                            signatureResponse.Content,
                            MaximumCatalogSignatureBytes,
                            timeoutCancellation.Token);
                        DistributionCatalogTrust.VerifyWithApplicationKey(
                            manifest,
                            Encoding.UTF8.GetString(signatureBytes));
                    }
                }

                return manifest;
            }
        }

        private static DistributionCatalogJson ParseCatalog(byte[] manifest)
        {
            var options = new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true
            };
            var catalog = JsonSerializer.Deserialize<DistributionCatalogJson>(
                Encoding.UTF8.GetString(manifest),
                options);
            ValidateCatalog(catalog);
            return catalog;
        }

        private static void ValidateCatalog(DistributionCatalogJson catalog)
        {
            if (catalog == null ||
                catalog.SchemaVersion != 1 ||
                catalog.Artifacts?.MiniIso == null ||
                catalog.Artifacts.Support == null ||
                catalog.Distributions == null ||
                catalog.Distributions.Count == 0)
            {
                throw new InvalidOperationException(
                    "Distribution catalog JSON is empty or invalid.");
            }

            ValidateWpfArtifact(catalog.Artifacts.Wpf);
            ValidateArtifact(
                catalog.Artifacts.MiniIso.Bios,
                "libertix-installer-bios.iso");
            ValidateArtifact(
                catalog.Artifacts.MiniIso.Uefi,
                "libertix-installer-uefi.iso");
            ValidateArtifact(catalog.Artifacts.Support.Aria2Archive, "aria2-64.zip");
            ValidateArtifact(
                catalog.Artifacts.Support.Ext4Driver,
                "ext4-win-driver.exe");
            ValidateArtifact(catalog.Artifacts.Support.Grub4DosLoader, "grldr");
            ValidateArtifact(catalog.Artifacts.Support.Grub4DosMbr, "grldr.mbr");
        }

        private static IReadOnlyList<DistroInfo> CreateDistributions(
            DistributionCatalogJson catalog,
            FilepoolConfig filepool)
        {
            CatalogArtifactJson biosMiniIso = catalog.Artifacts.MiniIso.Bios;
            CatalogArtifactJson uefiMiniIso = catalog.Artifacts.MiniIso.Uefi;
            var distributions = new List<DistroInfo>(catalog.Distributions.Count);
            var seenIds = new HashSet<string>(StringComparer.Ordinal);

            foreach (DistroInfoJson source in catalog.Distributions)
            {
                ValidateDistribution(source);
                if (!seenIds.Add(source.Id))
                {
                    throw new InvalidOperationException(
                        "Distribution manifest contains a duplicate id.");
                }

                distributions.Add(new DistroInfo
                {
                    Id = source.Id,
                    Name = source.Name,
                    OsReleaseId = source.OsReleaseId,
                    GrubDisplayName = source.GrubDisplayName,
                    GrubIcon = source.GrubIcon,
                    SecureBootMicrosoftAuthorities =
                        source.SecureBootMicrosoftAuthorities.ToList(),
                    Description = source.Description ?? "No description available",
                    ImageUrl = source.ImageUrl,
                    IsoUrl = filepool.ResolveUrl(biosMiniIso.Url),
                    IsoInstaller = filepool.ResolveUrl(source.IsoInstaller),
                    IsoInstallerFileName = source.IsoInstallerFileName,
                    IsoSha256 = biosMiniIso.Sha256,
                    UefiIsoUrl = filepool.ResolveUrl(uefiMiniIso.Url),
                    UefiIsoSha256 = uefiMiniIso.Sha256,
                    IsoInstallerSha256 = source.IsoInstallerSha256,
                    IsoInstallerSizeBytes = source.IsoInstallerSizeBytes,
                    SizeInGB = source.SizeInGB
                });
            }

            return distributions;
        }

        private static void ValidateDistribution(DistroInfoJson distribution)
        {
            if (!Regex.IsMatch(
                    distribution.Id ?? string.Empty,
                    "^[a-z0-9](?:[a-z0-9._-]{0,62}[a-z0-9])?$") ||
                string.IsNullOrWhiteSpace(distribution.Name) ||
                !Regex.IsMatch(
                    distribution.OsReleaseId ?? string.Empty,
                    "^[a-z0-9](?:[a-z0-9._-]{0,62}[a-z0-9])?$") ||
                !Regex.IsMatch(
                    distribution.GrubDisplayName ?? string.Empty,
                    "^[A-Za-z0-9][A-Za-z0-9 ._()+-]{0,79}$") ||
                !Regex.IsMatch(
                    distribution.GrubIcon ?? string.Empty,
                    "^[a-z0-9](?:[a-z0-9._-]{0,62}[a-z0-9])?$") ||
                distribution.SecureBootMicrosoftAuthorities == null ||
                distribution.SecureBootMicrosoftAuthorities.Count == 0 ||
                distribution.SecureBootMicrosoftAuthorities.Any(
                    authority => authority != "2011" && authority != "2023") ||
                distribution.SecureBootMicrosoftAuthorities
                    .Distinct(StringComparer.Ordinal).Count() !=
                    distribution.SecureBootMicrosoftAuthorities.Count ||
                string.IsNullOrWhiteSpace(distribution.IsoInstaller) ||
                string.IsNullOrWhiteSpace(distribution.IsoInstallerFileName) ||
                !Regex.IsMatch(
                    distribution.IsoInstallerSha256 ?? string.Empty,
                    "^[0-9a-fA-F]{64}$") ||
                distribution.IsoInstallerSizeBytes <= 0 ||
                distribution.SizeInGB < InstallationSizePolicy.MinimumFinalSizeGiB)
            {
                throw new InvalidOperationException(
                    "Distribution manifest contains an invalid entry.");
            }
        }

        private static void ValidateArtifact(
            CatalogArtifactJson artifact,
            string expectedFileName)
        {
            if (artifact == null ||
                !string.Equals(
                    artifact.FileName,
                    expectedFileName,
                    StringComparison.Ordinal) ||
                string.IsNullOrWhiteSpace(artifact.Url) ||
                !Regex.IsMatch(artifact.Sha256 ?? string.Empty, "^[0-9a-fA-F]{64}$") ||
                artifact.SizeBytes <= 0)
            {
                throw new InvalidOperationException(
                    "Distribution catalog contains invalid artifact metadata.");
            }
        }

        private static void ValidateWpfArtifact(CatalogArtifactJson artifact)
        {
            if (artifact == null ||
                !Regex.IsMatch(
                    artifact.FileName ?? string.Empty,
                    "^Libertix-(?:wpf|[0-9a-f]{7}|(?:0|[1-9][0-9]*)(?:\\.(?:0|[1-9][0-9]*)){1,2}(?:-[0-9A-Za-z.-]+)?)\\.zip$") ||
                string.IsNullOrWhiteSpace(artifact.Url) ||
                !artifact.Url.EndsWith("/" + artifact.FileName, StringComparison.Ordinal) ||
                !Regex.IsMatch(artifact.Sha256 ?? string.Empty, "^[0-9a-fA-F]{64}$") ||
                artifact.SizeBytes <= 0)
            {
                throw new InvalidOperationException(
                    "Distribution catalog contains invalid WPF artifact metadata.");
            }
        }
    }
}
