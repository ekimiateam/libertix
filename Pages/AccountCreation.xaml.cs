using System;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Libertix.Helpers;
using Libertix.Models;

namespace Libertix.Pages
{
    public partial class AccountCreation : Page
    {
        private readonly InstallationState _installationState;
        private readonly Regex usernameRegex = new Regex("^[a-z](?:[a-z0-9-]{0,30}[a-z0-9])?$");
        private readonly Regex hostnameRegex = new Regex("^[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$");

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
            string windowsUsername = Environment.UserName.ToLower();
            string sanitizedUsername = Regex.Replace(windowsUsername, "[^a-z0-9-]", "");
            if (!string.IsNullOrEmpty(sanitizedUsername) && char.IsLetter(sanitizedUsername[0]))
            {
                UsernameBox.Text = sanitizedUsername;
            }

            string windowsHostname = Environment.MachineName.ToLower();
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
            else if (!usernameRegex.IsMatch(UsernameBox.Text) || UsernameBox.Text == "root")
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
                PasswordError.Text = Application.Current.Resources["PasswordRequired"] as string ?? "Password is required";
                isValid = false;
            }
            else if (PasswordBox.Password.Length < 8)
            {
                PasswordError.Text = Application.Current.Resources["PasswordTooShort"] as string ?? "Password must be at least 8 characters";
                isValid = false;
            }
            else if (PasswordBox.Password.Length > 128)
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
            else if (!hostnameRegex.IsMatch(HostnameBox.Text))
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

        private void PasswordBox_PreviewExecuted(object sender, ExecutedRoutedEventArgs e)
        {
            if (e.Command == ApplicationCommands.Paste ||
                e.Command == ApplicationCommands.Copy ||
                e.Command == ApplicationCommands.Cut)
            {
                e.Handled = true;
            }
        }
    }
}
