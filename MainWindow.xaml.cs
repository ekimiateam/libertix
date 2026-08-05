using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
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
        private readonly object _welcomeContent;
        private bool _hiddenInTray;
        private bool _allowClose;

        public MainWindow()
        {
            _installationState = ((App)Application.Current).InstallationState;
            InitializeComponent();
            _welcomeContent = MainFrame.Content;
            _installationState.InstallationRunningChanged += InstallationState_InstallationRunningChanged;

            string windowsLang = Localization.GetWindowsLanguageCode();
            foreach (ComboBoxItem languageItem in LanguageComboBox.Items)
            {
                if (string.Equals(languageItem.Tag as string, windowsLang, StringComparison.OrdinalIgnoreCase))
                {
                    LanguageComboBox.SelectedItem = languageItem;
                    break;
                }
            }
            Localization.SetLanguage(windowsLang);
            _trayIcon = new TrayIconController(
                RestoreFromTray,
                ResourceText("TrayOpenLibertix", "Open Libertix"));

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
            return Application.Current.Resources[key] as string ?? fallback;
        }

        private void Button_Click(object sender, RoutedEventArgs e)
        {
            _installationState.SelectedDistro = null;
            _installationState.SelectedLinuxSizeGiB = null;
            _installationState.Account = null;
            NavigationHelper.NavigateWithAnimationInFrame(
                MainFrame,
                new CompatibilityCheck(_installationState),
                TimeSpan.FromSeconds(0.3));
        }

        private void AboutButton_Click(object sender, RoutedEventArgs e)
        {
            NavigationHelper.NavigateWithAnimationInFrame(
                MainFrame,
                new About(),
                TimeSpan.FromSeconds(0.3));
        }

        /// <summary>
        /// Restores the original welcome content after leaving an auxiliary page.
        /// The installation navigation stack is intentionally not involved.
        /// </summary>
        public void ReturnToWelcome()
        {
            // The welcome view is a XAML element rather than a Page. NavigationHelper
            // animates that element directly when About is opened, so its animation
            // clocks must be removed before the same instance is reused. Otherwise a
            // second navigation can leave the frame transparent after Get Started.
            if (_welcomeContent is UIElement welcomeElement)
            {
                welcomeElement.BeginAnimation(UIElement.OpacityProperty, null);
                welcomeElement.Opacity = 1.0;
            }

            if (_welcomeContent is FrameworkElement welcomeFrameworkElement)
            {
                welcomeFrameworkElement.BeginAnimation(FrameworkElement.MarginProperty, null);
                welcomeFrameworkElement.Margin = new Thickness(0);
            }

            // Return through the Frame journal when About was reached by navigation.
            // Assigning Frame.Content directly leaves NavigationService on the About
            // entry and the following animated navigation can render an empty frame.
            if (MainFrame.CanGoBack)
                MainFrame.GoBack();
            else
                MainFrame.Content = _welcomeContent;
        }

        private void LanguageComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (LanguageComboBox.SelectedItem is ComboBoxItem item)
            {
                string cultureName = item.Tag.ToString();
                Localization.SetLanguage(cultureName);
                _trayIcon?.SetOpenLabel(ResourceText("TrayOpenLibertix", "Open Libertix"));
            }
        }
    }
}
