namespace Libertix.Helpers
{
    public static class FilepoolConfig
    {
        private const string DefaultBaseUrl = "http://192.168.1.170:8000/filepool";

        public static string BaseUrl
        {
            get
            {
                var configured = System.Environment.GetEnvironmentVariable("FILEPOOL_BASE_URL");
                return string.IsNullOrWhiteSpace(configured)
                    ? DefaultBaseUrl
                    : configured.TrimEnd('/');
            }
        }

        public static string DistrosUrl => BaseUrl + "/distros.json";

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
