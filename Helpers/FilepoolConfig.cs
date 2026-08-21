using System;

namespace Libertix.Helpers
{
    public sealed class FilepoolConfig
    {
        private readonly bool _requiresCatalogSignature;
        private readonly bool _isDevelopmentOverride;

        private FilepoolConfig(
            string baseUrl,
            bool requiresCatalogSignature,
            bool isDevelopmentOverride)
        {
            BaseUrl = baseUrl;
            _requiresCatalogSignature = requiresCatalogSignature;
            _isDevelopmentOverride = isDevelopmentOverride;
        }

        public string BaseUrl { get; }

        public string CatalogUrl => BaseUrl + "/catalog.json";

        public string CatalogSignatureUrl => CatalogUrl + ".sig";

        public string ReleasesUrl => BaseUrl + "/releases.json";

        public string ReleasesSignatureUrl => ReleasesUrl + ".sig";

        public bool RequiresCatalogSignature => _requiresCatalogSignature;

        public bool IsDevelopmentMode => _isDevelopmentOverride;

        public static FilepoolConfig ForBuild(ApplicationBuild build)
        {
            if (build == null)
                throw new ArgumentNullException(nameof(build));
            return new FilepoolConfig(
                build.MetadataBaseUrl,
                requiresCatalogSignature: true,
                isDevelopmentOverride: false);
        }

        private static bool HasAllowedScheme(Uri uri) =>
            (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps) &&
            !string.IsNullOrWhiteSpace(uri.Host);

        // Credentials, query strings and fragments make URL resolution ambiguous
        // and may leak secrets into installer logs.
        private static bool HasDisallowedUrlComponents(Uri uri) =>
            !string.IsNullOrEmpty(uri.UserInfo) ||
            !string.IsNullOrEmpty(uri.Query) ||
            !string.IsNullOrEmpty(uri.Fragment);

        public static bool TryCreate(string value, out FilepoolConfig config, out string error)
        {
            config = null;
            error = null;

            if (!Uri.TryCreate(value, UriKind.Absolute, out Uri uri) || !HasAllowedScheme(uri))
            {
                error = "The filepool base URL must be an absolute HTTP or HTTPS URL.";
                return false;
            }

            if (HasDisallowedUrlComponents(uri))
            {
                error = "The filepool base URL cannot contain credentials, a query or a fragment.";
                return false;
            }

            config = new FilepoolConfig(
                uri.AbsoluteUri.TrimEnd('/'),
                requiresCatalogSignature: false,
                isDevelopmentOverride: true);
            return true;
        }

        public string ResolveUrl(string value)
        {
            if (string.IsNullOrWhiteSpace(value))
                return value;

            if (Uri.TryCreate(value, UriKind.Absolute, out Uri absoluteUri))
            {
                if (!HasAllowedScheme(absoluteUri) || HasDisallowedUrlComponents(absoluteUri))
                {
                    throw new ArgumentException(
                        "Artifact URLs must be public absolute HTTP(S) URLs.",
                        nameof(value));
                }
                return absoluteUri.AbsoluteUri;
            }

            return BaseUrl.TrimEnd('/') + "/" + value.TrimStart('/');
        }
    }
}
