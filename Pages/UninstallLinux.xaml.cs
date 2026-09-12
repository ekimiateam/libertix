using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Libertix.Helpers;
using Libertix.Installation;
using Libertix.Models;

namespace Libertix.Pages
{
    public partial class UninstallLinux : Page
    {
        private sealed class RecoveryTerminationException : InvalidOperationException
        {
            public RecoveryTerminationException(string message) : base(message) { }
        }

        private readonly InstallationState _installationState;
        private readonly InstalledLinuxRecoveryCandidate _candidate;
        private readonly string _uiLogPath;
        private bool _started;
        private bool _running;
        private bool _terminationUnverified;

        internal UninstallLinux(
            InstallationState installationState,
            InstalledLinuxRecoveryCandidate candidate)
        {
            _installationState = installationState ??
                throw new ArgumentNullException(nameof(installationState));
            _candidate = candidate ?? throw new ArgumentNullException(nameof(candidate));
            _uiLogPath = Path.Combine(candidate.RecoveryRoot, "uninstall-ui.log");
            InitializeComponent();
            DescriptionText.Text = string.Format(
                Localization.GetString("UninstallLinuxProgressDescription"),
                candidate.DistributionName);
        }

        private async void Page_Loaded(object sender, RoutedEventArgs e)
        {
            if (_started)
                return;
            _started = true;
            await RunUninstallAsync();
        }

        private async Task RunUninstallAsync()
        {
            if (_running || _terminationUnverified)
                return;

            _running = true;
            _installationState.SetInstallationRunning(true);
            RetryButton.Visibility = Visibility.Collapsed;
            BackButton.Visibility = Visibility.Collapsed;
            DoneButton.Visibility = Visibility.Collapsed;
            ProgressBar.Value = 5;
            CurrentStepText.Text = Localization.GetString("UninstallLinuxRunning");
            Log(Localization.GetString("UninstallLinuxStartingLog"));
            try
            {
                await Task.Run(() => RecoveryCodeUpgrade.Prepare(_candidate,
                    Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Scripts")));
                Task<int> processTask = RunRecoveryProcessAsync();
                try
                {
                    while (!processTask.IsCompleted)
                    {
                        RefreshProgressFromLedger();
                        await Task.WhenAny(processTask, Task.Delay(500));
                    }
                }
                finally
                {
                    // A failed progress read must not detach a mutating recovery process.
                    await processTask;
                }

                int exitCode = await processTask;
                if (exitCode != 0)
                {
                    throw new InvalidOperationException(string.Format(
                        Localization.GetString("UninstallLinuxExitCodeFormat"),
                        exitCode));
                }

                InstallationExecutionState state = InstallationStateStore.Read(
                    _candidate.ExecutionStatePath);
                if (state.Status != InstallationStatus.RolledBack ||
                    InstallationStateMachine.GetRollbackProgressPercent(state) != 100)
                {
                    throw new InvalidOperationException(
                        Localization.GetString("UninstallLinuxProofMissing"));
                }
                InstalledLinuxRecoveryLocator.VerifyRollbackResult(_candidate, state);

                ProgressBar.Value = 100;
                CurrentStepText.Text = Localization.GetString("UninstallLinuxComplete");
                Log(Localization.GetString("UninstallLinuxCompleteLog"));
                DoneButton.Visibility = Visibility.Visible;
                DoneButton.Focus();
            }
            catch (RecoveryTerminationException ex)
            {
                _terminationUnverified = true;
                CurrentStepText.Text = Localization.GetString("UninstallLinuxTerminationUnknown");
                Log(Localization.GetString("UninstallLinuxErrorPrefix") + ex.Message);
                ApplicationLogger.WriteException("Uninstall recovery process termination is unknown.", ex);
            }
            catch (Exception ex)
            {
                CurrentStepText.Text = Localization.GetString("UninstallLinuxFailed");
                Log(Localization.GetString("UninstallLinuxErrorPrefix") + ex.Message);
                ApplicationLogger.WriteException("Linux uninstall failed.", ex);
                BackButton.Visibility = Visibility.Visible;
                RetryButton.Visibility = Visibility.Visible;
                RetryButton.Focus();
            }
            finally
            {
                _running = _terminationUnverified;
                _installationState.SetInstallationRunning(_terminationUnverified);
            }
        }

        private async Task<int> RunRecoveryProcessAsync()
        {
            string arguments = _candidate.Firmware == InstallationFirmware.Uefi
                ? $"-NoProfile -ExecutionPolicy Bypass -File {Quote(_candidate.RecoveryScriptPath)} " +
                  $"-StatePath {Quote(_candidate.RecoveryStatePath)} -Action Cancel -VerifiedUninstall"
                : $"-NoProfile -ExecutionPolicy Bypass -File {Quote(_candidate.RecoveryScriptPath)} " +
                  "-Action Revert -VerifiedUninstall";

            return await Task.Run(() =>
            {
                var startInfo = new ProcessStartInfo
                {
                    FileName = WindowsProcessRunner.ResolvePowerShell(),
                    Arguments = arguments,
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true,
                    StandardOutputEncoding = Encoding.UTF8,
                    StandardErrorEncoding = Encoding.UTF8
                };
                try
                {
                    WindowsProcessResult result = WindowsProcessRunner.RunStreaming(
                        startInfo,
                        WindowsProcessTimeouts.RecoveryOperation,
                        output =>
                            Dispatcher.BeginInvoke(new Action(() => Log(output))),
                        error =>
                            Dispatcher.BeginInvoke(new Action(() =>
                                Log(Localization.GetString("UninstallLinuxErrorPrefix") + error))));
                    return result.ExitCode;
                }
                catch (UnterminatedProcessException ex)
                {
                    throw new RecoveryTerminationException(ex.Message);
                }
            });
        }

        private void RefreshProgressFromLedger()
        {
            try
            {
                InstallationExecutionState state = InstallationStateStore.Read(
                    _candidate.ExecutionStatePath);
                int rollbackPercent = InstallationStateMachine.GetRollbackProgressPercent(state);
                if (state.Status == InstallationStatus.RollbackRunning)
                {
                    ProgressBar.Value = 10 + rollbackPercent * 80 / 100;
                    CurrentStepText.Text = string.Format(
                        Localization.GetString("UninstallLinuxProgressFormat"),
                        rollbackPercent);
                }
            }
            catch (IOException)
            {
                // Atomic replacement can briefly make a read race the writer.
            }
        }

        private async void RetryButton_Click(object sender, RoutedEventArgs e)
        {
            await RunUninstallAsync();
        }

        private void BackButton_Click(object sender, RoutedEventArgs e)
        {
            if (_running)
                return;
            (Application.Current.MainWindow as MainWindow)?.ReturnToWelcome();
        }

        private void Log(string message)
        {
            string normalized = WindowsProcessRunner.NormalizeTerminalText(message);
            string line = $"[{DateTime.Now:HH:mm:ss}] {normalized}";
            bool atBottom = LogOutput.ExtentHeight <= LogOutput.ViewportHeight ||
                LogOutput.VerticalOffset >= LogOutput.ExtentHeight - LogOutput.ViewportHeight - 4;
            LogOutput.AppendText(line + Environment.NewLine);
            if (atBottom)
                LogOutput.ScrollToEnd();
            try
            {
                File.AppendAllText(_uiLogPath, line + Environment.NewLine, new UTF8Encoding(false));
            }
            catch
            {
                // The recovery agent keeps its authoritative log if this UI log is unavailable.
            }
        }

        private static string Quote(string value) => WindowsProcessRunner.QuoteArgument(value);
    }
}
