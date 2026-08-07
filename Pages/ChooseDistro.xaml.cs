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
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Diagnostics;
using System.IO;
using System.Text.RegularExpressions;
using Libertix.Installation;

namespace Libertix.Pages
{
    public partial class ChooseDistro : Page, INotifyPropertyChanged
    {
        private readonly InstallationState _installationState;
        private readonly FilepoolConfig _filepool;
        private ObservableCollection<DistroInfo> _distros;
        private DistroInfo _selectedDistro;
        private bool _isDistroSelected;
        private bool _partitionConfigValid = false;
        private static readonly HttpClient SharedHttpClient = new HttpClient
        {
            Timeout = Timeout.InfiniteTimeSpan
        };

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

        public ChooseDistro() : this(
            ((App)Application.Current).InstallationState,
            ((App)Application.Current).Filepool)
        {
        }

        public ChooseDistro(InstallationState installationState)
            : this(installationState, ((App)Application.Current).Filepool)
        {
        }

        public ChooseDistro(InstallationState installationState, FilepoolConfig filepool)
        {
            _installationState = installationState ?? throw new ArgumentNullException(nameof(installationState));
            _filepool = filepool ?? throw new ArgumentNullException(nameof(filepool));
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
                using (var timeoutCancellation = new CancellationTokenSource(TimeSpan.FromSeconds(30)))
                using (var response = await SharedHttpClient.GetAsync(
                    _filepool.DistrosUrl,
                    timeoutCancellation.Token))
                {
                    response.EnsureSuccessStatusCode();
                    byte[] manifest = await response.Content.ReadAsByteArrayAsync();
                    if (_filepool.RequiresCatalogSignature)
                    {
                        using (var signatureResponse = await SharedHttpClient.GetAsync(
                            _filepool.DistrosSignatureUrl,
                            timeoutCancellation.Token))
                        {
                            signatureResponse.EnsureSuccessStatusCode();
                            string signature = await signatureResponse.Content.ReadAsStringAsync();
                            DistributionCatalogTrust.Verify(
                                manifest,
                                signature,
                                DistributionCatalogTrust.GetApplicationPublicKeyPath());
                        }
                    }

                    string json = Encoding.UTF8.GetString(manifest);
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
                            string.IsNullOrWhiteSpace(distroJson.UefiIsoUrl) ||
                            !Regex.IsMatch(distroJson.UefiIsoSha256 ?? "", "^[0-9a-fA-F]{64}$") ||
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
                            IsoUrl = _filepool.ResolveUrl(distroJson.IsoUrl),
                            IsoInstaller = _filepool.ResolveUrl(distroJson.IsoInstaller),
                            IsoInstallerFileName = distroJson.IsoInstallerFileName,
                            IsoSha256 = distroJson.IsoSha256,
                            UefiIsoUrl = _filepool.ResolveUrl(distroJson.UefiIsoUrl),
                            UefiIsoSha256 = distroJson.UefiIsoSha256,
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
                    Localization.GetString("DistroLoadError", "Failed to load distributions") +
                    Environment.NewLine + ex.Message,
                    Localization.GetString("ErrorTitle"),
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
            }
        }

        private void LoadState()
        {
            string selectedDistroName = _installationState.SelectedDistro?.Name;
            if (!string.IsNullOrWhiteSpace(selectedDistroName))
            {
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
            if (_selectedDistro != null)
            {
                _selectedDistro.IsSelected = false;
            }

            _selectedDistro = distro;
            _selectedDistro.IsSelected = true;
            UpdateNextButtonState();
        }

        private void Border_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
        {
            if (sender is FrameworkElement element && element.DataContext is DistroInfo distro)
            {
                if (_selectedDistro != distro)
                {
                    _installationState.SelectedLinuxSizeGiB = null;
                }
                SelectDistro(distro);
            }
        }

        private void NextButton_Click(object sender, RoutedEventArgs e)
        {
            if (_selectedDistro != null)
            {
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
                if (!FirmwareInterop.TryGetFirmwareType(out var firmwareType) ||
                    (firmwareType != FirmwareType.Bios && firmwareType != FirmwareType.Uefi))
                    throw new InvalidOperationException("Windows could not determine the firmware type.");

                string scriptPath = Path.Combine(
                    AppDomain.CurrentDomain.BaseDirectory,
                    "Scripts",
                    "libertix-storage-preflight.ps1");
                if (!File.Exists(scriptPath))
                    throw new FileNotFoundException("Storage preflight script is missing.", scriptPath);

                string expected = firmwareType == FirmwareType.Uefi ? "UEFI" : "BIOS";
                // Same resolution and timeout policy as the ApplyChanges preflight:
                // "powershell.exe" alone is subject to WOW64 redirection.
                var result = await Task.Run(() => RunProcessWithTimeout(
                    WindowsProcessRunner.ResolvePowerShell(),
                    $"-NoProfile -ExecutionPolicy Bypass -File {WindowsProcessRunner.QuoteArgument(scriptPath)} " +
                    $"-ExpectedFirmware {expected}",
                    (int)WindowsProcessTimeouts.DiskOperation.TotalMilliseconds));
                PowerShellJsonResult preflight = PowerShellJsonResult.ParseFinalObject(result.output);
                if (result.exitCode != 0 || !preflight.GetBoolean("preflightOk"))
                    throw new InvalidOperationException(
                        "Storage preflight failed: " +
                        preflight.GetOptionalString("errorMessage", result.error));

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
