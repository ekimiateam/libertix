using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Navigation;
using Libertix.Helpers;
using Libertix.Pages;
using Libertix.Models;

namespace Libertix
{
    public partial class MainWindow : Window
    {
        private readonly InstallationState _installationState;
        private readonly TrayIconController _trayIcon;
        private bool _hiddenInTray;
        private bool _allowClose;

        public MainWindow()
        {
            _installationState = ((App)Application.Current).InstallationState;
            InitializeComponent();
            _trayIcon = new TrayIconController(RestoreFromTray);
            _installationState.InstallationRunningChanged += InstallationState_InstallationRunningChanged;

            // Detect Windows language and set as default
            string windowsLang = Localization.GetWindowsLanguageCode();
            int langIndex = 0; // Default to English

            switch (windowsLang)
            {
                case "en": langIndex = 0; break;
                case "fr": langIndex = 1; break;
                case "es": langIndex = 2; break;
                case "ja": langIndex = 3; break;
            }

            LanguageComboBox.SelectedIndex = langIndex;
            Localization.SetLanguage(windowsLang);

            if (_installationState.UefiRecoveryStatePath is string recoveryStatePath &&
                !string.IsNullOrWhiteSpace(recoveryStatePath))
            {
                Dispatcher.BeginInvoke(new Action(() =>
                    NavigationHelper.NavigateWithAnimationInFrame(
                        MainFrame,
                        new UefiBootFallback(_installationState),
                        TimeSpan.Zero)));
            }

/*#if DEBUG
            DebugPanel.Visibility = Visibility.Visible;
#endif*/
        }

        protected override void OnClosing(CancelEventArgs e)
        {
            if (_allowClose)
            {
                base.OnClosing(e);
                return;
            }

            if (_installationState.IsInstallationRunning)
            {
                e.Cancel = true;
                HideInTrayDuringInstallation();
                return;
            }

            var result = MessageBox.Show(
                ResourceText("CloseConfirmationMessage", "Voulez-vous vraiment fermer Libertix ?"),
                ResourceText("CloseConfirmationTitle", "Fermer Libertix"),
                MessageBoxButton.YesNo,
                MessageBoxImage.Question);
            if (result != MessageBoxResult.Yes)
            {
                e.Cancel = true;
                return;
            }

            _allowClose = true;
            base.OnClosing(e);
        }

        protected override void OnClosed(EventArgs e)
        {
            _installationState.InstallationRunningChanged -= InstallationState_InstallationRunningChanged;
            _trayIcon.Dispose();
            base.OnClosed(e);
        }

        public void PrepareForSystemRestart()
        {
            _allowClose = true;
        }

        private void HideInTrayDuringInstallation()
        {
            _hiddenInTray = true;
            Hide();
            _trayIcon.Show(
                ResourceText("TrayInstallTitle", "Installation Libertix en cours"),
                ResourceText(
                    "TrayInstallMessage",
                    "L'installation continue en arrière-plan. Double-cliquez sur l'icône Libertix près de l'horloge pour rouvrir la fenêtre."));
        }

        private void RestoreFromTray()
        {
            Dispatcher.BeginInvoke(new Action(() =>
            {
                _hiddenInTray = false;
                _trayIcon.Hide();
                Show();
                WindowState = WindowState.Normal;
                Activate();
                Topmost = true;
                Topmost = false;
                Focus();
            }));
        }

        private void InstallationState_InstallationRunningChanged(object sender, EventArgs e)
        {
            if (!_installationState.IsInstallationRunning && _hiddenInTray)
                RestoreFromTray();
        }

        private static string ResourceText(string key, string fallback)
        {
            return Application.Current.Resources[key] as string ?? fallback;
        }

        private void Button_Click(object sender, RoutedEventArgs e)
        {
            StateManager.ClearState("ChooseDistro"); // Clear state when starting fresh
            NavigationHelper.NavigateWithAnimationInFrame(
                MainFrame,
                new CompatibilityCheck(_installationState),
                TimeSpan.FromSeconds(0.3));
        }

        private void LanguageComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (LanguageComboBox.SelectedItem is ComboBoxItem item)
            {
                string cultureName = item.Tag.ToString();
                Localization.SetLanguage(cultureName);
            }
        }

        private void LanguageSelector_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (sender is ComboBox combo && combo.SelectedItem is ComboBoxItem item)
            {
                string lang = (string)item.Tag;
                Localization.SetLanguage(lang);
            }
        }

        private void DebugPageComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (DebugPageComboBox.SelectedItem is ComboBoxItem item)
            {
                string pageName = item.Tag.ToString();
                Page targetPage = null;

                switch (pageName)
                {
                    case "ChooseDistro":
                        targetPage = new ChooseDistro(_installationState);
                        break;
                    case "ResizeDisk":
                        targetPage = new ResizeDisk(_installationState);
                        break;
                    case "AccountCreation":
                        targetPage = new AccountCreation(_installationState);
                        break;
                    case "WarningConfirmation":
                        targetPage = new WarningConfirmation(_installationState);
                        break;
                    case "ApplyChanges":
                        targetPage = new ApplyChanges(_installationState);
                        break;
                }

                if (targetPage != null)
                {
                    NavigationHelper.NavigateWithAnimationInFrame(
                        MainFrame,
                        targetPage,
                        TimeSpan.FromSeconds(0.3));
                }
            }
        }
    }
}
