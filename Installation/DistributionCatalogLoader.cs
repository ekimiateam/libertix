using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
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

            using (var timeoutCancellation =
                new CancellationTokenSource(TimeSpan.FromSeconds(30)))
            using (var response = await SharedHttpClient.GetAsync(
                filepool.CatalogUrl,
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

                var options = new JsonSerializerOptions
                {
                    PropertyNameCaseInsensitive = true
                };
                var catalog = JsonSerializer.Deserialize<DistributionCatalogJson>(
                    Encoding.UTF8.GetString(manifest),
                    options);
                ValidateCatalog(catalog);
                return CreateDistributions(catalog, filepool);
            }
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
