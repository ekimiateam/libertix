using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Controls;
using Libertix.Helpers;
using Libertix.Models;
using Libertix.Pages;
using System.ComponentModel;
using System.Net.Http;
using System.Text.Json;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Text.RegularExpressions;
using System.Windows.Input;
using Libertix.Installation;

namespace Libertix.Pages
{
    public partial class ChooseDistro : Page, INotifyPropertyChanged
    {
        private const long MaximumCatalogBytes = 1024 * 1024;
        private const long MaximumCatalogSignatureBytes = 16 * 1024;
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
            _partitionConfigValid = _installationState.Compatibility != null;
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
            LoadState();
            DistrosListBox.Focus();
        }

        private void ChooseDistro_PreviewKeyDown(object sender, KeyEventArgs e)
        {
            if (e.Key == Key.Enter &&
                Keyboard.Modifiers == ModifierKeys.None &&
                NextButton.IsEnabled)
            {
                NavigateToSelectedDistro();
                e.Handled = true;
                return;
            }

            if (Keyboard.Modifiers != ModifierKeys.Control || DistrosListBox.Items.Count == 0)
            {
                return;
            }

            int selectedIndex = DistrosListBox.SelectedIndex;
            if (e.Key == Key.Home)
            {
                selectedIndex = 0;
            }
            else if (e.Key == Key.Right)
            {
                selectedIndex = Math.Min(
                    Math.Max(selectedIndex, 0) + 1,
                    DistrosListBox.Items.Count - 1);
            }
            else if (e.Key == Key.Left)
            {
                selectedIndex = Math.Max(selectedIndex - 1, 0);
            }
            else
            {
                return;
            }

            DistrosListBox.Focus();
            DistrosListBox.SelectedIndex = selectedIndex;
            DistrosListBox.ScrollIntoView(DistrosListBox.SelectedItem);
            e.Handled = true;
        }

        private async Task LoadDistrosAsync()
        {
            try
            {
                using (var timeoutCancellation = new CancellationTokenSource(TimeSpan.FromSeconds(30)))
                using (var response = await SharedHttpClient.GetAsync(
                    _filepool.CatalogUrl,
                    timeoutCancellation.Token))
                {
                    response.EnsureSuccessStatusCode();
                    byte[] manifest = await BoundedHttpContent.ReadAsync(
                        response.Content,
                        MaximumCatalogBytes,
                        timeoutCancellation.Token);
                    if (_filepool.RequiresCatalogSignature)
                    {
                        using (var signatureResponse = await SharedHttpClient.GetAsync(
                            _filepool.CatalogSignatureUrl,
                            timeoutCancellation.Token))
                        {
                            signatureResponse.EnsureSuccessStatusCode();
                            byte[] signatureBytes = await BoundedHttpContent.ReadAsync(
                                signatureResponse.Content,
                                MaximumCatalogSignatureBytes,
                                timeoutCancellation.Token);
                            string signature = Encoding.UTF8.GetString(signatureBytes);
                            DistributionCatalogTrust.VerifyWithApplicationKey(
                                manifest,
                                signature);
                        }
                    }

                    string json = Encoding.UTF8.GetString(manifest);
                    var options = new JsonSerializerOptions
                    {
                        PropertyNameCaseInsensitive = true
                    };
                    var catalog = JsonSerializer.Deserialize<DistributionCatalogJson>(json, options);
                    if (catalog == null ||
                        catalog.SchemaVersion != 1 ||
                        catalog.Artifacts?.MiniIso == null ||
                        catalog.Artifacts.Support == null ||
                        catalog.Distributions == null ||
                        catalog.Distributions.Count == 0)
                    {
                        throw new InvalidOperationException("Distribution catalog JSON is empty or invalid.");
                    }

                    ValidateCatalogArtifact(catalog.Artifacts.Wpf, "Libertix-wpf.zip");
                    ValidateCatalogArtifact(
                        catalog.Artifacts.MiniIso.Bios,
                        "libertix-installer-bios.iso");
                    ValidateCatalogArtifact(
                        catalog.Artifacts.MiniIso.Uefi,
                        "libertix-installer-uefi.iso");
                    ValidateCatalogArtifact(catalog.Artifacts.Support.Aria2Archive, "aria2-64.zip");
                    ValidateCatalogArtifact(
                        catalog.Artifacts.Support.Ext4Driver,
                        "ext4-win-driver.exe");
                    ValidateCatalogArtifact(catalog.Artifacts.Support.Grub4DosLoader, "grldr");
                    ValidateCatalogArtifact(catalog.Artifacts.Support.Grub4DosMbr, "grldr.mbr");

                    CatalogArtifactJson biosMiniIso = catalog.Artifacts.MiniIso.Bios;
                    CatalogArtifactJson uefiMiniIso = catalog.Artifacts.MiniIso.Uefi;
                    var validatedDistros = new List<DistroInfo>(catalog.Distributions.Count);
                    var seenDistroIds = new HashSet<string>(StringComparer.Ordinal);
                    foreach (var distroJson in catalog.Distributions)
                    {
                        if (!Regex.IsMatch(distroJson.Id ?? "", "^[a-z0-9](?:[a-z0-9._-]{0,62}[a-z0-9])?$") ||
                            string.IsNullOrWhiteSpace(distroJson.Name) ||
                            !Regex.IsMatch(distroJson.OsReleaseId ?? "", "^[a-z0-9](?:[a-z0-9._-]{0,62}[a-z0-9])?$") ||
                            !Regex.IsMatch(distroJson.GrubDisplayName ?? "", "^[A-Za-z0-9][A-Za-z0-9 ._()+-]{0,79}$") ||
                            !Regex.IsMatch(distroJson.GrubIcon ?? "", "^[a-z0-9](?:[a-z0-9._-]{0,62}[a-z0-9])?$") ||
                            string.IsNullOrWhiteSpace(distroJson.IsoInstaller) ||
                            string.IsNullOrWhiteSpace(distroJson.IsoInstallerFileName) ||
                            !Regex.IsMatch(distroJson.IsoInstallerSha256 ?? "", "^[0-9a-fA-F]{64}$") ||
                            distroJson.IsoInstallerSizeBytes <= 0 ||
                            distroJson.SizeInGB < InstallationSizePolicy.MinimumFinalSizeGiB)
                        {
                            throw new InvalidOperationException("Distribution manifest contains an invalid entry.");
                        }
                        if (!seenDistroIds.Add(distroJson.Id))
                        {
                            throw new InvalidOperationException("Distribution manifest contains a duplicate id.");
                        }
                        validatedDistros.Add(new DistroInfo
                        {
                            Id = distroJson.Id,
                            Name = distroJson.Name,
                            OsReleaseId = distroJson.OsReleaseId,
                            GrubDisplayName = distroJson.GrubDisplayName,
                            GrubIcon = distroJson.GrubIcon,
                            Description = distroJson.Description ?? "No description available",
                            ImageUrl = distroJson.ImageUrl,
                            IsoUrl = _filepool.ResolveUrl(biosMiniIso.Url),
                            IsoInstaller = _filepool.ResolveUrl(distroJson.IsoInstaller),
                            IsoInstallerFileName = distroJson.IsoInstallerFileName,
                            IsoSha256 = biosMiniIso.Sha256,
                            UefiIsoUrl = _filepool.ResolveUrl(uefiMiniIso.Url),
                            UefiIsoSha256 = uefiMiniIso.Sha256,
                            IsoInstallerSha256 = distroJson.IsoInstallerSha256,
                            IsoInstallerSizeBytes = distroJson.IsoInstallerSizeBytes,
                            SizeInGB = distroJson.SizeInGB
                        });
                    }

                    _distros.Clear();
                    foreach (DistroInfo distro in validatedDistros)
                    {
                        _distros.Add(distro);
                    }
                }
                DistrosListBox.ItemsSource = _distros;
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

        private static void ValidateCatalogArtifact(
            CatalogArtifactJson artifact,
            string expectedFileName)
        {
            if (artifact == null ||
                !string.Equals(artifact.FileName, expectedFileName, StringComparison.Ordinal) ||
                string.IsNullOrWhiteSpace(artifact.Url) ||
                !Regex.IsMatch(artifact.Sha256 ?? "", "^[0-9a-fA-F]{64}$") ||
                artifact.SizeBytes <= 0)
            {
                throw new InvalidOperationException(
                    "Distribution catalog contains invalid artifact metadata.");
            }
        }

        private void LoadState()
        {
            string selectedDistroId = _installationState.SelectedDistro?.Id;
            if (!string.IsNullOrWhiteSpace(selectedDistroId))
            {
                foreach (var distro in _distros)
                {
                    if (distro.Id == selectedDistroId)
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
            if (!ReferenceEquals(DistrosListBox.SelectedItem, distro))
            {
                DistrosListBox.SelectedItem = distro;
            }
            UpdateNextButtonState();
        }

        private void DistrosListBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (DistrosListBox.SelectedItem is DistroInfo distro)
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
            NavigateToSelectedDistro();
        }

        private void NavigateToSelectedDistro()
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

        private void UpdateNextButtonState()
        {
            // Compatibility is completed on the preceding page and the full
            // storage preflight is repeated immediately before disk mutation.
            // Re-running PowerShell here made a visible selection appear frozen.
            bool canProceed = _selectedDistro != null && _partitionConfigValid;
            NextButton.IsEnabled = canProceed;
        }
    }
}
