using System;
using System.IO;
using System.Security.Cryptography;

namespace Libertix.Installation
{
    public static class WindowsPreferenceMigrationContract
    {
        public const int BundleSchemaVersion = 1;
        public const string BundleFileName = "windows-preferences.secret.json";
        public const long MaximumBundleBytes = 128L * 1024L * 1024L;
        public const int MaximumWifiProfiles = 256;

        public static string ComputeSha256(string path)
        {
            if (string.IsNullOrWhiteSpace(path))
                throw new ArgumentException("A bundle path is required.", nameof(path));

            using (var stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read))
            using (var sha256 = SHA256.Create())
            {
                return BitConverter.ToString(sha256.ComputeHash(stream))
                    .Replace("-", string.Empty)
                    .ToLowerInvariant();
            }
        }
    }
}
