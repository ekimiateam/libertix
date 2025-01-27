using System;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media.Animation;
using System.IO;
using System.Diagnostics;
using Libertix.Commands;

namespace Libertix.Pages
{
    public partial class ResizeDisk : Page, INotifyPropertyChanged
    {
        private readonly double _totalSpace;
        private readonly double _initialFreeSpace;
        private double _selectedSize;
        private double _windowsUsedSpace;
        private double _windowsFreeSpace;
        private double _isoSize;
        private double _linuxSize;
        private bool _hasError;

        public event PropertyChangedEventHandler PropertyChanged;

        public double MinimumSize => 30; // Minimum 30GB for Linux
        public double MaximumSize => _initialFreeSpace;

        // These are now calculated as percentages of total disk space
        public GridLength WindowsUsedPercentage => new GridLength(_windowsUsedSpace * 100 / _totalSpace, GridUnitType.Star);
        public GridLength WindowsFreePercentage => new GridLength(_windowsFreeSpace * 100 / _totalSpace, GridUnitType.Star);
        public GridLength IsoPartitionPercentage => new GridLength(_isoSize * 100 / _totalSpace, GridUnitType.Star);
        public GridLength LinuxPartitionPercentage => new GridLength(_linuxSize * 100 / _totalSpace, GridUnitType.Star);

        public double WindowsUsedSpace
        {
            get => _windowsUsedSpace;
            private set
            {
                _windowsUsedSpace = value;
                NotifyPropertyChanged(nameof(WindowsUsedSpace));
                NotifyPropertyChanged(nameof(WindowsUsedPercentage));
            }
        }

        public double WindowsFreeSpace
        {
            get => _windowsFreeSpace;
            private set
            {
                _windowsFreeSpace = value;
                NotifyPropertyChanged(nameof(WindowsFreeSpace));
                NotifyPropertyChanged(nameof(WindowsFreePercentage));
            }
        }

        public double IsoSize
        {
            get => _isoSize;
            private set
            {
                _isoSize = value;
                NotifyPropertyChanged(nameof(IsoSize));
                NotifyPropertyChanged(nameof(IsoPartitionPercentage));
            }
        }

        public double LinuxSize
        {
            get => _linuxSize;
            private set
            {
                _linuxSize = value;
                NotifyPropertyChanged(nameof(LinuxSize));
                NotifyPropertyChanged(nameof(LinuxPartitionPercentage));
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
                    NotifyPropertyChanged(nameof(SelectedSize));
                }
            }
        }

        private void UpdatePartitionSizes(double linuxSize)
        {
            LinuxSize = linuxSize;
            WindowsFreeSpace = _initialFreeSpace - linuxSize;
            CheckSpaceRequirements();
        }

        public bool HasError
        {
            get => _hasError;
            set
            {
                _hasError = value;
                NotifyPropertyChanged(nameof(HasError));
            }
        }

        public string SystemRequirements => 
            $"Windows Used Space: {WindowsUsedSpace:N1} GB\n" +
            $"Windows Free Space: {WindowsFreeSpace:N1} GB\n" +
            $"ISO Partition: {IsoSize:N1} GB\n" +
            $"Required Linux Space: {MinimumSize:N1} GB";

        public string AdditionalSpaceNeeded => HasError ? 
            $"Additional space needed: {(MinimumSize - WindowsFreeSpace):N1} GB" : null;

        public ICommand OpenDiskCleanupCommand => new RelayCommand(_ => Process.Start("cleanmgr.exe"));

        public ResizeDisk()
        {
            InitializeComponent();
            DataContext = this;

            // Get system drive info
            var systemDrive = DriveInfo.GetDrives()[0];
            _totalSpace = Math.Round(systemDrive.TotalSize / 1024.0 / 1024.0 / 1024.0);
            WindowsUsedSpace = Math.Round((systemDrive.TotalSize - systemDrive.AvailableFreeSpace) / 1024.0 / 1024.0 / 1024.0);
            _initialFreeSpace = Math.Round(systemDrive.AvailableFreeSpace / 1024.0 / 1024.0 / 1024.0);
            WindowsFreeSpace = _initialFreeSpace;

            if (App.Current.Properties["SelectedDistro"] is Models.DistroInfo distro)
            {
                IsoSize = distro.SizeInGB;
            }

            // Set initial Linux partition size
            SelectedSize = MinimumSize;
        }

        private void CheckSpaceRequirements()
        {
            HasError = WindowsFreeSpace < 0 || LinuxSize < MinimumSize;
        }

        private void NotifyPropertyChanged(string propertyName)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        }

        private void BackButton_Click(object sender, RoutedEventArgs e)
        {
            var fadeOut = new DoubleAnimation
            {
                From = 1.0,
                To = 0.0,
                Duration = TimeSpan.FromSeconds(0.3)
            };

            var slideOut = new ThicknessAnimation
            {
                From = new Thickness(0),
                To = new Thickness(100, 0, 0, 0),
                Duration = TimeSpan.FromSeconds(0.3)
            };

            fadeOut.Completed += (s, _) =>
            {
                var currentBackground = ((Grid)this.Content).Background;
                
                // Create and navigate to a new instance of ChooseDistro
                var chooseDistroPage = new ChooseDistro();
                NavigationService.Navigate(chooseDistroPage);
                
                // Apply background and animations to the new page
                if (chooseDistroPage.Content is Grid grid)
                {
                    grid.Background = currentBackground;

                    var fadeIn = new DoubleAnimation
                    {
                        From = 0.0,
                        To = 1.0,
                        Duration = TimeSpan.FromSeconds(0.3)
                    };

                    var slideIn = new ThicknessAnimation
                    {
                        From = new Thickness(-100, 0, 0, 0),
                        To = new Thickness(0),
                        Duration = TimeSpan.FromSeconds(0.3)
                    };

                    chooseDistroPage.BeginAnimation(UIElement.OpacityProperty, fadeIn);
                    chooseDistroPage.BeginAnimation(FrameworkElement.MarginProperty, slideIn);
                }
            };

            this.BeginAnimation(UIElement.OpacityProperty, fadeOut);
            this.BeginAnimation(FrameworkElement.MarginProperty, slideOut);
        }

        private void NextButton_Click(object sender, RoutedEventArgs e)
        {
            Console.WriteLine("Next button clicked");
        }
    }
}