using System;
using System.Windows;

namespace Libertix
{
    public static class Localization
    {
        public static event EventHandler LanguageChanged;

        public static void SetLanguage(string cultureName)
        {
            // Find and remove the current language dictionary (if it exists)
            ResourceDictionary oldDict = null;
            foreach (ResourceDictionary dict in Application.Current.Resources.MergedDictionaries)
            {
                if (dict.Source != null && dict.Source.OriginalString.StartsWith("/Resources/Strings."))
                {
                    oldDict = dict;
                    break;
                }
            }

            if (oldDict != null)
            {
                Application.Current.Resources.MergedDictionaries.Remove(oldDict);
            }

            // Add the new language dictionary
            var newDict = new ResourceDictionary
            {
                Source = new Uri($"pack://application:,,,/Libertix;component/Resources/Strings.{cultureName}.xaml", UriKind.Absolute)
            };
            Application.Current.Resources.MergedDictionaries.Add(newDict);

            LanguageChanged?.Invoke(null, EventArgs.Empty);
        }
    }
}
