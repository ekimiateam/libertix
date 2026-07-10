using System;
using CryptSharp;

namespace Libertix.Helpers
{
    internal static class LinuxPasswordHasher
    {
        internal static string Hash(string password)
        {
            if (string.IsNullOrEmpty(password))
                throw new ArgumentException("Linux password cannot be empty", nameof(password));

            string hash = Crypter.Sha512.Crypt(password);
            if (string.IsNullOrWhiteSpace(hash) || !hash.StartsWith("$6$", StringComparison.Ordinal))
                throw new InvalidOperationException("Failed to generate a Linux SHA-512 crypt hash");
            return hash;
        }
    }
}
