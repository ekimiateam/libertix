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
using System.Windows.Media.Animation;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;

namespace Libertix
{
    public partial class ChooseDistro : Page, INotifyPropertyChanged
    {
        private const string STATE_KEY = "ChooseDistro";
        private const string DISTROS_URL = "https://ekimia.fr/libertix.json";
        private ObservableCollection<DistroInfo> _distros;
        private DistroInfo _selectedDistro;
        private bool _isDistroSelected;

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

        public ChooseDistro()
        {
            InitializeComponent();
            _distros = new ObservableCollection<DistroInfo>();
            LoadDistrosAsync();
            LoadState();
            DataContext = this;
            IsDistroSelected = false;
        }

        private async void LoadDistrosAsync()
        {
            try
            {
                using (var client = new HttpClient())
                {
                    var json = await client.GetStringAsync(DISTROS_URL);
                    var options = new JsonSerializerOptions
                    {
                        PropertyNameCaseInsensitive = true
                    };
                    var distroList = JsonSerializer.Deserialize<List<DistroInfoJson>>(json, options);
                    
                    _distros.Clear();
                    foreach (var distroJson in distroList)
                    {
                        _distros.Add(new DistroInfo
                        {
                            Name = distroJson.Name,
                            Description = distroJson.Description ?? "No description available",  // Add fallback text
                            ImageUrl = distroJson.ImageUrl,
                            IsoUrl = distroJson.IsoUrl,
                            SizeInGB = distroJson.SizeInGB
                        });
                    }
                }
                DistrosItemsControl.ItemsSource = _distros;
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    Application.Current.Resources["DistroLoadError"] as string ?? "Failed to load distributions",
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
            
            // Enable next button
            NextButton.IsEnabled = true;
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
                App.Current.Properties["SelectedDistro"] = _selectedDistro;
                NavigationHelper.NavigateWithAnimation(NavigationService, new ResizeDisk(), TimeSpan.FromSeconds(0.3));
            }
        }

        private void NavigateWithAnimation(Page nextPage)
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
                To = new Thickness(-100, 0, 0, 0),
                Duration = TimeSpan.FromSeconds(0.3)
            };

            fadeOut.Completed += (s, _) =>
            {
                var currentBackground = ((Grid)this.Content).Background;
                NavigationService.Navigate(nextPage);
                ((Grid)nextPage.Content).Background = currentBackground;

                var fadeIn = new DoubleAnimation
                {
                    From = 0.0,
                    To = 1.0,
                    Duration = TimeSpan.FromSeconds(0.3)
                };

                var slideIn = new ThicknessAnimation
                {
                    From = new Thickness(100, 0, 0, 0),
                    To = new Thickness(0),
                    Duration = TimeSpan.FromSeconds(0.3)
                };

                nextPage.BeginAnimation(UIElement.OpacityProperty, fadeIn);
                nextPage.BeginAnimation(FrameworkElement.MarginProperty, slideIn);
            };

            this.BeginAnimation(UIElement.OpacityProperty, fadeOut);
            this.BeginAnimation(FrameworkElement.MarginProperty, slideOut);
        }
    }
}