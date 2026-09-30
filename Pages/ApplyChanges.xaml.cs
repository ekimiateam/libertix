using System;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Libertix.Dialogs;
using Libertix.Helpers;
using Libertix.Installation;
using Libertix.Models;

namespace Libertix.Pages
{
    /// <summary>
    /// Installation progress screen. <see cref="InstallationEngine"/> performs
    /// the installation; this page only renders its progress and forwards the
    /// user's cancel, retry and restart decisions.
    /// </summary>
    public partial class ApplyChanges : Page, IInstallationView
    {
        private readonly InstallationState _installationState;
        private readonly InstallationEngine _engine;
        private bool _logOutputAutoScroll = true;
        private bool _expandedLogOutputAutoScroll = true;

        public ApplyChanges() : this(((App)Application.Current).InstallationState)
        {
        }

        public ApplyChanges(InstallationState installationState)
        {
            _installationState = installationState ?? throw new ArgumentNullException(nameof(installationState));
            InitializeComponent();
            var app = (App)Application.Current;
            _engine = new InstallationEngine(_installationState, app.Filepool, app.RuntimeOptions, this);
            Loaded += ApplyChanges_Loaded;
            Unloaded += ApplyChanges_Unloaded;
        }

        private void ApplyChanges_Unloaded(object sender, RoutedEventArgs e)
        {
            _engine.DisposeIfIdle();
        }

        private async void ApplyChanges_Loaded(object sender, RoutedEventArgs e)
        {
            Loaded -= ApplyChanges_Loaded;
            await _engine.RunAsync();
        }

        private void BackButton_Click(object sender, RoutedEventArgs e)
        {
            if (_engine.IsRunning || !_engine.CanRetry) return;

            Page retryPage = _installationState.Account?.HasPassword == true
                ? (Page)new WarningConfirmation(_installationState)
                : new AccountCreation(_installationState);
            NavigationHelper.NavigateWithAnimation(
                NavigationService,
                retryPage,
                TimeSpan.FromSeconds(0.3),
                slideLeft: false);
        }

        private void CancelInstallationButton_Click(object sender, RoutedEventArgs e)
        {
            if (!_engine.CanRequestCancellation)
                return;

            bool confirmed = LocalizedConfirmationDialog.Show(
                Application.Current.MainWindow,
                Localization.GetString("WarningTitle", "Warning"),
                Localization.GetString(
                    "ApplyChangesCancelConfirm",
                    "Cancel the installation and restore Windows?"),
                Localization.GetString("ConfirmationYes", "Yes"),
                Localization.GetString("ConfirmationNo", "No"));
            if (confirmed)
                _engine.RequestCancellation();
        }

        private async void RebootButton_Click(object sender, RoutedEventArgs e)
        {
            bool confirmed = LocalizedConfirmationDialog.Show(
                Application.Current.MainWindow,
                Localization.GetString("WarningTitle", "Warning"),
                Localization.GetString(
                    "ApplyChangesRebootConfirm",
                    "The computer will restart to complete the installation. Continue?"),
                Localization.GetString("ConfirmationYes", "Yes"),
                Localization.GetString("ConfirmationNo", "No"));

            if (confirmed)
            {
                RebootButton.IsEnabled = false;
                MainWindow mainWindow = Application.Current.MainWindow as MainWindow;
                mainWindow?.PrepareForSystemRestart();
                try
                {
                    WindowsProcessResult result = await Task.Run(() =>
                        WindowsProcessRunner.Run(
                            "shutdown.exe",
                            "/r /t 0",
                            WindowsProcessTimeouts.QuickCommand,
                            Encoding.UTF8));
                    if (result.ExitCode != 0)
                    {
                        throw new InvalidOperationException(
                            $"shutdown.exe failed with rc={result.ExitCode}: {result.StandardError}".Trim());
                    }
                    UnattendedWorkflow.Complete();
                }
                catch (Exception ex)
                {
                    mainWindow?.CancelSystemRestartPreparation();
                    RebootButton.IsEnabled = true;
                    _engine.Log($"ERROR: Restart request failed: {ex.Message}");
                    _engine.UpdateProgress(
                        100,
                        Localization.GetString(
                            "ApplyChangesRebootFailed",
                            "Windows refused the restart request. Try again."));
                }
            }
        }

        void IInstallationView.AppendLog(string line)
        {
            Dispatcher.Invoke(() =>
            {
                AppendLogLine(LogOutput, line);
                if (ExpandedLogsOverlay.Visibility == Visibility.Visible)
                    AppendLogLine(ExpandedLogOutput, line);
            });
        }

        void IInstallationView.ShowProgress(int percent, string step)
        {
            Dispatcher.Invoke(() =>
            {
                ProgressBar.Value = percent;
                ProgressText.Text = $"{percent}%";
                CurrentStepText.Text = step;
            });
        }

        void IInstallationView.SetCancellationAvailable(bool available)
        {
            Dispatcher.Invoke(() =>
            {
                CancelInstallationButton.Visibility = available ? Visibility.Visible : Visibility.Collapsed;
                if (available)
                    CancelInstallationButton.IsEnabled = true;
            });
        }

        void IInstallationView.DisableCancellation()
        {
            Dispatcher.Invoke(() => CancelInstallationButton.IsEnabled = false);
        }

        void IInstallationView.SetRetryEnabled(bool enabled)
        {
            Dispatcher.Invoke(() => BackButton.IsEnabled = enabled);
        }

        void IInstallationView.ShowRebootAction()
        {
            Dispatcher.Invoke(() =>
            {
                ExpandedLogsOverlay.Visibility = Visibility.Collapsed;
                RebootButton.Visibility = Visibility.Visible;
                RebootButton.IsDefault = true;
                RebootButton.Focus();
            });
        }

        void IInstallationView.HideRebootAction()
        {
            Dispatcher.Invoke(() =>
            {
                RebootButton.Visibility = Visibility.Collapsed;
                RebootButton.IsDefault = false;
            });
        }

        void IInstallationView.SetRebootEnabled(bool enabled)
        {
            Dispatcher.Invoke(() => RebootButton.IsEnabled = enabled);
        }

        void IInstallationView.ShowBlockingMessage(string title, string message, bool isError)
        {
            Dispatcher.Invoke(() => MessageBox.Show(
                message,
                title,
                MessageBoxButton.OK,
                isError ? MessageBoxImage.Error : MessageBoxImage.Warning));
        }

        private void AppendLogLine(TextBox output, string line)
        {
            double previousOffset = output.VerticalOffset;

            output.AppendText(line + Environment.NewLine);
            // TextBox updates its scroll extent after the append has returned.
            // Re-check the user's state on the next layout pass. This avoids a
            // queued append overriding a manual scroll that happened meanwhile.
            output.Dispatcher.BeginInvoke(
                DispatcherPriority.Background,
                new Action(() =>
                {
                    if (IsAutoScrollEnabled(output))
                        output.ScrollToEnd();
                    else
                        output.ScrollToVerticalOffset(previousOffset);
                }));
        }

        private void LogOutput_ScrollChanged(object sender, ScrollChangedEventArgs e)
        {
            // Content growth changes the scroll extent before ScrollToEnd runs.
            // Only a pure viewport movement represents a user scroll decision.
            if (e.ExtentHeightChange != 0 || !(sender is TextBox output))
                return;

            SetAutoScrollEnabled(output, IsAtBottom(output));
        }

        private static bool IsAtBottom(TextBox output)
        {
            const double bottomTolerance = 4.0;
            return output.ExtentHeight <= output.ViewportHeight ||
                output.VerticalOffset >=
                    output.ExtentHeight - output.ViewportHeight - bottomTolerance;
        }

        private bool IsAutoScrollEnabled(TextBox output)
        {
            return ReferenceEquals(output, ExpandedLogOutput)
                ? _expandedLogOutputAutoScroll
                : _logOutputAutoScroll;
        }

        private void SetAutoScrollEnabled(TextBox output, bool enabled)
        {
            if (ReferenceEquals(output, ExpandedLogOutput))
                _expandedLogOutputAutoScroll = enabled;
            else
                _logOutputAutoScroll = enabled;
        }

        private void ExpandLogsButton_Click(object sender, RoutedEventArgs e)
        {
            ExpandedLogOutput.Text = LogOutput.Text;
            ExpandedLogsOverlay.Visibility = Visibility.Visible;
            _expandedLogOutputAutoScroll = true;
            ExpandedLogOutput.ScrollToEnd();
            ExpandedLogOutput.Focus();
        }

        private void CloseExpandedLogsButton_Click(object sender, RoutedEventArgs e)
        {
            ExpandedLogsOverlay.Visibility = Visibility.Collapsed;
            ExpandLogsButton.Focus();
        }
    }
}
