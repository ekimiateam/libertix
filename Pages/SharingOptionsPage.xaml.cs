using System;
using System.Windows;
using System.Windows.Controls;
using Libertix.Helpers;
using Libertix.Models;

namespace Libertix.Pages
{
    public partial class SharingOptionsPage : Page
    {
        private readonly InstallationState _installationState;

        public SharingOptionsPage() : this(((App)Application.Current).InstallationState)
        {
        }

        public SharingOptionsPage(InstallationState installationState)
        {
            _installationState = installationState ?? throw new ArgumentNullException(nameof(installationState));
            InitializeComponent();
            SharingOptions options = _installationState.Sharing;
            WindowsToLinuxCheckBox.IsChecked = options.ShareWindowsFilesInLinux;
            LinuxToWindowsCheckBox.IsChecked = options.ShareLinuxFilesInWindows;
        }

        private void SaveOptions()
        {
            _installationState.Sharing = new SharingOptions
            {
                ShareWindowsFilesInLinux = WindowsToLinuxCheckBox.IsChecked == true,
                ShareLinuxFilesInWindows = LinuxToWindowsCheckBox.IsChecked == true
            };
        }

        private void BackButton_Click(object sender, RoutedEventArgs e)
        {
            SaveOptions();
            NavigationHelper.NavigateWithAnimation(
                NavigationService,
                new ResizeDisk(_installationState),
                TimeSpan.FromSeconds(0.3),
                slideLeft: false);
        }

        private void NextButton_Click(object sender, RoutedEventArgs e)
        {
            SaveOptions();
            NavigationHelper.NavigateWithAnimation(
                NavigationService,
                new AccountCreation(_installationState),
                TimeSpan.FromSeconds(0.3));
        }
    }
}
