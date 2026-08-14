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
                var validatedDistros = await DistributionCatalogLoader.LoadAsync(_filepool);
                _distros.Clear();
                foreach (DistroInfo distro in validatedDistros)
                {
                    _distros.Add(distro);
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
