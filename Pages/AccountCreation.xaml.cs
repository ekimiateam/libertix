using System;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using Libertix.Helpers;
using Libertix.Models;

namespace Libertix.Pages
{
    public partial class AccountCreation : Page
    {
        private const string STATE_KEY = "AccountCreation";
        private readonly Regex usernameRegex = new Regex("^[a-z][a-z0-9-]*$");
        private readonly Regex hostnameRegex = new Regex("^[a-z][a-z0-9-]*$");

        public AccountCreation()
        {
            InitializeComponent();
            UpdateDefaultValues();
            LoadState();
        }

        private void UpdateDefaultValues()
        {
            // Get current Windows username and convert to lowercase
            string windowsUsername = Environment.UserName.ToLower();
            
            // Remove any characters that don't match our regex
            string sanitizedUsername = Regex.Replace(windowsUsername, "[^a-z0-9-]", "");
            
            // Ensure it starts with a letter
            if (!string.IsNullOrEmpty(sanitizedUsername) && char.IsLetter(sanitizedUsername[0]))
            {
                UsernameBox.Text = sanitizedUsername;
            }
            
            // Set default hostname
            HostnameBox.Text = "linux-" + sanitizedUsername;
            
            // Validate the default values
            ValidateInput(null, null);
        }

        private void SaveState()
        {
            var state = new PageState
            {
                PageType = typeof(AccountCreation),
                StateKey = STATE_KEY,
                State = new AccountInfo
                {
                    Username = UsernameBox.Text,
                    Hostname = HostnameBox.Text
                    // Don't save password for security
                }
            };
            StateManager.SaveState(STATE_KEY, state);
        }

        private void LoadState()
        {
            var state = StateManager.GetState(STATE_KEY);
            if (state?.State is AccountInfo info)
            {
                UsernameBox.Text = info.Username;
                HostnameBox.Text = info.Hostname;
                ValidateInput(null, null);
            }
        }

        private void ValidateInput(object sender, RoutedEventArgs e)
        {
            bool isValid = true;
            
            // Validate username
            if (string.IsNullOrEmpty(UsernameBox.Text))
            {
                UsernameError.Text = "Username is required";
                isValid = false;
            }
            else if (!usernameRegex.IsMatch(UsernameBox.Text))
            {
                UsernameError.Text = "Username must start with a letter and contain only lowercase letters, numbers, or hyphens";
                isValid = false;
            }
            else
            {
                UsernameError.Text = "";
            }

            // Validate password
            if (string.IsNullOrEmpty(PasswordBox.Password))
            {
                PasswordError.Text = "Password is required";
                isValid = false;
            }
            else if (PasswordBox.Password.Length < 8)
            {
                PasswordError.Text = "Password must be at least 8 characters long";
                isValid = false;
            }
            else
            {
                PasswordError.Text = "";
            }

            // Validate hostname
            if (string.IsNullOrEmpty(HostnameBox.Text))
            {
                HostnameError.Text = "Computer name is required";
                isValid = false;
            }
            else if (!hostnameRegex.IsMatch(HostnameBox.Text))
            {
                HostnameError.Text = "Computer name must start with a letter and contain only lowercase letters, numbers, or hyphens";
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
                new ResizeDisk(),
                TimeSpan.FromSeconds(0.3),
                slideLeft: false);
        }

        private void NextButton_Click(object sender, RoutedEventArgs e)
        {
            var accountInfo = new AccountInfo
            {
                Username = UsernameBox.Text,
                Password = PasswordBox.Password,
                Hostname = HostnameBox.Text
            };
            
            App.Current.Properties["AccountInfo"] = accountInfo;
            SaveState();
            // Navigate to next page (Installation confirmation/summary)
            // NavigationHelper.NavigateWithAnimation(NavigationService, new InstallationSummary(), TimeSpan.FromSeconds(0.3));
        }
    }
}