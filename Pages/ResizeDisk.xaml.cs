using System;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.IO;
using System.Globalization;
using System.Linq;
using Libertix.Helpers;
using Libertix.Installation;
using Libertix.Models;

namespace Libertix.Pages
{
    public partial class ResizeDisk : Page, INotifyPropertyChanged
    {
        private readonly InstallationState _installationState;
        private readonly double _totalSpace;
        private readonly double _initialFreeSpace;
        private readonly double _shrinkAvailableSpace;
        private double _selectedSize;
        private double _windowsUsedSpace;
        private double _windowsFreeSpace;
        private double _isoSize;
        private double _linuxSize;
        private bool _hasError;
        private double _recommendedSize;
        private string _manualSize;
        private string _sizeErrorMessage;
        private bool _hasSizeError;

        public event PropertyChangedEventHandler PropertyChanged;

        public double MinimumSize => InstallationSizePolicy.MinimumFinalSizeGiB;
        public double MinimumWindowsFree => InstallationSizePolicy.MinimumWindowsFreeSpaceGiB;
        private double AvailableLinuxSize => InstallationSizePolicy.AvailableLinuxSizeGiB(
            _initialFreeSpace,
            _shrinkAvailableSpace,
            IsoSize);
        // WPF rejects a slider whose maximum is lower than its minimum. The
        // separate CanAllocateLinux flag still prevents an invalid install.
        public double MaximumSize => Math.Max(MinimumSize, AvailableLinuxSize);
        public bool CanAllocateLinux => AvailableLinuxSize >= MinimumSize;

        public double WindowsTotalSpace => _windowsUsedSpace + _windowsFreeSpace;
        public GridLength WindowsPartitionPercentage => new GridLength(WindowsTotalSpace * 100 / _totalSpace, GridUnitType.Star);
        public GridLength LinuxPartitionPercentage => new GridLength(_linuxSize * 100 / _totalSpace, GridUnitType.Star);
        public GridLength WindowsUsedPercentage => new GridLength(_windowsUsedSpace, GridUnitType.Star);
        public GridLength WindowsFreeInPartitionPercentage => new GridLength(_windowsFreeSpace > 0 ? _windowsFreeSpace : 0.001, GridUnitType.Star);

        public double WindowsUsedSpace
        {
            get => _windowsUsedSpace;
            private set
            {
                _windowsUsedSpace = value;
                NotifyPropertyChanged(nameof(WindowsUsedSpace));
                NotifyPropertyChanged(nameof(WindowsUsedPercentage));
                NotifyPropertyChanged(nameof(SystemRequirements));
            }
        }

        public double WindowsFreeSpace
        {
            get => _windowsFreeSpace;
            private set
            {
                _windowsFreeSpace = value;
                NotifyPropertyChanged(nameof(WindowsFreeSpace));
                NotifyPropertyChanged(nameof(WindowsTotalSpace));
                NotifyPropertyChanged(nameof(WindowsPartitionPercentage));
                NotifyPropertyChanged(nameof(WindowsFreeInPartitionPercentage));
                NotifyPropertyChanged(nameof(SystemRequirements));
                NotifyPropertyChanged(nameof(AdditionalSpaceNeeded));
            }
        }

        public double IsoSize
        {
            get => _isoSize;
            private set
            {
                _isoSize = value;
                NotifyPropertyChanged(nameof(IsoSize));
                NotifyPropertyChanged(nameof(SystemRequirements));
            }
        }

        public double LinuxSize
        {
            get => _linuxSize;
            private set
            {
                _linuxSize = value;
                NotifyPropertyChanged(nameof(LinuxSize));
            }
        }

        public double SelectedSize
        {
            get => _selectedSize;
            set
            {
                if (_selectedSize != value)
                {
                    _selectedSize = value;
                    UpdatePartitionSizes(value);
                    ManualSize = value.ToString("F0", CultureInfo.InvariantCulture);
                    NotifyPropertyChanged(nameof(SelectedSize));
                }
            }
        }

        public double RecommendedSize
        {
            get => _recommendedSize;
            private set
            {
                _recommendedSize = value;
                NotifyPropertyChanged(nameof(RecommendedSize));
            }
        }

        public string ManualSize
        {
            get => _manualSize;
            set
            {
                _manualSize = value;
                ValidateAndUpdateSize(value);
                NotifyPropertyChanged(nameof(ManualSize));
            }
        }

        public string SizeErrorMessage
        {
            get => _sizeErrorMessage;
            set
            {
                _sizeErrorMessage = value;
                NotifyPropertyChanged(nameof(SizeErrorMessage));
            }
        }

        public bool HasSizeError
        {
            get => _hasSizeError;
            set
            {
                _hasSizeError = value;
                NotifyPropertyChanged(nameof(HasSizeError));
            }
        }

        private void UpdatePartitionSizes(double linuxSize)
        {
            LinuxSize = linuxSize;
            WindowsFreeSpace = InstallationSizePolicy.RemainingWindowsFreeSpaceGiB(
                _initialFreeSpace,
                IsoSize,
                linuxSize);

            // These bindings depend on calculated properties rather than stored
            // fields, so changing LinuxSize does not notify them automatically.
            NotifyPropertyChanged(nameof(WindowsTotalSpace));
            NotifyPropertyChanged(nameof(WindowsPartitionPercentage));
            NotifyPropertyChanged(nameof(LinuxPartitionPercentage));
            NotifyPropertyChanged(nameof(WindowsUsedPercentage));
            NotifyPropertyChanged(nameof(WindowsFreeInPartitionPercentage));

            CheckSpaceRequirements();
        }

        public bool HasError
        {
            get => _hasError;
            set
            {
                _hasError = value;
                NotifyPropertyChanged(nameof(HasError));
                NotifyPropertyChanged(nameof(AdditionalSpaceNeeded));
            }
        }

        public string SystemRequirements => string.Join(
            Environment.NewLine,
            string.Format(CultureInfo.CurrentCulture,
                Localization.GetString("ResizeDiskWindowsUsedSpace"), WindowsUsedSpace),
            string.Format(CultureInfo.CurrentCulture,
                Localization.GetString("ResizeDiskWindowsFreeSpace"), WindowsFreeSpace),
            string.Format(CultureInfo.CurrentCulture,
                Localization.GetString("ResizeDiskIsoSize"), IsoSize),
            string.Format(CultureInfo.CurrentCulture,
                Localization.GetString("ResizeDiskLinuxMinimum"), MinimumSize));

        public string AdditionalSpaceNeeded => HasError
            ? string.Format(
                CultureInfo.CurrentCulture,
                Localization.GetString("ResizeDiskAdditionalSpace"),
                Math.Max(0, MinimumSize - AvailableLinuxSize))
            : null;

        public ResizeDisk() : this(((App)Application.Current).InstallationState)
        {
        }

        public ResizeDisk(InstallationState installationState)
        {
            _installationState = installationState ?? throw new ArgumentNullException(nameof(installationState));
            InitializeComponent();
            DataContext = this;

            // Use the actual Windows system drive instead of relying on DriveInfo enumeration order.
            var systemRoot = Path.GetPathRoot(Environment.SystemDirectory);
            var systemDrive = DriveInfo.GetDrives()
                .FirstOrDefault(d => d.IsReady && string.Equals(d.Name, systemRoot, StringComparison.OrdinalIgnoreCase));
            if (systemDrive == null)
                throw new InvalidOperationException($"System drive not found: {systemRoot}");
            _totalSpace = systemDrive.TotalSize / 1024.0 / 1024.0 / 1024.0;
            WindowsUsedSpace =
                (systemDrive.TotalSize - systemDrive.AvailableFreeSpace) /
                1024.0 / 1024.0 / 1024.0;
            // Keep the exact byte-derived value for policy decisions. Rounding
            // up here can offer a Linux size that the storage layer must reject
            // later when the machine is close to the minimum Windows reserve.
            _initialFreeSpace =
                systemDrive.AvailableFreeSpace / 1024.0 / 1024.0 / 1024.0;
            _shrinkAvailableSpace = Math.Max(
                0,
                (_installationState.Compatibility?.ShrinkAvailableBytes ?? 0) /
                    1024d / 1024d / 1024d);
            WindowsFreeSpace = _initialFreeSpace;

            if (_installationState.SelectedDistro is Models.DistroInfo distro)
            {
                LoadState(distro);
            }

            ManualSize = RecommendedSize.ToString("F0", CultureInfo.InvariantCulture);
        }

        private void ResizeDisk_Loaded(object sender, RoutedEventArgs e)
        {
            if (PartitionSlider.IsEnabled)
                PartitionSlider.Focus();
            else
                NextButton.Focus();
        }

        private void ResizeDisk_PreviewKeyDown(object sender, KeyEventArgs e)
        {
            if (e.Key == Key.Home && Keyboard.Modifiers == ModifierKeys.Control)
            {
                if (PartitionSlider.IsEnabled)
                    PartitionSlider.Focus();
                else
                    NextButton.Focus();
                e.Handled = true;
            }
        }

        private void SaveState()
        {
            _installationState.SelectedLinuxSizeGiB = SelectedSize;
        }

        private void LoadState(DistroInfo distro)
        {
            IsoSize = distro.IsoInstallerSizeBytes /
                (double)InstallationSizePolicy.BytesPerGiB;
            RecommendedSize = CalculateRecommendedSize();

            if (_installationState.SelectedLinuxSizeGiB is double savedSize)
            {
                // A previously saved choice can become invalid after Windows
                // moves unmovable files or consumes disk space. Clamp it to the
                // current typed preflight result instead of displaying an
                // allocation that the storage layer will later reject.
                SelectedSize = Math.Min(savedSize, MaximumSize);
                ManualSize = SelectedSize.ToString("F0", CultureInfo.InvariantCulture);
            }
            else
            {
                SelectedSize = RecommendedSize;
                ManualSize = RecommendedSize.ToString("F0", CultureInfo.InvariantCulture);
            }
        }

        private double CalculateRecommendedSize()
        {
            if (!CanAllocateLinux)
                return MinimumSize;
            double recommendedSize = Math.Max(MinimumSize, _initialFreeSpace * 0.4);
            return Math.Min(Math.Min(recommendedSize, 100), AvailableLinuxSize);
        }

        private void CheckSpaceRequirements()
        {
            HasError = WindowsFreeSpace < MinimumWindowsFree || AvailableLinuxSize < MinimumSize;
        }

        private void ValidateAndUpdateSize(string value)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                HasSizeError = true;
                SizeErrorMessage = Localization.GetString("ResizeDiskSizeEmpty");
                return;
            }

            if (uint.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out uint parsed))
            {
                double size = parsed;
                if (size < MinimumSize)
                {
                    HasSizeError = true;
                    SizeErrorMessage = string.Format(CultureInfo.CurrentCulture, Localization.GetString("ResizeDiskSizeTooSmall"), MinimumSize);
                    return;
                }

                if (AvailableLinuxSize < MinimumSize)
                {
                    HasSizeError = true;
                    SizeErrorMessage = string.Format(CultureInfo.CurrentCulture, Localization.GetString("ResizeDiskNotEnoughSpace"), MinimumWindowsFree, MinimumSize);
                    return;
                }

                if (size > AvailableLinuxSize)
                {
                    HasSizeError = true;
                    SizeErrorMessage = string.Format(CultureInfo.CurrentCulture, Localization.GetString("ResizeDiskSizeTooLarge"), AvailableLinuxSize, MinimumWindowsFree);
                    return;
                }

                HasSizeError = false;
                SizeErrorMessage = string.Empty;
                SelectedSize = size;
            }
            else
            {
                HasSizeError = true;
                SizeErrorMessage = Localization.GetString("ResizeDiskInvalidNumber");
            }
        }

        private void NumberValidationTextBox(object sender, TextCompositionEventArgs e)
        {
            e.Handled = !IsTextAllowed(e.Text);
        }

        private static bool IsTextAllowed(string text)
        {
            return text.All(char.IsDigit);
        }

        private void ManualSize_Pasting(object sender, DataObjectPastingEventArgs e)
        {
            if (!e.SourceDataObject.GetDataPresent(DataFormats.UnicodeText, true))
            {
                e.CancelCommand();
                return;
            }

            string text = e.SourceDataObject.GetData(DataFormats.UnicodeText) as string;
            if (string.IsNullOrEmpty(text) || !text.All(char.IsDigit))
                e.CancelCommand();
        }

        private void NotifyPropertyChanged(string propertyName)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        }

        private void BackButton_Click(object sender, RoutedEventArgs e)
        {
            if (_installationState.SelectedDistro != null)
            {
                SaveState();
            }
            NavigationHelper.NavigateWithAnimation(
                NavigationService,
                new ChooseDistro(_installationState),
                TimeSpan.FromSeconds(0.3),
                slideLeft: false);
        }

        private void NextButton_Click(object sender, RoutedEventArgs e)
        {
            ValidateAndUpdateSize(ManualSize);
            if (HasError || HasSizeError)
            {
                MessageBox.Show(
                    SizeErrorMessage ?? Localization.GetString("ResizeDiskNoSpace"),
                    Localization.GetString("ResizeDiskErrorTitle"),
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
                return;
            }

            if (_installationState.SelectedDistro != null)
            {
                SaveState();
            }
            NavigationHelper.NavigateWithAnimation(
                NavigationService,
                new SharingOptionsPage(_installationState),
                TimeSpan.FromSeconds(0.3));
        }

    }
}
