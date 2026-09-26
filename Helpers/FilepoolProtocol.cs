using System;
using System.Net;
using System.Text.RegularExpressions;

namespace Libertix.Helpers
{
    public static class FilepoolProtocol
    {
        public const int DiscoveryPort = 18081;
        public const int DefaultHttpsPort = 18080;
        public const string DiscoveryRequest = "LIBERTIX_FILEPOOL_1";

        public static Uri ValidateServer(string value)
        {
            Uri uri;
            IPAddress address;
            if (!Uri.TryCreate(value, UriKind.Absolute, out uri) ||
                uri.Scheme != Uri.UriSchemeHttps ||
                !IPAddress.TryParse(uri.Host.Trim('[', ']'), out address) ||
                address.Equals(IPAddress.Any) || address.Equals(IPAddress.IPv6Any) ||
                uri.AbsolutePath != "/" || uri.UserInfo.Length != 0 ||
                uri.Query.Length != 0 || uri.Fragment.Length != 0)
                throw new ArgumentException("A local filepool must use an HTTPS IP address and port.");
            return uri;
        }

        public static string ArtifactPath(string fileName, string sha256)
        {
            if (!Regex.IsMatch(fileName ?? "", "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$") ||
                !Regex.IsMatch(sha256 ?? "", "^[0-9a-fA-F]{64}$"))
                throw new ArgumentException("Invalid filepool artifact identity.");
            return "/files/" + sha256.ToLowerInvariant() + "/" + fileName;
        }
    }
}
