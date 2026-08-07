using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using Libertix.Helpers;
using Libertix.Installation;
using Libertix.Models;

namespace Libertix.Pages
{
    public partial class ApplyChanges
    {
        private async Task ExecuteUefiInstallationAsync()
        {
            if (!IsRunningAsAdministrator())
            {
                Log("ERROR: Administrator privileges are required for UEFI installation.");
                UpdateProgress(0, Localized("ApplyChangesError", "Error occurred"));
                FinishInstallation(enableBackButton: true);
                return;
            }

            string scriptPath = Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory,
                "Scripts",
                "libertix-uefi-install.ps1");
            string aria2Path = Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory,
                "Tools",
                "aria2",
                "aria2c.exe");

            if (!File.Exists(scriptPath))
            {
                Log($"ERROR: UEFI installer script missing: {scriptPath}");
                UpdateProgress(0, Localized("ApplyChangesError", "Error occurred"));
                FinishInstallation(enableBackButton: true);
                return;
            }
            if (!File.Exists(aria2Path))
            {
                Log($"ERROR: bundled aria2 missing: {aria2Path}");
                UpdateProgress(0, Localized("ApplyChangesError", "Error occurred"));
                FinishInstallation(enableBackButton: true);
                return;
            }
            if (!(_installationState.Account is AccountInfo account) ||
                string.IsNullOrWhiteSpace(account.Username) ||
                string.IsNullOrWhiteSpace(account.Password) ||
                string.IsNullOrWhiteSpace(account.ComputerName))
            {
                Log("ERROR: Linux account configuration is missing.");
                UpdateProgress(0, Localized("ApplyChangesError", "Error occurred"));
                FinishInstallation(enableBackButton: true);
                return;
            }

            InstallationSizes installationSizes =
                InstallationSizePolicy.FromRequestedGigabytes(_linuxSizeGB);
            UpdateProgress(5, Localized("ApplyChangesPreparingUefi", "Preparing UEFI installation..."));
            Log($"UEFI installer partition size: {installationSizes.FinalSizeGiB}GB");
            Log($"Filepool: {Filepool.BaseUrl}");
            Log($"aria2: bundled, max {Aria2MaxConnections} connections");
            Log($"Linux account: {account.Username}");

            string powershell = ResolveSystemExecutable(
                "WindowsPowerShell\\v1.0\\powershell.exe",
                "powershell.exe");
            UefiRecoveryState recovery = CreateUefiRecoverySession();
            _activeUefiRecovery = recovery;

            // Persist one validated contract before PowerShell is allowed to
            // mutate storage. The adapter receives paths, not a second copy of
            // account, locale, sizing, or disk policy.
            InitializeInstallationContext(
                FirmwareType.Uefi,
                recovery.RecoveryRoot,
                recovery.RecoveryRoot,
                recovery.RunId);
            string configPath = WriteProtectedUefiConfig(new
            {
                InstallationPlanPath = _installationPlanPath,
                ExecutionStatePath = _executionLedger.StatePath,
                FilepoolBaseUrl = Filepool.BaseUrl,
                Aria2ExePath = aria2Path,
                Aria2Connections = Aria2MaxConnections
            });
            File.Copy(configPath, recovery.ConfigPath, true);
            WriteUefiRecoveryState(recovery);

            int exitCode;
            try
            {
                string arguments =
                    $"-NoProfile -ExecutionPolicy Bypass -File {QuoteArgument(scriptPath)} " +
                    $"-ConfigPath {QuoteArgument(configPath)} -Force -PreserveConfig";
                exitCode = await RunStreamingProcessAsync(
                    powershell,
                    arguments,
                    WindowsProcessTimeouts.InstallerOperation,
                    HandleUefiInstallerOutput);
            }
            finally
            {
                try
                {
                    if (File.Exists(configPath))
                        File.Delete(configPath);
                }
                catch (Exception ex)
                {
                    Log($"Temporary UEFI configuration cleanup failed: {ex.Message}");
                }
            }

            if (_installationCancellation.IsCancellationRequested || exitCode == -2)
                throw new OperationCanceledException(_installationCancellation.Token);

            if (exitCode != 0)
            {
                await HandleUefiPreparationFailureAsync(
                    scriptPath,
                    powershell,
                    $"UEFI installer preparation failed with rc={exitCode}.");
                return;
            }

            try
            {
                InstallUefiRecoveryAgent(recovery, powershell);
            }
            catch (Exception ex)
            {
                Log($"ERROR: UEFI recovery agent setup failed: {ex.Message}");
                await HandleUefiPreparationFailureAsync(
                    scriptPath,
                    powershell,
                    $"UEFI recovery agent setup failed: {ex.Message}",
                    "UEFI_RECOVERY_AGENT_FAILED");
                return;
            }

            UpdateProgress(100, Localized("ApplyChangesComplete", "Partitioning complete!"));
            Log("UEFI installation preparation completed successfully.");
            RebootButton.Visibility = Visibility.Visible;
            FinishInstallation(enableBackButton: false);
        }

        private async Task HandleUefiPreparationFailureAsync(
            string scriptPath,
            string powershell,
            string reason,
            string failureCode = "UEFI_PREPARATION_FAILED")
        {
            ReloadExecutionState();
            bool rollbackVerified = _executionLedger != null &&
                _executionLedger.State.Status == InstallationStatus.RolledBack;

            if (!rollbackVerified)
            {
                RecordExecutionFailure(failureCode, reason, InstallationPhase.Windows);
                BeginExecutionRollback();
                int revertExitCode = await RunStreamingProcessAsync(
                    powershell,
                    $"-NoProfile -ExecutionPolicy Bypass -File {QuoteArgument(scriptPath)} -Revert",
                    WindowsProcessTimeouts.DiskImageOperation,
                    line => Log($"ROLLBACK: {line}"),
                    observeCancellation: false);
                Log($"UEFI automatic revert finished with rc={revertExitCode}.");
                if (revertExitCode == 0)
                    CompleteExecutionRollback();
                ReloadExecutionState();
                rollbackVerified = _executionLedger != null &&
                    _executionLedger.State.Status == InstallationStatus.RolledBack;
            }

            CleanupPendingWindowsSharePayload();
            if (rollbackVerified)
            {
                if (!await BitLockerMatchesInitialPreflightStateAfterRollbackAsync())
                {
                    ShowBitLockerRollbackIncomplete();
                    return;
                }
                Log($"{reason} Automatic rollback was verified.");
                UpdateProgress(
                    0,
                    Localized(
                        "ApplyChangesPreparationErrorRestored",
                        "Preparation failed. Windows has been restored."));
                FinishInstallation(enableBackButton: true);
                return;
            }

            Log($"CRITICAL: {reason} Rollback was not verified. Do not restart the machine.");
            UpdateProgress(
                0,
                Localized(
                    "ApplyChangesRollbackIncomplete",
                    "Rollback incomplete. Manual intervention is required."));
            FinishInstallation(enableBackButton: false);
            MessageBox.Show(
                LocalizedFormat(
                    "ApplyChangesPreparationRollbackIncompleteDetails",
                    "Preparation failed and automatic rollback could not be verified. " +
                    "Do not restart; review {0}.",
                    Path.Combine(WindowsSystemDrive, RuntimeNames.InstallationLogDirectory)),
                Localized(
                    "ApplyChangesRollbackIncompleteTitle",
                    "Libertix - Incomplete rollback"),
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }

        private UefiRecoveryState CreateUefiRecoverySession()
        {
            string runId = Guid.NewGuid().ToString("N");
            string root = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                "Libertix",
                "UefiRecovery",
                runId);
            string payloadRoot = Path.Combine(root, "payload");
            ProtectDirectoryForInstallerAndSystem(root);
            Directory.CreateDirectory(payloadRoot);

            var manifestFiles = new List<UefiRecoveryManifestFile>();
            string sourceRoot = AppDomain.CurrentDomain.BaseDirectory;
            foreach (string sourceFile in EnumerateUefiRecoveryPayloadFiles(sourceRoot))
            {
                string relativePath = sourceFile
                    .Substring(sourceRoot.Length)
                    .TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                string destinationFile = Path.Combine(payloadRoot, relativePath);
                Directory.CreateDirectory(Path.GetDirectoryName(destinationFile));
                File.Copy(sourceFile, destinationFile, true);
                var info = new FileInfo(destinationFile);
                using (var sha = SHA256.Create())
                using (var stream = File.OpenRead(destinationFile))
                {
                    manifestFiles.Add(new UefiRecoveryManifestFile
                    {
                        RelativePath = relativePath,
                        Length = info.Length,
                        Sha256 = BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant()
                    });
                }
            }

            File.WriteAllText(
                Path.Combine(root, "payload-manifest.json"),
                JsonSerializer.Serialize(new UefiRecoveryManifest { Files = manifestFiles.ToArray() }),
                new UTF8Encoding(false));

            if (_storagePreflight == null)
                throw new InvalidOperationException("UEFI recovery requires a completed storage preflight.");

            return new UefiRecoveryState
            {
                RunId = runId,
                RecoveryRoot = root,
                PayloadRoot = payloadRoot,
                ConfigPath = Path.Combine(root, "uefi-config.json"),
                TaskName = UefiRecoveryTaskPrefix + runId,
                PromptTaskName = UefiRecoveryPromptTaskPrefix + runId,
                Phase = "Preparing",
                CreatedUtc = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture),
                SystemDiskNumber = _storagePreflight.SystemDiskNumber,
                ExpectedLinuxPartitionSize =
                    InstallationSizePolicy.FromRequestedGigabytes(_linuxSizeGB).FinalSizeBytes
            };
        }

        internal static IEnumerable<string> EnumerateUefiRecoveryPayloadFiles(string sourceRoot)
        {
            string[] topLevelFiles = Directory.EnumerateFiles(
                    sourceRoot,
                    "*",
                    SearchOption.TopDirectoryOnly)
                .Where(path =>
                    Path.GetFileName(path).Equals("Libertix.exe", StringComparison.OrdinalIgnoreCase) ||
                    Path.GetExtension(path).Equals(".dll", StringComparison.OrdinalIgnoreCase) ||
                    Path.GetExtension(path).Equals(".config", StringComparison.OrdinalIgnoreCase))
                .ToArray();
            var payloadFiles = new List<string>(topLevelFiles);
            foreach (string directoryName in new[] { "Scripts", "Tools" })
            {
                string directory = Path.Combine(sourceRoot, directoryName);
                if (Directory.Exists(directory))
                    payloadFiles.AddRange(Directory.EnumerateFiles(
                        directory,
                        "*",
                        SearchOption.AllDirectories));
            }
            return payloadFiles;
        }

        private static void WriteUefiRecoveryState(UefiRecoveryState state)
        {
            // The startup recovery agent decides which phase applies from this
            // document alone; a torn write would leave it undecidable.
            string statePath = Path.Combine(state.RecoveryRoot, "state.json");
            AtomicJsonFile.Write(statePath, JsonSerializer.Serialize(state));
        }

        private void InstallUefiRecoveryAgent(UefiRecoveryState recovery, string powershell)
        {
            string agent = Path.Combine(recovery.PayloadRoot, "Scripts", "libertix-uefi-recovery-agent.ps1");
            string taskRegistrationScript = Path.Combine(
                recovery.PayloadRoot,
                "Scripts",
                "libertix-register-uefi-recovery-tasks.ps1");
            if (!File.Exists(agent) || !File.Exists(taskRegistrationScript) || !File.Exists(recovery.ConfigPath))
                throw new InvalidOperationException("Cached UEFI recovery payload is incomplete.");

            recovery.Phase = "AwaitingReboot";
            WriteUefiRecoveryState(recovery);

            string registrationArguments =
                $"-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File {QuoteArgument(taskRegistrationScript)} " +
                $"-StartupTaskName {QuoteArgument(recovery.TaskName)} " +
                $"-AgentPath {QuoteArgument(agent)} " +
                $"-PromptTaskName {QuoteArgument(recovery.PromptTaskName)} " +
                $"-StatePath {QuoteArgument(Path.Combine(recovery.RecoveryRoot, "state.json"))} " +
                $"-PromptUser {QuoteArgument(WindowsIdentity.GetCurrent().Name)}";
            var result = RunProcess(
                powershell,
                registrationArguments,
                waitMs: (int)WindowsProcessTimeouts.QuickCommand.TotalMilliseconds);
            if (result.exitCode != 0)
                throw new InvalidOperationException($"Cannot create UEFI recovery tasks: {result.output} {result.error}".Trim());

            Log($"UEFI return-to-Windows guards installed: {recovery.TaskName}, {recovery.PromptTaskName}");
        }

        private static void DeleteUefiRecoverySession(UefiRecoveryState recovery)
        {
            if (recovery == null || string.IsNullOrWhiteSpace(recovery.RecoveryRoot))
                return;
            try
            {
                if (Directory.Exists(recovery.RecoveryRoot))
                    Directory.Delete(recovery.RecoveryRoot, true);
            }
            catch
            {
                // Recovery session cleanup is best-effort. The scheduled
                // recovery guard owns the same directory and can remove it.
            }
        }

        private static string WriteProtectedUefiConfig(object config)
        {
            string directory = Path.Combine(Path.GetTempPath(), "Libertix");
            Directory.CreateDirectory(directory);
            string path = Path.Combine(directory, $"uefi-config-{Guid.NewGuid():N}.json");
            WriteProtectedInstallerFile(path, JsonSerializer.Serialize(config));
            return path;
        }

        private static void ProtectDirectoryForInstallerAndSystem(string directory)
        {
            Directory.CreateDirectory(directory);
            using (var identity = WindowsIdentity.GetCurrent())
            {
                var security = new DirectorySecurity();
                security.SetAccessRuleProtection(true, false);
                security.SetOwner(identity.User);
                var inheritance = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
                security.AddAccessRule(new FileSystemAccessRule(
                    identity.User,
                    FileSystemRights.FullControl,
                    inheritance,
                    PropagationFlags.None,
                    AccessControlType.Allow));
                security.AddAccessRule(new FileSystemAccessRule(
                    new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
                    FileSystemRights.FullControl,
                    inheritance,
                    PropagationFlags.None,
                    AccessControlType.Allow));
                Directory.SetAccessControl(directory, security);
            }
        }

        private static void WriteProtectedInstallerFile(string path, string content)
        {
            string directory = Path.GetDirectoryName(path);
            if (string.IsNullOrWhiteSpace(directory))
                throw new InvalidOperationException("Protected installer file has no parent directory.");
            Directory.CreateDirectory(directory);
            File.WriteAllText(path, content, new UTF8Encoding(false));

            using (var identity = WindowsIdentity.GetCurrent())
            {
                var security = new FileSecurity();
                security.SetAccessRuleProtection(true, false);
                security.SetOwner(identity.User);
                security.AddAccessRule(new FileSystemAccessRule(
                    identity.User,
                    FileSystemRights.FullControl,
                    AccessControlType.Allow));
                security.AddAccessRule(new FileSystemAccessRule(
                    new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
                    FileSystemRights.FullControl,
                    AccessControlType.Allow));
                File.SetAccessControl(path, security);
            }
        }

        private void HandleUefiInstallerOutput(string line)
        {
            if (string.IsNullOrWhiteSpace(line))
                return;

            Log(line);
            RefreshUefiProgressFromExecutionState();
        }

        private void RefreshUefiProgressFromExecutionState()
        {
            try
            {
                InstallationExecutionState state = InstallationStateStore.Read(_executionLedger.StatePath);
                if (state.Progress == null || state.Revision <= _lastUefiProgressRevision)
                    return;

                _lastUefiProgressRevision = state.Revision;
                HandleUefiProgressEvent(state.Progress);
            }
            catch (IOException)
            {
                // Atomic replacement can briefly race with a log callback. The
                // next output line reloads the complete document.
            }
            catch (JsonException)
            {
                // A transient read never changes UI state. The persisted
                // execution ledger remains authoritative on the next callback.
            }
        }

        private void HandleUefiProgressEvent(InstallationProgress progress)
        {
            int percent = progress.OverallPercent;
            switch (progress.Stage)
            {
                case "secure-boot":
                    UpdateProgress(percent, Localized("ApplyChangesCheckingSecureBoot", "Checking Secure Boot..."));
                    break;
                case "windows-decryption-start":
                    UpdateProgress(
                        percent,
                        LocalizedFormat(
                            "ApplyChangesDecryptingWindowsInit",
                            "Initializing Windows {0} decryption...",
                            _storagePreflight.SystemDrive));
                    break;
                case "windows-decryption":
                    int encryptedPercent = progress.DetailPercent ?? 100;
                    int decryptedPercent = 100 - encryptedPercent;
                    UpdateProgress(
                        percent,
                        LocalizedFormat(
                            "ApplyChangesDecryptingWindowsPercent",
                            "Decrypting Windows {0}: {1}%",
                            _storagePreflight.SystemDrive,
                            decryptedPercent));
                    break;
                case "windows-decryption-complete":
                    UpdateProgress(
                        percent,
                        LocalizedFormat(
                            "ApplyChangesWindowsDecrypted",
                            "Windows {0} decrypted",
                            _storagePreflight.SystemDrive));
                    break;
                case "installer-iso-download":
                    UpdateProgress(percent, Localized("ApplyChangesDownloadingMint", "Downloading Mint ISO..."));
                    break;
                case "installer-iso-ready":
                    UpdateProgress(percent, Localized("ApplyChangesMintReady", "Mint ISO ready"));
                    break;
                case "staging-partition":
                    UpdateProgress(percent, Localized("ApplyChangesCreatingUefiPartition", "Creating UEFI installer partition..."));
                    break;
                case "live-iso-download":
                    UpdateProgress(percent, Localized("ApplyChangesDownloadingUefiIso", "Downloading Libertix UEFI ISO..."));
                    break;
                case "live-iso-copy":
                    UpdateProgress(percent, Localized("ApplyChangesCopyingUefiInstaller", "Copying UEFI installer..."));
                    break;
                case "temporary-boot":
                    UpdateProgress(percent, Localized("ApplyChangesConfiguringUefiBoot", "Configuring UEFI boot..."));
                    break;
                case "complete":
                    UpdateProgress(percent, Localized("ApplyChangesUefiComplete", "UEFI preparation complete"));
                    break;
            }
        }

    }
}
