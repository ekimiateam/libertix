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
        private double _linuxSizeGB;
        private const string RecoveryTaskName = "LibertixInstallRecovery";
        private static readonly string WindowsSystemDrive =
            Path.GetPathRoot(Environment.SystemDirectory);
        private static readonly string RecoveryRoot =
            Path.Combine(WindowsSystemDrive, "LibertixInstallRecovery");
        private const string UefiRecoveryTaskPrefix = "LibertixUefiRecovery_";
        private const string UefiRecoveryPromptTaskPrefix = "LibertixUefiRecoveryPrompt_";
        private const int Aria2MaxConnections = 5;
        private static readonly string WindowsShareRoot =
            Path.Combine(WindowsSystemDrive, @"ProgramData\Libertix\WindowsShare");
        private static readonly ArtifactCatalog Artifacts =
            ArtifactCatalog.LoadFromApplicationDirectory();
        private bool _isRunning = false;
        private bool _uefiDownloadingInstallerIso = false;
        private StoragePreflightInfo _storagePreflight;
        private bool _biosRecoveryGuardInstalled;
        private string _biosInstallerDriveLetter;

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

            NavigationHelper.NavigateWithAnimation(
                NavigationService,
                new WarningConfirmation(_installationState),
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
                if (_linuxSizeGB < 20 || double.IsNaN(_linuxSizeGB) || double.IsInfinity(_linuxSizeGB))
                {
                    Log($"ERROR: Invalid Linux partition size: {_linuxSizeGB:N1}GB");
                    UpdateProgress(0, Application.Current.Resources["ApplyChangesError"] as string ?? "Error occurred");
                    FinishInstallation(enableBackButton: true);
                    return;
                }

                FirmwareType firmware = DetectFirmwareTypeOrThrow();
                _activeFirmware = firmware;
                ThrowIfCancellationRequested();
                _storagePreflight = await RunStoragePreflightAsync(firmware);
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
                    InitializeInstallationContext(
                        firmware,
                        RecoveryRoot,
                        recoveryRoot: null,
                        recoveryRunId: null);
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
                UpdateProgress(0, Application.Current.Resources["ApplyChangesError"] as string ?? "Error occurred");
                FinishInstallation(enableBackButton: true);
            }
        }

        private void RebootButton_Click(object sender, RoutedEventArgs e)
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
                (Application.Current.MainWindow as MainWindow)?.PrepareForSystemRestart();
                Process.Start("shutdown", "/r /t 0");
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
            return Application.Current.Resources[key] as string ?? englishFallback;
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

        private static void AppendLogLine(TextBox output, string line)
        {
            const double bottomTolerance = 4.0;
            bool wasAtBottom =
                output.ExtentHeight <= output.ViewportHeight ||
                output.VerticalOffset >=
                    output.ExtentHeight - output.ViewportHeight - bottomTolerance;
            double previousOffset = output.VerticalOffset;

            output.AppendText(line + Environment.NewLine);
            // TextBox updates its scroll extent after the append has returned.
            // Apply the decision on the next layout pass: follow new lines only
            // when the user was already at the bottom, otherwise preserve the
            // exact manual reading position.
            output.Dispatcher.BeginInvoke(
                DispatcherPriority.Background,
                new Action(() =>
                {
                    if (wasAtBottom)
                        output.ScrollToEnd();
                    else
                        output.ScrollToVerticalOffset(previousOffset);
                }));
        }

        private void ExpandLogsButton_Click(object sender, RoutedEventArgs e)
        {
            ExpandedLogOutput.Text = LogOutput.Text;
            ExpandedLogsOverlay.Visibility = Visibility.Visible;
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
