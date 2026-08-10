using System;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Libertix.Helpers;
using Libertix.Installation;
using Libertix.Models;

namespace Libertix.Pages
{
    public partial class AccountCreation : Page
    {
        private readonly InstallationState _installationState;
        public AccountCreation() : this(((App)Application.Current).InstallationState)
        {
        }

        public AccountCreation(InstallationState installationState)
        {
            _installationState = installationState ?? throw new ArgumentNullException(nameof(installationState));
            InitializeComponent();
            UpdateDefaultValues();
            LoadState();
        }

        private void UpdateDefaultValues()
        {
            string windowsUsername = Environment.UserName.ToLowerInvariant();
            string sanitizedUsername = Regex.Replace(windowsUsername, "[^a-z0-9-]", "");
            if (!string.IsNullOrEmpty(sanitizedUsername) && char.IsLetter(sanitizedUsername[0]))
            {
                UsernameBox.Text = sanitizedUsername;
            }

            string windowsHostname = Environment.MachineName.ToLowerInvariant();
            string sanitizedHostname = Regex.Replace(windowsHostname, "[^a-z0-9-]", "");
            if (!string.IsNullOrEmpty(sanitizedHostname) && char.IsLetter(sanitizedHostname[0]))
            {
                HostnameBox.Text = sanitizedHostname + "-linux";
            }
            else
            {
                HostnameBox.Text = "linux-pc";
            }
            ValidateInput(null, null);
        }

        private void SaveState()
        {
            _installationState.Account = new AccountInfo
            {
                Username = UsernameBox.Text,
                ComputerName = HostnameBox.Text
                // Passwords never survive backward navigation.
            };
        }

        private void AccountCreation_Loaded(object sender, RoutedEventArgs e)
        {
            UsernameBox.Focus();
            UsernameBox.SelectAll();
        }

        private void AccountCreation_PreviewKeyDown(object sender, KeyEventArgs e)
        {
            if (e.Key == Key.Home && Keyboard.Modifiers == ModifierKeys.Control)
            {
                UsernameBox.Focus();
                UsernameBox.SelectAll();
                e.Handled = true;
            }
        }

        private void LoadState()
        {
            if (_installationState.Account is AccountInfo info)
            {
                UsernameBox.Text = info.Username;
                HostnameBox.Text = info.ComputerName;
                ValidateInput(null, null);
            }
        }

        private void ValidateInput(object sender, RoutedEventArgs e)
        {
            bool isValid = true;

            if (string.IsNullOrEmpty(UsernameBox.Text))
            {
                UsernameError.Text = Localization.GetString("UsernameRequired");
                isValid = false;
            }
            else if (!AccountPolicy.IsValidUsername(UsernameBox.Text) || UsernameBox.Text == "root")
            {
                UsernameError.Text = Localization.GetString("UsernameInvalid");
                isValid = false;
            }
            else
            {
                UsernameError.Text = "";
            }

            if (string.IsNullOrEmpty(PasswordBox.Password))
            {
                PasswordError.Text = Localization.GetString("PasswordRequired", "Password is required");
                isValid = false;
            }
            else if (PasswordBox.Password.Length < AccountPolicy.MinimumPasswordLength)
            {
                PasswordError.Text = Localization.GetString(
                    "PasswordTooShort",
                    "Password must be at least 8 characters");
                isValid = false;
            }
            else if (PasswordBox.Password.Length > AccountPolicy.MaximumPasswordLength)
            {
                PasswordError.Text = Localization.GetString("PasswordTooLong");
                isValid = false;
            }
            else
            {
                PasswordError.Text = "";
            }

            if (string.IsNullOrEmpty(ConfirmPasswordBox.Password))
            {
                ConfirmPasswordError.Text = Localization.GetString("ConfirmPasswordRequired");
                isValid = false;
            }
            else if (PasswordBox.Password != ConfirmPasswordBox.Password)
            {
                ConfirmPasswordError.Text = Localization.GetString("PasswordsDoNotMatch");
                isValid = false;
            }
            else
            {
                ConfirmPasswordError.Text = "";
            }

            if (string.IsNullOrEmpty(HostnameBox.Text))
            {
                HostnameError.Text = Localization.GetString("ComputerNameRequired");
                isValid = false;
            }
            else if (!AccountPolicy.IsValidComputerName(HostnameBox.Text))
            {
                HostnameError.Text = Localization.GetString("ComputerNameInvalid");
                isValid = false;
            }
            else
            {
                HostnameError.Text = "";
            }

            NextButton.IsEnabled = isValid;
        }

        private void BackButton_Click(object sender, RoutedEventArgs e)
        {
            SaveState();
            NavigationHelper.NavigateWithAnimation(
                NavigationService,
                new SharingOptionsPage(_installationState),
                TimeSpan.FromSeconds(0.3),
                slideLeft: false);
        }

        private void NextButton_Click(object sender, RoutedEventArgs e)
        {
            var accountInfo = new AccountInfo
            {
                Username = UsernameBox.Text,
                Password = PasswordBox.Password,
                ComputerName = HostnameBox.Text
            };

            _installationState.Account = accountInfo;
            NavigationHelper.NavigateWithAnimation(
                NavigationService,
                new WarningConfirmation(_installationState),
                TimeSpan.FromSeconds(0.3));
        }

    }
}
