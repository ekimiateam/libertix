using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.IO;
using System.Diagnostics;
using Libertix.Commands;
using Libertix.Helpers;
using Libertix.Models;

namespace Libertix.Pages
{
    public partial class ResizeDisk : Page, INotifyPropertyChanged
    {
        private const string STATE_KEY = "ResizeDisk";
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
                LoadState(distro);
            }
        }

        private void SaveState(DistroInfo distro)
        {
            var stateKey = $"{STATE_KEY}_{distro.Name}";
            var state = new PageState
            {
                PageType = typeof(ResizeDisk),
                StateKey = stateKey,
                State = new Dictionary<string, double>
                {
                    { "SelectedSize", SelectedSize },
                    { "WindowsFreeSpace", WindowsFreeSpace },
                    { "LinuxSize", LinuxSize }
                }
            };
            StateManager.SaveState(stateKey, state);
        }

        private void LoadState(DistroInfo distro)
        {
            var stateKey = $"{STATE_KEY}_{distro.Name}";
            var state = StateManager.GetState(stateKey);
            
            if (state?.State is Dictionary<string, double> savedState)
            {
                // Restore saved values
                IsoSize = distro.SizeInGB;
                SelectedSize = savedState["SelectedSize"];
                WindowsFreeSpace = savedState["WindowsFreeSpace"];
                LinuxSize = savedState["LinuxSize"];
            }
            else
            {
                // Initialize with default values
                IsoSize = distro.SizeInGB;
                SelectedSize = MinimumSize;
            }
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
            if (App.Current.Properties["SelectedDistro"] is DistroInfo distro)
            {
                SaveState(distro);
            }
            NavigationHelper.NavigateWithAnimation(
                NavigationService,
                new ChooseDistro(),
                TimeSpan.FromSeconds(0.3),
                slideLeft: false);
        }

        private void NextButton_Click(object sender, RoutedEventArgs e)
        {
            if (App.Current.Properties["SelectedDistro"] is DistroInfo distro)
            {
                SaveState(distro);
            }
            NavigationHelper.NavigateWithAnimation(
                NavigationService,
                new AccountCreation(),
                TimeSpan.FromSeconds(0.3));
        }

        // In ChooseDistro when a different distro is selected
        private void OnDistroSelected(DistroInfo distro)
        {
            StateManager.ClearDependentStates(STATE_KEY);
            // ... rest of selection code
        }
    }
}