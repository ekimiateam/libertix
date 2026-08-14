using System;
using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Controls;
using Libertix.Helpers;
using Libertix.Models;
using System.ComponentModel;
using System.Threading.Tasks;
using System.Windows.Input;
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
        private bool _isCatalogLoading;
        private bool _partitionConfigValid = false;
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
            DistrosListBox.ItemsSource = _distros;
            DataContext = this;
            IsDistroSelected = false;
            Loaded += ChooseDistro_Loaded;
        }

        private async void ChooseDistro_Loaded(object sender, RoutedEventArgs e)
        {
            Loaded -= ChooseDistro_Loaded;
            if (await LoadDistrosAsync())
            {
                DistrosListBox.Focus();
            }
            else
            {
                RetryCatalogButton.Focus();
            }
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

        private async Task<bool> LoadDistrosAsync()
        {
            if (_isCatalogLoading)
            {
                return false;
            }

            _isCatalogLoading = true;
            RetryCatalogButton.IsEnabled = false;
            CatalogErrorPanel.Visibility = Visibility.Collapsed;
            try
            {
                var validatedDistros = await DistributionCatalogLoader.LoadAsync(_filepool);
                string selectedDistroId = _selectedDistro?.Id ??
                    _installationState.SelectedDistro?.Id;
                var publishedDistros = new ObservableCollection<DistroInfo>(validatedDistros);

                ClearSelection();
                _distros = publishedDistros;
                DistrosListBox.ItemsSource = _distros;
                RestoreSelection(selectedDistroId);
                return true;
            }
            catch (Exception ex)
            {
                CatalogErrorDetailsText.Text = ex.Message;
                CatalogErrorPanel.Visibility = Visibility.Visible;
                return false;
            }
            finally
            {
                _isCatalogLoading = false;
                RetryCatalogButton.IsEnabled = true;
            }
        }

        private async void RetryCatalogButton_Click(object sender, RoutedEventArgs e)
        {
            if (await LoadDistrosAsync())
            {
                DistrosListBox.Focus();
            }
            else
            {
                RetryCatalogButton.Focus();
            }
        }

        private void RestoreSelection(string selectedDistroId)
        {
            if (!string.IsNullOrWhiteSpace(selectedDistroId))
            {
                foreach (DistroInfo distro in _distros)
                {
                    if (string.Equals(distro.Id, selectedDistroId, StringComparison.Ordinal))
                    {
                        SelectDistro(distro);
                        return;
                    }
                }
            }

            _installationState.SelectedDistro = null;
            _installationState.SelectedLinuxSizeGiB = null;
            UpdateNextButtonState();
        }

        private void ClearSelection()
        {
            if (_selectedDistro != null)
            {
                _selectedDistro.IsSelected = false;
            }
            _selectedDistro = null;
            DistrosListBox.SelectedItem = null;
            IsDistroSelected = false;
        }

        private void SelectDistro(DistroInfo distro)
        {
            if (_selectedDistro != null)
            {
                _selectedDistro.IsSelected = false;
            }

            _selectedDistro = distro;
            _selectedDistro.IsSelected = true;
            IsDistroSelected = true;
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
