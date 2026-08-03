using System;

namespace Libertix.Helpers
{
    public static class FilepoolConfig
    {
        public const string ProductionBaseUrl = "https://ekimia.fr/libertix";

        public static string BaseUrl { get; private set; } = ProductionBaseUrl;

        public static string DistrosUrl => BaseUrl + "/distros.json";

        public static bool TryUseOverride(string value, out string error)
        {
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

            BaseUrl = uri.AbsoluteUri.TrimEnd('/');
            return true;
        }

        public static string ResolveUrl(string value)
        {
            if (string.IsNullOrWhiteSpace(value))
                return value;

            if (System.Uri.TryCreate(value, System.UriKind.Absolute, out _))
                return value;

            return BaseUrl.TrimEnd('/') + "/" + value.TrimStart('/');
        }
    }
}
