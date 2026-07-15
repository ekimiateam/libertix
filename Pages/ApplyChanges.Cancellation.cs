using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using Libertix.Helpers;

namespace Libertix.Pages
{
    public partial class ApplyChanges
    {
        private readonly CancellationTokenSource _installationCancellation =
            new CancellationTokenSource();
        private readonly object _activeProcessLock = new object();
        private readonly object _persistentLogLock = new object();
        private Process _activeStreamingProcess;
        private FirmwareType _activeFirmware = FirmwareType.Unknown;
        private UefiRecoveryState _activeUefiRecovery;
        private bool _cancellationHandled;
        private string _persistentLogPath;

        private void InitializeInstallationControls()
        {
            try
            {
                string logRoot = @"C:\LibertixInstallLogs";
                Directory.CreateDirectory(logRoot);
                _persistentLogPath = Path.Combine(
                    logRoot,
                    $"windows-preparation-{DateTime.Now:yyyyMMdd-HHmmss}.log");
                File.WriteAllText(
                    _persistentLogPath,
                    $"===== Libertix Windows preparation {DateTime.Now:O} ====={Environment.NewLine}",
                    new UTF8Encoding(false));
            }
            catch
            {
                _persistentLogPath = null;
            }
        }

        private void SetInstallationRunning(bool running)
        {
            _isRunning = running;
            _installationState.SetInstallationRunning(running);
            CancelInstallationButton.Visibility = running ? Visibility.Visible : Visibility.Collapsed;
            if (running)
                CancelInstallationButton.IsEnabled = true;
        }

        private void FinishInstallation(bool enableBackButton)
        {
            BackButton.IsEnabled = enableBackButton;
            SetInstallationRunning(false);
        }

        private void ThrowIfCancellationRequested()
        {
            _installationCancellation.Token.ThrowIfCancellationRequested();
        }

        private async void CancelInstallationButton_Click(object sender, RoutedEventArgs e)
        {
            if (!_isRunning || _installationCancellation.IsCancellationRequested)
                return;

            var confirmation = MessageBox.Show(
                Application.Current.Resources["ApplyChangesCancelConfirm"] as string ??
                    "Annuler l'installation et restaurer Windows ?",
                Application.Current.Resources["WarningTitle"] as string ?? "Avertissement",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning);
            if (confirmation != MessageBoxResult.Yes)
                return;

            CancelInstallationButton.IsEnabled = false;
            UpdateProgress(
                (int)ProgressBar.Value,
                Application.Current.Resources["ApplyChangesCancelInProgress"] as string ??
                    "Annulation demandée. Restauration de Windows en cours...");
            Log("User requested installation cancellation.");
            _installationCancellation.Cancel();
            await TerminateActiveProcessTreeAsync();
        }

        private async Task HandleCancellationAsync()
        {
            if (_cancellationHandled)
                return;

            _cancellationHandled = true;
            CancelInstallationButton.IsEnabled = false;
            Log("Cancellation acknowledged; starting controlled rollback.");
            UpdateProgress(0, "Annulation en cours, restauration de Windows...");

            if (_activeFirmware == FirmwareType.Bios && _biosRecoveryGuardInstalled)
            {
                await FailBiosPreparationAndRollbackAsync("Installation annulée par l'utilisateur");
                return;
            }

            if (_activeFirmware == FirmwareType.Uefi)
            {
                await RollbackUefiCancellationAsync();
                return;
            }

            CleanupPendingWindowsSharePayload();
            Log("Installation cancelled before any disk change.");
            UpdateProgress(0, "Installation annulée avant toute modification du disque.");
            FinishInstallation(enableBackButton: true);
        }

        private async Task RollbackUefiCancellationAsync()
        {
            string scriptPath = Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory,
                "Scripts",
                "libertix-uefi-install.ps1");
            string powershell = ResolveSystemExecutable(
                "WindowsPowerShell\\v1.0\\powershell.exe",
                "powershell.exe");

            int exitCode = await RunStreamingProcessAsync(
                powershell,
                $"-NoProfile -ExecutionPolicy Bypass -File {QuoteArgument(scriptPath)} -Revert",
                WindowsProcessTimeouts.DiskImageOperation,
                line => Log($"ROLLBACK: {line}"),
                observeCancellation: false);

            if (_activeUefiRecovery != null)
                DeleteUefiRecoverySession(_activeUefiRecovery);
            CleanupPendingWindowsSharePayload();

            if (exitCode == 0)
            {
                if (!await BitLockerMatchesPreflightStateAfterCancellationAsync())
                {
                    Log(
                        "CRITICAL: Disk and UEFI rollback completed, but BitLocker did not " +
                        "return to its initial state.");
                    UpdateProgress(
                        0,
                        "Disque et démarrage restaurés, mais BitLocker doit être réactivé dans Windows.");
                    FinishInstallation(enableBackButton: false);
                    MessageBox.Show(
                        "L'installation a été annulée et les modifications disque/démarrage ont été " +
                        "restaurées. BitLocker a toutefois terminé ou poursuivi son déchiffrement et " +
                        "ne peut pas être réactivé automatiquement sur cette édition de Windows. " +
                        "Réactivez le chiffrement dans les paramètres Windows avant de considérer " +
                        "la restauration comme complète.",
                        "Libertix - BitLocker à réactiver",
                        MessageBoxButton.OK,
                        MessageBoxImage.Warning);
                    return;
                }

                Log("UEFI cancellation rollback completed and verified.");
                UpdateProgress(0, "Installation annulée. Windows a été restauré.");
                FinishInstallation(enableBackButton: true);
                return;
            }

            Log($"CRITICAL: UEFI cancellation rollback failed with rc={exitCode}.");
            UpdateProgress(0, "Rollback incomplet. Une intervention manuelle est requise.");
            FinishInstallation(enableBackButton: false);
            MessageBox.Show(
                "L'installation a été annulée, mais le rollback UEFI n'a pas pu être vérifié. " +
                "Ne redémarrez pas et consultez C:\\LibertixInstallLogs.",
                "Libertix - rollback incomplet",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }

        private async Task<bool> BitLockerMatchesPreflightStateAfterCancellationAsync()
        {
            StoragePreflightInfo initial = _storagePreflight;
            if (initial == null)
                return true;

            StoragePreflightInfo current;
            try
            {
                current = await RunStoragePreflightAsync(FirmwareType.Uefi);
            }
            catch (Exception ex)
            {
                Log($"CRITICAL: BitLocker state verification failed after rollback: {ex.Message}");
                return false;
            }

            bool matches =
                current.BitLockerConversionStatus == initial.BitLockerConversionStatus &&
                current.BitLockerEncryptionPercentage == initial.BitLockerEncryptionPercentage &&
                current.BitLockerProtectionStatus == initial.BitLockerProtectionStatus;
            if (!matches)
            {
                Log(
                    "BitLocker state mismatch after rollback: " +
                    $"initial conversion={initial.BitLockerConversionStatus}, " +
                    $"encrypted={initial.BitLockerEncryptionPercentage}%, " +
                    $"protection={initial.BitLockerProtectionStatus}; " +
                    $"current conversion={current.BitLockerConversionStatus}, " +
                    $"encrypted={current.BitLockerEncryptionPercentage}%, " +
                    $"protection={current.BitLockerProtectionStatus}.");
            }
            return matches;
        }

        private void SetActiveStreamingProcess(Process process)
        {
            lock (_activeProcessLock)
                _activeStreamingProcess = process;
        }

        private void ClearActiveStreamingProcess(Process process)
        {
            lock (_activeProcessLock)
            {
                if (ReferenceEquals(_activeStreamingProcess, process))
                    _activeStreamingProcess = null;
            }
        }

        private async Task TerminateActiveProcessTreeAsync()
        {
            Process process;
            lock (_activeProcessLock)
                process = _activeStreamingProcess;

            if (process == null)
                return;

            int processId;
            try
            {
                if (process.HasExited)
                    return;
                processId = process.Id;
            }
            catch
            {
                return;
            }

            await Task.Run(() =>
            {
                try { StopProcessTree(process); }
                catch (Exception ex) { Dispatcher.Invoke(() => Log($"Cancellation process-tree stop warning: {ex.Message}")); }
            });
        }

        private static void StopProcessTree(Process process)
        {
            int processId;
            try
            {
                if (process == null || process.HasExited)
                    return;
                processId = process.Id;
            }
            catch
            {
                return;
            }

            try
            {
                using (var taskKill = Process.Start(new ProcessStartInfo
                {
                    FileName = "taskkill.exe",
                    Arguments = $"/PID {processId} /T /F",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                }))
                {
                    taskKill?.WaitForExit(10000);
                }
            }
            catch
            {
                try { process.Kill(); } catch { }
            }
        }

        private void AppendPersistentLog(string line)
        {
            if (string.IsNullOrWhiteSpace(_persistentLogPath))
                return;

            try
            {
                lock (_persistentLogLock)
                    File.AppendAllText(_persistentLogPath, line + Environment.NewLine, new UTF8Encoding(false));
            }
            catch
            {
                // The GUI log remains available even if Windows refuses the persistent log write.
            }
        }
    }
}
