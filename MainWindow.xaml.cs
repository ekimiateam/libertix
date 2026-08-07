using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Navigation;
using Libertix.Helpers;
using Libertix.Dialogs;
using Libertix.Pages;
using Libertix.Models;

namespace Libertix
{
    public partial class MainWindow : Window
    {
        private readonly InstallationState _installationState;
        private readonly TrayIconController _trayIcon;
        private string _selectedLanguageCode;
        private bool _hiddenInTray;
        private bool _allowClose;

        public MainWindow()
        {
            _installationState = ((App)Application.Current).InstallationState;
            InitializeComponent();
            _installationState.InstallationRunningChanged += InstallationState_InstallationRunningChanged;

            string windowsLang = Localization.GetWindowsLanguageCode();
            Localization.SetLanguage(windowsLang);
            _selectedLanguageCode = windowsLang;
            _trayIcon = new TrayIconController(
                RestoreFromTray,
                ResourceText("TrayOpenLibertix", "Open Libertix"));
            MainFrame.Content = CreateWelcomePage();

            if (_installationState.UefiRecoveryStatePath is string recoveryStatePath &&
                !string.IsNullOrWhiteSpace(recoveryStatePath))
            {
                Dispatcher.BeginInvoke(new Action(() =>
                    NavigationHelper.NavigateWithAnimationInFrame(
                        MainFrame,
                        new UefiBootFallback(_installationState),
                        TimeSpan.Zero)));
            }

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

            e.Cancel = true;
            bool confirmed = LocalizedConfirmationDialog.Show(
                this,
                ResourceText("CloseConfirmationTitle", "Close Libertix"),
                ResourceText("CloseConfirmationMessage", "Do you really want to close Libertix?"),
                ResourceText("ConfirmationYes", "Yes"),
                ResourceText("ConfirmationNo", "No"));
            if (!confirmed)
            {
                return;
            }

            _allowClose = true;
            e.Cancel = false;
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
                ResourceText("TrayInstallTitle", "Libertix installation in progress"),
                ResourceText(
                    "TrayInstallMessage",
                    "The installation is still running. Double-click the Libertix icon near the clock to reopen the window."));
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
            return Localization.GetString(key, fallback);
        }

        private void StartInstallation()
        {
            _installationState.SelectedDistro = null;
            _installationState.SelectedLinuxSizeGiB = null;
            _installationState.Account = null;
            NavigationHelper.NavigateWithAnimationInFrame(
                MainFrame,
                new CompatibilityCheck(_installationState),
                TimeSpan.FromSeconds(0.3));
        }

        private void OpenAbout()
        {
            NavigationHelper.NavigateWithAnimationInFrame(
                MainFrame,
                new About(),
                TimeSpan.FromSeconds(0.3));
        }

        /// <summary>Restores a fresh welcome page outside the installation journal.</summary>
        public void ReturnToWelcome()
        {
            NavigationService navigation = MainFrame.NavigationService;
            NavigatedEventHandler navigated = null;
            navigated = (sender, args) =>
            {
                navigation.Navigated -= navigated;

                // Auxiliary pages must not become part of the installation journal.
                // Clear About only after the fresh welcome page has become current.
                while (navigation.RemoveBackEntry() != null)
                {
                }
            };

            navigation.Navigated += navigated;
            NavigationHelper.NavigateWithAnimationInFrame(
                MainFrame,
                CreateWelcomePage(),
                TimeSpan.FromSeconds(0.3),
                slideLeft: false);
        }

        private Welcome CreateWelcomePage()
        {
            return new Welcome(
                _selectedLanguageCode,
                StartInstallation,
                OpenAbout,
                ChangeLanguage);
        }

        private void ChangeLanguage(string cultureName)
        {
            _selectedLanguageCode = cultureName;
            Localization.SetLanguage(cultureName);
            _trayIcon?.SetOpenLabel(ResourceText("TrayOpenLibertix", "Open Libertix"));
        }
    }
}
