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
        private async Task ExecutePartitioningAsync()
        {
            if (_installationPlan == null)
                throw new InvalidOperationException("Installation plan is not initialized.");

            InstallationDistribution distribution = _installationPlan.Distribution;
            InstallationSizes installationSizes =
                InstallationSizePolicy.FromRequestedGigabytes(_linuxSizeGB);

            // Query available shrink space first
            Log("Checking available shrink space...");
            double maxShrinkMB = await QueryShrinkSpaceAsync();
            ThrowIfCancellationRequested();
            Log($"Maximum shrinkable space: {maxShrinkMB / 1024:N1}GB ({maxShrinkMB:N0}MB)");

            // The temporary FAT32 live partition is created at the final Linux size.
            // The live system reformats this same slot as ext4, avoiding MBR delete/recreate.
            double requestedLinuxMB = installationSizes.FinalSizeMiB;
            double minRequiredMB = requestedLinuxMB;
            if (maxShrinkMB < minRequiredMB)
            {
                RecordExecutionFailure(
                    "BIOS_INSUFFICIENT_SHRINK_SPACE",
                    "Windows does not expose enough shrinkable space for the requested Linux size.",
                    InstallationPhase.Windows);
                Log($"ERROR: Not enough shrinkable space!");
                Log($"  Minimum required: {minRequiredMB / 1024:N1}GB");
                Log($"  Available: {maxShrinkMB / 1024:N1}GB");
                UpdateProgress(0, Application.Current.Resources["ApplyChangesError"] as string ?? "Error occurred");
                FinishInstallation(enableBackButton: true);
                return;
            }

            Log("Installing Windows recovery guard...");
            // This guard is installed before any partition change. If the live
            // installer dies before writing a success marker, Windows can delete
            // the temporary Linux slot and grow C: back on the next startup.
            StartExecutionStep(InstallationStep.WindowsRecoveryArmed);
            bool recoveryGuardReady = await InstallWindowsRecoveryGuardAsync(requestedLinuxMB);
            ThrowIfCancellationRequested();
            if (!recoveryGuardReady)
            {
                RecordExecutionFailure(
                    "BIOS_RECOVERY_GUARD_FAILED",
                    "Windows recovery guard installation failed before any disk modification.",
                    InstallationPhase.Windows);
                Log("ERROR: Failed to install Windows recovery guard");
                UpdateProgress(0, Application.Current.Resources["ApplyChangesError"] as string ?? "Error occurred");
                FinishInstallation(enableBackButton: true);
                return;
            }
            CompleteExecutionStep(InstallationStep.WindowsRecoveryArmed);

            // Step 1: Shrink Windows by the full requested Linux size.
            UpdateProgress(10, Application.Current.Resources["ApplyChangesStep1"] as string ?? "Shrinking Windows partition...");
            Log($"Step 1: Shrinking Windows by {_linuxSizeGB:N0}GB for the reusable live/Linux partition...");

            StartExecutionStep(InstallationStep.WindowsSystemVolumeShrunk);
            bool step1Success = await ShrinkWindowsPartitionAsync(requestedLinuxMB);
            ThrowIfCancellationRequested();
            if (!step1Success)
            {
                await FailBiosPreparationAndRollbackAsync("Failed to shrink Windows partition (step 1)");
                return;
            }
            CompleteExecutionStep(InstallationStep.WindowsSystemVolumeShrunk);

            // Wait for disk to update
            Log("Waiting for disk to update...");
            await Task.Delay(3000, _installationCancellation.Token);

            // Step 2: Create FAT32 in the free space immediately after Windows.
            // Windows cannot reliably format FAT32 above 32 GB, so large Linux
            // allocations use an 8 GB staging partition that the live expands.
            double biosStagingMB = installationSizes.StagingSizeMiB;
            UpdateProgress(
                30,
                Application.Current.Resources["ApplyChangesStep2"] as string
                    ?? "Creating FAT32 boot partition (Z:)...");
            if (biosStagingMB < requestedLinuxMB)
            {
                Log(
                    $"Step 2: Creating {biosStagingMB / 1024:N0}GB FAT32 staging partition; "
                    + $"the live will expand it to {_linuxSizeGB:N0}GB...");
            }
            else
            {
                Log($"Step 2: Creating FAT32 live partition at final size ({_linuxSizeGB:N0}GB)...");
            }

            StartExecutionStep(InstallationStep.WindowsInstallerPartitionCreated);
            bool step2Success = await CreateFat32PartitionSimpleAsync(biosStagingMB);
            ThrowIfCancellationRequested();
            if (!step2Success)
            {
                await FailBiosPreparationAndRollbackAsync("Failed to create FAT32 partition");
                return;
            }
            await UpdateInstallerPartitionIdentityAsync('Z');
            CompleteExecutionStep(InstallationStep.WindowsInstallerPartitionCreated);

            // On MBR, inserting the Linux slot before the recovery partition
            // can change its partition number. Refresh WinRE while Windows is
            // still booted through its normal BCD store; after GRUB is written,
            // ReAgentC can no longer reliably update that store.
            Log("Refreshing Windows Recovery Environment registration...");
            bool winReReady = await RefreshWindowsRecoveryRegistrationAsync();
            ThrowIfCancellationRequested();
            if (!winReReady)
            {
                await FailBiosPreparationAndRollbackAsync(
                    "Windows Recovery Environment could not be re-enabled after partitioning");
                return;
            }

            // Wait for disk to update
            Log("Waiting for disk to update...");
            await Task.Delay(3000, _installationCancellation.Token);

            Log("Step 3: No second shrink needed; live partition will become the Linux partition.");

            // Wait for disk to update
            Log("Waiting for disk to update...");
            UpdateProgress(50, Application.Current.Resources["ApplyChangesWaitDisk"] as string ?? "Waiting for disk update...");
            await Task.Delay(3000, _installationCancellation.Token);

            // Step 4: Download ISO
            string isoUrl = distribution.LiveIsoUrl;

            if (string.IsNullOrEmpty(isoUrl))
            {
                await FailBiosPreparationAndRollbackAsync("No ISO URL found for selected distribution");
                return;
            }

            UpdateProgress(55, Localized("ApplyChangesDownloadingIso", "Downloading ISO..."));
            Log($"Step 4: Downloading ISO from {isoUrl}...");
            StartExecutionStep(InstallationStep.WindowsArtifactsVerified);

            string tempIsoPath = Path.Combine(Path.GetTempPath(), "libertix_installer.iso");
            string localIsoName = Path.GetFileName(new Uri(isoUrl).LocalPath);
            string localIsoPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, localIsoName);
            bool downloadSuccess = false;

            if (File.Exists(localIsoPath))
            {
                Log($"Found local ISO: {localIsoName}, copying...");
                await Task.Run(() => File.Copy(localIsoPath, tempIsoPath, true));
                ThrowIfCancellationRequested();
                downloadSuccess = true;
                UpdateProgress(80, Localized("ApplyChangesIsoCopied", "ISO copied from local folder"));
            }
            else
            {
                downloadSuccess = await DownloadIsoAsync(isoUrl, tempIsoPath);
            }
            ThrowIfCancellationRequested();

            if (!downloadSuccess)
            {
                await FailBiosPreparationAndRollbackAsync("Failed to download ISO");
                return;
            }
            if (!await VerifySha256Async(tempIsoPath, distribution.LiveIsoSha256, "Libertix BIOS ISO"))
            {
                await FailBiosPreparationAndRollbackAsync("Libertix BIOS ISO integrity verification failed");
                return;
            }
            ThrowIfCancellationRequested();
            CompleteExecutionStep(InstallationStep.WindowsArtifactsVerified);

            // Step 5: Mount ISO and copy contents to Z:
            UpdateProgress(80, Localized("ApplyChangesCopyingIsoContents", "Copying ISO contents to Z:..."));
            Log("Step 5: Mounting ISO and copying contents to Z:...");
            StartExecutionStep(InstallationStep.WindowsLiveMediaPrepared);

            bool copySuccess = await MountAndCopyIsoAsync(tempIsoPath);
            ThrowIfCancellationRequested();
            if (!copySuccess)
            {
                await FailBiosPreparationAndRollbackAsync("Failed to copy ISO contents");
                return;
            }

            bool biosLowMemoryMode =
                _installationState.Compatibility is CompatibilityInfo biosCompatibility &&
                biosCompatibility.LowMemoryMode;
            if (biosLowMemoryMode && !await ConfigureBiosLowMemoryBootAsync(tempIsoPath))
            {
                await FailBiosPreparationAndRollbackAsync("Failed to configure low-memory live boot");
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
            if (!string.IsNullOrEmpty(distribution.InstallerIsoUrl) &&
                !string.IsNullOrEmpty(distribution.InstallerIsoFileName))
            {
                UpdateProgress(85, Localized("ApplyChangesDownloadingLinuxIso", "Downloading Linux installer ISO..."));
                Log($"Step 6: Downloading Linux installer from {distribution.InstallerIsoUrl}...");

                string installerPath = distribution.InstallerIsoWindowsPath;
                Directory.CreateDirectory(Path.GetDirectoryName(installerPath));
                string localInstallerPath = Path.Combine(
                    AppDomain.CurrentDomain.BaseDirectory,
                    distribution.InstallerIsoFileName);
                bool installerDownloadSuccess = false;

                if (File.Exists(localInstallerPath))
                {
                    Log($"Found local installer ISO: {distribution.InstallerIsoFileName}, copying...");
                    await Task.Run(() => File.Copy(localInstallerPath, installerPath, true));
                    ThrowIfCancellationRequested();
                    installerDownloadSuccess = true;
                    UpdateProgress(95, Localized("ApplyChangesLinuxIsoCopied", "Linux installer copied from local folder"));
                }
                else
                {
                    installerDownloadSuccess = await DownloadInstallerIsoAsync(
                        distribution.InstallerIsoUrl,
                        installerPath);
                }
                ThrowIfCancellationRequested();

                if (!installerDownloadSuccess)
                {
                    await FailBiosPreparationAndRollbackAsync("Failed to download Linux installer ISO");
                    return;
                }
                if (!await VerifySha256Async(
                    installerPath,
                    distribution.InstallerIsoSha256,
                    "Mint ISO"))
                {
                    await FailBiosPreparationAndRollbackAsync("Mint ISO integrity verification failed");
                    return;
                }
                ThrowIfCancellationRequested();
                Log($"Linux installer saved to {installerPath}");
            }

            // Step 7: Write config.txt AFTER ISO copy (so it doesn't get overwritten)
            UpdateProgress(95, Localized("ApplyChangesWritingConfiguration", "Writing configuration..."));
            Log("Step 7: Writing configuration to Z:\\config.txt...");

            bool configSuccess = await WriteConfigToFat32Async();
            ThrowIfCancellationRequested();
            if (!configSuccess)
            {
                await FailBiosPreparationAndRollbackAsync("Failed to write config.txt");
                return;
            }
            PublishInstallationContextToLive(@"Z:\");
            CompleteExecutionStep(InstallationStep.WindowsLiveMediaPrepared);

            // Step 8: GRUB4DOS is only a temporary Windows Boot Manager bridge.
            // The live installer removes these files before touching Linux.
            UpdateProgress(96, Localized("ApplyChangesDownloadingBootloader", "Downloading bootloader files..."));
            Log("Step 8: Downloading GRUB4DOS files to C:\\...");
            StartExecutionStep(InstallationStep.WindowsTemporaryBootPrepared);

            string[] grubFiles = { "grldr", "grldr.mbr", "menu.lst" };
            var grubHashes = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                ["grldr"] = "124988a6091248111f5d372ad210f21250a42cfd05d9d6366be28347b6368675",
                ["grldr.mbr"] = "53fce0d82a09531b1a7af728e712a957db3966835304e8bdae5e350220270b33",
                ["menu.lst"] = "13731be2f7bee147e1da523293caa0a2fd8fdc65c299c7f8419cf050fcaa0760"
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
                ThrowIfCancellationRequested();

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
            UpdateProgress(98, Localized("ApplyChangesConfiguringBootEntry", "Configuring boot entry..."));
            Log("Step 9: Configuring GRUB4DOS boot entry...");
            await Task.Delay(1000, _installationCancellation.Token);

            bool bootConfigured = await ConfigureBootEntryAsync();
            ThrowIfCancellationRequested();
            if (!bootConfigured)
            {
                await FailBiosPreparationAndRollbackAsync("Failed to configure boot entry");
                return;
            }
            CompleteExecutionStep(InstallationStep.WindowsTemporaryBootPrepared);

            // Done
            UpdateProgress(100, Application.Current.Resources["ApplyChangesComplete"] as string ?? "Partitioning complete!");
            Log("Installation preparation completed successfully!");
            Log($"- FAT32 live partition: Z: ({biosStagingMB / 1024:N0}GB staging, {_linuxSizeGB:N0}GB reserved for Linux)");
            Log("- The live installer will expand it if needed, then reformat it as ext4 without deleting/recreating the MBR entry");
            Log("- ISO contents copied to Z:");
            Log("- GRUB4DOS bootloader installed");
            Log("- Boot entry 'Install Linux' added to Windows Boot Manager");
            Log("- Next reboot will automatically boot the Linux installer");
            Log("- Layout: [Windows] [FAT32 live/future Linux] [Recovery]");

            RebootButton.Visibility = Visibility.Visible;
            FinishInstallation(enableBackButton: false);
        }

        private async Task FailBiosPreparationAndRollbackAsync(
            string reason,
            string rollbackCompletedMessage = null)
        {
            RecordExecutionFailure("BIOS_PREPARATION_FAILED", reason, InstallationPhase.Windows);
            BeginExecutionRollback();
            Log($"ERROR: {reason}");
            UpdateProgress(0, Localized("ApplyChangesErrorRollback", "Error detected. Restoring Windows..."));

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
                        line => Log($"ROLLBACK: {line}"),
                        observeCancellation: false);
                    rollbackSucceeded = exitCode == 0;
                }
            }

            _biosRecoveryGuardInstalled = !rollbackSucceeded;
            if (rollbackSucceeded)
            {
                CompleteExecutionRollback();
                CleanupPendingWindowsSharePayload();
                Log("Automatic rollback completed and verified.");
                UpdateProgress(
                    0,
                    rollbackCompletedMessage ??
                        Localized(
                            "ApplyChangesPreparationErrorRestored",
                            "Preparation failed. Windows has been restored."));
                FinishInstallation(enableBackButton: true);
            }
            else
            {
                Log("CRITICAL: Automatic rollback did not complete. Do not retry or power off the machine.");
                UpdateProgress(
                    0,
                    Localized(
                        "ApplyChangesRollbackIncomplete",
                        "Rollback incomplete. Manual intervention is required."));
                FinishInstallation(enableBackButton: false);
                MessageBox.Show(
                    Localized(
                        "ApplyChangesBiosRollbackIncompleteDetails",
                        "Preparation failed and automatic rollback could not be verified. Do not " +
                        "restart the installation; review " +
                        "C:\\LibertixInstallRecovery\\recovery.log."),
                    Localized(
                        "ApplyChangesRollbackIncompleteTitle",
                        "Libertix - Incomplete rollback"),
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
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
                    RunProcess(
                        bcdeditPath,
                        "/create /d \"Install Linux\" /application bootsector",
                        (int)WindowsProcessTimeouts.QuickCommand.TotalMilliseconds,
                        GetWindowsConsoleEncoding()));
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

        private async Task<bool> WriteConfigToFat32Async()
        {
            if (_installationPlan == null ||
                !_installationPlan.Disk.Installer.Number.HasValue ||
                !_installationPlan.Disk.Installer.OffsetBytes.HasValue)
            {
                Log("ERROR: Installation plan is incomplete while writing live config.");
                return false;
            }

            return await Task.Run(() =>
            {
                try
                {
                    InstallationPlan plan = _installationPlan;
                    InstallationDisk disk = plan.Disk;
                    InstallerPartitionPlan installer = disk.Installer;
                    InstallationLocale locale = plan.Locale;
                    InstallationAccount account = plan.Account;
                    InstallationFeatures features = plan.Features;
                    InstallationRuntime runtime = plan.Runtime;
                    string configPath = @"Z:\config.txt";

                    // This compatibility projection remains until every
                    // supported live image consumes installation-plan.json.
                    var configLines = new List<string>
                    {
                        $"INSTALLATION_PLAN_ID={ShellQuoteValue(plan.PlanId)}",
                        $"LANGUAGE_CODE={ShellQuoteValue(locale.LanguageCode)}",
                        $"SYSTEM_LANG={ShellQuoteValue(locale.SystemLanguage)}",
                        $"KEYBOARD_LAYOUT={ShellQuoteValue(locale.KeyboardLayout)}",
                        $"KEYBOARD_MODEL={ShellQuoteValue(locale.KeyboardModel)}",
                        $"TIMEZONE={ShellQuoteValue(locale.Timezone)}",
                        $"USERNAME={ShellQuoteValue(account.Username)}",
                        $"PASSWORD_HASH={ShellQuoteValue(account.PasswordHash)}",
                        $"COMPUTER_NAME={ShellQuoteValue(account.ComputerName)}",
                        $"ISO_FILENAME={ShellQuoteValue(plan.Distribution.InstallerIsoFileName)}",
                        $"ISO_URL={ShellQuoteValue(plan.Distribution.InstallerIsoUrl)}",
                        $"ISO_WINDOWS_PATH={ShellQuoteValue(plan.Distribution.InstallerIsoWindowsPath)}",
                        $"ISO_SHA256={ShellQuoteValue(plan.Distribution.InstallerIsoSha256)}",
                        "LINUX_SIZE_GB="
                            + ShellQuoteValue(
                                (installer.FinalSizeBytes / InstallationSizePolicy.BytesPerGiB)
                                    .ToString(CultureInfo.InvariantCulture)),
                        $"TARGET_DISK_NUMBER={ShellQuoteValue(disk.Number.ToString(CultureInfo.InvariantCulture))}",
                        $"TARGET_DISK_UNIQUE_ID={ShellQuoteValue(disk.UniqueId)}",
                        $"TARGET_DISK_SIZE_BYTES={ShellQuoteValue(disk.SizeBytes.ToString(CultureInfo.InvariantCulture))}",
                        "TARGET_LOGICAL_SECTOR_SIZE_BYTES="
                            + ShellQuoteValue(disk.LogicalSectorSizeBytes.ToString(CultureInfo.InvariantCulture)),
                        "WINDOWS_PARTITION_NUMBER="
                            + ShellQuoteValue(disk.Windows.Number.ToString(CultureInfo.InvariantCulture)),
                        "WINDOWS_PARTITION_OFFSET_BYTES="
                            + ShellQuoteValue(disk.Windows.OffsetBytes.ToString(CultureInfo.InvariantCulture)),
                        "WINDOWS_BOOT_PARTITION_NUMBER="
                            + ShellQuoteValue(disk.Boot.Number.ToString(CultureInfo.InvariantCulture)),
                        "WINDOWS_BOOT_PARTITION_OFFSET_BYTES="
                            + ShellQuoteValue(disk.Boot.OffsetBytes.ToString(CultureInfo.InvariantCulture)),
                        "INSTALLER_PARTITION_NUMBER="
                            + ShellQuoteValue(installer.Number.Value.ToString(CultureInfo.InvariantCulture)),
                        "INSTALLER_PARTITION_OFFSET_BYTES="
                            + ShellQuoteValue(installer.OffsetBytes.Value.ToString(CultureInfo.InvariantCulture)),
                        "INSTALLER_FINAL_SIZE_BYTES="
                            + ShellQuoteValue(installer.FinalSizeBytes.ToString(CultureInfo.InvariantCulture)),
                        "INSTALLER_STAGING_SIZE_BYTES="
                            + ShellQuoteValue(installer.StagingSizeBytes.ToString(CultureInfo.InvariantCulture)),
                        $"EXPECTED_PARTITION_STYLE={ShellQuoteValue(disk.PartitionStyle)}",
                        $"RECOVERY_PARTITION_NUMBER={ShellQuoteValue(disk.Recovery.Number.ToString(CultureInfo.InvariantCulture))}",
                        "RECOVERY_PARTITION_OFFSET_BYTES="
                            + ShellQuoteValue(disk.Recovery.OffsetBytes.ToString(CultureInfo.InvariantCulture)),
                        $"RECOVERY_PARTITION_SIZE_BYTES={ShellQuoteValue(disk.Recovery.SizeBytes.ToString(CultureInfo.InvariantCulture))}",
                        $"RECOVERY_ROOT_WINDOWS={ShellQuoteValue(runtime.RecoveryRootWindows)}",
                        $"RECOVERY_RUN_ID={ShellQuoteValue(runtime.RecoveryRunId)}",
                        $"LOW_MEMORY_MODE={ShellQuoteValue(runtime.LowMemoryMode.ToString().ToLowerInvariant())}",
                        $"SHARE_WINDOWS_FILES_IN_LINUX={ShellQuoteValue(features.ShareWindowsFilesInLinux.ToString().ToLowerInvariant())}",
                        $"SHARE_LINUX_FILES_IN_WINDOWS={ShellQuoteValue(features.ShareLinuxFilesInWindows.ToString().ToLowerInvariant())}",
                        $"WINDOWS_PROFILES_JSON_BASE64={ShellQuoteValue(features.WindowsProfilesJsonBase64)}"
                    };

                    File.WriteAllText(configPath, string.Join("\n", configLines) + "\n");
                    NormalizeRootFileNameCase(@"Z:\", "config.txt");

                    Dispatcher.Invoke(() =>
                    {
                        Log(@"Config written to Z:\config.txt:");
                        Log($"  INSTALLATION_PLAN_ID={plan.PlanId}");
                        Log($"  LANGUAGE_CODE={locale.LanguageCode}");
                        Log($"  SYSTEM_LANG={locale.SystemLanguage}");
                        Log($"  KEYBOARD_LAYOUT={locale.KeyboardLayout}");
                        Log($"  TIMEZONE={locale.Timezone}");
                        Log($"  USERNAME={account.Username}");
                        Log($"  LINUX_SIZE_GB={installer.FinalSizeBytes / InstallationSizePolicy.BytesPerGiB}");
                    });
                    return true;
                }
                catch (Exception ex)
                {
                    Dispatcher.Invoke(() => Log($"ERROR writing config: {ex.Message}"));
                    return false;
                }
            });
        }

        private static void NormalizeLiveBootNames(string destinationRoot)
        {
            string[] liveDirectories = Directory.GetDirectories(destinationRoot)
                .Where(path => string.Equals(
                    Path.GetFileName(path), "live", StringComparison.OrdinalIgnoreCase))
                .ToArray();
            if (liveDirectories.Length != 1)
                throw new IOException($"Expected exactly one copied live directory; found {liveDirectories.Length}.");

            string expectedLiveDirectory = Path.Combine(destinationRoot, "live");
            if (!string.Equals(
                Path.GetFileName(liveDirectories[0]), "live", StringComparison.Ordinal))
            {
                string temporaryDirectory = Path.Combine(
                    destinationRoot, $".libertix-live-case-{Guid.NewGuid():N}");
                Directory.Move(liveDirectories[0], temporaryDirectory);
                Directory.Move(temporaryDirectory, expectedLiveDirectory);
            }
            if (!string.Equals(
                Path.GetFileName(new DirectoryInfo(expectedLiveDirectory).FullName),
                "live",
                StringComparison.Ordinal))
            {
                throw new IOException("Live directory name case normalization failed.");
            }

            foreach (string expectedName in new[] { "filesystem.squashfs", "initrd.img", "vmlinuz" })
            {
                string[] matches = Directory.GetFiles(expectedLiveDirectory)
                    .Where(path => string.Equals(
                        Path.GetFileName(path), expectedName, StringComparison.OrdinalIgnoreCase))
                    .ToArray();
                if (matches.Length != 1)
                    throw new IOException($"Expected exactly one copied live file for {expectedName}; found {matches.Length}.");

                string expectedPath = Path.Combine(expectedLiveDirectory, expectedName);
                if (!string.Equals(Path.GetFileName(matches[0]), expectedName, StringComparison.Ordinal))
                {
                    string temporaryPath = Path.Combine(
                        expectedLiveDirectory, $".libertix-case-{Guid.NewGuid():N}");
                    File.Move(matches[0], temporaryPath);
                    File.Move(temporaryPath, expectedPath);
                }
                if (!string.Equals(
                    Path.GetFileName(new FileInfo(expectedPath).FullName),
                    expectedName,
                    StringComparison.Ordinal))
                {
                    throw new IOException($"Live file name case normalization failed: {expectedName}.");
                }
            }
        }

        private static void NormalizeRootFileNameCase(string directory, string expectedName)
        {
            string[] matches = Directory.GetFiles(directory)
                .Where(path => string.Equals(
                    Path.GetFileName(path), expectedName, StringComparison.OrdinalIgnoreCase))
                .ToArray();
            if (matches.Length != 1)
                throw new IOException($"Expected exactly one file for {expectedName}; found {matches.Length}.");

            string expectedPath = Path.Combine(directory, expectedName);
            if (!string.Equals(Path.GetFileName(matches[0]), expectedName, StringComparison.Ordinal))
            {
                string temporaryPath = Path.Combine(
                    directory, $".libertix-case-{Guid.NewGuid():N}");
                File.Move(matches[0], temporaryPath);
                File.Move(temporaryPath, expectedPath);
            }
            if (!string.Equals(
                Path.GetFileName(new FileInfo(expectedPath).FullName),
                expectedName,
                StringComparison.Ordinal))
            {
                throw new IOException($"File name case normalization failed: {expectedName}.");
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

                    var mountResult = RunProcess(
                        "powershell.exe",
                        $"-NoProfile -ExecutionPolicy Bypass -File \"{scriptPath}\"",
                        (int)WindowsProcessTimeouts.DiskImageOperation.TotalMilliseconds);
                    mountedDrive = mountResult.output.Trim();
                    if (mountResult.exitCode != 0 || string.IsNullOrEmpty(mountedDrive))
                    {
                        Dispatcher.Invoke(() => Log($"ERROR mounting ISO: {mountResult.error}"));
                        File.Delete(scriptPath);
                        return false;
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

                    // Use xcopy for reliable copying (robocopy can have issues with ISO).
                    var copyResult = RunProcess(
                        "xcopy",
                        $"\"{sourceDir}*\" \"{destDir}\" /E /H /Y /Q",
                        (int)WindowsProcessTimeouts.FileCopy.TotalMilliseconds);
                    if (copyResult.exitCode != 0)
                    {
                        Dispatcher.Invoke(() => Log($"Copy error (exit {copyResult.exitCode}): {copyResult.error}"));
                        return false;
                    }

                    // Get file count from xcopy output.
                    var lines = copyResult.output.Split('\n');
                    string lastLine = lines.Length > 0 ? lines[lines.Length - 1].Trim() : "done";
                    if (string.IsNullOrWhiteSpace(lastLine) && lines.Length > 1)
                        lastLine = lines[lines.Length - 2].Trim();
                    Dispatcher.Invoke(() => Log($"Copy completed: {(string.IsNullOrWhiteSpace(lastLine) ? "done" : lastLine)}"));

                    NormalizeLiveBootNames(destDir);
                    Dispatcher.Invoke(() => Log("Live boot directory and file name casing verified"));

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
                        var unmountResult = RunProcess(
                            "powershell.exe",
                            $"-NoProfile -ExecutionPolicy Bypass -Command \"Dismount-DiskImage -ImagePath '{isoPath.Replace("'", "''")}'\"",
                            (int)WindowsProcessTimeouts.DiskImageOperation.TotalMilliseconds);
                        if (unmountResult.exitCode != 0)
                            throw new InvalidOperationException(unmountResult.error);
                        Dispatcher.Invoke(() => Log("ISO dismounted"));
                    }
                    catch (Exception unmountEx)
                    {
                        Dispatcher.Invoke(() => Log($"Warning: Could not dismount ISO: {unmountEx.Message}"));
                    }
                }
            });
        }

        private async Task<bool> ConfigureBiosLowMemoryBootAsync(string verifiedIsoPath)
        {
            const string retainedIsoPath = @"C:\libertix-live.iso";
            try
            {
                await Task.Run(() => File.Copy(verifiedIsoPath, retainedIsoPath, true));
                string expectedHash = _installationPlan?.Distribution?.LiveIsoSha256;
                if (!await VerifySha256Async(retainedIsoPath, expectedHash, "Libertix low-memory ISO"))
                    return false;

                string[] bootConfigs = Directory.GetFiles(@"Z:\", "*.cfg", SearchOption.AllDirectories);
                int updatedCount = 0;
                foreach (string bootConfig in bootConfigs)
                {
                    string content = File.ReadAllText(bootConfig);
                    string updated = Regex.Replace(
                        content,
                        @"(?i)(^|\s)toram(?=\s|$)",
                        "$1findiso=/libertix-live.iso");
                    if (updated == content) continue;
                    File.SetAttributes(bootConfig, FileAttributes.Normal);
                    File.WriteAllText(bootConfig, updated, new UTF8Encoding(false));
                    updatedCount++;
                }

                if (updatedCount == 0)
                {
                    Log("ERROR: No BIOS boot configuration accepted low-memory findiso mode.");
                    return false;
                }
                Log($"Low-memory findiso mode configured in {updatedCount} BIOS boot files.");
                return true;
            }
            catch (Exception ex)
            {
                Log($"Low-memory BIOS setup failed: {ex.Message}");
                return false;
            }
        }
    }
}
