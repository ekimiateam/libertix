using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Navigation;
using Libertix.Helpers;
using Libertix.Installation;
using Libertix.Models;

namespace Libertix.Pages
{
    public partial class UefiBootFallback : Page
    {
        private sealed class ProcessTreeTerminationException : InvalidOperationException
        {
            public ProcessTreeTerminationException(string message)
                : base(message)
            {
            }
        }

        private readonly InstallationState _installationState;
        private UefiRecoveryState _state;
        private string _statePath;
        private bool _running;
        private bool _secureBootFlow;
        private bool _secureBootRestored;
        private bool _preferredPathFlow;

        public UefiBootFallback() : this(((App)Application.Current).InstallationState)
        {
        }

        public UefiBootFallback(InstallationState installationState)
        {
            _installationState = installationState ?? throw new ArgumentNullException(nameof(installationState));
            InitializeComponent();
            LoadRecoveryState();
            Loaded += UefiBootFallback_Loaded;
        }

        private void LoadRecoveryState()
        {
            _statePath = _installationState.UefiRecoveryStatePath;
            try
            {
                if (string.IsNullOrWhiteSpace(_statePath) || !File.Exists(_statePath))
                    throw new InvalidOperationException(Localization.GetString("UefiFallbackStateMissing"));
                _state = JsonSerializer.Deserialize<UefiRecoveryState>(File.ReadAllText(_statePath));
                if (_state == null || string.IsNullOrWhiteSpace(_state.PayloadRoot) || string.IsNullOrWhiteSpace(_state.ConfigPath))
                    throw new InvalidOperationException(Localization.GetString("UefiFallbackStateIncomplete"));
                if (IsPreferredPathPhase(_state.Phase))
                {
                    ConfigurePreferredPathFlow();
                }
                else if (_state.SecureBootEnabled)
                {
                    ConfigureSecureBootFlow();
                }
                else
                {
                    Log(Localization.GetString("UefiFallbackBootNextFailedLog"));
                    CurrentStepText.Text = Localization.GetString("UefiFallbackReady");
                }
            }
            catch (Exception ex)
            {
                CurrentStepText.Text = Localization.GetString("UefiFallbackLoadFailed");
                Log(Localization.GetString("UefiFallbackErrorPrefix") + ex.Message);
                FallbackButton.IsEnabled = false;
                CancelButton.IsEnabled = false;
            }
        }

        private static bool IsPreferredPathPhase(string phase)
        {
            return phase == "InstalledBootBypassed" ||
                phase == "PreferredPathPrompted" ||
                phase == "PreferredPathPreparationFailed" ||
                phase == "AwaitingPreferredPathReboot";
        }

        private void ConfigurePreferredPathFlow()
        {
            _preferredPathFlow = true;
            PageTitleText.Text = Localization.GetString("UefiPreferredPathTitle");
            DescriptionText.Text = Localization.GetString("UefiPreferredPathDescription");
            CurrentStepText.Text = Localization.GetString("UefiPreferredPathReady");
            FallbackButton.Content = Localization.GetString("UefiPreferredPathUse");
            Log(Localization.GetString("UefiPreferredPathDetectedLog"));
        }

        private void ConfigureSecureBootFlow()
        {
            _secureBootFlow = true;
            PageTitleText.Text = Localization.GetString("UefiFallbackSecureBootTitle");
            DescriptionText.Text = Localization.GetString("UefiFallbackSecureBootDescription");
            SecureBootGuidancePanel.Visibility = Visibility.Visible;
            FallbackButton.Visibility = Visibility.Collapsed;
            CancelButton.Visibility = Visibility.Collapsed;
            SecureBootCloseButton.Visibility = Visibility.Visible;
            CurrentStepText.Text = Localization.GetString("UefiFallbackSecureBootRestoring");
            Log(Localization.GetString("UefiFallbackSecureBootBlockedLog"));
        }

        private async void UefiBootFallback_Loaded(object sender, RoutedEventArgs e)
        {
            Loaded -= UefiBootFallback_Loaded;
            if (_secureBootFlow && _state != null)
                await RestoreWindowsForSecureBootAsync();
        }

        private async void FallbackButton_Click(object sender, RoutedEventArgs e)
        {
            if (_running || _state == null)
                return;

            _running = true;
            FallbackButton.IsEnabled = false;
            CancelButton.IsEnabled = false;
            CurrentStepText.Text = Localization.GetString("UefiFallbackPreparingFirmware");
            ProgressBar.Value = 20;

            string script = Path.Combine(_state.PayloadRoot, "Scripts", "libertix-uefi-install.ps1");
            string powershell = WindowsProcessRunner.ResolvePowerShell();
            try
            {
                int exitCode;
                if (_preferredPathFlow)
                {
                    _state.Phase = "PreferredPathRunning";
                    SaveState();
                    CurrentStepText.Text = Localization.GetString("UefiPreferredPathPreparing");
                    string agent = Path.Combine(
                        _state.PayloadRoot,
                        "Scripts",
                        "libertix-uefi-recovery-agent.ps1");
                    exitCode = await RunProcessAsync(
                        powershell,
                        $"-NoProfile -ExecutionPolicy Bypass -File {QuoteArgument(agent)} " +
                        $"-StatePath {QuoteArgument(_statePath)} -Action InstallPreferredPath");
                }
                else
                {
                    _state.Phase = "FallbackRunning";
                    SaveState();
                    exitCode = await RunProcessAsync(
                        powershell,
                        $"-NoProfile -ExecutionPolicy Bypass -File {QuoteArgument(script)} " +
                        $"-ConfigPath {QuoteArgument(_state.ConfigPath)} -PreserveConfig " +
                        "-BootStrategy FirmwareBootOrder -ReusePreparedInstaller");
                }
                if (exitCode != 0)
                    throw new InvalidOperationException(string.Format(
                        Localization.GetString(
                            _preferredPathFlow
                                ? "UefiPreferredPathFailedFormat"
                                : "UefiFallbackFirmwareFailedFormat"),
                        exitCode));

                _state.Phase = _preferredPathFlow
                    ? "AwaitingPreferredPathReboot"
                    : "AwaitingFallbackReboot";
                SaveState();
                ProgressBar.Value = 100;
                CurrentStepText.Text = Localization.GetString(
                    _preferredPathFlow
                        ? "UefiPreferredPathRebootReady"
                        : "UefiFallbackFirmwareReady");
                RebootButton.Visibility = Visibility.Visible;
                FallbackButton.Visibility = Visibility.Collapsed;
            }
            catch (ProcessTreeTerminationException ex)
            {
                _state.Phase = "FallbackProcessStateUnknown";
                try
                {
                    SaveState();
                }
                catch (Exception stateError)
                {
                    Log(Localization.GetString("UefiFallbackErrorPrefix") + stateError.Message);
                }
                CurrentStepText.Text = Localization.GetString("UefiFallbackTerminationFailed");
                Log(Localization.GetString("UefiFallbackErrorPrefix") + ex.Message);
            }
            catch (Exception ex)
            {
                _state.Phase = _preferredPathFlow
                    ? "PreferredPathPreparationFailed"
                    : "FallbackPreparationFailed";
                try
                {
                    SaveState();
                }
                catch (Exception stateError)
                {
                    Log(Localization.GetString("UefiFallbackErrorPrefix") + stateError.Message);
                }
                CurrentStepText.Text = Localization.GetString("UefiFallbackPreparationFailed");
                Log(Localization.GetString("UefiFallbackErrorPrefix") + ex.Message);
                FallbackButton.IsEnabled = true;
                CancelButton.IsEnabled = true;
            }
            finally
            {
                _running = false;
            }
        }

        private async void CancelButton_Click(object sender, RoutedEventArgs e)
        {
            if (_running || _state == null)
                return;

            _running = true;
            FallbackButton.IsEnabled = false;
            CancelButton.IsEnabled = false;
            CurrentStepText.Text = Localization.GetString("UefiFallbackRestoring");
            ProgressBar.Value = 35;
            try
            {
                int exitCode = await RestoreWindowsAsync();
                if (exitCode != 0)
                    throw new InvalidOperationException(string.Format(
                        Localization.GetString("UefiFallbackRestoreFailedFormat"), exitCode));
                ProgressBar.Value = 100;
                CurrentStepText.Text = Localization.GetString("UefiFallbackWindowsRestored");
                Log(Localization.GetString("UefiFallbackCancelledLog"));
                await Task.Delay(1200);
                Application.Current.Shutdown(0);
            }
            catch (ProcessTreeTerminationException ex)
            {
                CurrentStepText.Text = Localization.GetString("UefiFallbackTerminationFailed");
                Log(Localization.GetString("UefiFallbackErrorPrefix") + ex.Message);
            }
            catch (Exception ex)
            {
                CurrentStepText.Text = Localization.GetString("UefiFallbackRestoreFailed");
                Log(Localization.GetString("UefiFallbackErrorPrefix") + ex.Message);
                FallbackButton.IsEnabled = true;
                CancelButton.IsEnabled = true;
            }
            finally
            {
                _running = false;
            }
        }

        private async Task RestoreWindowsForSecureBootAsync()
        {
            if (_running || _state == null)
                return;

            _running = true;
            SecureBootCloseButton.IsEnabled = false;
            SecureBootCloseButton.Content = Localization.GetString("UefiFallbackSecureBootClose");
            CurrentStepText.Text = Localization.GetString("UefiFallbackSecureBootRestoring");
            ProgressBar.Value = 35;
            try
            {
                int exitCode = await RestoreWindowsAsync();
                if (exitCode != 0)
                    throw new InvalidOperationException(string.Format(
                        Localization.GetString("UefiFallbackRestoreFailedFormat"), exitCode));

                _secureBootRestored = true;
                ProgressBar.Value = 100;
                CurrentStepText.Text = Localization.GetString("UefiFallbackSecureBootWindowsRestored");
                Log(Localization.GetString("UefiFallbackCancelledLog"));
                SecureBootCloseButton.IsEnabled = true;
            }
            catch (ProcessTreeTerminationException ex)
            {
                CurrentStepText.Text = Localization.GetString("UefiFallbackTerminationFailed");
                Log(Localization.GetString("UefiFallbackErrorPrefix") + ex.Message);
            }
            catch (Exception ex)
            {
                CurrentStepText.Text = Localization.GetString("UefiFallbackRestoreFailed");
                Log(Localization.GetString("UefiFallbackErrorPrefix") + ex.Message);
                SecureBootCloseButton.Content = Localization.GetString("UefiFallbackSecureBootRetry");
                SecureBootCloseButton.IsEnabled = true;
            }
            finally
            {
                _running = false;
            }
        }

        private async Task<int> RestoreWindowsAsync()
        {
            string agent = Path.Combine(
                _state.PayloadRoot,
                "Scripts",
                "libertix-uefi-recovery-agent.ps1");
            string powershell = WindowsProcessRunner.ResolvePowerShell();
            return await RunProcessAsync(
                powershell,
                $"-NoProfile -ExecutionPolicy Bypass -File {QuoteArgument(agent)} " +
                $"-StatePath {QuoteArgument(_statePath)} -Action Cancel");
        }

        private async void SecureBootCloseButton_Click(object sender, RoutedEventArgs e)
        {
            if (_running)
                return;
            if (!_secureBootRestored)
            {
                await RestoreWindowsForSecureBootAsync();
                return;
            }
            Application.Current.Shutdown(0);
        }

        private void SecureBootHelpLink_RequestNavigate(
            object sender,
            RequestNavigateEventArgs e)
        {
            try
            {
                Process.Start(new ProcessStartInfo(e.Uri.AbsoluteUri)
                {
                    UseShellExecute = true
                });
                e.Handled = true;
            }
            catch (Exception ex)
            {
                Log(Localization.GetString("UefiFallbackErrorPrefix") + ex.Message);
            }
        }

        private async void RebootButton_Click(object sender, RoutedEventArgs e)
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
                        string.Format(
                            Localization.GetString("UefiFallbackRebootFailedFormat"),
                            result.ExitCode));
                }
            }
            catch (Exception ex)
            {
                mainWindow?.CancelSystemRestartPreparation();
                RebootButton.IsEnabled = true;
                CurrentStepText.Text = Localization.GetString("UefiFallbackRebootFailed");
                Log(Localization.GetString("UefiFallbackErrorPrefix") + ex.Message);
            }
        }

        private async Task<int> RunProcessAsync(string fileName, string arguments)
        {
            return await Task.Run(() =>
            {
                var startInfo = new ProcessStartInfo
                {
                    FileName = fileName,
                    Arguments = arguments,
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true,
                    StandardOutputEncoding = Encoding.UTF8,
                    StandardErrorEncoding = Encoding.UTF8
                };
                using (var process = new Process { StartInfo = startInfo })
                {
                    var outputClosed = new TaskCompletionSource<bool>();
                    var errorClosed = new TaskCompletionSource<bool>();
                    process.OutputDataReceived += (_, output) =>
                    {
                        if (output.Data == null)
                        {
                            outputClosed.TrySetResult(true);
                        }
                        else
                        {
                            Dispatcher.BeginInvoke(new Action(() => Log(output.Data)));
                        }
                    };
                    process.ErrorDataReceived += (_, output) =>
                    {
                        if (output.Data == null)
                        {
                            errorClosed.TrySetResult(true);
                        }
                        else
                        {
                            Dispatcher.BeginInvoke(new Action(() => Log("ERROR: " + output.Data)));
                        }
                    };
                    if (!process.Start())
                        throw new InvalidOperationException("The recovery process could not be started.");
                    process.BeginOutputReadLine();
                    process.BeginErrorReadLine();
                    if (!process.WaitForExit(
                        (int)WindowsProcessTimeouts.RecoveryOperation.TotalMilliseconds))
                    {
                        bool stopped;
                        try
                        {
                            stopped = WindowsProcessRunner.TerminateProcessTree(process);
                        }
                        catch
                        {
                            stopped = false;
                        }
                        if (!stopped)
                        {
                            throw new ProcessTreeTerminationException(
                                Localization.GetString("UefiFallbackTerminationFailed"));
                        }
                        Dispatcher.BeginInvoke(new Action(() =>
                            Log(Localization.GetString("UefiFallbackTimeoutLog"))));
                        return -1;
                    }
                    WindowsProcessRunner.WaitForRedirectedStreams(
                        outputClosed.Task,
                        errorClosed.Task);
                    return process.ExitCode;
                }
            });
        }

        private void SaveState()
        {
            _state.LastCheckedUtc = DateTime.UtcNow.ToString("o");
            // The startup recovery agent derives its next action from this
            // document alone. Publish each phase transition atomically so an
            // interrupted fallback cannot leave recovery without a valid state.
            AtomicJsonFile.Write(_statePath, JsonSerializer.Serialize(_state));
        }

        private static string QuoteArgument(string value)
        {
            return WindowsProcessRunner.QuoteArgument(value);
        }

        private void Log(string value)
        {
            LogOutput.AppendText("[" + DateTime.Now.ToString("HH:mm:ss") + "] " + value + Environment.NewLine);
            LogOutput.ScrollToEnd();
        }
    }
}
