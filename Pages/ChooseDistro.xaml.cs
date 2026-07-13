using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Libertix.Helpers;
using Libertix.Models;
using Libertix.Pages;
using System.ComponentModel;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;
using System.Diagnostics;
using System.IO;
using System.Text.RegularExpressions;
using System.Runtime.InteropServices;

namespace Libertix
{
    public partial class ChooseDistro : Page, INotifyPropertyChanged
    {
        private readonly InstallationState _installationState;
        private const string STATE_KEY = "ChooseDistro";
        private ObservableCollection<DistroInfo> _distros;
        private DistroInfo _selectedDistro;
        private bool _isDistroSelected;
        private bool _partitionConfigValid = false;

        private enum FirmwareType
        {
            Unknown = 0,
            Bios = 1,
            Uefi = 2,
            Max = 3
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFirmwareType(out FirmwareType firmwareType);

        public bool IsDistroSelected
        {
            get => _isDistroSelected;
            set
            {
                _isDistroSelected = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsDistroSelected)));
            }
        }

        public event PropertyChangedEventHandler PropertyChanged;

        public ChooseDistro() : this(((App)Application.Current).InstallationState)
        {
        }

        public ChooseDistro(InstallationState installationState)
        {
            _installationState = installationState ?? throw new ArgumentNullException(nameof(installationState));
            InitializeComponent();
            _distros = new ObservableCollection<DistroInfo>();
            DataContext = this;
            IsDistroSelected = false;
            Loaded += ChooseDistro_Loaded;
        }

        private async void ChooseDistro_Loaded(object sender, RoutedEventArgs e)
        {
            Loaded -= ChooseDistro_Loaded;
            await LoadDistrosAsync();
            await CheckPartitionConfigurationAsync();
            LoadState();
        }

        private async Task LoadDistrosAsync()
        {
            try
            {
                using (var client = new HttpClient())
                {
                    client.Timeout = TimeSpan.FromSeconds(30);
                    var json = await client.GetStringAsync(FilepoolConfig.DistrosUrl);
                    var options = new JsonSerializerOptions
                    {
                        PropertyNameCaseInsensitive = true
                    };
                    var distroList = JsonSerializer.Deserialize<List<DistroInfoJson>>(json, options);
                    if (distroList == null || distroList.Count == 0)
                    {
                        throw new InvalidOperationException("Distribution list JSON is empty or invalid.");
                    }
                    
                    _distros.Clear();
                    foreach (var distroJson in distroList)
                    {
                        if (string.IsNullOrWhiteSpace(distroJson.Name) ||
                            string.IsNullOrWhiteSpace(distroJson.IsoUrl) ||
                            string.IsNullOrWhiteSpace(distroJson.IsoInstaller) ||
                            string.IsNullOrWhiteSpace(distroJson.IsoInstallerFileName) ||
                            !Regex.IsMatch(distroJson.IsoSha256 ?? "", "^[0-9a-fA-F]{64}$") ||
                            !Regex.IsMatch(distroJson.IsoInstallerSha256 ?? "", "^[0-9a-fA-F]{64}$") ||
                            distroJson.SizeInGB < 20)
                        {
                            throw new InvalidOperationException("Distribution manifest contains an invalid entry.");
                        }
                        _distros.Add(new DistroInfo
                        {
                            Name = distroJson.Name,
                            Description = distroJson.Description ?? "No description available",
                            ImageUrl = distroJson.ImageUrl,
                            IsoUrl = FilepoolConfig.ResolveUrl(distroJson.IsoUrl),
                            IsoInstaller = FilepoolConfig.ResolveUrl(distroJson.IsoInstaller),
                            IsoInstallerFileName = distroJson.IsoInstallerFileName,
                            IsoSha256 = distroJson.IsoSha256,
                            IsoInstallerSha256 = distroJson.IsoInstallerSha256,
                            SizeInGB = distroJson.SizeInGB
                        });
                    }
                }
                DistrosItemsControl.ItemsSource = _distros;
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    (Application.Current.Resources["DistroLoadError"] as string ?? "Failed to load distributions") +
                    Environment.NewLine + ex.Message,
                    "Error",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
            }
        }

        private void SaveState()
        {
            if (_selectedDistro != null)
            {
                var state = new PageState
                {
                    PageType = typeof(ChooseDistro),
                    StateKey = STATE_KEY,
                    State = _selectedDistro.Name // Save just the name of the selected distro
                };
                StateManager.SaveState(STATE_KEY, state);
            }
        }

        private void LoadState()
        {
            var state = StateManager.GetState(STATE_KEY);
            if (state?.State is string selectedDistroName)
            {
                // Find and select the previously selected distro
                foreach (var distro in _distros)
                {
                    if (distro.Name == selectedDistroName)
                    {
                        SelectDistro(distro);
                        break;
                    }
                }
            }
        }

        private void SelectDistro(DistroInfo distro)
        {
            // Deselect previous selection
            if (_selectedDistro != null)
            {
                _selectedDistro.IsSelected = false;
            }

            // Select new distro
            _selectedDistro = distro;
            _selectedDistro.IsSelected = true;

            // Update next button state (considers partition validation)
            UpdateNextButtonState();
        }

        private void Border_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
        {
            if (sender is FrameworkElement element && element.DataContext is DistroInfo distro)
            {
                if (_selectedDistro != distro)
                {
                    StateManager.ClearDependentStates("ResizeDisk");
                }
                SelectDistro(distro);
            }
        }

        private void NextButton_Click(object sender, RoutedEventArgs e)
        {
            if (_selectedDistro != null)
            {
                SaveState();
                _installationState.SelectedDistro = _selectedDistro;
                NavigationHelper.NavigateWithAnimation(
                    NavigationService,
                    new ResizeDisk(_installationState),
                    TimeSpan.FromSeconds(0.3));
            }
        }

        #region Partition Validation

        private async Task CheckPartitionConfigurationAsync()
        {
            var (isValid, warnings) = await ValidatePartitionLayoutAsync();

            _partitionConfigValid = isValid;

            if (!isValid)
            {
                string warningMessage = string.Join("\n", warnings);
                PartitionWarningText.Text = warningMessage;
                PartitionWarningPanel.Visibility = Visibility.Visible;
            }

            UpdateNextButtonState();
        }

        private void UpdateNextButtonState()
        {
            // Storage preflight failures are safety blockers, not warnings that
            // can be bypassed with a checkbox.
            bool canProceed = _selectedDistro != null && _partitionConfigValid;
            NextButton.IsEnabled = canProceed;
        }

        private async Task<(bool isValid, List<string> warnings)> ValidatePartitionLayoutAsync()
        {
            var warnings = new List<string>();
            try
            {
                if (!GetFirmwareType(out var firmwareType) ||
                    (firmwareType != FirmwareType.Bios && firmwareType != FirmwareType.Uefi))
                    throw new InvalidOperationException("Windows could not determine the firmware type.");

                string scriptPath = Path.Combine(
                    AppDomain.CurrentDomain.BaseDirectory,
                    "Scripts",
                    "libertix-storage-preflight.ps1");
                if (!File.Exists(scriptPath))
                    throw new FileNotFoundException("Storage preflight script is missing.", scriptPath);

                string expected = firmwareType == FirmwareType.Uefi ? "UEFI" : "BIOS";
                var result = await Task.Run(() => RunProcessWithTimeout(
                    "powershell.exe",
                    $"-NoProfile -ExecutionPolicy Bypass -File \"{scriptPath}\" -ExpectedFirmware {expected}",
                    120000));
                if (result.exitCode != 0 || !result.output.Contains("PREFLIGHT_OK=true"))
                    throw new InvalidOperationException(
                        $"Storage preflight failed: {result.error} {result.output}");

                return (true, warnings);
            }
            catch (Exception ex)
            {
                warnings.Add($"Error checking partitions: {ex.Message}");
                return (false, warnings);
            }
        }

        private static (int exitCode, string output, string error) RunProcessWithTimeout(
            string fileName,
            string arguments,
            int timeoutMilliseconds)
        {
            WindowsProcessResult result = WindowsProcessRunner.Run(
                fileName,
                arguments,
                TimeSpan.FromMilliseconds(timeoutMilliseconds));
            return (
                result.ExitCode,
                result.StandardOutput,
                result.TimedOut ? "Storage preflight timed out." : result.StandardError);
        }

        #endregion
    }
}
