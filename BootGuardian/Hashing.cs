using System;
using System.IO;
using System.Security.Cryptography;
using System.Text.RegularExpressions;

namespace Libertix.BootGuardian
{
    internal static class Hashing
    {
        internal static bool IsSha256(string value)
        {
            return Regex.IsMatch(value ?? string.Empty, "^[0-9a-f]{64}$");
        }

        internal static string Sha256(byte[] value)
        {
            using (SHA256 sha = SHA256.Create())
                return ToHex(sha.ComputeHash(value));
        }

        internal static string Sha256File(string path)
        {
            using (SHA256 sha = SHA256.Create())
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
                return ToHex(sha.ComputeHash(stream));
        }

        private static string ToHex(byte[] value)
        {
            return BitConverter.ToString(value).Replace("-", string.Empty).ToLowerInvariant();
        }
    }
}
