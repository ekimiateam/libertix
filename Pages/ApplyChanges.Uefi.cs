using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
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
                UpdateProgress(0, Application.Current.Resources["ApplyChangesError"] as string ?? "Error occurred");
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
                UpdateProgress(0, Application.Current.Resources["ApplyChangesError"] as string ?? "Error occurred");
                FinishInstallation(enableBackButton: true);
                return;
            }
            if (!File.Exists(aria2Path))
            {
                Log($"ERROR: bundled aria2 missing: {aria2Path}");
                UpdateProgress(0, Application.Current.Resources["ApplyChangesError"] as string ?? "Error occurred");
                FinishInstallation(enableBackButton: true);
                return;
            }
            if (!(_installationState.Account is AccountInfo account) ||
                string.IsNullOrWhiteSpace(account.Username) ||
                string.IsNullOrWhiteSpace(account.Password) ||
                string.IsNullOrWhiteSpace(account.ComputerName))
            {
                Log("ERROR: Linux account configuration is missing.");
                UpdateProgress(0, Application.Current.Resources["ApplyChangesError"] as string ?? "Error occurred");
                FinishInstallation(enableBackButton: true);
                return;
            }

            InstallationSizes installationSizes =
                InstallationSizePolicy.FromRequestedGigabytes(_linuxSizeGB);
            UpdateProgress(5, Localized("ApplyChangesPreparingUefi", "Preparing UEFI installation..."));
            Log($"UEFI installer partition size: {installationSizes.FinalSizeGiB}GB");
            Log($"Filepool: {FilepoolConfig.BaseUrl}");
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
                ExecutionStatePath = _executionStatePath,
                FilepoolBaseUrl = FilepoolConfig.BaseUrl,
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
                try { if (File.Exists(configPath)) File.Delete(configPath); } catch { }
            }

            if (_installationCancellation.IsCancellationRequested || exitCode == -2)
                throw new OperationCanceledException(_installationCancellation.Token);

            if (exitCode != 0)
            {
                ReloadExecutionState();
                CleanupPendingWindowsSharePayload();
                Log($"ERROR: UEFI installer preparation failed with rc={exitCode}");
                UpdateProgress(0, Application.Current.Resources["ApplyChangesError"] as string ?? "Error occurred");
                FinishInstallation(enableBackButton: true);
                return;
            }

            try
            {
                InstallUefiRecoveryAgent(recovery, powershell);
            }
            catch (Exception ex)
            {
                Log($"ERROR: UEFI recovery agent setup failed: {ex.Message}");
                ReloadExecutionState();
                RecordExecutionFailure(
                    "UEFI_RECOVERY_AGENT_FAILED",
                    ex.Message,
                    InstallationPhase.Windows);
                BeginExecutionRollback();
                var revert = await Task.Run(() => RunProcess(
                    powershell,
                    $"-NoProfile -ExecutionPolicy Bypass -File {QuoteArgument(scriptPath)} -Revert",
                    (int)WindowsProcessTimeouts.DiskImageOperation.TotalMilliseconds));
                Log($"UEFI revert after recovery-agent failure: rc={revert.exitCode}");
                if (revert.exitCode == 0)
                    CompleteExecutionRollback();
                CleanupPendingWindowsSharePayload();
                throw;
            }

            UpdateProgress(100, Application.Current.Resources["ApplyChangesComplete"] as string ?? "Partitioning complete!");
            Log("UEFI installation preparation completed successfully.");
            RebootButton.Visibility = Visibility.Visible;
            FinishInstallation(enableBackButton: false);
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
            Directory.CreateDirectory(payloadRoot);

            var manifestFiles = new List<UefiRecoveryManifestFile>();
            string sourceRoot = AppDomain.CurrentDomain.BaseDirectory;
            foreach (string sourceFile in Directory.EnumerateFiles(sourceRoot, "*", SearchOption.AllDirectories))
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

        private static void WriteUefiRecoveryState(UefiRecoveryState state)
        {
            string statePath = Path.Combine(state.RecoveryRoot, "state.json");
            File.WriteAllText(statePath, JsonSerializer.Serialize(state), new UTF8Encoding(false));
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
            catch { }
        }

        private static string WriteProtectedUefiConfig(object config)
        {
            string directory = Path.Combine(Path.GetTempPath(), "Libertix");
            Directory.CreateDirectory(directory);
            string path = Path.Combine(directory, $"uefi-config-{Guid.NewGuid():N}.json");
            File.WriteAllText(path, JsonSerializer.Serialize(config), new UTF8Encoding(false));

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
            return path;
        }

        private void HandleUefiInstallerOutput(string line)
        {
            if (string.IsNullOrWhiteSpace(line))
                return;

            Log(line);

            string normalized = line.ToLowerInvariant();
            if (normalized.Contains("checking secure boot"))
                UpdateProgress(8, Localized("ApplyChangesCheckingSecureBoot", "Checking Secure Boot..."));
            else if (normalized.Contains("disabling bitlocker"))
                UpdateProgress(18, Localized("ApplyChangesDecryptingWindowsInit", "Initializing Windows C: decryption..."));
            else if (normalized.Contains("windows c: decrypted"))
                UpdateProgress(28, Localized("ApplyChangesWindowsDecrypted", "Windows C: decrypted"));
            else if (normalized.Contains("waiting for c: decryption") || normalized.Contains("decryptioninprogress"))
                UpdateDecryptionProgress(line);
            else if (normalized.Contains("downloading mint iso"))
            {
                _uefiDownloadingInstallerIso = false;
                UpdateProgress(30, Localized("ApplyChangesDownloadingMint", "Downloading Mint ISO..."));
            }
            else if (normalized.Contains("mint iso ready"))
            {
                _uefiDownloadingInstallerIso = false;
                UpdateProgress(45, Localized("ApplyChangesMintReady", "Mint ISO ready"));
            }
            else if (normalized.Contains("creating") && normalized.Contains("libertixefi"))
                UpdateProgress(52, Localized("ApplyChangesCreatingUefiPartition", "Creating UEFI installer partition..."));
            else if (normalized.Contains("downloading libertix uefi iso"))
            {
                _uefiDownloadingInstallerIso = true;
                UpdateProgress(62, Localized("ApplyChangesDownloadingUefiIso", "Downloading Libertix UEFI ISO..."));
            }
            else if (normalized.Contains("libertix-installer-uefi.iso"))
            {
                _uefiDownloadingInstallerIso = true;
            }
            else if (normalized.Contains("copying iso contents"))
                UpdateProgress(78, Localized("ApplyChangesCopyingUefiInstaller", "Copying UEFI installer..."));
            else if (normalized.Contains("configuring one-time uefi boot entry"))
                UpdateProgress(90, Localized("ApplyChangesConfiguringUefiBoot", "Configuring UEFI boot..."));
            else if (normalized.Contains("complete. next boot"))
                UpdateProgress(100, Localized("ApplyChangesUefiComplete", "UEFI preparation complete"));

            var ariaProgress = Regex.Match(line, @"\((\d{1,3})%\)");
            if (ariaProgress.Success && int.TryParse(ariaProgress.Groups[1].Value, out int percent))
            {
                int clamped = Math.Max(0, Math.Min(100, percent));
                if (_uefiDownloadingInstallerIso)
                {
                    UpdateProgress(
                        62 + (clamped * 10 / 100),
                        LocalizedFormat(
                            "ApplyChangesDownloadingUefiIsoPercent",
                            "Downloading Libertix UEFI ISO... {0}%",
                            clamped));
                }
                else
                {
                    UpdateProgress(
                        30 + (clamped * 15 / 100),
                        LocalizedFormat(
                            "ApplyChangesDownloadingMintPercent",
                            "Downloading Mint ISO... {0}%",
                            clamped));
                }
            }
        }

        private void UpdateDecryptionProgress(string line)
        {
            var encryptedMatch = Regex.Match(line, @"(\d+(?:[.,]\d+)?)%\s+encrypted", RegexOptions.IgnoreCase);
            if (!encryptedMatch.Success)
            {
                encryptedMatch = Regex.Match(line, @"DecryptionInProgress\s+(\d+(?:[.,]\d+)?)", RegexOptions.IgnoreCase);
            }
            if (!encryptedMatch.Success)
            {
                UpdateProgress(18, Localized("ApplyChangesDecryptingWindows", "Decrypting Windows C:..."));
                return;
            }

            if (!double.TryParse(
                encryptedMatch.Groups[1].Value.Replace(',', '.'),
                NumberStyles.Float,
                CultureInfo.InvariantCulture,
                out double encryptedPercent))
            {
                UpdateProgress(18, Localized("ApplyChangesDecryptingWindows", "Decrypting Windows C:..."));
                return;
            }

            int decryptedPercent = Math.Max(0, Math.Min(100, (int)Math.Round(100 - encryptedPercent)));
            int overallProgress = 18 + (decryptedPercent * 10 / 100);
            UpdateProgress(
                overallProgress,
                LocalizedFormat(
                    "ApplyChangesDecryptingWindowsPercent",
                    "Decrypting Windows C: {0}%",
                    decryptedPercent));
        }
    }
}
