using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Globalization;
using System.Linq;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Security.Cryptography;
using System.Security.AccessControl;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Libertix.Helpers;
using Libertix.Dialogs;
using Libertix.Installation;
using Libertix.Models;

namespace Libertix.Pages
{
    public partial class ApplyChanges : Page
    {
        private readonly InstallationState _installationState;
        private FilepoolConfig Filepool => ((App)Application.Current).Filepool;
        private double _linuxSizeGB;
        private static readonly string WindowsSystemDrive =
            Path.GetPathRoot(Environment.SystemDirectory);
        private static readonly string RecoveryRoot =
            Path.Combine(WindowsSystemDrive, RuntimeNames.BiosRecoveryDirectory);
        private const string UefiRecoveryTaskPrefix = "LibertixUefiRecovery_";
        private const string UefiRecoveryPromptTaskPrefix = "LibertixUefiRecoveryPrompt_";
        private static int Aria2MaxConnections =>
            InstallationPolicy.Current.Download.Aria2MaximumConnections;
        private static readonly string WindowsShareRoot =
            Path.Combine(WindowsSystemDrive, @"ProgramData\Libertix\WindowsShare");
        private static readonly Lazy<ArtifactCatalog> ArtifactCatalogHolder =
            new Lazy<ArtifactCatalog>(ArtifactCatalog.LoadFromApplicationDirectory);
        private static ArtifactCatalog Artifacts => ArtifactCatalogHolder.Value;
        private bool _isRunning = false;
        private int _lastUefiProgressRevision = -1;
        private StoragePreflightInfo _storagePreflight;
        private bool _biosRecoveryGuardInstalled;
        private string _biosInstallerDriveLetter;
        private bool _logOutputAutoScroll = true;
        private bool _expandedLogOutputAutoScroll = true;

        private string BiosInstallerRoot
        {
            get
            {
                if (string.IsNullOrWhiteSpace(_biosInstallerDriveLetter))
                    throw new InvalidOperationException("BIOS installer drive is not mounted.");
                return _biosInstallerDriveLetter + @":\";
            }
        }

        public ApplyChanges() : this(((App)Application.Current).InstallationState)
        {
        }

        public ApplyChanges(InstallationState installationState)
        {
            _installationState = installationState ?? throw new ArgumentNullException(nameof(installationState));
            InitializeComponent();
            InitializeInstallationControls();
            LoadSummary();
            Loaded += ApplyChanges_Loaded;
            Unloaded += ApplyChanges_Unloaded;
        }

        private void ApplyChanges_Unloaded(object sender, RoutedEventArgs e)
        {
            if (_isRunning || _cancellationDisposed)
                return;

            _installationCancellation.Dispose();
            _cancellationDisposed = true;
        }

        private async void ApplyChanges_Loaded(object sender, RoutedEventArgs e)
        {
            await StartInstallationAsync();
        }

        private void LoadSummary()
        {
            if (_installationState.SelectedLinuxSizeGiB is double linuxSize)
                _linuxSizeGB = linuxSize;
        }

        private void BackButton_Click(object sender, RoutedEventArgs e)
        {
            if (_isRunning) return;

            Page retryPage = _installationState.Account?.HasPassword == true
                ? (Page)new WarningConfirmation(_installationState)
                : new AccountCreation(_installationState);
            NavigationHelper.NavigateWithAnimation(
                NavigationService,
                retryPage,
                TimeSpan.FromSeconds(0.3),
                slideLeft: false);
        }

        private async Task StartInstallationAsync()
        {
            if (_isRunning) return;

            SetInstallationRunning(true);
            BackButton.IsEnabled = false;

            try
            {
                if (_linuxSizeGB < InstallationSizePolicy.MinimumFinalSizeGiB ||
                    double.IsNaN(_linuxSizeGB) ||
                    double.IsInfinity(_linuxSizeGB))
                {
                    Log($"ERROR: Invalid Linux partition size: {_linuxSizeGB:N1}GB");
                    UpdateProgress(0, Localized("ApplyChangesError", "Error occurred"));
                    FinishInstallation(enableBackButton: true);
                    return;
                }

                FirmwareType firmware = DetectFirmwareTypeOrThrow();
                _activeFirmware = firmware;
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
                    string biosRecoveryRunId = Guid.NewGuid().ToString("N");
                    InitializeInstallationContext(
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
                FinishInstallation(enableBackButton: false);
            }
            catch (Exception ex)
            {
                if (_biosRecoveryGuardInstalled)
                {
                    await FailBiosPreparationAndRollbackAsync($"Unexpected preparation failure: {ex.Message}");
                    return;
                }
                RecordExecutionFailure(
                    "WINDOWS_PREPARATION_FAILED",
                    ex.Message,
                    InstallationPhase.Windows);
                Log($"ERROR: {ex.Message}");
                CleanupPendingWindowsSharePayload();
                UpdateProgress(0, Localized("ApplyChangesError", "Error occurred"));
                FinishInstallation(enableBackButton: true);
            }
        }

        private async void RebootButton_Click(object sender, RoutedEventArgs e)
        {
            bool confirmed = LocalizedConfirmationDialog.Show(
                Application.Current.MainWindow,
                Localized("WarningTitle", "Warning"),
                Localized(
                    "ApplyChangesRebootConfirm",
                    "The computer will restart to complete the installation. Continue?"),
                Localized("ConfirmationYes", "Yes"),
                Localized("ConfirmationNo", "No"));

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
                }
                catch (Exception ex)
                {
                    mainWindow?.CancelSystemRestartPreparation();
                    RebootButton.IsEnabled = true;
                    Log($"ERROR: Restart request failed: {ex.Message}");
                    UpdateProgress(
                        100,
                        Localized(
                            "ApplyChangesRebootFailed",
                            "Windows refused the restart request. Try again."));
                }
            }
        }

        private void UpdateProgress(int percent, string step)
        {
            Dispatcher.Invoke(() =>
            {
                ProgressBar.Value = percent;
                ProgressText.Text = $"{percent}%";
                CurrentStepText.Text = step;
            });
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

        private void Log(string message)
        {
            message = WindowsProcessRunner.NormalizeTerminalText(message);
            string line = $"[{DateTime.Now:HH:mm:ss}] {message}";
            Dispatcher.Invoke(() =>
            {
                AppendLogLine(LogOutput, line);
                if (ExpandedLogsOverlay.Visibility == Visibility.Visible)
                    AppendLogLine(ExpandedLogOutput, line);
            });
            AppendPersistentLog(line);
            ApplicationLogger.Write($"INSTALLATION: {message}");
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
