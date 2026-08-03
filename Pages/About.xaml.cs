using System;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;

namespace Libertix.Pages
{
    /// <summary>
    /// Presents project credits from public Libertix and Ekimia sources.
    /// The page is deliberately offline-first; links open only on user action.
    /// </summary>
    public partial class About : Page
    {
        public About()
        {
            InitializeComponent();
        }

        private void Back_Click(object sender, RoutedEventArgs e)
        {
            if (Application.Current.MainWindow is MainWindow mainWindow)
                mainWindow.ReturnToWelcome();
        }

        private void OpenLink_Click(object sender, RoutedEventArgs e)
        {
            if (!(sender is Button button) || !(button.Tag is string url))
                return;

            try
            {
                Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
            }
            catch (Exception error)
            {
                MessageBox.Show(
                    string.Format(Localization.GetString("AboutLinkError"), error.Message),
                    Localization.GetString("AboutTitle"),
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
            }
        }
    }
}
