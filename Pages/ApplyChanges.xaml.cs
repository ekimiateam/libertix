using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Security.Principal;
using System.Text;
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
        private const double FAT32_SIZE_GB = 2.0;
        private const string RecoveryTaskName = "LibertixInstallRecovery";
        private const string RecoveryRoot = @"C:\LibertixInstallRecovery";
        private bool _isRunning = false;

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

                await ExecutePartitioningAsync();
            }
            catch (Exception ex)
            {
                Log($"ERROR: {ex.Message}");
                UpdateProgress(0, Application.Current.Resources["ApplyChangesError"] as string ?? "Error occurred");
                BackButton.IsEnabled = true;
                _isRunning = false;
            }
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
                Log("ERROR: Failed to shrink Windows partition (step 1)");
                BackButton.IsEnabled = true;
                _isRunning = false;
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
                Log("ERROR: Failed to create FAT32 partition");
                BackButton.IsEnabled = true;
                _isRunning = false;
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
            string isoUrl = "";
            if (App.Current.Properties["SelectedDistro"] is DistroInfo distro && !string.IsNullOrEmpty(distro.IsoUrl))
            {
                isoUrl = distro.IsoUrl;
            }

            if (string.IsNullOrEmpty(isoUrl))
            {
                Log("ERROR: No ISO URL found for selected distribution");
                UpdateProgress(0, Application.Current.Resources["ApplyChangesError"] as string ?? "Error occurred");
                BackButton.IsEnabled = true;
                _isRunning = false;
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
                Log("ERROR: Failed to download ISO");
                UpdateProgress(0, Application.Current.Resources["ApplyChangesError"] as string ?? "Error occurred");
                BackButton.IsEnabled = true;
                _isRunning = false;
                return;
            }

            // Step 5: Mount ISO and copy contents to Z:
            UpdateProgress(80, "Copying ISO contents to Z:...");
            Log("Step 5: Mounting ISO and copying contents to Z:...");

            bool copySuccess = await MountAndCopyIsoAsync(tempIsoPath);
            if (!copySuccess)
            {
                Log("ERROR: Failed to copy ISO contents");
                UpdateProgress(0, Application.Current.Resources["ApplyChangesError"] as string ?? "Error occurred");
                BackButton.IsEnabled = true;
                _isRunning = false;
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
                    Log("ERROR: Failed to download Linux installer ISO");
                    UpdateProgress(0, Application.Current.Resources["ApplyChangesError"] as string ?? "Error occurred");
                    BackButton.IsEnabled = true;
                    _isRunning = false;
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
                Log("WARNING: Failed to write config.txt, will use defaults");
            }

            // Step 8: GRUB4DOS is only a temporary Windows Boot Manager bridge.
            // The live installer removes these files before touching Linux.
            UpdateProgress(96, "Downloading bootloader files...");
            Log("Step 8: Downloading GRUB4DOS files to C:\\...");

            string[] grubFiles = { "grldr", "grldr.mbr", "menu.lst" };
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
                    Log($"ERROR: Failed to obtain {file}");
                    UpdateProgress(0, Application.Current.Resources["ApplyChangesError"] as string ?? "Error occurred");
                    BackButton.IsEnabled = true;
                    _isRunning = false;
                    return;
                }
                Log($"Ready: {file} at C:\\");
            }

            // Step 9: make the next reboot enter the live installer once.
            // Windows remains the default BCD entry for later boots.
            UpdateProgress(98, "Configuring boot entry...");
            Log("Step 9: Configuring GRUB4DOS boot entry...");
            System.Threading.Thread.Sleep(1000);

            bool bootConfigured = await ConfigureBootEntryAsync();
            if (!bootConfigured)
            {
                Log("ERROR: Failed to configure boot entry");
                UpdateProgress(0, Application.Current.Resources["ApplyChangesError"] as string ?? "Error occurred");
                BackButton.IsEnabled = true;
                _isRunning = false;
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

            return await Task.Run(() =>
            {
                try
                {
                    string configPath = @"Z:\config.txt";

                    // These defaults are only used if the wizard state is missing.
                    // Normal automation fills AccountInfo before this page runs.
                    string username = "user";
                    string password = "password";
                    string computerName = "linux-pc";

                    if (App.Current.Properties["AccountInfo"] is AccountInfo account)
                    {
                        username = account.Username;
                        password = account.Password;
                        computerName = account.ComputerName;
                    }

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
                        $"PASSWORD={ShellQuoteValue(password)}",
                        $"ISO_FILENAME={ShellQuoteValue(isoFilename)}",
                        $"ISO_WINDOWS_PATH={ShellQuoteValue(isoWindowsPath)}",
                        $"LINUX_SIZE_GB={ShellQuoteValue(_linuxSizeGB.ToString("F0"))}"
                    };

                    File.WriteAllText(configPath, string.Join("\n", configLines));

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

                    // pending.env lets the startup guard identify the expected
                    // temporary partition size without hardcoding UI choices.
                    string metadataPath = Path.Combine(RecoveryRoot, "pending.env");
                    string metadata = string.Join(Environment.NewLine, new[]
                    {
                        "LIBERTIX_INSTALL_PENDING=true",
                        $"LINUX_SIZE_MB={requestedLinuxMB:F0}",
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

                    return result.exitCode == 0;
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

        private async Task<bool> CreateFat32PartitionSimpleAsync(double sizeMB)
        {
            string diskpartScript = Path.Combine(Path.GetTempPath(), $"create_fat32_{Guid.NewGuid()}.txt");

            try
            {
                // No offset is specified: diskpart places this at the first free
                // slot after Windows, which is the slot the live installer reuses.
                string script = $@"rescan
select disk 0
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
