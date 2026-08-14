using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;

namespace Libertix.Pages
{
    /// <summary>
    /// Provides localized entry actions without owning the installation workflow.
    /// </summary>
    public partial class Welcome : Page
    {
        private readonly Action _startInstallation;
        private readonly Action _openAbout;
        private readonly Action<string> _changeLanguage;
        private bool _initialized;

        public Welcome(
            string selectedLanguageCode,
            Action startInstallation,
            Action openAbout,
            Action<string> changeLanguage)
        {
            _startInstallation = startInstallation ??
                throw new ArgumentNullException(nameof(startInstallation));
            _openAbout = openAbout ?? throw new ArgumentNullException(nameof(openAbout));
            _changeLanguage = changeLanguage ?? throw new ArgumentNullException(nameof(changeLanguage));

            InitializeComponent();
            PopulateLanguages();
            SelectLanguage(selectedLanguageCode);
            _initialized = true;
        }

        private void PopulateLanguages()
        {
            Style itemStyle = (Style)FindResource("ModernComboBoxItem");
            foreach (KeyValuePair<string, string> language in Localization.GetAvailableLanguages())
            {
                LanguageComboBox.Items.Add(new ComboBoxItem
                {
                    Content = language.Value,
                    Tag = language.Key,
                    Style = itemStyle
                });
            }
        }

        private void SelectLanguage(string languageCode)
        {
            foreach (ComboBoxItem item in LanguageComboBox.Items)
            {
                if (string.Equals(
                    item.Tag as string,
                    languageCode,
                    StringComparison.OrdinalIgnoreCase))
                {
                    LanguageComboBox.SelectedItem = item;
                    return;
                }
            }

            LanguageComboBox.SelectedIndex = 0;
        }

        private void Start_Click(object sender, RoutedEventArgs e)
        {
            _startInstallation();
        }

        private void Welcome_Loaded(object sender, RoutedEventArgs e)
        {
            StartButton.Focus();
        }

        private void About_Click(object sender, RoutedEventArgs e)
        {
            _openAbout();
        }

        private void LanguageComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (_initialized && LanguageComboBox.SelectedItem is ComboBoxItem item)
                _changeLanguage(item.Tag.ToString());
        }
    }
}
