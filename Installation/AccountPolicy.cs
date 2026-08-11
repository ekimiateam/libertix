using System.Text.RegularExpressions;

namespace Libertix.Installation
{
    public static class AccountPolicy
    {
        public const int MinimumPasswordLength = 8;
        public const int MaximumPasswordLength = 128;

        private static readonly Regex UsernamePattern = new Regex(
            "^[a-z](?:[a-z0-9-]{0,30}[a-z0-9])?$",
            RegexOptions.CultureInvariant);

        private static readonly Regex ComputerNamePattern = new Regex(
            "^[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$",
            RegexOptions.CultureInvariant);

        public static bool IsValidUsername(string value)
        {
            return UsernamePattern.IsMatch(value ?? string.Empty);
        }

        public static bool IsValidComputerName(string value)
        {
            return ComputerNamePattern.IsMatch(value ?? string.Empty);
        }
    }
}
