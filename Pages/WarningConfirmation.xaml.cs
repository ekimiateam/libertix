using System;
using System.Windows;
using System.Windows.Controls;
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
        }

        private void ConfirmCheckBox_Changed(object sender, RoutedEventArgs e)
        {
            ConfirmButton.IsEnabled = ConfirmCheckBox.IsChecked == true;
        }

        private void BackButton_Click(object sender, RoutedEventArgs e)
        {
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
