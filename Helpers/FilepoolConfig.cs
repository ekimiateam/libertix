namespace Libertix.Helpers
{
    public static class FilepoolConfig
    {
        ///public const string BaseUrl = "http://192.168.1.170:8000/filepool";
        public const string BaseUrl = "https://ekimia.fr/libertix";

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
