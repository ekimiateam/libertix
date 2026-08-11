using System;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Libertix.Helpers;

namespace Libertix.Installation
{
    public sealed class ReleaseMetadata
    {
        [JsonPropertyName("schemaVersion")]
        public int SchemaVersion { get; set; }

        [JsonPropertyName("channel")]
        public string Channel { get; set; }

        [JsonPropertyName("latest")]
        public ReleaseMetadataEntry Latest { get; set; }
    }

    public sealed class ReleaseMetadataEntry
    {
        [JsonPropertyName("version")]
        public string Version { get; set; }

        [JsonPropertyName("tag")]
        public string Tag { get; set; }

        [JsonPropertyName("commit")]
        public string Commit { get; set; }

        [JsonPropertyName("releaseUrl")]
        public string ReleaseUrl { get; set; }
    }

    public sealed class ReleaseCheckResult
    {
        private ReleaseCheckResult(
            bool isCurrent,
            string latestVersion,
            string releaseUrl,
            string error)
        {
            IsCurrent = isCurrent;
            LatestVersion = latestVersion;
            ReleaseUrl = releaseUrl;
            Error = error;
        }

        public bool IsCurrent { get; }

        public string LatestVersion { get; }

        public string ReleaseUrl { get; }

        public string Error { get; }

        public static ReleaseCheckResult Current() =>
            new ReleaseCheckResult(true, null, null, null);

        public static ReleaseCheckResult Outdated(string latestVersion, string releaseUrl) =>
            new ReleaseCheckResult(false, latestVersion, releaseUrl, null);

        public static ReleaseCheckResult Failed(string error) =>
            new ReleaseCheckResult(false, null, null, error);
    }

    public static class ReleaseMetadataClient
    {
        private const long MaximumMetadataBytes = 256 * 1024;
        private const long MaximumSignatureBytes = 16 * 1024;
        private static readonly Regex StableVersionPattern = new Regex(
            "^(?:0|[1-9][0-9]*)(?:\\.(?:0|[1-9][0-9]*)){1,2}(?:-[0-9A-Za-z.-]+)?$",
            RegexOptions.CultureInvariant);
        private static readonly Regex CommitPattern = new Regex(
            "^[0-9a-f]{40}$",
            RegexOptions.CultureInvariant);
        private static readonly HttpClient SharedHttpClient = new HttpClient
        {
            Timeout = Timeout.InfiniteTimeSpan
        };

        public static async Task<ReleaseCheckResult> CheckAsync(
            ApplicationBuild build,
            FilepoolConfig filepool)
        {
            if (build == null)
                throw new ArgumentNullException(nameof(build));
            if (filepool == null)
                throw new ArgumentNullException(nameof(filepool));
            if (!build.RequiresPublishedVersionCheck || filepool.IsDevelopmentMode)
                return ReleaseCheckResult.Current();

            try
            {
                using (var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(30)))
                {
                    byte[] metadata = await DownloadAsync(
                        filepool.ReleasesUrl,
                        MaximumMetadataBytes,
                        cancellation.Token);
                    byte[] signatureBytes = await DownloadAsync(
                        filepool.ReleasesSignatureUrl,
                        MaximumSignatureBytes,
                        cancellation.Token);
                    DistributionCatalogTrust.VerifyWithApplicationKey(
                        metadata,
                        Encoding.UTF8.GetString(signatureBytes));
                    ReleaseMetadata parsed = ParseAndValidate(metadata);
                    if (string.Equals(
                        build.Version,
                        parsed.Latest.Version,
                        StringComparison.Ordinal))
                    {
                        return ReleaseCheckResult.Current();
                    }
                    return ReleaseCheckResult.Outdated(
                        parsed.Latest.Version,
                        parsed.Latest.ReleaseUrl);
                }
            }
            catch (Exception exception) when (
                exception is HttpRequestException ||
                exception is IOException ||
                exception is UnauthorizedAccessException ||
                exception is OperationCanceledException ||
                exception is JsonException ||
                exception is InvalidDataException ||
                exception is InvalidOperationException)
            {
                return ReleaseCheckResult.Failed(exception.Message);
            }
        }

        internal static ReleaseMetadata ParseAndValidate(byte[] metadata)
        {
            var options = new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = false
            };
            ReleaseMetadata parsed = JsonSerializer.Deserialize<ReleaseMetadata>(metadata, options);
            if (parsed == null ||
                parsed.SchemaVersion != 1 ||
                !string.Equals(parsed.Channel, "main", StringComparison.Ordinal) ||
                parsed.Latest == null ||
                !StableVersionPattern.IsMatch(parsed.Latest.Version ?? string.Empty) ||
                !string.Equals(parsed.Latest.Tag, parsed.Latest.Version, StringComparison.Ordinal) ||
                !CommitPattern.IsMatch(parsed.Latest.Commit ?? string.Empty) ||
                !IsTrustedReleaseUrl(parsed.Latest.ReleaseUrl, parsed.Latest.Tag))
            {
                throw new InvalidDataException("Published release metadata is invalid.");
            }
            return parsed;
        }

        private static bool IsTrustedReleaseUrl(string value, string tag)
        {
            return Uri.TryCreate(value, UriKind.Absolute, out Uri uri) &&
                uri.Scheme == Uri.UriSchemeHttps &&
                string.Equals(uri.Host, "github.com", StringComparison.OrdinalIgnoreCase) &&
                string.Equals(
                    uri.AbsolutePath,
                    "/ekimiateam/libertix/releases/tag/" + Uri.EscapeDataString(tag),
                    StringComparison.Ordinal) &&
                string.IsNullOrEmpty(uri.Query) &&
                string.IsNullOrEmpty(uri.Fragment) &&
                string.IsNullOrEmpty(uri.UserInfo);
        }

        private static async Task<byte[]> DownloadAsync(
            string url,
            long maximumBytes,
            CancellationToken cancellationToken)
        {
            using (HttpResponseMessage response = await SharedHttpClient.GetAsync(
                url,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken))
            {
                response.EnsureSuccessStatusCode();
                return await BoundedHttpContent.ReadAsync(
                    response.Content,
                    maximumBytes,
                    cancellationToken);
            }
        }
    }
}
