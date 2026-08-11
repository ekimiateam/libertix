using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Libertix.Helpers;
using Libertix.Models;

namespace Libertix.Pages
{
    public partial class WarningConfirmation : Page
    {
        private readonly InstallationState _installationState;

        public WarningConfirmation() : this(((App)Application.Current).InstallationState)
        {
        }

        public WarningConfirmation(InstallationState installationState)
        {
            _installationState = installationState ?? throw new ArgumentNullException(nameof(installationState));
            InitializeComponent();
            HibernationNotice.Visibility = _installationState.Sharing.ShareWindowsFilesInLinux
                ? Visibility.Visible
                : Visibility.Collapsed;
        }

        private void ConfirmCheckBox_Changed(object sender, RoutedEventArgs e)
        {
            ConfirmButton.IsEnabled = ConfirmCheckBox.IsChecked == true;
        }

        private void WarningConfirmation_Loaded(object sender, RoutedEventArgs e)
        {
            ConfirmCheckBox.Focus();
        }

        private void WarningConfirmation_PreviewKeyDown(object sender, KeyEventArgs e)
        {
            if (e.Key == Key.Home && Keyboard.Modifiers == ModifierKeys.Control)
            {
                ConfirmCheckBox.Focus();
                e.Handled = true;
            }
        }

        private void BackButton_Click(object sender, RoutedEventArgs e)
        {
            _installationState.Account?.ClearPassword();
            NavigationHelper.NavigateWithAnimation(
                NavigationService,
                new AccountCreation(_installationState),
                TimeSpan.FromSeconds(0.3),
                slideLeft: false);
        }

        private void ConfirmButton_Click(object sender, RoutedEventArgs e)
        {
            NavigationHelper.NavigateWithAnimation(
                NavigationService,
                new ApplyChanges(_installationState),
                TimeSpan.FromSeconds(0.3));
        }
    }
}
