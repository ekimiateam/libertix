using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Navigation;

namespace Libertix.Helpers
{
    public static class NavigationHelper
    {
        public static void NavigateWithAnimation(
            NavigationService navigation,
            Page newPage,
            TimeSpan duration,
            double slideOffset = 100,
            bool slideLeft = true)
        {
            if (navigation == null)
                throw new ArgumentNullException(nameof(navigation));

            NavigateWithAnimationCore(
                navigation.Content,
                page => navigation.Navigate(page),
                newPage,
                duration,
                slideOffset,
                slideLeft);
        }

        public static void NavigateWithAnimationInFrame(
            Frame frame,
            Page newPage,
            TimeSpan duration,
            double slideOffset = 100,
            bool slideLeft = true)
        {
            if (frame == null)
                throw new ArgumentNullException(nameof(frame));

            NavigateWithAnimationCore(
                frame.Content,
                page => frame.Navigate(page),
                newPage,
                duration,
                slideOffset,
                slideLeft);
        }

        private static void NavigateWithAnimationCore(
            object currentContent,
            Func<Page, bool> navigate,
            Page newPage,
            TimeSpan duration,
            double slideOffset,
            bool slideLeft)
        {
            if (newPage == null)
                throw new ArgumentNullException(nameof(newPage));

            if (newPage.Content is Grid grid)
            {
                grid.Background = Brushes.Transparent;
            }

            if (!(currentContent is UIElement currentPage))
            {
                navigate(newPage);
                return;
            }

            // Default buttons can receive another Enter while a transition is
            // still running. Ignore that duplicate activation so two completed
            // handlers cannot race to replace the same frame content.
            if (!currentPage.IsHitTestVisible)
                return;

            if (duration <= TimeSpan.Zero)
            {
                navigate(newPage);
                return;
            }

            var fadeOut = CreateFadeAnimation(1.0, 0.0, duration);
            var slideOut = CreateSlideAnimation(
                new Thickness(0),
                new Thickness(slideLeft ? -slideOffset : slideOffset, 0, 0, 0),
                duration);

            fadeOut.Completed += (s, _) =>
            {
                currentPage.BeginAnimation(UIElement.OpacityProperty, null);
                currentPage.BeginAnimation(FrameworkElement.MarginProperty, null);
                currentPage.IsHitTestVisible = true;

                if (!navigate(newPage))
                    return;

                var fadeIn = CreateFadeAnimation(0.0, 1.0, duration);
                var slideIn = CreateSlideAnimation(
                    new Thickness(slideLeft ? slideOffset : -slideOffset, 0, 0, 0),
                    new Thickness(0),
                    duration);

                newPage.BeginAnimation(UIElement.OpacityProperty, fadeIn);
                newPage.BeginAnimation(FrameworkElement.MarginProperty, slideIn);
            };

            currentPage.IsHitTestVisible = false;
            currentPage.BeginAnimation(UIElement.OpacityProperty, fadeOut);
            currentPage.BeginAnimation(FrameworkElement.MarginProperty, slideOut);
        }

        private static DoubleAnimation CreateFadeAnimation(double from, double to, TimeSpan duration)
        {
            return new DoubleAnimation
            {
                From = from,
                To = to,
                Duration = duration,
                FillBehavior = FillBehavior.Stop,
                EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseInOut }
            };
        }

        private static ThicknessAnimation CreateSlideAnimation(Thickness from, Thickness to, TimeSpan duration)
        {
            return new ThicknessAnimation
            {
                From = from,
                To = to,
                Duration = duration,
                FillBehavior = FillBehavior.Stop,
                EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseInOut }
            };
        }
    }
}
