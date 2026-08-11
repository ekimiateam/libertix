using System;
using System.Collections.Generic;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using Libertix.Helpers;

namespace Libertix.Installation
{
    public sealed class LinuxKeyboardConfiguration
    {
        public LinuxKeyboardConfiguration(
            string layout,
            string variant,
            string windowsKeyboardIdentifier,
            bool usedFallback)
        {
            Layout = layout;
            Variant = variant;
            WindowsKeyboardIdentifier = windowsKeyboardIdentifier;
            UsedFallback = usedFallback;
        }

        public string Layout { get; }

        public string Variant { get; }

        public string WindowsKeyboardIdentifier { get; }

        public bool UsedFallback { get; }
    }

    /// <summary>
    /// Resolves the calling Windows thread's active keyboard identifier to an
    /// equivalent XKB layout and variant.
    /// </summary>
    public static class WindowsKeyboardLayout
    {
        private const int KeyboardLayoutNameLength = 9;

        private static readonly IReadOnlyDictionary<string, LinuxKeyboardConfiguration> ExactMappings =
            new Dictionary<string, LinuxKeyboardConfiguration>(StringComparer.OrdinalIgnoreCase)
            {
                { "00000409", Mapping("us") },
                { "00010409", Mapping("us", "dvorak") },
                { "00020409", Mapping("us", "intl") },
                { "00030409", Mapping("us", "dvorak-l") },
                { "00040409", Mapping("us", "dvorak-r") },
                { "00000809", Mapping("gb") },
                { "0000040C", Mapping("fr") },
                { "0000080C", Mapping("be") },
                { "00000C0C", Mapping("ca", "fr-legacy") },
                { "00001009", Mapping("ca") },
                { "00011009", Mapping("ca", "multix") },
                { "0000100C", Mapping("ch", "fr") },
                { "0000040A", Mapping("es", "winkeys") },
                { "0000080A", Mapping("latam") },
                { "00000411", Mapping("jp") }
            };

        private static readonly IReadOnlyDictionary<int, LinuxKeyboardConfiguration> LanguageFallbacks =
            new Dictionary<int, LinuxKeyboardConfiguration>
            {
                { 0x0409, Mapping("us") },
                { 0x0809, Mapping("gb") },
                { 0x040C, Mapping("fr") },
                { 0x080C, Mapping("be") },
                { 0x0C0C, Mapping("ca", "fr-legacy") },
                { 0x1009, Mapping("ca") },
                { 0x1109, Mapping("ca", "multix") },
                { 0x100C, Mapping("ch", "fr") },
                { 0x040A, Mapping("es", "winkeys") },
                { 0x080A, Mapping("latam") },
                { 0x0411, Mapping("jp") }
            };

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetKeyboardLayoutName(StringBuilder keyboardLayoutName);

        public static LinuxKeyboardConfiguration ResolveActive(string fallbackLayout)
        {
            try
            {
                var identifier = new StringBuilder(KeyboardLayoutNameLength);
                if (GetKeyboardLayoutName(identifier))
                    return ResolveIdentifier(identifier.ToString(), fallbackLayout);

                ApplicationLogger.Write(
                    "Windows did not expose an active keyboard identifier; using the UI-language fallback.");
            }
            catch (Exception error)
            {
                ApplicationLogger.Write(
                    $"Active Windows keyboard detection failed; using the UI-language fallback: {error.Message}");
            }

            return Fallback(fallbackLayout, string.Empty);
        }

        public static LinuxKeyboardConfiguration ResolveIdentifier(
            string windowsKeyboardIdentifier,
            string fallbackLayout)
        {
            string normalizedIdentifier = (windowsKeyboardIdentifier ?? string.Empty)
                .Trim()
                .ToUpperInvariant();

            if (ExactMappings.TryGetValue(normalizedIdentifier, out LinuxKeyboardConfiguration exact))
                return WithIdentifier(exact, normalizedIdentifier, false);

            // Windows can synthesize KLIDs for installed input methods. Their
            // low word still carries the language identifier, which preserves
            // the physical layout more accurately than the Libertix UI language.
            if (
                normalizedIdentifier.Length == 8 &&
                int.TryParse(
                    normalizedIdentifier.Substring(4),
                    NumberStyles.HexNumber,
                    CultureInfo.InvariantCulture,
                    out int languageIdentifier) &&
                LanguageFallbacks.TryGetValue(
                    languageIdentifier,
                    out LinuxKeyboardConfiguration languageFallback))
            {
                return WithIdentifier(languageFallback, normalizedIdentifier, true);
            }

            return Fallback(fallbackLayout, normalizedIdentifier);
        }

        private static LinuxKeyboardConfiguration Mapping(string layout, string variant = "")
        {
            return new LinuxKeyboardConfiguration(layout, variant, string.Empty, false);
        }

        private static LinuxKeyboardConfiguration WithIdentifier(
            LinuxKeyboardConfiguration mapping,
            string identifier,
            bool usedFallback)
        {
            return new LinuxKeyboardConfiguration(
                mapping.Layout,
                mapping.Variant,
                identifier,
                usedFallback);
        }

        private static LinuxKeyboardConfiguration Fallback(string fallbackLayout, string identifier)
        {
            string safeFallback = string.IsNullOrWhiteSpace(fallbackLayout) ? "us" : fallbackLayout;
            return new LinuxKeyboardConfiguration(safeFallback, string.Empty, identifier, true);
        }
    }
}
