using System;
using System.Windows;
using System.Windows.Media.Animation;
using System.Windows.Navigation;

namespace Libertix
{
    public partial class MainWindow : Window
    {
        public MainWindow()
        {
            InitializeComponent();
        }

        private void Button_Click(object sender, RoutedEventArgs e)
        {
            // Create new page instance
            var secondPage = new ChooseDistro();

            // Create fade out animation
            var fadeOut = new DoubleAnimation
            {
                From = 1.0,
                To = 0.0,
                Duration = TimeSpan.FromSeconds(0.3)
            };

            // Create slide animation
            var slideOut = new ThicknessAnimation
            {
                From = new Thickness(0),
                To = new Thickness(-100, 0, 0, 0),
                Duration = TimeSpan.FromSeconds(0.3)
            };

            // When animations complete, navigate to new page and play entrance animations
            fadeOut.Completed += (s, _) =>
            {
                MainFrame.Navigate(secondPage);

                // Create fade in animation
                var fadeIn = new DoubleAnimation
                {
                    From = 0.0,
                    To = 1.0,
                    Duration = TimeSpan.FromSeconds(0.3)
                };

                // Create slide in animation
                var slideIn = new ThicknessAnimation
                {
                    From = new Thickness(100, 0, 0, 0),
                    To = new Thickness(0),
                    Duration = TimeSpan.FromSeconds(0.3)
                };

                secondPage.BeginAnimation(UIElement.OpacityProperty, fadeIn);
                secondPage.BeginAnimation(FrameworkElement.MarginProperty, slideIn);
            };

            // Start exit animations - with proper casting
            if (MainFrame.Content is UIElement currentPage)
            {
                currentPage.BeginAnimation(UIElement.OpacityProperty, fadeOut);
                currentPage.BeginAnimation(FrameworkElement.MarginProperty, slideOut);
            }
        }
    }
}