using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Libertix.Models;
using Libertix.Pages;  // Add this line
using System;
using System.ComponentModel;
using System.Windows.Media.Animation;

namespace Libertix
{
    public partial class ChooseDistro : Page, INotifyPropertyChanged
    {
        private readonly List<DistroInfo> _distros;
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
            
            _distros = new List<DistroInfo>
            {
                new DistroInfo 
                {
                    Name = "Zorin OS 17.2 Core",
                    Description = "A powerful, secure and easy to use operating system designed for everyone",
                    ImageUrl = "https://assets.zorincdn.com/images/releases/17/desktop.jpg",
                    IsoUrl = "https://mirrors.ircam.fr/pub/zorinos-isos/17/Zorin-OS-17.2-Core-64-bit.iso",
                    SizeInGB = 3.2
                },
                new DistroInfo 
                {
                    Name = "Ubuntu 24.04 LTS",
                    Description = "Fast, free and full of new features. Ubuntu is the world’s favourite Linux operating system",
                    ImageUrl = "https://res.cloudinary.com/canonical/image/fetch/f_auto,q_auto,fl_sanitize,c_fill,w_720/https://lh7-us.googleusercontent.com/7-Wcy72kffGY3f_KhI4VNoDGow_nnsGwB10oSO2oACqBYORb5xRWuQSKwAkaLE0YWciUWlrf5Hk2yKNb66kdo7t3d8YQSu1yS1JaJiGliqn3aFDAG5Qy558ApHb_did8V0EGmWKaH2DzhOnGa8pR50I",
                    IsoUrl = "https://releases.ubuntu.com/noble/ubuntu-24.04.1-desktop-amd64.iso",
                    SizeInGB = 5.8
                }
            };

            DistrosItemsControl.ItemsSource = _distros;
            DataContext = this;
            IsDistroSelected = false;
        }

        private void Border_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
        {
            if (sender is Border border && border.DataContext is DistroInfo distro)
            {
                // Deselect previous selection
                foreach (var item in _distros)
                {
                    item.IsSelected = false;
                }
                
                distro.IsSelected = true;
                App.Current.Properties["SelectedDistro"] = distro;
                IsDistroSelected = true;
            }
        }

        private void NextButton_Click(object sender, RoutedEventArgs e)
        {
            var resizeDiskPage = new ResizeDisk();
            NavigateWithAnimation(resizeDiskPage);
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