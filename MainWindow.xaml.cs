using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Navigation;
using Libertix.Helpers;

namespace Libertix
{
    public partial class MainWindow : Window
    {
        public MainWindow()
        {
            InitializeComponent();
            LanguageComboBox.SelectedIndex = 0; // Default to English
        }

        private void Button_Click(object sender, RoutedEventArgs e)
        {
            StateManager.ClearState("ChooseDistro"); // Clear state when starting fresh
            NavigationHelper.NavigateWithAnimationInFrame(
                MainFrame,
                new ChooseDistro(),
                TimeSpan.FromSeconds(0.3));
        }

        private void LanguageComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (LanguageComboBox.SelectedItem is ComboBoxItem item)
            {
                string cultureName = item.Tag.ToString();
                Localization.SetLanguage(cultureName);
            }
        }

        private void LanguageSelector_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (sender is ComboBox combo && combo.SelectedItem is ComboBoxItem item)
            {
                string lang = (string)item.Tag;
                Localization.SetLanguage(lang);
            }
        }
    }
}