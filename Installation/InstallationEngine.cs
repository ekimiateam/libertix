using System;
using System.Globalization;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Libertix.Helpers;
using Libertix.Models;

namespace Libertix.Installation
{
    /// <summary>
    /// Runs the Windows-side installation, cancellation and rollback for one
    /// wizard session. It owns every disk, boot and download operation and
    /// reports to an <see cref="IInstallationView"/> without touching WPF.
    /// </summary>
    internal sealed partial class InstallationEngine
    {
        private readonly InstallationState _installationState;
        private readonly IInstallationView _view;
        // Process output callbacks are posted here so every engine callback runs
        // on the thread that started the installation, as the page did before.
        private readonly SynchronizationContext _eventContext;
        private FilepoolConfig Filepool { get; }
        private StartupOptions RuntimeOptions { get; }
        private string LocalArtifactPath(string fileName) => Path.Combine(
            Filepool.LocalDirectory ?? AppDomain.CurrentDomain.BaseDirectory,
            fileName);
        private double _linuxSizeGB;
        private static readonly string WindowsSystemDrive =
            Path.GetPathRoot(Environment.SystemDirectory);
        private static readonly string RecoveryRoot =
            Path.Combine(WindowsSystemDrive, RuntimeNames.BiosRecoveryDirectory);
        private const string UefiRecoveryTaskPrefix = "LibertixUefiRecovery_";
        private const string UefiRecoveryPromptTaskPrefix = "LibertixUefiRecoveryPrompt_";
        private static int Aria2MaxConnections =>
            InstallationPolicy.Current.Download.Aria2MaximumConnections;
        private static int DownloadMaximumAttempts =>
            InstallationPolicy.Current.Download.MaximumAttempts;
        private static int DownloadRetryBaseDelaySeconds =>
            InstallationPolicy.Current.Download.RetryBaseDelaySeconds;
        private static readonly string WindowsShareRoot =
            Path.Combine(WindowsSystemDrive, @"ProgramData\Libertix\WindowsShare");
        private static readonly Lazy<ArtifactCatalog> ArtifactCatalogHolder =
            new Lazy<ArtifactCatalog>(ArtifactCatalog.LoadFromApplicationDirectory);
        private static ArtifactCatalog Artifacts => ArtifactCatalogHolder.Value;
        private bool _isRunning = false;
        private int _lastUefiProgressRevision = -1;
        private int _lastProgressPercent;
        private StoragePreflightInfo _storagePreflight;
        private bool _biosRecoveryGuardInstalled;
        private string _biosInstallerDriveLetter;
        private bool _unattendedRebootReady;
        private bool _unattendedFailurePublished;

        private string BiosInstallerRoot
        {
            get
            {
                if (string.IsNullOrWhiteSpace(_biosInstallerDriveLetter))
                    throw new InvalidOperationException("BIOS installer drive is not mounted.");
                return _biosInstallerDriveLetter + @":\";
            }
        }

        /// <param name="filepool">Artifact source chosen at application startup.</param>
        /// <param name="runtimeOptions">Command-line options validated at application startup.</param>
        public InstallationEngine(
            InstallationState installationState,
            FilepoolConfig filepool,
            StartupOptions runtimeOptions,
            IInstallationView view)
        {
            _installationState = installationState ??
                throw new ArgumentNullException(nameof(installationState));
            Filepool = filepool ?? throw new ArgumentNullException(nameof(filepool));
            RuntimeOptions = runtimeOptions ?? throw new ArgumentNullException(nameof(runtimeOptions));
            _view = view ?? throw new ArgumentNullException(nameof(view));
            _eventContext = SynchronizationContext.Current;
            InitializePersistentLog();
            if (_installationState.SelectedLinuxSizeGiB is double linuxSize)
                _linuxSizeGB = linuxSize;
        }

        public bool IsRunning => _isRunning;

        /// <summary>True when no unknown process state or unverified rollback forbids a retry.</summary>
        public bool CanRetry =>
            CanRetryAfterFailure(true, _processTerminationUnverified, _rollbackVerificationPending);

        public bool CanRequestCancellation =>
            _isRunning && !_installationCancellation.IsCancellationRequested;

        /// <summary>Runs the complete Windows-side preparation; failures end in a visible state.</summary>
        public async Task RunAsync()
        {
            try
            {
                await UnattendedWorkflow.PublishStageAndWaitAsync("installation-started");
                await StartInstallationAsync();
            }
            catch (Exception ex)
            {
                LogException("Installation startup failed", ex);
                UpdateProgress(0, _rollbackVerificationPending
                    ? Localized("ApplyChangesRollbackIncomplete", "Rollback incomplete. Manual intervention is required.")
                    : Localized("ApplyChangesError", "Error occurred"));
                PublishUnattendedFailure("installation-start-failed", ex.Message);
                FinishInstallation(allowRetry: true);
            }
        }

        /// <summary>Starts the controlled rollback after the user confirmed cancellation.</summary>
        public void RequestCancellation()
        {
            if (!CanRequestCancellation)
                return;

            _view.DisableCancellation();
            UpdateProgress(
                _lastProgressPercent,
                Localized(
                    "ApplyChangesCancelInProgress",
                    "Cancellation requested. Restoring Windows..."));
            Log("User requested installation cancellation.");
            // The tracked streaming loop owns termination and does not return
            // until it has verified that the process tree stopped. A second
            // concurrent taskkill here could race that verification.
            _installationCancellation.Cancel();
        }

        /// <summary>Releases the cancellation source once the screen closes after a finished run.</summary>
        public void DisposeIfIdle()
        {
            if (_isRunning || _cancellationDisposed)
                return;

            _installationCancellation.Dispose();
            _cancellationDisposed = true;
        }

        private async Task StartInstallationAsync()
        {
            if (_isRunning) return;

            SetInstallationRunning(true);
            _view.SetRetryEnabled(false);

            try
            {
                if (_linuxSizeGB < InstallationSizePolicy.MinimumFinalSizeGiB ||
                    double.IsNaN(_linuxSizeGB) ||
                    double.IsInfinity(_linuxSizeGB))
                {
                    Log($"ERROR: Invalid Linux partition size: {_linuxSizeGB:N1}GB");
                    UpdateProgress(0, Localized("ApplyChangesError", "Error occurred"));
                    PublishUnattendedFailure(
                        "invalid-linux-partition-size",
                        $"Invalid Linux partition size: {_linuxSizeGB:N1}GB");
                    FinishInstallation(allowRetry: true);
                    return;
                }

                FirmwareType firmware = DetectFirmwareTypeOrThrow();
                if (_installationState.SelectedInstallationTarget != null)
                    Log("WARNING: " + string.Format(CultureInfo.CurrentCulture,
                        Localization.GetString("ResizeDiskSecondaryWarning"),
                        _installationState.SelectedInstallationTarget.Drive,
                        WindowsSystemDrive));
                _activeFirmware = firmware;
                if (firmware == FirmwareType.Uefi)
                    AssertSelectedDistroSecureBootCompatibility();
                ThrowIfCancellationRequested();
                // The wizard preflight prevents an invalid topology from being selected.
                // Re-run it immediately before mutation because disk layout and BitLocker
                // state may have changed while the user completed the remaining pages.
                // The first pass is deliberately read-only. Firmware-specific
                // recovery must be armed before BitLocker or storage is changed.
                _storagePreflight = await RunStoragePreflightAsync(
                    firmware,
                    decryptBitLocker: false);
                ThrowIfCancellationRequested();
                if (firmware == FirmwareType.Uefi)
                {
                    if (!await RecoverPreviousUefiTransactionAsync())
                        return;
                    // Recovery may have restored the Windows partition and power
                    // settings. Re-read the topology before creating a new plan.
                    _storagePreflight = await RunStoragePreflightAsync(
                        firmware,
                        decryptBitLocker: false);
                    ThrowIfCancellationRequested();
                }
                await ReadWindowsSharingInventoryAsync();
                ThrowIfCancellationRequested();
                if (!await PrepareWindowsSharePayloadAsync())
                    throw new InvalidOperationException("Windows read-only Linux sharing payload preparation failed.");
                ThrowIfCancellationRequested();

                if (firmware == FirmwareType.Uefi)
                {
                    Log("UEFI firmware detected. Using Libertix UEFI workflow.");
                    await ExecuteUefiInstallationAsync();
                }
                else if (firmware == FirmwareType.Bios)
                {
                    Log("BIOS firmware detected. Using existing BIOS workflow.");
                    ArchivePreviousBiosRecoverySession();
                    string biosRecoveryRunId = Guid.NewGuid().ToString("N");
                    await InitializeInstallationContextAsync(
                        firmware,
                        RecoveryRoot,
                        RecoveryRoot,
                        biosRecoveryRunId);
                    await ExecutePartitioningAsync();
                }
                else
                {
                    throw new InvalidOperationException("Unsupported firmware type.");
                }
            }
            catch (OperationCanceledException)
            {
                await HandleCancellationAsync();
            }
            catch (UnterminatedProcessException ex)
            {
                _processTerminationUnverified = true;
                RecordExecutionFailure(
                    "WINDOWS_PROCESS_TERMINATION_UNVERIFIED",
                    ex.Message,
                    InstallationPhase.Windows);
                Log($"CRITICAL: {ex.Message} Rollback and retry are disabled while the process state is unknown.");
                UpdateProgress(
                    0,
                    Localized(
                        "ApplyChangesRollbackIncomplete",
                        "Rollback incomplete. Manual intervention is required."));
                PublishUnattendedFailure(
                    "windows-process-termination-unverified",
                    ex.Message);
                FinishInstallation(allowRetry: false);
            }
            catch (Exception ex)
            {
                if (_biosRecoveryGuardInstalled)
                {
                    WritePersistentDiagnostic("Unexpected BIOS preparation failure", ex);
                    await FailBiosPreparationAndRollbackAsync($"Unexpected preparation failure: {ex.Message}");
                    return;
                }
                RecordExecutionFailure(
                    "WINDOWS_PREPARATION_FAILED",
                    ex.Message,
                    InstallationPhase.Windows);
                LogException(null, ex);
                CleanupPendingWindowsSharePayload();
                CleanupPendingWindowsPreferenceMigrationBundle();
                UpdateProgress(0, Localized("ApplyChangesError", "Error occurred"));
                PublishUnattendedFailure(
                    "windows-preparation-failed",
                    ex.Message);
                FinishInstallation(allowRetry: true);
            }
        }

        internal void UpdateProgress(int percent, string step)
        {
            _lastProgressPercent = percent;
            _view.ShowProgress(percent, step);
        }

        /// <summary>
        /// Resolves runtime status text from the active language dictionary.
        /// Progress messages are created in code, so normal XAML bindings do
        /// not translate them automatically.
        /// </summary>
        private static string Localized(string key, string englishFallback)
        {
            return Localization.GetString(key, englishFallback);
        }

        private static string LocalizedFormat(string key, string englishFallback, params object[] args)
        {
            return string.Format(
                CultureInfo.CurrentCulture,
                Localized(key, englishFallback),
                args);
        }

        internal void Log(string message)
        {
            message = WindowsProcessRunner.NormalizeTerminalText(message);
            string line = $"[{DateTime.Now:HH:mm:ss}] {message}";
            _view.AppendLog(line);
            AppendPersistentLog(line);
            ApplicationLogger.Write($"INSTALLATION: {message}");
        }

        /// <summary>
        /// Shows the short reason to the user and keeps the exception type and
        /// stack trace in the persistent logs for diagnosis.
        /// </summary>
        private void LogException(string context, Exception exception)
        {
            string prefix = string.IsNullOrEmpty(context) ? "ERROR" : "ERROR: " + context;
            Log($"{prefix}: {exception.Message}");
            WritePersistentDiagnostic(context ?? "Installation failure", exception);
        }

        private void WritePersistentDiagnostic(string context, Exception exception)
        {
            string details = $"DIAGNOSTIC: {context}: {exception}";
            AppendPersistentLog($"[{DateTime.Now:HH:mm:ss}] {details}");
            ApplicationLogger.Write($"INSTALLATION: {details}");
        }

        private void PostEvent(Action action)
        {
            if (_eventContext == null)
                action();
            else
                _eventContext.Post(_ => action(), null);
        }
    }
}
