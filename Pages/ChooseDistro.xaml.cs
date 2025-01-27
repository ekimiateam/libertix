using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Libertix.Models;

namespace Libertix
{
    public partial class ChooseDistro : Page
    {
        private readonly List<DistroInfo> _distros;

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
                }
            };

            DistrosItemsControl.ItemsSource = _distros;
        }

        private void Border_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
        {
            if (sender is Border border && border.DataContext is DistroInfo distro)
            {
                // Store selected distribution for later use
                App.Current.Properties["SelectedDistro"] = distro;
                
                // TODO: Navigate to confirmation page
                MessageBox.Show($"Selected {distro.Name}");
            }
        }
    }
}