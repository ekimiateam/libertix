using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using Libertix.Dialogs;
using Libertix.Helpers;
using Libertix.Installation;

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
        private bool _cancellationDisposed;
        private string _persistentLogPath;

        private void InitializeInstallationControls()
        {
            try
            {
                string logRoot = Path.Combine(
                    WindowsSystemDrive,
                    RuntimeNames.InstallationLogDirectory);
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

            bool confirmed = LocalizedConfirmationDialog.Show(
                Application.Current.MainWindow,
                Localized("WarningTitle", "Warning"),
                Localized(
                    "ApplyChangesCancelConfirm",
                    "Cancel the installation and restore Windows?"),
                Localized("ConfirmationYes", "Yes"),
                Localized("ConfirmationNo", "No"));
            if (!confirmed)
                return;

            CancelInstallationButton.IsEnabled = false;
            UpdateProgress(
                (int)ProgressBar.Value,
                Localized(
                    "ApplyChangesCancelInProgress",
                    "Cancellation requested. Restoring Windows..."));
            Log("User requested installation cancellation.");
            _installationCancellation.Cancel();
            // The tracked streaming loop owns termination and does not return
            // until it has verified that the process tree stopped. A second
            // concurrent taskkill here can race that verification.
            await Task.Yield();
        }

        private async Task HandleCancellationAsync()
        {
            if (_cancellationHandled)
                return;

            _cancellationHandled = true;
            CancelInstallationButton.IsEnabled = false;
            Log("Cancellation acknowledged; starting controlled rollback.");
            UpdateProgress(
                0,
                Localized(
                    "ApplyChangesRollbackInProgress",
                    "Cancellation in progress. Restoring Windows..."));

            if (_activeFirmware == FirmwareType.Bios && _biosRecoveryGuardInstalled)
            {
                await FailBiosPreparationAndRollbackAsync(
                    "Installation cancelled by the user",
                    Localized(
                        "ApplyChangesCancelledRestored",
                        "Installation cancelled. Windows has been restored."));
                return;
            }

            if (_activeFirmware == FirmwareType.Uefi && _activeUefiRecovery != null)
            {
                await RollbackUefiCancellationAsync();
                return;
            }

            CleanupPendingWindowsSharePayload();
            CleanupTransactionDownloadsBestEffort();
            Log("Installation cancelled before any disk change.");
            UpdateProgress(
                0,
                Localized(
                    "ApplyChangesCancelledBeforeDiskChange",
                    "Installation cancelled before any disk change."));
            FinishInstallation(enableBackButton: true);
        }

        private async Task RollbackUefiCancellationAsync()
        {
            string scriptPath = Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory,
                "Scripts",
                "libertix-uefi-install.ps1");
            string powershell = WindowsProcessRunner.ResolvePowerShell();

            // PowerShell owns the UEFI state while it runs. Reload its latest
            // durable snapshot before recording the cancellation transition so
            // the GUI never overwrites newer completed steps with stale data.
            ReloadExecutionState();
            RecordExecutionFailure(
                "UEFI_INSTALLATION_CANCELLED",
                "Installation cancelled by the user.",
                InstallationPhase.Windows);
            BeginExecutionRollback();

            StreamingProcessResult processResult = await RunStreamingProcessAsync(
                powershell,
                $"-NoProfile -ExecutionPolicy Bypass -File {QuoteArgument(scriptPath)} -Revert " +
                $"-ExpectedRecoveryRunId {QuoteArgument(_activeUefiRecovery.RunId)}",
                WindowsProcessTimeouts.DiskImageOperation,
                line => Log($"ROLLBACK: {line}"),
                observeCancellation: false);

            CleanupPendingWindowsSharePayload();

            if (
                processResult.Completion == StreamingProcessCompletion.Exited &&
                processResult.ExitCode == 0
            )
            {
                if (!await BitLockerMatchesInitialPreflightStateAfterRollbackAsync())
                {
                    CleanupTransactionDownloadsBestEffort();
                    ShowBitLockerRollbackIncomplete();
                    return;
                }

                // Preserve diagnostics in the log archive before removing the
                // temporary recovery payload from the completed transaction.
                CompleteExecutionRollback();
                CleanupTransactionDownloadsBestEffort();
                await FinalizeUefiRecoveryAfterVerifiedRollbackAsync();
                Log("UEFI cancellation rollback completed and verified.");
                UpdateProgress(
                    0,
                    Localized(
                        "ApplyChangesCancelledRestored",
                        "Installation cancelled. Windows has been restored."));
                FinishInstallation(enableBackButton: true);
                return;
            }

            Log($"CRITICAL: UEFI cancellation rollback failed with rc={processResult.ExitCode} ({processResult.Completion}).");
            UpdateProgress(
                0,
                Localized(
                    "ApplyChangesRollbackIncomplete",
                    "Rollback incomplete. Manual intervention is required."));
            FinishInstallation(enableBackButton: false);
            MessageBox.Show(
                LocalizedFormat(
                    "ApplyChangesUefiRollbackIncompleteDetails",
                    "The installation was cancelled, but the UEFI rollback could not be verified. " +
                    "Do not restart; review {0}.",
                    Path.Combine(WindowsSystemDrive, RuntimeNames.InstallationLogDirectory)),
                Localized("ApplyChangesRollbackIncompleteTitle", "Libertix - Incomplete rollback"),
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }

        private async Task<bool> BitLockerMatchesInitialPreflightStateAfterRollbackAsync()
        {
            StoragePreflightInfo initial = _storagePreflight;
            if (initial == null)
                return true;

            StoragePreflightInfo current;
            try
            {
                current = await RunStoragePreflightAsync(
                    initial.Firmware,
                    decryptBitLocker: false);
            }
            catch (Exception ex)
            {
                Log($"CRITICAL: BitLocker state verification failed after rollback: {ex.Message}");
                return false;
            }

            bool matches =
                current.BitLockerConversionStatus == initial.InitialBitLockerConversionStatus &&
                current.BitLockerEncryptionPercentage == initial.InitialBitLockerEncryptionPercentage &&
                current.BitLockerProtectionStatus == initial.InitialBitLockerProtectionStatus;
            if (!matches)
            {
                Log(
                    "BitLocker state mismatch after rollback: " +
                    $"initial conversion={initial.InitialBitLockerConversionStatus}, " +
                    $"encrypted={initial.InitialBitLockerEncryptionPercentage}%, " +
                    $"protection={initial.InitialBitLockerProtectionStatus}; " +
                    $"current conversion={current.BitLockerConversionStatus}, " +
                    $"encrypted={current.BitLockerEncryptionPercentage}%, " +
                    $"protection={current.BitLockerProtectionStatus}.");
            }
            return matches;
        }

        private void ShowBitLockerRollbackIncomplete()
        {
            Log(
                "CRITICAL: Disk and boot rollback completed, but BitLocker did not " +
                "return to its initial state.");
            UpdateProgress(
                0,
                Localized(
                    "ApplyChangesBitLockerReenable",
                    "Disk and boot restored, but BitLocker must be re-enabled in Windows."));
            FinishInstallation(enableBackButton: false);
            MessageBox.Show(
                Localized(
                    "ApplyChangesBitLockerReenableDetails",
                    "Disk and boot changes were restored, but BitLocker continued or completed " +
                    "decryption and cannot be re-enabled automatically on this Windows edition. " +
                    "Re-enable encryption in Windows settings before considering recovery complete."),
                Localized(
                    "ApplyChangesBitLockerReenableTitle",
                    "Libertix - Re-enable BitLocker"),
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
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
