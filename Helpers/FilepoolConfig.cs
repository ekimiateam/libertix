using System;

namespace Libertix.Helpers
{
    public sealed class FilepoolConfig
    {
        public const string ProductionBaseUrl = "https://ekimia.fr/libertix";

        private FilepoolConfig(string baseUrl)
        {
            BaseUrl = baseUrl;
        }

        public string BaseUrl { get; }

        public string DistrosUrl => BaseUrl + "/distros.json";

        public string DistrosSignatureUrl => DistrosUrl + ".sig";

        public bool RequiresCatalogSignature => string.Equals(
            BaseUrl,
            ProductionBaseUrl,
            StringComparison.OrdinalIgnoreCase);

        public bool IsDevelopmentMode => !RequiresCatalogSignature;

        public static FilepoolConfig Production { get; } =
            new FilepoolConfig(ProductionBaseUrl);

        public static bool TryCreate(string value, out FilepoolConfig config, out string error)
        {
            config = null;
            error = null;

            if (!Uri.TryCreate(value, UriKind.Absolute, out Uri uri) ||
                (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps) ||
                string.IsNullOrWhiteSpace(uri.Host))
            {
                error = "The filepool base URL must be an absolute HTTP or HTTPS URL.";
                return false;
            }

            // Credentials, query strings and fragments make URL resolution ambiguous
            // and may leak secrets into installer logs.
            if (!string.IsNullOrEmpty(uri.UserInfo) ||
                !string.IsNullOrEmpty(uri.Query) ||
                !string.IsNullOrEmpty(uri.Fragment))
            {
                error = "The filepool base URL cannot contain credentials, a query or a fragment.";
                return false;
            }

            config = new FilepoolConfig(uri.AbsoluteUri.TrimEnd('/'));
            return true;
        }

        public string ResolveUrl(string value)
        {
            if (string.IsNullOrWhiteSpace(value))
                return value;

            if (Uri.TryCreate(value, UriKind.Absolute, out Uri absoluteUri))
            {
                if ((absoluteUri.Scheme != Uri.UriSchemeHttp &&
                     absoluteUri.Scheme != Uri.UriSchemeHttps) ||
                    string.IsNullOrWhiteSpace(absoluteUri.Host) ||
                    !string.IsNullOrEmpty(absoluteUri.UserInfo) ||
                    !string.IsNullOrEmpty(absoluteUri.Query) ||
                    !string.IsNullOrEmpty(absoluteUri.Fragment))
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
