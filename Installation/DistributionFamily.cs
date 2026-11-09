using System;

namespace Libertix.Installation
{
    /// <summary>
    /// How the live installer puts a distribution on disk. Catalogues and plans
    /// written before families existed carry no family and always meant
    /// <see cref="Debian"/>: the system is copied from the ISO squashfs.
    /// <see cref="Arch"/> bootstraps from the ISO and downloads packages.
    /// </summary>
    public static class DistributionFamily
    {
        public const string Debian = "debian";
        public const string Arch = "arch";

        public static string Normalize(string family) => family ?? Debian;

        public static bool IsSupported(string family)
        {
            string normalized = Normalize(family);
            return string.Equals(normalized, Debian, StringComparison.Ordinal) ||
                string.Equals(normalized, Arch, StringComparison.Ordinal);
        }

        /// <summary>
        /// Whether the installed system boots through a distribution shim signed by a
        /// Microsoft UEFI CA. Families without one require Secure Boot to be disabled.
        /// </summary>
        public static bool HasSignedBootChain(string family) =>
            !string.Equals(Normalize(family), Arch, StringComparison.Ordinal);

        /// <summary>
        /// Whether the live installer needs an internet connection to install packages.
        /// </summary>
        public static bool RequiresNetwork(string family) =>
            string.Equals(Normalize(family), Arch, StringComparison.Ordinal);

        /// <summary>
        /// Windows preference migration writes Cinnamon/GNOME settings and is limited to
        /// the Debian-family desktops it was built for.
        /// </summary>
        public static bool SupportsWindowsPreferenceMigration(string family) =>
            string.Equals(Normalize(family), Debian, StringComparison.Ordinal);
    }
}
