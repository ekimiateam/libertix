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

        private static readonly Lazy<TranslationCatalog> Translations =
            new Lazy<TranslationCatalog>(LoadTranslations);

        private static ResourceDictionary _languageDictionary;

        private static readonly Lazy<IReadOnlyDictionary<string, string>> WindowsToIanaZones =
            new Lazy<IReadOnlyDictionary<string, string>>(LoadWindowsToIanaZones);

        public static void SetLanguage(string cultureName)
        {
            cultureName = Translations.Value.SupportedLanguages.FirstOrDefault(
                language => string.Equals(
                    language,
                    cultureName,
                    StringComparison.OrdinalIgnoreCase)) ?? "en";
            CurrentLanguage = cultureName;

            if (_languageDictionary != null)
                Application.Current.Resources.MergedDictionaries.Remove(_languageDictionary);

            TranslationLanguage english = Translations.Value.Languages["en"];
            TranslationLanguage selected = Translations.Value.Languages[cultureName];
            var dictionary = new ResourceDictionary();
            foreach (KeyValuePair<string, string> entry in english.Wpf)
            {
                dictionary[entry.Key] = selected.Wpf.TryGetValue(
                    entry.Key,
                    out string value)
                    ? value
                    : entry.Value;
            }
            _languageDictionary = dictionary;
            Application.Current.Resources.MergedDictionaries.Add(dictionary);

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
                string twoLetterCode = culture.TwoLetterISOLanguageName.ToLowerInvariant();

                foreach (string lang in Translations.Value.SupportedLanguages)
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

        public static string GetBootstrapString(string key, string fallback)
        {
            try
            {
                string language = GetWindowsLanguageCode();
                TranslationLanguage selected = Translations.Value.Languages[language];
                TranslationLanguage english = Translations.Value.Languages["en"];
                if (!selected.Compatibility.BootstrapMessages.TryGetValue(key, out string message))
                    english.Compatibility.BootstrapMessages.TryGetValue(key, out message);
                if (!string.IsNullOrWhiteSpace(message))
                    return message;
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
            catch (KeyNotFoundException)
            {
            }
            catch (JsonException)
            {
            }
            catch (InvalidOperationException)
            {
            }
            return fallback;
        }

        /// <summary>
        /// Converts the current Windows time-zone identifier to an IANA identifier.
        /// </summary>
        public static string GetWindowsTimezoneAsLinux()
        {
            try
            {
                return ResolveWindowsTimezoneAsLinux(
                    TimeZoneInfo.Local.Id,
                    WindowsToIanaZones.Value);
            }
            catch
            {
                return "Etc/UTC";
            }
        }

        internal static string ResolveWindowsTimezoneAsLinux(
            string windowsTimezoneId,
            IReadOnlyDictionary<string, string> mappings)
        {
            if (!string.IsNullOrWhiteSpace(windowsTimezoneId) &&
                mappings != null &&
                mappings.TryGetValue(windowsTimezoneId, out string ianaZone) &&
                !string.IsNullOrWhiteSpace(ianaZone))
            {
                return ianaZone;
            }

            ApplicationLogger.Write(
                $"No CLDR time-zone mapping for Windows ID '{windowsTimezoneId}'; using Etc/UTC.");
            return "Etc/UTC";
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
            return GetCurrentLanguage().LinuxLocale;
        }

        /// <summary>
        /// Returns the Linux keyboard layout corresponding to the selected language.
        /// </summary>
        public static string GetKeyboardLayout()
        {
            return GetCurrentLanguage().KeyboardLayout;
        }

        public static IReadOnlyList<KeyValuePair<string, string>> GetAvailableLanguages()
        {
            return Translations.Value.SupportedLanguages
                .Select(language => new KeyValuePair<string, string>(
                    language,
                    Translations.Value.Languages[language].DisplayName))
                .ToList();
        }

        public static bool IsLanguageSupported(string language)
        {
            return Translations.Value.SupportedLanguages.Any(candidate =>
                string.Equals(candidate, language, StringComparison.Ordinal));
        }

        public static string GetSupportedLanguageList()
        {
            return string.Join(", ", Translations.Value.SupportedLanguages);
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

        private static TranslationLanguage GetCurrentLanguage()
        {
            return Translations.Value.Languages.TryGetValue(
                CurrentLanguage,
                out TranslationLanguage language)
                ? language
                : Translations.Value.Languages["en"];
        }

        private static TranslationCatalog LoadTranslations()
        {
            string path = Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory,
                "Resources",
                "Libertix.Translations.json");
            var options = new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true
            };
            TranslationCatalog catalogue = JsonSerializer.Deserialize<TranslationCatalog>(
                File.ReadAllText(path),
                options);
            if (catalogue?.SupportedLanguages == null ||
                catalogue.Languages == null ||
                catalogue.SupportedLanguages.Count == 0 ||
                !catalogue.Languages.ContainsKey("en"))
            {
                throw new InvalidOperationException(
                    "The Libertix translation catalogue is incomplete.");
            }

            foreach (string language in catalogue.SupportedLanguages)
            {
                if (!catalogue.Languages.TryGetValue(
                        language,
                        out TranslationLanguage values) ||
                    string.IsNullOrWhiteSpace(values.DisplayName) ||
                    string.IsNullOrWhiteSpace(values.LinuxLocale) ||
                    string.IsNullOrWhiteSpace(values.KeyboardLayout) ||
                    values.Wpf == null ||
                    values.Compatibility?.BootstrapMessages == null)
                {
                    throw new InvalidOperationException(
                        $"The Libertix translation catalogue is incomplete for '{language}'.");
                }
            }
            return catalogue;
        }

        private sealed class TranslationCatalog
        {
            public List<string> SupportedLanguages { get; set; }

            public Dictionary<string, TranslationLanguage> Languages { get; set; }
        }

        private sealed class TranslationLanguage
        {
            public string DisplayName { get; set; }

            public string LinuxLocale { get; set; }

            public string KeyboardLayout { get; set; }

            public Dictionary<string, string> Wpf { get; set; }

            public CompatibilityTranslations Compatibility { get; set; }
        }

        private sealed class CompatibilityTranslations
        {
            public Dictionary<string, string> BootstrapMessages { get; set; }
        }
    }
}
