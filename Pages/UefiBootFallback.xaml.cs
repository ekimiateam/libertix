using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Libertix.Helpers;
using Libertix.Installation;
using Libertix.Models;

namespace Libertix.Pages
{
    public partial class UefiBootFallback : Page
    {
        private readonly InstallationState _installationState;
        private UefiRecoveryState _state;
        private string _statePath;
        private bool _running;

        public UefiBootFallback() : this(((App)Application.Current).InstallationState)
        {
        }

        public UefiBootFallback(InstallationState installationState)
        {
            _installationState = installationState ?? throw new ArgumentNullException(nameof(installationState));
            InitializeComponent();
            LoadRecoveryState();
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
                Log(Localization.GetString("UefiFallbackBootNextFailedLog"));
                CurrentStepText.Text = Localization.GetString("UefiFallbackReady");
            }
            catch (Exception ex)
            {
                CurrentStepText.Text = Localization.GetString("UefiFallbackLoadFailed");
                Log(Localization.GetString("UefiFallbackErrorPrefix") + ex.Message);
                FallbackButton.IsEnabled = false;
                CancelButton.IsEnabled = false;
            }
        }

        private async void FallbackButton_Click(object sender, RoutedEventArgs e)
        {
            if (_running || _state == null)
                return;

            _running = true;
            FallbackButton.IsEnabled = false;
            CancelButton.IsEnabled = false;
            _state.Phase = "FallbackRunning";
            SaveState();
            CurrentStepText.Text = Localization.GetString("UefiFallbackPreparingFirmware");
            ProgressBar.Value = 20;

            string script = Path.Combine(_state.PayloadRoot, "Scripts", "libertix-uefi-install.ps1");
            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
            try
            {
                int exitCode = await RunProcessAsync(
                    powershell,
                    $"-NoProfile -ExecutionPolicy Bypass -File {QuoteArgument(script)} " +
                    $"-ConfigPath {QuoteArgument(_state.ConfigPath)} -PreserveConfig " +
                    "-BootStrategy FirmwareBootOrder -ReusePreparedInstaller");
                if (exitCode != 0)
                    throw new InvalidOperationException(string.Format(
                        Localization.GetString("UefiFallbackFirmwareFailedFormat"), exitCode));

                _state.Phase = "AwaitingFallbackReboot";
                SaveState();
                ProgressBar.Value = 100;
                CurrentStepText.Text = Localization.GetString("UefiFallbackFirmwareReady");
                RebootButton.Visibility = Visibility.Visible;
                FallbackButton.Visibility = Visibility.Collapsed;
            }
            catch (Exception ex)
            {
                _state.Phase = "FallbackPreparationFailed";
                SaveState();
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
                string agent = Path.Combine(_state.PayloadRoot, "Scripts", "libertix-uefi-recovery-agent.ps1");
                string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
                int exitCode = await RunProcessAsync(
                    powershell,
                    $"-NoProfile -ExecutionPolicy Bypass -File {QuoteArgument(agent)} " +
                    $"-StatePath {QuoteArgument(_statePath)} -Action Cancel");
                if (exitCode != 0)
                    throw new InvalidOperationException(string.Format(
                        Localization.GetString("UefiFallbackRestoreFailedFormat"), exitCode));
                ProgressBar.Value = 100;
                CurrentStepText.Text = Localization.GetString("UefiFallbackWindowsRestored");
                Log(Localization.GetString("UefiFallbackCancelledLog"));
                await Task.Delay(1200);
                Application.Current.Shutdown(0);
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

        private void RebootButton_Click(object sender, RoutedEventArgs e)
        {
            Process.Start("shutdown", "/r /t 0");
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
                    process.OutputDataReceived += (_, output) =>
                    {
                        if (output.Data != null)
                            Dispatcher.BeginInvoke(new Action(() => Log(output.Data)));
                    };
                    process.ErrorDataReceived += (_, output) =>
                    {
                        if (output.Data != null)
                            Dispatcher.BeginInvoke(new Action(() => Log("ERROR: " + output.Data)));
                    };
                    process.Start();
                    process.BeginOutputReadLine();
                    process.BeginErrorReadLine();
                    if (!process.WaitForExit(
                        (int)WindowsProcessTimeouts.RecoveryOperation.TotalMilliseconds))
                    {
                        try
                        {
                            WindowsProcessRunner.TerminateProcessTree(process);
                        }
                        catch
                        {
                            // A process that exits at the timeout boundary no
                            // longer needs to be terminated.
                        }
                        Dispatcher.BeginInvoke(new Action(() =>
                            Log(Localization.GetString("UefiFallbackTimeoutLog"))));
                        return -1;
                    }
                    process.WaitForExit();
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
