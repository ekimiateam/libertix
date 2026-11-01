using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using Libertix.Helpers;

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
        private readonly Action<InstalledLinuxRecoveryCandidate> _uninstallLinux;
        private readonly InstalledLinuxRecoveryDetection _recoveryDetection;
        private bool _initialized;

        internal Welcome(
            string selectedLanguageCode,
            Action startInstallation,
            Action openAbout,
            Action<string> changeLanguage,
            InstalledLinuxRecoveryDetection recoveryDetection,
            Action<InstalledLinuxRecoveryCandidate> uninstallLinux)
        {
            _startInstallation = startInstallation ??
                throw new ArgumentNullException(nameof(startInstallation));
            _openAbout = openAbout ?? throw new ArgumentNullException(nameof(openAbout));
            _changeLanguage = changeLanguage ?? throw new ArgumentNullException(nameof(changeLanguage));
            _recoveryDetection = recoveryDetection ??
                throw new ArgumentNullException(nameof(recoveryDetection));
            _uninstallLinux = uninstallLinux ??
                throw new ArgumentNullException(nameof(uninstallLinux));

            InitializeComponent();
            PopulateLanguages();
            SelectLanguage(selectedLanguageCode);
            ConfigureInstalledLinuxPanel();
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
            if (UninstallButton.IsVisible)
                UninstallButton.Focus();
            else
                StartButton.Focus();
        }

        private void About_Click(object sender, RoutedEventArgs e)
        {
            _openAbout();
        }

        private void LanguageComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (_initialized && LanguageComboBox.SelectedItem is ComboBoxItem item)
            {
                _changeLanguage(item.Tag.ToString());
                ConfigureInstalledLinuxPanel();
            }
        }

        private void ConfigureInstalledLinuxPanel()
        {
            if (_recoveryDetection.Status == InstalledLinuxRecoveryStatus.None)
            {
                InstalledLinuxPanel.Visibility = Visibility.Collapsed;
                StartButton.Visibility = Visibility.Visible;
                StartButton.IsEnabled = true;
                return;
            }

            InstalledLinuxPanel.Visibility = Visibility.Visible;
            StartButton.Visibility = Visibility.Collapsed;
            StartButton.IsEnabled = false;
            if (_recoveryDetection.Status == InstalledLinuxRecoveryStatus.Available)
            {
                InstalledLinuxRecoveryCandidate candidate = _recoveryDetection.Candidate;
                InstalledLinuxText.Text = string.Format(
                    Localization.GetString(
                        candidate.RollbackInProgress
                            ? "UninstallLinuxResumeDescription"
                            : "UninstallLinuxDetectedDescription"),
                    candidate.DistributionName);
                UninstallButton.Content = Localization.GetString(
                    candidate.RollbackInProgress
                        ? "UninstallLinuxResumeButton"
                        : "UninstallLinuxButton");
                UninstallButton.Visibility = Visibility.Visible;
                return;
            }

            InstalledLinuxText.Text = Localization.GetString("UninstallLinuxBlockedDescription");
            UninstallButton.Visibility = Visibility.Collapsed;
        }

        private void Uninstall_Click(object sender, RoutedEventArgs e)
        {
            if (_recoveryDetection.Status == InstalledLinuxRecoveryStatus.Available)
                _uninstallLinux(_recoveryDetection.Candidate);
        }
    }
}
