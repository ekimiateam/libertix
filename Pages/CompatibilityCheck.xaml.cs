using System;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Libertix.Helpers;
using Libertix.Models;

namespace Libertix.Pages
{
    public partial class CompatibilityCheck : Page
    {
        private readonly InstallationState _installationState;
        private readonly StringBuilder _details = new StringBuilder();
        private bool _running;

        public CompatibilityCheck() : this(((App)Application.Current).InstallationState)
        {
        }

        public CompatibilityCheck(InstallationState installationState)
        {
            _installationState = installationState ?? throw new ArgumentNullException(nameof(installationState));
            InitializeComponent();
            Loaded += CompatibilityCheck_Loaded;
        }

        private async void CompatibilityCheck_Loaded(object sender, RoutedEventArgs e)
        {
            Loaded -= CompatibilityCheck_Loaded;
            await RunChecksAsync();
        }

        private async Task RunChecksAsync()
        {
            if (_running) return;
            _running = true;
            _details.Clear();
            DetailsText.Text = string.Empty;
            StatusText.Text = Localization.GetString("CompatibilityRunning");
            StatusText.Foreground = (System.Windows.Media.Brush)FindResource("TextPrimary");
            CheckProgress.IsIndeterminate = true;
            CheckProgress.Value = 0;
            ContinueButton.IsEnabled = false;
            RetryButton.Visibility = Visibility.Collapsed;

            try
            {
                bool skipNvramWriteProbe =
                    ((App)Application.Current).RuntimeOptions.SkipNvramWriteProbe;
                CompatibilityInfo info = await CompatibilityPreflightRunner.RunAsync(
                    AppendDetail,
                    skipNvramWriteProbe);
                _installationState.Compatibility = info;
                CheckProgress.IsIndeterminate = false;
                CheckProgress.Value = 100;
                StatusText.Text = info.LowMemoryMode
                    ? Localization.GetString("CompatibilityLowMemorySuccess")
                    : Localization.GetString("CompatibilitySuccess");
                StatusText.Foreground = (System.Windows.Media.Brush)FindResource("AccentColor");
                ContinueButton.IsEnabled = true;
                ContinueButton.Focus();
                foreach (string warning in info.Warnings)
                    AppendDetail(Localization.GetString("CompatibilityWarningPrefix") + warning);
            }
            catch (CompatibilityPreflightException ex)
            {
                _installationState.Compatibility = null;
                CheckProgress.IsIndeterminate = false;
                CheckProgress.Value = 0;
                StatusText.Text = ex.Code + " : " + ex.Message;
                StatusText.Foreground = (System.Windows.Media.Brush)FindResource("ErrorColor");
                AppendDetail(ex.Diagnostics);
                RetryButton.Visibility = Visibility.Visible;
                RetryButton.Focus();
            }
            catch (Exception ex)
            {
                _installationState.Compatibility = null;
                CheckProgress.IsIndeterminate = false;
                CheckProgress.Value = 0;
                StatusText.Text = Localization.GetString("CompatibilityUnexpectedPrefix") + ex.Message;
                StatusText.Foreground = (System.Windows.Media.Brush)FindResource("ErrorColor");
                RetryButton.Visibility = Visibility.Visible;
                RetryButton.Focus();
            }
            finally
            {
                _running = false;
            }
        }

        private void AppendDetail(string line)
        {
            if (string.IsNullOrWhiteSpace(line)) return;
            Dispatcher.Invoke(() =>
            {
                _details.AppendLine(line.Trim());
                DetailsText.Text = _details.ToString();
            });
        }

        private async void RetryButton_Click(object sender, RoutedEventArgs e) => await RunChecksAsync();

        private void ContinueButton_Click(object sender, RoutedEventArgs e)
        {
            if (_installationState.Compatibility == null) return;
            NavigationHelper.NavigateWithAnimation(
                NavigationService,
                new ChooseDistro(_installationState),
                TimeSpan.FromSeconds(0.3));
        }
    }
}
