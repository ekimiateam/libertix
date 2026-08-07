using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.Json;
using System.Windows;
using System.Xml.Linq;
using Libertix.Helpers;

namespace Libertix
{
    public static class Localization
    {
        public static event EventHandler LanguageChanged;

        public static string CurrentLanguage { get; private set; } = "en";

        private static readonly string[] AvailableLanguages = { "en", "fr", "es", "ja" };

        private static readonly Dictionary<string, string> LinuxLocales = new Dictionary<string, string>
        {
            { "en", "en_US.UTF-8" },
            { "fr", "fr_FR.UTF-8" },
            { "es", "es_ES.UTF-8" },
            { "ja", "ja_JP.UTF-8" }
        };

        private static readonly Dictionary<string, string> KeyboardLayouts = new Dictionary<string, string>
        {
            { "en", "us" },
            { "fr", "fr" },
            { "es", "es" },
            { "ja", "jp" }
        };

        private static readonly Lazy<IReadOnlyDictionary<string, string>> WindowsToIanaZones =
            new Lazy<IReadOnlyDictionary<string, string>>(LoadWindowsToIanaZones);

        public static void SetLanguage(string cultureName)
        {
            if (!AvailableLanguages.Contains(cultureName, StringComparer.OrdinalIgnoreCase))
                cultureName = "en";
            CurrentLanguage = cultureName;

            ResourceDictionary oldDict = null;
            foreach (ResourceDictionary dict in Application.Current.Resources.MergedDictionaries)
            {
                if (dict.Source != null && dict.Source.OriginalString.StartsWith("/Resources/Lang/Strings."))
                {
                    oldDict = dict;
                    break;
                }
            }

            if (oldDict != null)
            {
                Application.Current.Resources.MergedDictionaries.Remove(oldDict);
            }

            var newDict = new ResourceDictionary
            {
                Source = new Uri($"pack://application:,,,/Libertix;component/Resources/Lang/Strings.{cultureName}.xaml", UriKind.Absolute)
            };
            Application.Current.Resources.MergedDictionaries.Add(newDict);

            LanguageChanged?.Invoke(null, EventArgs.Empty);
        }

        /// <summary>
        /// Returns the supported application language matching the Windows UI language.
        /// </summary>
        public static string GetWindowsLanguageCode()
        {
            try
            {
                var culture = CultureInfo.CurrentUICulture;
                string twoLetterCode = culture.TwoLetterISOLanguageName.ToLower();

                foreach (var lang in AvailableLanguages)
                {
                    if (lang == twoLetterCode)
                        return lang;
                }

                return "en";
            }
            catch
            {
                return "en";
            }
        }

        public static string GetBootstrapString(string key)
        {
            string path = Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory,
                "Scripts",
                "config",
                "Libertix.CompatibilityMessages.json");
            try
            {
                using (JsonDocument document = JsonDocument.Parse(File.ReadAllText(path)))
                {
                    JsonElement section = document.RootElement.GetProperty("bootstrapMessages");
                    string language = GetWindowsLanguageCode();
                    if (!section.TryGetProperty(language, out JsonElement messages))
                        messages = section.GetProperty("en");
                    if (!messages.TryGetProperty(key, out JsonElement value))
                    {
                        if (language == "en" ||
                            !section.GetProperty("en").TryGetProperty(key, out value))
                            return "Libertix must be run as administrator.";
                    }
                    string message = value.GetString();
                    if (!string.IsNullOrWhiteSpace(message))
                        return message;
                }
            }
            catch (IOException)
            {
            }
            catch (JsonException)
            {
            }
            catch (InvalidOperationException)
            {
            }
            return "Libertix must be run as administrator.";
        }

        /// <summary>
        /// Converts the current Windows time-zone identifier to an IANA identifier.
        /// </summary>
        public static string GetWindowsTimezoneAsLinux()
        {
            try
            {
                if (WindowsToIanaZones.Value.TryGetValue(
                    TimeZoneInfo.Local.Id,
                    out string ianaZone))
                    return ianaZone;

                ApplicationLogger.Write(
                    $"No CLDR time-zone mapping for Windows ID '{TimeZoneInfo.Local.Id}'; using UTC.");
                return "UTC";
            }
            catch
            {
                return "UTC";
            }
        }

        private static IReadOnlyDictionary<string, string> LoadWindowsToIanaZones()
        {
            const string resourceName = "Libertix.Resources.windowsZones.xml";
            using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(resourceName))
            {
                if (stream == null)
                    throw new InvalidOperationException("The embedded CLDR time-zone map is missing.");

                return XDocument.Load(stream)
                    .Root
                    .Elements("mapZone")
                    .ToDictionary(
                        element => (string)element.Attribute("other"),
                        element => ((string)element.Attribute("type")).Split(' ')[0],
                        StringComparer.OrdinalIgnoreCase);
            }
        }

        /// <summary>
        /// Returns the Linux locale corresponding to the selected language.
        /// </summary>
        public static string GetLinuxLocale()
        {
            return LinuxLocales.TryGetValue(CurrentLanguage, out string locale) ? locale : "en_US.UTF-8";
        }

        /// <summary>
        /// Returns the Linux keyboard layout corresponding to the selected language.
        /// </summary>
        public static string GetKeyboardLayout()
        {
            return KeyboardLayouts.TryGetValue(CurrentLanguage, out string layout) ? layout : "us";
        }

        /// <summary>
        /// Resolve a localized string used by page code-behind.
        /// </summary>
        public static string GetString(string key)
        {
            return Application.Current.TryFindResource(key) as string ?? key;
        }

        /// <summary>
        /// Resolves a localized string and returns the supplied English text when the key is absent.
        /// </summary>
        public static string GetString(string key, string englishFallback)
        {
            return Application.Current.TryFindResource(key) as string ?? englishFallback;
        }
    }
}
