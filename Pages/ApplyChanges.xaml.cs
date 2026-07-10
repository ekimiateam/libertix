using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Globalization;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Security.Cryptography;
using System.Security.AccessControl;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Libertix.Helpers;
using Libertix.Models;

namespace Libertix.Pages
{
    public partial class ApplyChanges : Page
    {
        private double _linuxSizeGB;
        private const string RecoveryTaskName = "LibertixInstallRecovery";
        private const string RecoveryRoot = @"C:\LibertixInstallRecovery";
        private const string UefiRecoveryTaskPrefix = "LibertixUefiRecovery_";
        private const string UefiRecoveryPromptTaskPrefix = "LibertixUefiRecoveryPrompt_";
        private const int Aria2MaxConnections = 5;
        private bool _isRunning = false;
        private bool _uefiDownloadingInstallerIso = false;
        private StoragePreflightInfo _storagePreflight;
        private bool _biosRecoveryGuardInstalled;

        private sealed class StoragePreflightInfo
        {
            public FirmwareType Firmware { get; set; }
            public string SystemDrive { get; set; }
            public int SystemDiskNumber { get; set; }
            public int SystemPartitionNumber { get; set; }
            public long SystemPartitionOffset { get; set; }
            public long SystemPartitionSize { get; set; }
            public int BootPartitionNumber { get; set; }
            public long BootPartitionOffset { get; set; }
            public long BootPartitionSize { get; set; }
            public string SystemDiskUniqueId { get; set; }
            public long SystemDiskSize { get; set; }
            public string PartitionStyle { get; set; }
            public int RecoveryPartitionNumber { get; set; }
            public long RecoveryPartitionOffset { get; set; }
            public long RecoveryPartitionSize { get; set; }
            public bool BitLockerSafe { get; set; }
            public string BitLockerState { get; set; }
        }

        private enum FirmwareType
        {
            Unknown = 0,
            Bios = 1,
            Uefi = 2,
            Max = 3
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFirmwareType(out FirmwareType firmwareType);

        public ApplyChanges()
        {
            InitializeComponent();
            LoadSummary();
            Loaded += ApplyChanges_Loaded;
        }

        private async void ApplyChanges_Loaded(object sender, RoutedEventArgs e)
        {
            // Partition validation is now done in ChooseDistro page
            await StartInstallationAsync();
        }

        private void LoadSummary()
        {
            // Load Linux size from saved state
            var stateKey = $"ResizeDisk_{(App.Current.Properties["SelectedDistro"] as DistroInfo)?.Name}";
            var state = StateManager.GetState(stateKey);
            if (state?.State is System.Collections.Generic.Dictionary<string, double> savedState &&
                savedState.TryGetValue("LinuxSize", out var linuxSize))
            {
                _linuxSizeGB = linuxSize;
            }
        }

        private async Task<string> RunDiskpartAndGetOutputAsync(string scriptPath)
        {
            return await Task.Run(() =>
            {
                try
                {
                    var result = RunProcess("diskpart.exe", $"/s \"{scriptPath}\"", waitMs: 120000);
                    if (result.exitCode != 0)
                        return $"Error: diskpart failed rc={result.exitCode}\n{result.output}\n{result.error}";
                    return result.output;
                }
                catch (Exception ex)
                {
                    return $"Error: {ex.Message}";
                }
            });
        }

        private void BackButton_Click(object sender, RoutedEventArgs e)
        {
            if (_isRunning) return;

            NavigationHelper.NavigateWithAnimation(
                NavigationService,
                new WarningConfirmation(),
                TimeSpan.FromSeconds(0.3),
                slideLeft: false);
        }

        private async Task StartInstallationAsync()
        {
            if (_isRunning) return;

            _isRunning = true;
            BackButton.IsEnabled = false;

            try
            {
                if (_linuxSizeGB < 20 || double.IsNaN(_linuxSizeGB) || double.IsInfinity(_linuxSizeGB))
                {
                    Log($"ERROR: Invalid Linux partition size: {_linuxSizeGB:N1}GB");
                    UpdateProgress(0, Application.Current.Resources["ApplyChangesError"] as string ?? "Error occurred");
                    BackButton.IsEnabled = true;
                    _isRunning = false;
                    return;
                }

                FirmwareType firmware = DetectFirmwareTypeOrThrow();
                _storagePreflight = await RunStoragePreflightAsync(firmware);

                if (firmware == FirmwareType.Uefi)
                {
                    Log("UEFI firmware detected. Using Libertix UEFI workflow.");
                    await ExecuteUefiInstallationAsync();
                }
                else if (firmware == FirmwareType.Bios)
                {
                    Log("BIOS firmware detected. Using existing BIOS workflow.");
                    await ExecutePartitioningAsync();
                }
                else
                {
                    throw new InvalidOperationException("Unsupported firmware type.");
                }
            }
            catch (Exception ex)
            {
                if (_biosRecoveryGuardInstalled)
                {
                    await FailBiosPreparationAndRollbackAsync($"Unexpected preparation failure: {ex.Message}");
                    return;
                }
                Log($"ERROR: {ex.Message}");
                UpdateProgress(0, Application.Current.Resources["ApplyChangesError"] as string ?? "Error occurred");
                BackButton.IsEnabled = true;
                _isRunning = false;
            }
        }

        private async Task ExecuteUefiInstallationAsync()
        {
            if (!IsRunningAsAdministrator())
            {
                Log("ERROR: Administrator privileges are required for UEFI installation.");
                UpdateProgress(0, Application.Current.Resources["ApplyChangesError"] as string ?? "Error occurred");
                BackButton.IsEnabled = true;
                _isRunning = false;
                return;
            }

            string scriptPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Scripts", "libertix-uefi-install.ps1");
            string aria2Path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Tools", "aria2", "aria2c.exe");

            if (!File.Exists(scriptPath))
            {
                Log($"ERROR: UEFI installer script missing: {scriptPath}");
                UpdateProgress(0, Application.Current.Resources["ApplyChangesError"] as string ?? "Error occurred");
                BackButton.IsEnabled = true;
                _isRunning = false;
                return;
            }

            if (!File.Exists(aria2Path))
            {
                Log($"ERROR: bundled aria2 missing: {aria2Path}");
                UpdateProgress(0, Application.Current.Resources["ApplyChangesError"] as string ?? "Error occurred");
                BackButton.IsEnabled = true;
                _isRunning = false;
                return;
            }

            int installerSizeGB = Math.Max(20, (int)Math.Round(_linuxSizeGB));
            if (!(App.Current.Properties["AccountInfo"] is AccountInfo account) ||
                string.IsNullOrWhiteSpace(account.Username) ||
                string.IsNullOrWhiteSpace(account.Password) ||
                string.IsNullOrWhiteSpace(account.ComputerName))
            {
                Log("ERROR: Linux account configuration is missing.");
                UpdateProgress(0, Application.Current.Resources["ApplyChangesError"] as string ?? "Error occurred");
                BackButton.IsEnabled = true;
                _isRunning = false;
                return;
            }

            string systemLang = Localization.GetLinuxLocale();
            string keyboardLayout = Localization.GetKeyboardLayout();
            string timezone = Localization.GetWindowsTimezoneAsLinux();

            UpdateProgress(5, "Préparation de l'installation UEFI...");
            Log($"UEFI installer partition size: {installerSizeGB}GB");
            Log($"Filepool: {FilepoolConfig.BaseUrl}");
            Log($"aria2: bundled, max {Aria2MaxConnections} connections");
            Log($"Linux account: {account.Username}");

            string powershell = ResolveSystemExecutable("WindowsPowerShell\\v1.0\\powershell.exe", "powershell.exe");
            UefiRecoveryState recovery = CreateUefiRecoverySession();
            string configPath = WriteProtectedUefiConfig(new
            {
                InstallerPartitionSizeGB = installerSizeGB,
                FilepoolBaseUrl = FilepoolConfig.BaseUrl,
                Aria2ExePath = aria2Path,
                Aria2Connections = Aria2MaxConnections,
                LinuxUsername = account.Username,
                LinuxPasswordHash = LinuxPasswordHasher.Hash(account.Password),
                LinuxComputerName = account.ComputerName,
                SystemLang = systemLang,
                KeyboardLayout = keyboardLayout,
                KeyboardModel = "pc105",
                Timezone = timezone,
                BootStrategy = "BootNext",
                RecoveryRoot = recovery.RecoveryRoot,
                RecoveryRunId = recovery.RunId
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
                    TimeSpan.FromHours(6.5),
                    line => HandleUefiInstallerOutput(line));
            }
            finally
            {
                try { if (File.Exists(configPath)) File.Delete(configPath); } catch { }
            }

            if (exitCode != 0)
            {
                DeleteUefiRecoverySession(recovery);
                Log($"ERROR: UEFI installer preparation failed with rc={exitCode}");
                UpdateProgress(0, Application.Current.Resources["ApplyChangesError"] as string ?? "Error occurred");
                BackButton.IsEnabled = true;
                _isRunning = false;
                return;
            }

            try
            {
                InstallUefiRecoveryAgent(recovery, powershell);
            }
            catch (Exception ex)
            {
                Log($"ERROR: UEFI recovery agent setup failed: {ex.Message}");
                var revert = await Task.Run(() => RunProcess(
                    powershell,
                    $"-NoProfile -ExecutionPolicy Bypass -File {QuoteArgument(scriptPath)} -Revert",
                    300000));
                Log($"UEFI revert after recovery-agent failure: rc={revert.exitCode}");
                DeleteUefiRecoverySession(recovery);
                throw;
            }

            UpdateProgress(100, Application.Current.Resources["ApplyChangesComplete"] as string ?? "Partitioning complete!");
            Log("UEFI installation preparation completed successfully.");
            RebootButton.Visibility = Visibility.Visible;
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
                string relativePath = sourceFile.Substring(sourceRoot.Length).TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
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
                ExpectedLinuxPartitionSize = checked((long)Math.Max(20, (int)Math.Round(_linuxSizeGB)) * 1024L * 1024L * 1024L)
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

            string launcher = Path.Combine(recovery.RecoveryRoot, "run-recovery-agent.cmd");
            File.WriteAllText(
                launcher,
                "@echo off\r\n" +
                "\"%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe\" " +
                "-NoProfile -ExecutionPolicy Bypass -File \"%~dp0payload\\Scripts\\libertix-uefi-recovery-agent.ps1\" " +
                "-StatePath \"%~dp0state.json\"\r\n",
                new UTF8Encoding(false));
            string promptLauncher = Path.Combine(recovery.RecoveryRoot, "run-recovery-prompt.cmd");
            File.WriteAllText(
                promptLauncher,
                "@echo off\r\n" +
                "\"%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe\" " +
                "-NoProfile -ExecutionPolicy Bypass -File \"%~dp0payload\\Scripts\\libertix-uefi-recovery-agent.ps1\" " +
                "-StatePath \"%~dp0state.json\" -Action Prompt\r\n",
                new UTF8Encoding(false));

            string registrationArguments =
                $"-NoProfile -ExecutionPolicy Bypass -File {QuoteArgument(taskRegistrationScript)} " +
                $"-StartupTaskName {QuoteArgument(recovery.TaskName)} " +
                $"-StartupLauncher {QuoteArgument(launcher)} " +
                $"-PromptTaskName {QuoteArgument(recovery.PromptTaskName)} " +
                $"-PromptLauncher {QuoteArgument(promptLauncher)} " +
                $"-PromptUser {QuoteArgument(WindowsIdentity.GetCurrent().Name)}";
            var result = RunProcess(powershell, registrationArguments, waitMs: 30000);
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
                UpdateProgress(8, "Vérification Secure Boot...");
            else if (normalized.Contains("disabling bitlocker"))
                UpdateProgress(18, "Déchiffrement de Windows C: initialisation...");
            else if (normalized.Contains("windows c: decrypted"))
                UpdateProgress(28, "Windows C: déchiffré");
            else if (normalized.Contains("waiting for c: decryption") || normalized.Contains("decryptioninprogress"))
                UpdateDecryptionProgress(line);
            else if (normalized.Contains("downloading mint iso"))
            {
                _uefiDownloadingInstallerIso = false;
                UpdateProgress(30, "Downloading Mint ISO...");
            }
            else if (normalized.Contains("mint iso ready"))
            {
                _uefiDownloadingInstallerIso = false;
                UpdateProgress(45, "Mint ISO ready");
            }
            else if (normalized.Contains("creating") && normalized.Contains("libertixefi"))
                UpdateProgress(52, "Creating UEFI installer partition...");
            else if (normalized.Contains("downloading libertix uefi iso"))
            {
                _uefiDownloadingInstallerIso = true;
                UpdateProgress(62, "Downloading Libertix UEFI ISO...");
            }
            else if (normalized.Contains("libertix-installer-uefi.iso"))
            {
                _uefiDownloadingInstallerIso = true;
            }
            else if (normalized.Contains("copying iso contents"))
                UpdateProgress(78, "Copying UEFI installer...");
            else if (normalized.Contains("configuring one-time uefi boot entry"))
                UpdateProgress(90, "Configuring UEFI boot...");
            else if (normalized.Contains("complete. next boot"))
                UpdateProgress(100, "UEFI preparation complete");

            var ariaProgress = Regex.Match(line, @"\((\d{1,3})%\)");
            if (ariaProgress.Success && int.TryParse(ariaProgress.Groups[1].Value, out int percent))
            {
                int clamped = Math.Max(0, Math.Min(100, percent));
                if (_uefiDownloadingInstallerIso)
                {
                    UpdateProgress(62 + (clamped * 10 / 100), $"Downloading Libertix UEFI ISO... {clamped}%");
                }
                else
                {
                    UpdateProgress(30 + (clamped * 15 / 100), $"Downloading Mint ISO... {clamped}%");
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
                UpdateProgress(18, "Déchiffrement de Windows C: en cours...");
                return;
            }

            if (!double.TryParse(encryptedMatch.Groups[1].Value.Replace(',', '.'), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out double encryptedPercent))
            {
                UpdateProgress(18, "Déchiffrement de Windows C: en cours...");
                return;
            }

            int decryptedPercent = Math.Max(0, Math.Min(100, (int)Math.Round(100 - encryptedPercent)));
            int overallProgress = 18 + (decryptedPercent * 10 / 100);
            UpdateProgress(overallProgress, $"Déchiffrement de Windows C: {decryptedPercent}%");
        }

        private async Task<int> RunStreamingProcessAsync(
            string fileName,
            string arguments,
            TimeSpan timeout,
            Action<string> onLine)
        {
            return await Task.Run(() =>
            {
                var psi = new ProcessStartInfo
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

                using (var process = new Process { StartInfo = psi, EnableRaisingEvents = true })
                {
                    process.OutputDataReceived += (_, e) =>
                    {
                        if (e.Data != null)
                            Dispatcher.BeginInvoke(new Action(() => onLine(e.Data)));
                    };
                    process.ErrorDataReceived += (_, e) =>
                    {
                        if (e.Data != null)
                            Dispatcher.BeginInvoke(new Action(() => onLine($"ERROR: {e.Data}")));
                    };

                    if (!process.Start())
                        throw new InvalidOperationException($"Failed to start {fileName}");

                    process.BeginOutputReadLine();
                    process.BeginErrorReadLine();

                    if (!process.WaitForExit((int)timeout.TotalMilliseconds))
                    {
                        try { process.Kill(); } catch { }
                        Dispatcher.Invoke(() => Log($"ERROR: process timed out after {timeout.TotalMinutes:N0} minutes"));
                        return -1;
                    }

                    process.WaitForExit();
                    return process.ExitCode;
                }
            });
        }

        private async Task ExecutePartitioningAsync()
        {
            // Query available shrink space first
            Log("Checking available shrink space...");
            double maxShrinkMB = await QueryShrinkSpaceAsync();
            Log($"Maximum shrinkable space: {maxShrinkMB / 1024:N1}GB ({maxShrinkMB:N0}MB)");

            // The temporary FAT32 live partition is created at the final Linux size.
            // The live system reformats this same slot as ext4, avoiding MBR delete/recreate.
            double requestedLinuxMB = _linuxSizeGB * 1024;
            double minRequiredMB = requestedLinuxMB;
            if (maxShrinkMB < minRequiredMB)
            {
                Log($"ERROR: Not enough shrinkable space!");
                Log($"  Minimum required: {minRequiredMB / 1024:N1}GB");
                Log($"  Available: {maxShrinkMB / 1024:N1}GB");
                UpdateProgress(0, Application.Current.Resources["ApplyChangesError"] as string ?? "Error occurred");
                BackButton.IsEnabled = true;
                _isRunning = false;
                return;
            }

            Log("Installing Windows recovery guard...");
            // This guard is installed before any partition change. If the live
            // installer dies before writing a success marker, Windows can delete
            // the temporary Linux slot and grow C: back on the next startup.
            bool recoveryGuardReady = await InstallWindowsRecoveryGuardAsync(requestedLinuxMB);
            if (!recoveryGuardReady)
            {
                Log("ERROR: Failed to install Windows recovery guard");
                UpdateProgress(0, Application.Current.Resources["ApplyChangesError"] as string ?? "Error occurred");
                BackButton.IsEnabled = true;
                _isRunning = false;
                return;
            }

            // Step 1: Shrink Windows by the full requested Linux size.
            UpdateProgress(10, Application.Current.Resources["ApplyChangesStep1"] as string ?? "Shrinking Windows partition...");
            Log($"Step 1: Shrinking Windows by {_linuxSizeGB:N0}GB for the reusable live/Linux partition...");

            bool step1Success = await ShrinkWindowsPartitionAsync(requestedLinuxMB);
            if (!step1Success)
            {
                await FailBiosPreparationAndRollbackAsync("Failed to shrink Windows partition (step 1)");
                return;
            }

            // Wait for disk to update
            Log("Waiting for disk to update...");
            await Task.Delay(3000);

            // Step 2: Create FAT32 partition in the free space (no offset - goes right after Windows).
            // It is intentionally sized like the final Linux partition; the live installer reformats it.
            UpdateProgress(30, Application.Current.Resources["ApplyChangesStep2"] as string ?? "Creating FAT32 boot partition (Z:)...");
            Log($"Step 2: Creating FAT32 live partition at final size ({_linuxSizeGB:N0}GB)...");

            bool step2Success = await CreateFat32PartitionSimpleAsync(requestedLinuxMB);
            if (!step2Success)
            {
                await FailBiosPreparationAndRollbackAsync("Failed to create FAT32 partition");
                return;
            }

            // On MBR, inserting the Linux slot before the recovery partition
            // can change its partition number. Refresh WinRE while Windows is
            // still booted through its normal BCD store; after GRUB is written,
            // ReAgentC can no longer reliably update that store.
            Log("Refreshing Windows Recovery Environment registration...");
            bool winReReady = await RefreshWindowsRecoveryRegistrationAsync();
            if (!winReReady)
            {
                await FailBiosPreparationAndRollbackAsync(
                    "Windows Recovery Environment could not be re-enabled after partitioning");
                return;
            }

            // Wait for disk to update
            Log("Waiting for disk to update...");
            await Task.Delay(3000);

            Log("Step 3: No second shrink needed; live partition will become the Linux partition.");

            // Wait for disk to update
            Log("Waiting for disk to update...");
            UpdateProgress(50, Application.Current.Resources["ApplyChangesWaitDisk"] as string ?? "Waiting for disk update...");
            await Task.Delay(3000);

            // Step 4: Download ISO
            var selectedDistroConfig = App.Current.Properties["SelectedDistro"] as DistroInfo;
            string isoUrl = selectedDistroConfig?.IsoUrl ?? "";

            if (string.IsNullOrEmpty(isoUrl))
            {
                await FailBiosPreparationAndRollbackAsync("No ISO URL found for selected distribution");
                return;
            }

            UpdateProgress(55, "Downloading ISO...");
            Log($"Step 4: Downloading ISO from {isoUrl}...");

            string tempIsoPath = Path.Combine(Path.GetTempPath(), "libertix_installer.iso");
            string localIsoName = Path.GetFileName(new Uri(isoUrl).LocalPath);
            string localIsoPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, localIsoName);
            bool downloadSuccess = false;

            if (File.Exists(localIsoPath))
            {
                Log($"Found local ISO: {localIsoName}, copying...");
                await Task.Run(() => File.Copy(localIsoPath, tempIsoPath, true));
                downloadSuccess = true;
                UpdateProgress(80, "ISO copied from local folder");
            }
            else
            {
                downloadSuccess = await DownloadIsoAsync(isoUrl, tempIsoPath);
            }

            if (!downloadSuccess)
            {
                await FailBiosPreparationAndRollbackAsync("Failed to download ISO");
                return;
            }
            if (!await VerifySha256Async(tempIsoPath, selectedDistroConfig?.IsoSha256, "Libertix BIOS ISO"))
            {
                await FailBiosPreparationAndRollbackAsync("Libertix BIOS ISO integrity verification failed");
                return;
            }

            // Step 5: Mount ISO and copy contents to Z:
            UpdateProgress(80, "Copying ISO contents to Z:...");
            Log("Step 5: Mounting ISO and copying contents to Z:...");

            bool copySuccess = await MountAndCopyIsoAsync(tempIsoPath);
            if (!copySuccess)
            {
                await FailBiosPreparationAndRollbackAsync("Failed to copy ISO contents");
                return;
            }

            // Cleanup temp ISO
            try
            {
                if (File.Exists(tempIsoPath))
                    File.Delete(tempIsoPath);
            }
            catch { }

            // Step 6: keep the large Mint ISO on the Windows NTFS partition.
            // The live system remounts this path read-only after partitioning.
            if (App.Current.Properties["SelectedDistro"] is DistroInfo selectedDistro &&
                !string.IsNullOrEmpty(selectedDistro.IsoInstaller) &&
                !string.IsNullOrEmpty(selectedDistro.IsoInstallerFileName))
            {
                UpdateProgress(85, "Downloading Linux installer ISO...");
                Log($"Step 6: Downloading Linux installer from {selectedDistro.IsoInstaller}...");

                string installerDir = Path.Combine(Path.GetTempPath(), "Libertix");
                Directory.CreateDirectory(installerDir);
                string installerPath = Path.Combine(installerDir, selectedDistro.IsoInstallerFileName);
                string localInstallerPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, selectedDistro.IsoInstallerFileName);
                bool installerDownloadSuccess = false;

                if (File.Exists(localInstallerPath))
                {
                    Log($"Found local installer ISO: {selectedDistro.IsoInstallerFileName}, copying...");
                    await Task.Run(() => File.Copy(localInstallerPath, installerPath, true));
                    installerDownloadSuccess = true;
                    UpdateProgress(95, "Linux installer copied from local folder");
                }
                else
                {
                    installerDownloadSuccess = await DownloadInstallerIsoAsync(selectedDistro.IsoInstaller, installerPath);
                }

                if (!installerDownloadSuccess)
                {
                    await FailBiosPreparationAndRollbackAsync("Failed to download Linux installer ISO");
                    return;
                }
                if (!await VerifySha256Async(
                    installerPath,
                    selectedDistro.IsoInstallerSha256,
                    "Mint ISO"))
                {
                    await FailBiosPreparationAndRollbackAsync("Mint ISO integrity verification failed");
                    return;
                }
                Log($"Linux installer saved to {installerPath}");
            }

            // Step 7: Write config.txt AFTER ISO copy (so it doesn't get overwritten)
            UpdateProgress(95, "Writing configuration...");
            Log("Step 7: Writing configuration to Z:\\config.txt...");

            bool configSuccess = await WriteConfigToFat32Async();
            if (!configSuccess)
            {
                await FailBiosPreparationAndRollbackAsync("Failed to write config.txt");
                return;
            }

            // Step 8: GRUB4DOS is only a temporary Windows Boot Manager bridge.
            // The live installer removes these files before touching Linux.
            UpdateProgress(96, "Downloading bootloader files...");
            Log("Step 8: Downloading GRUB4DOS files to C:\\...");

            string[] grubFiles = { "grldr", "grldr.mbr", "menu.lst" };
            var grubHashes = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                ["grldr"] = "124988a6091248111f5d372ad210f21250a42cfd05d9d6366be28347b6368675",
                ["grldr.mbr"] = "53fce0d82a09531b1a7af728e712a957db3966835304e8bdae5e350220270b33",
                ["menu.lst"] = "9351d1477b214f860da85307adff0713cfac725fde46b90944acd5b4617aa747"
            };
            foreach (var file in grubFiles)
            {
                string url = $"{FilepoolConfig.BaseUrl}/{file}";
                string destPath = Path.Combine(@"C:\", file);
                string localFile = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, file);
                bool success = false;

                if (File.Exists(localFile))
                {
                    Log($"Found local {file}, copying...");
                    try
                    {
                        File.Copy(localFile, destPath, true);
                        success = true;
                    }
                    catch (Exception ex)
                    {
                        Log($"ERROR: Failed to copy local {file}: {ex.Message}");
                    }
                }

                if (!success)
                {
                    success = await DownloadFileAsync(url, destPath);
                }

                if (!success)
                {
                    await FailBiosPreparationAndRollbackAsync($"Failed to obtain {file}");
                    return;
                }
                if (!await VerifySha256Async(destPath, grubHashes[file], file))
                {
                    await FailBiosPreparationAndRollbackAsync($"Integrity verification failed for {file}");
                    return;
                }
                Log($"Ready: {file} at C:\\");
            }

            // Step 9: make the next reboot enter the live installer once.
            // Windows remains the default BCD entry for later boots.
            UpdateProgress(98, "Configuring boot entry...");
            Log("Step 9: Configuring GRUB4DOS boot entry...");
            await Task.Delay(1000);

            bool bootConfigured = await ConfigureBootEntryAsync();
            if (!bootConfigured)
            {
                await FailBiosPreparationAndRollbackAsync("Failed to configure boot entry");
                return;
            }

            // Done
            UpdateProgress(100, Application.Current.Resources["ApplyChangesComplete"] as string ?? "Partitioning complete!");
            Log("Installation preparation completed successfully!");
            Log($"- FAT32 live partition: Z: ({_linuxSizeGB:N0}GB, final Linux slot)");
            Log("- The live installer will reformat Z: as ext4 instead of deleting/recreating the MBR entry");
            Log("- ISO contents copied to Z:");
            Log("- GRUB4DOS bootloader installed");
            Log("- Boot entry 'Install Linux' added to Windows Boot Manager");
            Log("- Next reboot will automatically boot the Linux installer");
            Log("- Layout: [Windows] [FAT32 live/future Linux] [Recovery]");

            RebootButton.Visibility = Visibility.Visible;
        }

        private async Task FailBiosPreparationAndRollbackAsync(string reason)
        {
            Log($"ERROR: {reason}");
            UpdateProgress(0, "Erreur détectée, restauration de Windows en cours...");

            bool rollbackSucceeded = false;
            if (_biosRecoveryGuardInstalled)
            {
                string recoveryScript = Path.Combine(RecoveryRoot, "recover.ps1");
                if (File.Exists(recoveryScript))
                {
                    string powershell = ResolveSystemExecutable(
                        "WindowsPowerShell\\v1.0\\powershell.exe",
                        "powershell.exe");
                    int exitCode = await RunStreamingProcessAsync(
                        powershell,
                        $"-NoProfile -ExecutionPolicy Bypass -File {QuoteArgument(recoveryScript)}",
                        TimeSpan.FromMinutes(10),
                        line => Log($"ROLLBACK: {line}"));
                    rollbackSucceeded = exitCode == 0;
                }
            }

            _biosRecoveryGuardInstalled = !rollbackSucceeded;
            _isRunning = false;
            if (rollbackSucceeded)
            {
                Log("Automatic rollback completed and verified.");
                UpdateProgress(0, "Erreur pendant la préparation. Windows a été restauré.");
                BackButton.IsEnabled = true;
            }
            else
            {
                Log("CRITICAL: Automatic rollback did not complete. Do not retry or power off the machine.");
                UpdateProgress(0, "Rollback incomplet. Une intervention manuelle est requise.");
                BackButton.IsEnabled = false;
                MessageBox.Show(
                    "La préparation a échoué et le rollback automatique n'a pas pu être vérifié. " +
                    "Ne relancez pas l'installation et consultez C:\\LibertixInstallRecovery\\recovery.log.",
                    "Libertix - rollback incomplet",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
            }
        }

        private async Task<bool> DownloadFileAsync(string url, string destinationPath)
        {
            try
            {
                using (var client = new HttpClient())
                {
                    client.Timeout = TimeSpan.FromMinutes(5);
                    var data = await client.GetByteArrayAsync(url);
                    File.WriteAllBytes(destinationPath, data);
                    return true;
                }
            }
            catch (Exception ex)
            {
                Dispatcher.Invoke(() => Log($"Download failed for {url}: {ex.Message}"));
                return false;
            }
        }

        private async Task<bool> VerifySha256Async(string path, string expectedHash, string label)
        {
            if (string.IsNullOrWhiteSpace(expectedHash) ||
                !Regex.IsMatch(expectedHash, "^[0-9a-fA-F]{64}$"))
            {
                Log($"ERROR: Missing or invalid SHA256 manifest entry for {label}.");
                return false;
            }
            if (!File.Exists(path))
            {
                Log($"ERROR: Cannot verify missing file for {label}: {path}");
                return false;
            }

            string actualHash = await Task.Run(() =>
            {
                using (var stream = File.OpenRead(path))
                using (var sha = SHA256.Create())
                {
                    return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
                }
            });
            bool valid = string.Equals(actualHash, expectedHash, StringComparison.OrdinalIgnoreCase);
            Log($"{label} SHA256: {actualHash} ({(valid ? "verified" : "MISMATCH")})");
            return valid;
        }

        private async Task<bool> ConfigureBootEntryAsync()
        {
            try
            {
                if (!IsRunningAsAdministrator())
                {
                    Log("ERROR: Administrator privileges are required to configure BCD.");
                    return false;
                }

                // Full path to bcdedit.exe - use Sysnative to bypass WOW64 redirection
                string bcdeditPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Sysnative", "bcdedit.exe");

                // If Sysnative doesn't exist (running as 64-bit), use System32
                if (!File.Exists(bcdeditPath))
                {
                    bcdeditPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "bcdedit.exe");
                }

                Log($"Using bcdedit at: {bcdeditPath}");

                // Create a temporary bootsector entry. The live ISO deletes this
                // entry from the offline BCD store as its first cleanup step.
                string guid = "";
                var createResult = await Task.Run(() =>
                    RunProcess(bcdeditPath, "/create /d \"Install Linux\" /application bootsector", 30000));
                string output = createResult.output;
                string error = createResult.error;

                Log($"bcdedit create output: {output}");
                if (!string.IsNullOrEmpty(error))
                    Log($"bcdedit create error: {error}");

                if (createResult.exitCode != 0)
                {
                    Log($"ERROR: bcdedit create failed with rc={createResult.exitCode}");
                    return false;
                }

                // Find GUID between { and } in the output
                int startIdx = output.IndexOf('{');
                int endIdx = output.IndexOf('}');
                if (startIdx >= 0 && endIdx > startIdx)
                {
                    guid = output.Substring(startIdx, endIdx - startIdx + 1);
                    Log($"Found GUID: {guid}");
                }
                else
                {
                    Log($"ERROR: Could not find GUID in output");
                    return false;
                }

                // Wait 1 second before next bcdedit commands
                await Task.Delay(1000);

                // Step 2: Set device partition
                await RunBcdeditCommandAsync(bcdeditPath, $"/set {guid} device partition=C:");

                await Task.Delay(1000);

                // Step 3: Set path to grldr.mbr
                await RunBcdeditCommandAsync(bcdeditPath, $"/set {guid} path \\grldr.mbr");

                await Task.Delay(1000);

                // Keep the entry visible in BCD metadata, but bootsequence makes
                // it one-shot. If the user reboots later, Windows is still default.
                await RunBcdeditCommandAsync(bcdeditPath, $"/displayorder {guid} /addlast");

                await Task.Delay(1000);

                // Suppress the Windows selector for this automated run only.
                await RunBcdeditCommandAsync(bcdeditPath, "/set {bootmgr} displaybootmenu no");

                await Task.Delay(1000);

                await RunBcdeditCommandAsync(bcdeditPath, "/timeout 0");

                await Task.Delay(1000);

                await RunBcdeditCommandAsync(bcdeditPath, "/default {current}");

                await Task.Delay(1000);

                await RunBcdeditCommandAsync(bcdeditPath, $"/bootsequence {guid}");

                Log("Boot entry configured successfully");
                Log("Next reboot will automatically boot Install Linux once.");
                return true;
            }
            catch (Exception ex)
            {
                Log($"Boot configuration failed: {ex.Message}");
                return false;
            }
        }

        private async Task RunBcdeditCommandAsync(string bcdeditPath, string arguments)
        {
            var result = await Task.Run(() => RunProcess(bcdeditPath, arguments, 30000));
            if (!string.IsNullOrWhiteSpace(result.output))
                Log($"bcdedit output: {result.output.Trim()}");
            if (!string.IsNullOrWhiteSpace(result.error))
                Log($"bcdedit error: {result.error.Trim()}");

            Log($"bcdedit {arguments}: {(result.exitCode == 0 ? "OK" : "Failed")}");
            if (result.exitCode != 0)
            {
                throw new InvalidOperationException($"bcdedit {arguments} failed with rc={result.exitCode}");
            }
        }

        private async Task<bool> WriteConfigToFat32Async()
        {
            // Get locale settings from main thread before running on background thread
            string systemLang = "";
            string keyboardLayout = "";
            string timezone = "";

            Dispatcher.Invoke(() =>
            {
                systemLang = Localization.GetLinuxLocale();
                keyboardLayout = Localization.GetKeyboardLayout();
                timezone = Localization.GetWindowsTimezoneAsLinux();
            });

            if (_storagePreflight == null)
            {
                Log("ERROR: Storage preflight is missing while writing live config.");
                return false;
            }
            if (!(App.Current.Properties["AccountInfo"] is AccountInfo configuredAccount) ||
                string.IsNullOrWhiteSpace(configuredAccount.Username) ||
                string.IsNullOrWhiteSpace(configuredAccount.Password) ||
                string.IsNullOrWhiteSpace(configuredAccount.ComputerName))
            {
                Log("ERROR: Linux account configuration is missing.");
                return false;
            }

            long installerPartitionOffset = await QueryPartitionOffsetAsync('Z');
            if (installerPartitionOffset <= 0)
            {
                Log("ERROR: Could not identify the temporary installer partition Z:.");
                return false;
            }

            return await Task.Run(() =>
            {
                try
                {
                    string configPath = @"Z:\config.txt";

                    string username = configuredAccount.Username;
                    string passwordHash = LinuxPasswordHasher.Hash(configuredAccount.Password);
                    string computerName = configuredAccount.ComputerName;

                    // Get distro info - use IsoInstallerFileName for config
                    string isoFilename = "mint.iso";
                    if (App.Current.Properties["SelectedDistro"] is DistroInfo distro && !string.IsNullOrEmpty(distro.IsoInstallerFileName))
                    {
                        isoFilename = distro.IsoInstallerFileName;
                    }

                    string isoWindowsPath = isoFilename;
                    if (App.Current.Properties["SelectedDistro"] is DistroInfo selectedInstaller &&
                        !string.IsNullOrEmpty(selectedInstaller.IsoInstallerFileName))
                    {
                        isoWindowsPath = Path.Combine(
                            Path.GetTempPath(),
                            "Libertix",
                            selectedInstaller.IsoInstallerFileName);
                    }

                    // config.txt is consumed by the live installer after toram.
                    // Keep the values shell-compatible because install-mint.sh sources it.
                    var configLines = new List<string>
                    {
                        $"SYSTEM_LANG={ShellQuoteValue(systemLang)}",
                        $"KEYBOARD_LAYOUT={ShellQuoteValue(keyboardLayout)}",
                        $"KEYBOARD_MODEL={ShellQuoteValue("pc105")}",
                        $"TIMEZONE={ShellQuoteValue(timezone)}",
                        $"USERNAME={ShellQuoteValue(username)}",
                        $"PASSWORD_HASH={ShellQuoteValue(passwordHash)}",
                        $"COMPUTER_NAME={ShellQuoteValue(computerName)}",
                        $"ISO_FILENAME={ShellQuoteValue(isoFilename)}",
                        $"ISO_WINDOWS_PATH={ShellQuoteValue(isoWindowsPath)}",
                        $"LINUX_SIZE_GB={ShellQuoteValue(_linuxSizeGB.ToString("F0", CultureInfo.InvariantCulture))}",
                        $"TARGET_DISK_SIZE_BYTES={ShellQuoteValue(_storagePreflight.SystemDiskSize.ToString(CultureInfo.InvariantCulture))}",
                        $"WINDOWS_PARTITION_OFFSET_BYTES={ShellQuoteValue(_storagePreflight.SystemPartitionOffset.ToString(CultureInfo.InvariantCulture))}",
                        $"WINDOWS_BOOT_PARTITION_OFFSET_BYTES={ShellQuoteValue(_storagePreflight.BootPartitionOffset.ToString(CultureInfo.InvariantCulture))}",
                        $"INSTALLER_PARTITION_OFFSET_BYTES={ShellQuoteValue(installerPartitionOffset.ToString(CultureInfo.InvariantCulture))}",
                        $"EXPECTED_PARTITION_STYLE={ShellQuoteValue(_storagePreflight.PartitionStyle)}",
                        $"RECOVERY_PARTITION_OFFSET_BYTES={ShellQuoteValue(_storagePreflight.RecoveryPartitionOffset.ToString(CultureInfo.InvariantCulture))}",
                        $"RECOVERY_PARTITION_SIZE_BYTES={ShellQuoteValue(_storagePreflight.RecoveryPartitionSize.ToString(CultureInfo.InvariantCulture))}"
                    };

                    // POSIX read loops do not process a final unterminated line. Keep the
                    // manifest newline-terminated so the recovery geometry is always read.
                    File.WriteAllText(configPath, string.Join("\n", configLines) + "\n");

                    Dispatcher.Invoke(() =>
                    {
                        Log($"Config written to Z:\\config.txt:");
                        Log($"  SYSTEM_LANG={systemLang}");
                        Log($"  KEYBOARD_LAYOUT={keyboardLayout}");
                        Log($"  TIMEZONE={timezone}");
                        Log($"  USERNAME={username}");
                        Log($"  LINUX_SIZE_GB={_linuxSizeGB:F0}");
                    });
                    return true;
                }
                catch (Exception ex)
                {
                    Dispatcher.Invoke(() => Log($"Failed to write config: {ex.Message}"));
                    return false;
                }
            });
        }

        private async Task<long> QueryPartitionOffsetAsync(char driveLetter)
        {
            string powershell = ResolveSystemExecutable(
                "WindowsPowerShell\\v1.0\\powershell.exe",
                "powershell.exe");
            string command =
                $"$p=Get-Partition -DriveLetter {char.ToUpperInvariant(driveLetter)} -ErrorAction Stop; " +
                "[Console]::Out.WriteLine($p.Offset.ToString([Globalization.CultureInfo]::InvariantCulture))";
            var result = await Task.Run(() => RunProcess(
                powershell,
                $"-NoProfile -Command {QuoteArgument(command)}",
                30000));
            if (result.exitCode != 0)
            {
                Log($"ERROR: Partition identity query failed: {result.error}");
                return 0;
            }
            return long.TryParse(result.output.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out long offset)
                ? offset
                : 0;
        }

        private async Task<bool> DownloadIsoAsync(string url, string destinationPath)
        {
            return await DownloadFileWithRetriesAsync(
                url,
                destinationPath,
                attempts: 3,
                timeout: TimeSpan.FromHours(2),
                bufferSize: 8192,
                progressStart: 60,
                progressSpan: 20,
                label: "ISO",
                progressMessage: "Downloading...");
        }

        private async Task<bool> DownloadInstallerIsoAsync(string url, string destinationPath)
        {
            return await DownloadFileWithRetriesAsync(
                url,
                destinationPath,
                attempts: 3,
                timeout: TimeSpan.FromHours(4),
                bufferSize: 81920,
                progressStart: 85,
                progressSpan: 10,
                label: "Linux installer ISO",
                progressMessage: "Downloading Linux ISO...");
        }

        private async Task<bool> DownloadFileWithRetriesAsync(
            string url,
            string destinationPath,
            int attempts,
            TimeSpan timeout,
            int bufferSize,
            int progressStart,
            int progressSpan,
            string label,
            string progressMessage)
        {
            for (int attempt = 1; attempt <= attempts; attempt++)
            {
                try
                {
                    bool aria2Downloaded = await TryDownloadWithBundledAria2Async(
                        url,
                        destinationPath,
                        timeout,
                        progressStart,
                        progressSpan,
                        label,
                        progressMessage,
                        attempt,
                        attempts);
                    if (aria2Downloaded)
                    {
                        Dispatcher.Invoke(() => Log($"{label} download completed with aria2"));
                        return true;
                    }

                    await DownloadFileOnceAsync(
                        url,
                        destinationPath,
                        timeout,
                        bufferSize,
                        progressStart,
                        progressSpan,
                        label,
                        progressMessage,
                        attempt,
                        attempts);
                    Dispatcher.Invoke(() => Log($"{label} download completed"));
                    return true;
                }
                catch (Exception ex)
                {
                    try { if (File.Exists(destinationPath)) File.Delete(destinationPath); } catch { }
                    Dispatcher.Invoke(() => Log($"{label} download attempt {attempt}/{attempts} failed: {ex.Message}"));
                    if (attempt == attempts)
                        return false;
                    await Task.Delay(TimeSpan.FromSeconds(2 * attempt));
                }
            }

            return false;
        }

        private async Task<bool> TryDownloadWithBundledAria2Async(
            string url,
            string destinationPath,
            TimeSpan timeout,
            int progressStart,
            int progressSpan,
            string label,
            string progressMessage,
            int attempt,
            int attempts)
        {
            string aria2Path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Tools", "aria2", "aria2c.exe");
            if (!File.Exists(aria2Path))
            {
                Dispatcher.Invoke(() => Log($"{label}: bundled aria2 not found, using HTTP downloader"));
                return false;
            }

            string destinationDir = Path.GetDirectoryName(destinationPath);
            if (string.IsNullOrWhiteSpace(destinationDir))
                destinationDir = Path.GetTempPath();

            string fileName = Path.GetFileName(destinationPath);
            string downloadDir = destinationDir;
            string aria2OutputPath = destinationPath;

            // aria2 is less predictable when writing directly to a drive root
            // on Windows. Use a temp folder, then move the completed file.
            string root = Path.GetPathRoot(destinationDir);
            if (!string.IsNullOrEmpty(root) &&
                string.Equals(destinationDir.TrimEnd('\\'), root.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
            {
                downloadDir = Path.Combine(Path.GetTempPath(), "LibertixDownloads", Guid.NewGuid().ToString("N"));
                aria2OutputPath = Path.Combine(downloadDir, fileName);
            }

            Directory.CreateDirectory(downloadDir);
            Directory.CreateDirectory(destinationDir);

            var args = new[]
            {
                "--allow-overwrite=true",
                "--auto-file-renaming=false",
                "--continue=true",
                $"--max-connection-per-server={Aria2MaxConnections}",
                $"--split={Aria2MaxConnections}",
                "--min-split-size=1M",
                "--summary-interval=2",
                "--console-log-level=warn",
                "--check-certificate=true",
                $"--dir={downloadDir}",
                $"--out={fileName}",
                url
            };

            Dispatcher.Invoke(() =>
            {
                Log($"{label}: downloading with bundled aria2 ({Aria2MaxConnections} connections, attempt {attempt}/{attempts})");
                UpdateProgress(progressStart, progressMessage);
            });

            int exitCode = await RunStreamingProcessAsync(
                aria2Path,
                string.Join(" ", Array.ConvertAll(args, QuoteArgument)),
                timeout,
                line => HandleAria2DownloadOutput(line, label, progressMessage, progressStart, progressSpan));

            if (exitCode != 0)
            {
                Dispatcher.Invoke(() => Log($"{label}: aria2 failed with rc={exitCode}, using HTTP fallback"));
                try { if (File.Exists(aria2OutputPath)) File.Delete(aria2OutputPath); } catch { }
                return false;
            }

            if (!File.Exists(aria2OutputPath) || new FileInfo(aria2OutputPath).Length == 0)
            {
                Dispatcher.Invoke(() => Log($"{label}: aria2 output missing or empty, using HTTP fallback"));
                return false;
            }

            if (!string.Equals(aria2OutputPath, destinationPath, StringComparison.OrdinalIgnoreCase))
            {
                if (File.Exists(destinationPath))
                    File.Delete(destinationPath);
                File.Move(aria2OutputPath, destinationPath);
                try { Directory.Delete(downloadDir, true); } catch { }
            }

            return true;
        }

        private void HandleAria2DownloadOutput(
            string line,
            string label,
            string progressMessage,
            int progressStart,
            int progressSpan)
        {
            if (string.IsNullOrWhiteSpace(line))
                return;

            Log($"aria2 {label}: {line}");

            var match = Regex.Match(line, @"\((\d{1,3})%\)");
            if (!match.Success)
                match = Regex.Match(line, @"\b(\d{1,3})%");

            if (!match.Success || !int.TryParse(match.Groups[1].Value, out int percent))
                return;

            int clamped = Math.Max(0, Math.Min(100, percent));
            int overallProgress = progressStart + (clamped * progressSpan / 100);
            UpdateProgress(overallProgress, $"{progressMessage} {clamped}%");
        }

        private async Task DownloadFileOnceAsync(
            string url,
            string destinationPath,
            TimeSpan timeout,
            int bufferSize,
            int progressStart,
            int progressSpan,
            string label,
            string progressMessage,
            int attempt,
            int attempts)
        {
            using (var client = new HttpClient())
            {
                client.Timeout = timeout;
                using (var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead))
                {
                    response.EnsureSuccessStatusCode();

                    var totalBytes = response.Content.Headers.ContentLength ?? 0;
                    var totalMB = totalBytes / 1024.0 / 1024.0;
                    Dispatcher.Invoke(() => Log($"{label} size: {totalMB:N0} MB (attempt {attempt}/{attempts})"));

                    using (var contentStream = await response.Content.ReadAsStreamAsync())
                    using (var fileStream = new FileStream(destinationPath, FileMode.Create, FileAccess.Write, FileShare.None, bufferSize, true))
                    {
                        var buffer = new byte[bufferSize];
                        long totalRead = 0;
                        int bytesRead;
                        var lastProgressUpdate = DateTime.Now;

                        while ((bytesRead = await contentStream.ReadAsync(buffer, 0, buffer.Length)) > 0)
                        {
                            await fileStream.WriteAsync(buffer, 0, bytesRead);
                            totalRead += bytesRead;

                            if ((DateTime.Now - lastProgressUpdate).TotalMilliseconds > 500)
                            {
                                var progressPercent = totalBytes > 0 ? (int)(totalRead * 100 / totalBytes) : 0;
                                var downloadedMB = totalRead / 1024.0 / 1024.0;
                                Dispatcher.Invoke(() =>
                                {
                                    var overallProgress = progressStart + (progressPercent * progressSpan / 100);
                                    UpdateProgress(overallProgress, $"{progressMessage} {downloadedMB:N0}/{totalMB:N0} MB ({progressPercent}%)");
                                });
                                lastProgressUpdate = DateTime.Now;
                            }
                        }

                        if (totalBytes > 0 && totalRead != totalBytes)
                        {
                            throw new IOException($"Downloaded size mismatch for {url}: expected {totalBytes} bytes, got {totalRead} bytes");
                        }
                    }
                }
            }
        }

        private async Task<bool> MountAndCopyIsoAsync(string isoPath)
        {
            return await Task.Run(() =>
            {
                string mountedDrive = "";

                try
                {
                    // Use a temporary PowerShell file instead of an inline command
                    // so ISO paths with spaces or quotes stay predictable.
                    string scriptPath = Path.Combine(Path.GetTempPath(), $"mount_iso_{Guid.NewGuid()}.ps1");
                    string scriptContent = $@"
$ErrorActionPreference = 'Stop'
try {{
    $mountResult = Mount-DiskImage -ImagePath '{isoPath.Replace("'", "''")}' -PassThru
    Start-Sleep -Seconds 2
    $volume = $mountResult | Get-Volume
    if ($volume -and $volume.DriveLetter) {{
        Write-Output $volume.DriveLetter
    }} else {{
        Write-Error 'Failed to get drive letter'
        exit 1
    }}
}} catch {{
    Write-Error $_.Exception.Message
    exit 1
}}
";
                    File.WriteAllText(scriptPath, scriptContent);

                    // Run the mount script
                    var mountPsi = new ProcessStartInfo
                    {
                        FileName = "powershell.exe",
                        Arguments = $"-NoProfile -ExecutionPolicy Bypass -File \"{scriptPath}\"",
                        UseShellExecute = false,
                        RedirectStandardOutput = true,
                        RedirectStandardError = true,
                        CreateNoWindow = true
                    };

                    using (var process = Process.Start(mountPsi))
                    {
                        mountedDrive = process.StandardOutput.ReadToEnd().Trim();
                        string error = process.StandardError.ReadToEnd();
                        process.WaitForExit();

                        if (process.ExitCode != 0 || string.IsNullOrEmpty(mountedDrive))
                        {
                            Dispatcher.Invoke(() => Log($"ERROR mounting ISO: {error}"));
                            File.Delete(scriptPath);
                            return false;
                        }
                    }

                    File.Delete(scriptPath);

                    // Get only the first letter if multiple lines
                    if (mountedDrive.Contains("\n"))
                    {
                        mountedDrive = mountedDrive.Split('\n')[0].Trim();
                    }

                    Dispatcher.Invoke(() => Log($"ISO mounted at {mountedDrive}:"));

                    // Wait a bit for the drive to be ready
                    System.Threading.Thread.Sleep(2000);

                    // Copy all contents from mounted ISO to Z:
                    string sourceDir = $"{mountedDrive}:\\";
                    string destDir = @"Z:\";

                    if (!Directory.Exists(sourceDir))
                    {
                        Dispatcher.Invoke(() => Log($"ERROR: Source directory not found: {sourceDir}"));
                        return false;
                    }

                    Dispatcher.Invoke(() => Log($"Copying files from {sourceDir} to {destDir}..."));

                    // Use xcopy for reliable copying (robocopy can have issues with ISO)
                    var copyPsi = new ProcessStartInfo
                    {
                        FileName = "xcopy",
                        Arguments = $"\"{sourceDir}*\" \"{destDir}\" /E /H /Y /Q",
                        UseShellExecute = false,
                        RedirectStandardOutput = true,
                        RedirectStandardError = true,
                        CreateNoWindow = true
                    };

                    using (var copyProcess = Process.Start(copyPsi))
                    {
                        string copyOutput = copyProcess.StandardOutput.ReadToEnd();
                        string copyError = copyProcess.StandardError.ReadToEnd();
                        copyProcess.WaitForExit();

                        if (copyProcess.ExitCode != 0)
                        {
                            Dispatcher.Invoke(() => Log($"Copy error (exit {copyProcess.ExitCode}): {copyError}"));
                            return false;
                        }

                        // Get file count from xcopy output
                        var lines = copyOutput.Split('\n');
                        string lastLine = lines.Length > 0 ? lines[lines.Length - 1].Trim() : "done";
                        if (string.IsNullOrWhiteSpace(lastLine) && lines.Length > 1)
                            lastLine = lines[lines.Length - 2].Trim();
                        Dispatcher.Invoke(() => Log($"Copy completed: {(string.IsNullOrWhiteSpace(lastLine) ? "done" : lastLine)}"));
                    }

                    Dispatcher.Invoke(() => Log("Files copied successfully"));
                    return true;
                }
                catch (Exception ex)
                {
                    Dispatcher.Invoke(() => Log($"Mount/copy failed: {ex.Message}"));
                    return false;
                }
                finally
                {
                    // Always try to unmount the ISO
                    try
                    {
                        Dispatcher.Invoke(() => Log("Dismounting ISO..."));
                        var unmountPsi = new ProcessStartInfo
                        {
                            FileName = "powershell.exe",
                            Arguments = $"-NoProfile -ExecutionPolicy Bypass -Command \"Dismount-DiskImage -ImagePath '{isoPath.Replace("'", "''")}'\"",
                            UseShellExecute = false,
                            CreateNoWindow = true
                        };

                        using (var unmountProcess = Process.Start(unmountPsi))
                        {
                            unmountProcess.WaitForExit();
                        }
                        Dispatcher.Invoke(() => Log("ISO dismounted"));
                    }
                    catch (Exception unmountEx)
                    {
                        Dispatcher.Invoke(() => Log($"Warning: Could not dismount ISO: {unmountEx.Message}"));
                    }
                }
            });
        }

        private async Task<bool> InstallWindowsRecoveryGuardAsync(double requestedLinuxMB)
        {
            return await Task.Run(() =>
            {
                try
                {
                    Directory.CreateDirectory(RecoveryRoot);

                    string sourceScript = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Scripts", "libertix-recovery-guard.ps1");
                    string targetScript = Path.Combine(RecoveryRoot, "recover.ps1");
                    if (!File.Exists(sourceScript))
                    {
                        Dispatcher.Invoke(() => Log($"ERROR: Recovery guard script missing: {sourceScript}"));
                        return false;
                    }

                    File.Copy(sourceScript, targetScript, true);

                    if (_storagePreflight == null || _storagePreflight.Firmware != FirmwareType.Bios)
                    {
                        Dispatcher.Invoke(() => Log("ERROR: BIOS storage preflight is missing."));
                        return false;
                    }

                    string bcdBackupPath = Path.Combine(RecoveryRoot, "bcd-backup");
                    if (File.Exists(bcdBackupPath))
                        File.Delete(bcdBackupPath);
                    var bcdBackup = RunProcess(
                        ResolveSystemExecutable("bcdedit.exe", "bcdedit.exe"),
                        $"/export {QuoteArgument(bcdBackupPath)}",
                        waitMs: 30000);
                    if (bcdBackup.exitCode != 0 || !File.Exists(bcdBackupPath))
                    {
                        Dispatcher.Invoke(() => Log(
                            $"ERROR: BCD backup failed rc={bcdBackup.exitCode}: {bcdBackup.error}"));
                        return false;
                    }

                    // pending.env lets the startup guard identify the expected
                    // temporary partition size without hardcoding UI choices.
                    string metadataPath = Path.Combine(RecoveryRoot, "pending.env");
                    string metadata = string.Join(Environment.NewLine, new[]
                    {
                        "LIBERTIX_INSTALL_PENDING=true",
                        $"LINUX_SIZE_MB={requestedLinuxMB:F0}",
                        $"SYSTEM_DRIVE={_storagePreflight.SystemDrive}",
                        $"SYSTEM_DISK_NUMBER={_storagePreflight.SystemDiskNumber}",
                        $"SYSTEM_PARTITION_NUMBER={_storagePreflight.SystemPartitionNumber}",
                        $"SYSTEM_PARTITION_OFFSET={_storagePreflight.SystemPartitionOffset}",
                        $"SYSTEM_PARTITION_SIZE_BYTES={_storagePreflight.SystemPartitionSize}",
                        $"SYSTEM_DISK_UNIQUE_ID={_storagePreflight.SystemDiskUniqueId}",
                        $"RECOVERY_PARTITION_NUMBER={_storagePreflight.RecoveryPartitionNumber}",
                        $"RECOVERY_PARTITION_OFFSET_BYTES={_storagePreflight.RecoveryPartitionOffset}",
                        $"RECOVERY_PARTITION_SIZE_BYTES={_storagePreflight.RecoveryPartitionSize}",
                        $"CREATED_UTC={DateTime.UtcNow:O}"
                    });
                    File.WriteAllText(metadataPath, metadata + Environment.NewLine);

                    string taskCommand = $"powershell.exe -NoProfile -ExecutionPolicy Bypass -File '{targetScript}'";
                    string args = $"/Create /TN \"{RecoveryTaskName}\" /SC ONSTART /RU SYSTEM /RL HIGHEST /TR \"{taskCommand}\" /F";
                    var result = RunProcess("schtasks.exe", args, waitMs: 30000);
                    Dispatcher.Invoke(() =>
                    {
                        Log($"schtasks create {RecoveryTaskName}: {(result.exitCode == 0 ? "OK" : "Failed")}");
                        if (!string.IsNullOrWhiteSpace(result.output))
                            Log(result.output.Trim());
                        if (!string.IsNullOrWhiteSpace(result.error))
                            Log($"ERROR: {result.error.Trim()}");
                    });

                    _biosRecoveryGuardInstalled = result.exitCode == 0;
                    return _biosRecoveryGuardInstalled;
                }
                catch (Exception ex)
                {
                    Dispatcher.Invoke(() => Log($"Recovery guard setup failed: {ex.Message}"));
                    return false;
                }
            });
        }

        private static bool IsRunningAsAdministrator()
        {
            using (var identity = WindowsIdentity.GetCurrent())
            {
                var principal = new WindowsPrincipal(identity);
                return principal.IsInRole(WindowsBuiltInRole.Administrator);
            }
        }

        private static FirmwareType DetectFirmwareTypeOrThrow()
        {
            if (GetFirmwareType(out var firmwareType))
            {
                if (firmwareType == FirmwareType.Bios || firmwareType == FirmwareType.Uefi)
                    return firmwareType;
                throw new InvalidOperationException($"Unsupported firmware type: {firmwareType}.");
            }

            int error = Marshal.GetLastWin32Error();
            throw new InvalidOperationException(
                $"Windows could not determine the firmware type (Win32 error {error}). " +
                "Installation was stopped before any disk change.");
        }

        private async Task<StoragePreflightInfo> RunStoragePreflightAsync(FirmwareType firmware)
        {
            string scriptPath = Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory,
                "Scripts",
                "libertix-storage-preflight.ps1");
            if (!File.Exists(scriptPath))
                throw new FileNotFoundException("Storage preflight script is missing.", scriptPath);

            string expected = firmware == FirmwareType.Uefi ? "UEFI" : "BIOS";
            string powershell = ResolveSystemExecutable(
                "WindowsPowerShell\\v1.0\\powershell.exe",
                "powershell.exe");
            var result = await Task.Run(() => RunProcess(
                powershell,
                $"-NoProfile -ExecutionPolicy Bypass -File {QuoteArgument(scriptPath)} " +
                $"-ExpectedFirmware {expected} " +
                (firmware == FirmwareType.Bios ? "-DecryptBitLocker" : ""),
                firmware == FirmwareType.Bios ? (int)TimeSpan.FromHours(6.5).TotalMilliseconds : 120000));

            if (!string.IsNullOrWhiteSpace(result.output))
                Log(result.output.Trim());
            if (!string.IsNullOrWhiteSpace(result.error))
                Log($"ERROR: {result.error.Trim()}");
            if (result.exitCode != 0)
            {
                throw new InvalidOperationException(
                    $"Storage preflight failed with rc={result.exitCode}: {result.error}");
            }

            var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (string rawLine in result.output.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
            {
                int separator = rawLine.IndexOf('=');
                if (separator <= 0)
                    continue;
                values[rawLine.Substring(0, separator).Trim()] = rawLine.Substring(separator + 1).Trim();
            }

            string[] required =
            {
                "PREFLIGHT_OK", "FIRMWARE", "SYSTEM_DRIVE", "SYSTEM_DISK_NUMBER",
                "SYSTEM_PARTITION_NUMBER", "SYSTEM_PARTITION_OFFSET", "SYSTEM_PARTITION_SIZE",
                "BOOT_PARTITION_NUMBER", "BOOT_PARTITION_OFFSET", "BOOT_PARTITION_SIZE",
                "SYSTEM_DISK_UNIQUE_ID", "SYSTEM_DISK_SIZE", "PARTITION_STYLE",
                "RECOVERY_PARTITION_NUMBER", "RECOVERY_PARTITION_OFFSET", "RECOVERY_PARTITION_SIZE",
                "BITLOCKER_SAFE", "BITLOCKER_STATE"
            };
            foreach (string key in required)
            {
                if (!values.ContainsKey(key))
                    throw new InvalidOperationException($"Storage preflight did not return {key}.");
            }
            if (!string.Equals(values["PREFLIGHT_OK"], "true", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Storage preflight did not confirm a safe state.");

            var info = new StoragePreflightInfo
            {
                Firmware = firmware,
                SystemDrive = values["SYSTEM_DRIVE"],
                SystemDiskNumber = int.Parse(values["SYSTEM_DISK_NUMBER"], CultureInfo.InvariantCulture),
                SystemPartitionNumber = int.Parse(values["SYSTEM_PARTITION_NUMBER"], CultureInfo.InvariantCulture),
                SystemPartitionOffset = long.Parse(values["SYSTEM_PARTITION_OFFSET"], CultureInfo.InvariantCulture),
                SystemPartitionSize = long.Parse(values["SYSTEM_PARTITION_SIZE"], CultureInfo.InvariantCulture),
                BootPartitionNumber = int.Parse(values["BOOT_PARTITION_NUMBER"], CultureInfo.InvariantCulture),
                BootPartitionOffset = long.Parse(values["BOOT_PARTITION_OFFSET"], CultureInfo.InvariantCulture),
                BootPartitionSize = long.Parse(values["BOOT_PARTITION_SIZE"], CultureInfo.InvariantCulture),
                SystemDiskUniqueId = values["SYSTEM_DISK_UNIQUE_ID"],
                SystemDiskSize = long.Parse(values["SYSTEM_DISK_SIZE"], CultureInfo.InvariantCulture),
                PartitionStyle = values["PARTITION_STYLE"],
                RecoveryPartitionNumber = int.Parse(values["RECOVERY_PARTITION_NUMBER"], CultureInfo.InvariantCulture),
                RecoveryPartitionOffset = long.Parse(values["RECOVERY_PARTITION_OFFSET"], CultureInfo.InvariantCulture),
                RecoveryPartitionSize = long.Parse(values["RECOVERY_PARTITION_SIZE"], CultureInfo.InvariantCulture),
                BitLockerSafe = bool.Parse(values["BITLOCKER_SAFE"]),
                BitLockerState = values["BITLOCKER_STATE"]
            };

            if (firmware == FirmwareType.Bios && !info.BitLockerSafe)
                throw new InvalidOperationException("BitLocker is not fully decrypted on the Windows volume.");

            Log($"Storage preflight OK: firmware={expected}, disk={info.SystemDiskNumber}, " +
                $"partition={info.SystemPartitionNumber}, style={info.PartitionStyle}, " +
                $"BitLocker={info.BitLockerState}.");
            return info;
        }

        private static string ResolveSystemExecutable(string relativeSystemPath, string fallback)
        {
            string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            string sysnative = Path.Combine(windows, "Sysnative", relativeSystemPath);
            if (File.Exists(sysnative))
                return sysnative;

            string system32 = Path.Combine(windows, "System32", relativeSystemPath);
            if (File.Exists(system32))
                return system32;

            string system = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), fallback);
            return File.Exists(system) ? system : fallback;
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

        private static string ShellQuoteValue(string value)
        {
            value = value ?? string.Empty;
            if (value.Contains("\r") || value.Contains("\n"))
                throw new InvalidOperationException("Config values cannot contain newlines");
            return "'" + value.Replace("'", "'\\''") + "'";
        }

        private (int exitCode, string output, string error) RunProcess(string fileName, string arguments, int waitMs)
        {
            var psi = new ProcessStartInfo
            {
                FileName = fileName,
                Arguments = arguments,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            };

            using (var process = Process.Start(psi))
            {
                var outputTask = process.StandardOutput.ReadToEndAsync();
                var errorTask = process.StandardError.ReadToEndAsync();
                if (!process.WaitForExit(waitMs))
                {
                    try { process.Kill(); } catch { }
                    Task.WaitAll(new Task[] { outputTask, errorTask }, 2000);
                    return (-1, outputTask.IsCompleted ? outputTask.Result : "", "Process timed out");
                }

                Task.WaitAll(outputTask, errorTask);
                return (process.ExitCode, outputTask.Result, errorTask.Result);
            }
        }

        private async Task<(double freeSpaceSizeMB, double recoveryOffsetMB)> GetFreeSpaceInfoAsync()
        {
            string diskpartScript = Path.Combine(Path.GetTempPath(), $"freespace_{Guid.NewGuid()}.txt");

            try
            {
                // Query partition layout to find free space
                string script = @"select disk 0
list partition
exit";

                File.WriteAllText(diskpartScript, script);
                string output = await RunDiskpartAndGetOutputAsync(diskpartScript);

                // Parse partitions to find free space location
                var partitions = new List<(int number, double offsetMB, double sizeMB)>();

                var lines = output.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);

                foreach (var line in lines)
                {
                    // Match: "Partition 2    Principale         127 G octets     51 M octets"
                    // The first size is the partition size, the second is the offset
                    var partitionMatch = Regex.Match(line, @"Partition\s+(\d+)", RegexOptions.IgnoreCase);
                    if (!partitionMatch.Success)
                        continue;

                    int partitionNumber = int.Parse(partitionMatch.Groups[1].Value);

                    // Find all size/offset values in the line
                    var sizeMatches = Regex.Matches(line, @"(\d+)\s*(G|M|K)\s*o?", RegexOptions.IgnoreCase);

                    if (sizeMatches.Count >= 2)
                    {
                        // First match = size, Second match = offset
                        double sizeMB = ParseSizeToMB(sizeMatches[0]);
                        double offsetMB = ParseSizeToMB(sizeMatches[1]);

                        partitions.Add((partitionNumber, offsetMB, sizeMB));
                        Log($"  Partition {partitionNumber}: size={sizeMB:N0}MB, offset={offsetMB:N0}MB");
                    }
                }

                if (partitions.Count < 2)
                {
                    Log("ERROR: Could not find enough partitions to determine free space");
                    return (0, 0);
                }

                // Sort by offset
                partitions.Sort((a, b) => a.offsetMB.CompareTo(b.offsetMB));

                // Find Windows partition (second partition after sorting) and where it ends
                var windowsPartition = partitions[1];
                double windowsEndMB = windowsPartition.offsetMB + windowsPartition.sizeMB;

                // Find Recovery partition (last partition by offset)
                var recoveryPartition = partitions[partitions.Count - 1];
                double recoveryOffsetMB = recoveryPartition.offsetMB;

                // Free space is between Windows end and Recovery start
                double freeSpaceSizeMB = recoveryOffsetMB - windowsEndMB;

                Log($"Windows ends at: {windowsEndMB:N0}MB");
                Log($"Recovery starts at: {recoveryOffsetMB:N0}MB");
                Log($"Free space size: {freeSpaceSizeMB:N0}MB");

                return (freeSpaceSizeMB, recoveryOffsetMB);
            }
            catch (Exception ex)
            {
                Log($"Error getting free space info: {ex.Message}");
                return (0, 0);
            }
            finally
            {
                if (File.Exists(diskpartScript))
                    File.Delete(diskpartScript);
            }
        }

        private double ParseSizeToMB(Match match)
        {
            double size = double.Parse(match.Groups[1].Value);
            string unit = match.Groups[2].Value.ToUpper();

            switch (unit)
            {
                case "G":
                    return size * 1024;
                case "K":
                    return size / 1024;
                default:
                    return size;
            }
        }

        private async Task<double> QueryShrinkSpaceAsync()
        {
            string diskpartScript = Path.Combine(Path.GetTempPath(), $"querymax_{Guid.NewGuid()}.txt");

            try
            {
                string systemDrive = Path.GetPathRoot(Environment.SystemDirectory).TrimEnd('\\');

                string script = $@"rescan
select volume {systemDrive[0]}
shrink querymax
exit";

                File.WriteAllText(diskpartScript, script);
                var (success, output) = await RunDiskpartWithResultAsync(diskpartScript);

                // Parse the max shrink size from output
                // French: "Le nombre maximal d'octets récupérables est :   12 GB (12445 Mo)"
                // English: "The maximum number of reclaimable bytes is: 12 GB"
                var match = Regex.Match(output, @"(\d+)\s*(?:GB|Go|G)\s*\((\d+)\s*Mo\)", RegexOptions.IgnoreCase);
                if (match.Success)
                {
                    return double.Parse(match.Groups[2].Value); // Return MB value
                }

                // Try alternative pattern
                match = Regex.Match(output, @"(\d+)\s*(?:MB|Mo|M)", RegexOptions.IgnoreCase);
                if (match.Success)
                {
                    return double.Parse(match.Groups[1].Value);
                }

                return 0;
            }
            finally
            {
                if (File.Exists(diskpartScript))
                    File.Delete(diskpartScript);
            }
        }

        private async Task<bool> ShrinkWindowsPartitionAsync(double shrinkSizeMB)
        {
            string diskpartScript = Path.Combine(Path.GetTempPath(), $"shrink_{Guid.NewGuid()}.txt");

            try
            {
                // Get system drive letter
                string systemDrive = Path.GetPathRoot(Environment.SystemDirectory).TrimEnd('\\');

                // Create diskpart script with rescan to refresh disk state
                string script = $@"rescan
list volume
select volume {systemDrive[0]}
shrink desired={shrinkSizeMB:F0}
exit";

                File.WriteAllText(diskpartScript, script);
                Log($"Running diskpart: shrink {shrinkSizeMB:F0}MB from {systemDrive}");

                var (success, output) = await RunDiskpartWithResultAsync(diskpartScript);

                // Check if shrink was successful by looking for success message
                if (output.Contains("réduit") || output.Contains("shrunk") || output.Contains("reduced"))
                {
                    return true;
                }

                // Check for specific error messages
                if (output.Contains("insuffisant") || output.Contains("pas assez") || output.Contains("not enough"))
                {
                    Log("ERROR: Not enough space available for shrinking");
                    return false;
                }

                return success;
            }
            finally
            {
                if (File.Exists(diskpartScript))
                    File.Delete(diskpartScript);
            }
        }

        private async Task<bool> RefreshWindowsRecoveryRegistrationAsync()
        {
            return await Task.Run(() =>
            {
                var disable = RunProcess("reagentc.exe", "/disable", waitMs: 60000);
                if (disable.exitCode != 0)
                {
                    Log($"WinRE disable was not required: {disable.output} {disable.error}".Trim());
                }

                var enable = RunProcess("reagentc.exe", "/enable", waitMs: 60000);
                if (enable.exitCode != 0)
                {
                    Log($"ERROR: reagentc /enable failed rc={enable.exitCode}: {enable.output} {enable.error}".Trim());
                    return false;
                }

                var status = RunProcess("reagentc.exe", "/info", waitMs: 60000);
                if (status.exitCode != 0)
                {
                    Log($"ERROR: reagentc /info failed rc={status.exitCode}: {status.output} {status.error}".Trim());
                    return false;
                }

                string normalizedStatus = RemoveDiacritics(status.output).ToLowerInvariant();
                bool enabled = normalizedStatus.Contains("enabled") ||
                    (normalizedStatus.Contains("active") && !normalizedStatus.Contains("desactive"));
                if (!enabled)
                {
                    Log($"ERROR: WinRE is not enabled after refresh: {status.output}".Trim());
                    return false;
                }

                Log("Windows Recovery Environment is enabled on the final partition layout.");
                return true;
            });
        }

        private static string RemoveDiacritics(string value)
        {
            string decomposed = (value ?? string.Empty).Normalize(NormalizationForm.FormD);
            var builder = new StringBuilder(decomposed.Length);
            foreach (char character in decomposed)
            {
                if (CharUnicodeInfo.GetUnicodeCategory(character) != UnicodeCategory.NonSpacingMark)
                    builder.Append(character);
            }
            return builder.ToString().Normalize(NormalizationForm.FormC);
        }

        private async Task<bool> CreateFat32PartitionSimpleAsync(double sizeMB)
        {
            string diskpartScript = Path.Combine(Path.GetTempPath(), $"create_fat32_{Guid.NewGuid()}.txt");

            try
            {
                // No offset is specified: diskpart places this at the first free
                // slot after Windows, which is the slot the live installer reuses.
                if (_storagePreflight == null)
                    throw new InvalidOperationException("Storage preflight is missing.");

                string script = $@"rescan
select disk {_storagePreflight.SystemDiskNumber}
create partition primary size={sizeMB:F0}
format fs=fat32 quick label=LIBERTIX
assign letter=Z
exit";

                File.WriteAllText(diskpartScript, script);
                Log($"Diskpart command: create partition primary size={sizeMB:F0} (no offset)");
                Log("Running diskpart to create FAT32 partition...");

                var (success, output) = await RunDiskpartWithResultAsync(diskpartScript);

                // Check for success indicators
                if (output.Contains("créé") || output.Contains("created") || output.Contains("formaté") || output.Contains("formatted"))
                {
                    return true;
                }

                return success;
            }
            finally
            {
                if (File.Exists(diskpartScript))
                    File.Delete(diskpartScript);
            }
        }

        private async Task<(bool success, string output)> RunDiskpartWithResultAsync(string scriptPath)
        {
            return await Task.Run(() =>
            {
                try
                {
                    var psi = new ProcessStartInfo
                    {
                        FileName = "diskpart.exe",
                        Arguments = $"/s \"{scriptPath}\"",
                        UseShellExecute = false,
                        RedirectStandardOutput = true,
                        RedirectStandardError = true,
                        CreateNoWindow = true
                    };

                    using (var process = Process.Start(psi))
                    {
                        string output = process.StandardOutput.ReadToEnd();
                        string error = process.StandardError.ReadToEnd();
                        process.WaitForExit();

                        Dispatcher.Invoke(() =>
                        {
                            if (!string.IsNullOrWhiteSpace(output))
                                Log(output);
                            if (!string.IsNullOrWhiteSpace(error))
                                Log($"ERROR: {error}");
                        });

                        // Check for error keywords in output
                        bool hasError = output.ToLower().Contains("introuvable") ||
                                       output.ToLower().Contains("erreur") ||
                                       output.ToLower().Contains("error") ||
                                       output.ToLower().Contains("failed") ||
                                       output.ToLower().Contains("impossible") ||
                                       output.ToLower().Contains("insuffisant");

                        return (process.ExitCode == 0 && !hasError, output);
                    }
                }
                catch (Exception ex)
                {
                    Dispatcher.Invoke(() => Log($"Exception: {ex.Message}"));
                    return (false, ex.Message);
                }
            });
        }

        private void RebootButton_Click(object sender, RoutedEventArgs e)
        {
            var result = MessageBox.Show(
                Application.Current.Resources["ApplyChangesRebootConfirm"] as string ?? "The computer will restart to complete the installation. Continue?",
                Application.Current.Resources["WarningTitle"] as string ?? "Warning",
                MessageBoxButton.YesNo,
                MessageBoxImage.Question);

            if (result == MessageBoxResult.Yes)
            {
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

        private void Log(string message)
        {
            Dispatcher.Invoke(() =>
            {
                LogOutput.AppendText($"[{DateTime.Now:HH:mm:ss}] {message}\n");
                LogOutput.ScrollToEnd();
            });
        }
    }
}
