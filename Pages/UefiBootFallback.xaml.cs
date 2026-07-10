using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Libertix.Helpers;

namespace Libertix.Pages
{
    public partial class UefiBootFallback : Page
    {
        private UefiRecoveryState _state;
        private string _statePath;
        private bool _running;

        public UefiBootFallback()
        {
            InitializeComponent();
            LoadRecoveryState();
        }

        private void LoadRecoveryState()
        {
            _statePath = App.Current.Properties["UefiRecoveryStatePath"] as string;
            try
            {
                if (string.IsNullOrWhiteSpace(_statePath) || !File.Exists(_statePath))
                    throw new InvalidOperationException("Etat de reprise UEFI introuvable.");
                _state = JsonSerializer.Deserialize<UefiRecoveryState>(File.ReadAllText(_statePath));
                if (_state == null || string.IsNullOrWhiteSpace(_state.PayloadRoot) || string.IsNullOrWhiteSpace(_state.ConfigPath))
                    throw new InvalidOperationException("Etat de reprise UEFI incomplet.");
                Log("BootNext n'a pas atteint le live. La strategie firmware validee est prete.");
                CurrentStepText.Text = "Choisissez si Libertix doit relancer avec l'entree firmware UEFI.";
            }
            catch (Exception ex)
            {
                CurrentStepText.Text = "Impossible de charger la reprise UEFI.";
                Log("ERROR: " + ex.Message);
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
            CurrentStepText.Text = "Preparation du demarrage firmware UEFI...";
            ProgressBar.Value = 20;

            string script = Path.Combine(_state.PayloadRoot, "Scripts", "libertix-uefi-install.ps1");
            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
            try
            {
                int exitCode = await RunProcessAsync(
                    powershell,
                    $"-NoProfile -ExecutionPolicy Bypass -File {QuoteArgument(script)} " +
                    $"-ConfigPath {QuoteArgument(_state.ConfigPath)} -Force -PreserveConfig -BootStrategy FirmwareBootOrder");
                if (exitCode != 0)
                    throw new InvalidOperationException("La preparation du demarrage firmware a echoue (rc=" + exitCode + ").");

                _state.Phase = "AwaitingFallbackReboot";
                SaveState();
                ProgressBar.Value = 100;
                CurrentStepText.Text = "Demarrage firmware prepare. Redemarrez pour lancer le live.";
                RebootButton.Visibility = Visibility.Visible;
                FallbackButton.Visibility = Visibility.Collapsed;
            }
            catch (Exception ex)
            {
                _state.Phase = "FallbackPreparationFailed";
                SaveState();
                CurrentStepText.Text = "La preparation du fallback a echoue.";
                Log("ERROR: " + ex.Message);
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
            CurrentStepText.Text = "Restauration de l'etat UEFI initial...";
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
                    throw new InvalidOperationException("La restauration UEFI a echoue (rc=" + exitCode + ").");
                ProgressBar.Value = 100;
                CurrentStepText.Text = "Windows a ete restaure. Libertix va se fermer.";
                Log("Transaction UEFI annulee et fichiers temporaires programmes pour suppression.");
                await Task.Delay(1200);
                Application.Current.Shutdown(0);
            }
            catch (Exception ex)
            {
                CurrentStepText.Text = "La restauration UEFI a echoue.";
                Log("ERROR: " + ex.Message);
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
                    process.WaitForExit();
                    return process.ExitCode;
                }
            });
        }

        private void SaveState()
        {
            _state.LastCheckedUtc = DateTime.UtcNow.ToString("o");
            File.WriteAllText(_statePath, JsonSerializer.Serialize(_state), new UTF8Encoding(false));
        }

        private static string QuoteArgument(string value)
        {
            if (value == null)
                return "\"\"";

            var quoted = new StringBuilder("\"");
            int backslashes = 0;
            foreach (char character in value)
            {
                if (character == '\\')
                {
                    backslashes++;
                    continue;
                }
                if (character == '"')
                {
                    quoted.Append('\\', backslashes * 2 + 1);
                    quoted.Append('"');
                    backslashes = 0;
                    continue;
                }
                quoted.Append('\\', backslashes);
                quoted.Append(character);
                backslashes = 0;
            }
            quoted.Append('\\', backslashes * 2);
            quoted.Append('"');
            return quoted.ToString();
        }

        private void Log(string value)
        {
            LogOutput.AppendText("[" + DateTime.Now.ToString("HH:mm:ss") + "] " + value + Environment.NewLine);
            LogOutput.ScrollToEnd();
        }
    }
}
