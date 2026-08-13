using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace Libertix.Installation
{
    public static class AccountPolicy
    {
        public const int MinimumPasswordLength = 4;
        public const int MaximumPasswordLength = 128;
        private const int MaximumUsernameLength = 32;
        private const string DefaultUsernameSuffix = "-linux";

        private static readonly Regex UsernamePattern = new Regex(
            "^[a-z](?:[a-z0-9-]{0,30}[a-z0-9])?$",
            RegexOptions.CultureInvariant);

        private static readonly Regex ComputerNamePattern = new Regex(
            "^[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$",
            RegexOptions.CultureInvariant);

        private static readonly HashSet<string> ReservedUsernames = new HashSet<string>(
            InstallationPolicy.Current.Account.ReservedUsernames,
            StringComparer.OrdinalIgnoreCase);

        public static bool IsValidUsername(string value)
        {
            return IsValidUsernameSyntax(value) && !IsReservedUsername(value);
        }

        public static bool IsValidUsernameSyntax(string value)
        {
            return UsernamePattern.IsMatch(value ?? string.Empty);
        }

        public static bool IsReservedUsername(string value)
        {
            return !string.IsNullOrEmpty(value) && ReservedUsernames.Contains(value);
        }

        public static string CreateDefaultUsername(string windowsUsername)
        {
            string candidate = Regex.Replace(
                (windowsUsername ?? string.Empty).ToLowerInvariant(),
                "[^a-z0-9-]",
                string.Empty).Trim('-');
            candidate = TruncateUsername(candidate, MaximumUsernameLength);

            if (candidate.Length == 0 || !char.IsLetter(candidate[0]))
                candidate = "user";
            if (IsValidUsername(candidate))
                return candidate;

            int baseLength = MaximumUsernameLength - DefaultUsernameSuffix.Length;
            string suffixedBase = TruncateUsername(candidate, baseLength);
            if (suffixedBase.Length == 0 || !char.IsLetter(suffixedBase[0]))
                suffixedBase = "user";

            string suffixed = suffixedBase + DefaultUsernameSuffix;
            return IsValidUsername(suffixed) ? suffixed : "user-linux";
        }

        private static string TruncateUsername(string value, int maximumLength)
        {
            string truncated = value.Length <= maximumLength
                ? value
                : value.Substring(0, maximumLength);
            return truncated.TrimEnd('-');
        }

        public static bool IsValidComputerName(string value)
        {
            return ComputerNamePattern.IsMatch(value ?? string.Empty);
        }
    }
}
