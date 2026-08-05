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

            double requestedLinuxMB = installationSizes.FinalSizeMiB;

            Log("Installing Windows recovery guard...");
            // This guard is installed before any partition change. If the live
            // installer dies before writing a success marker, Windows can delete
            // the temporary Linux slot and grow its system volume on next startup.
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

            if (_installationState.Sharing.ShareWindowsFilesInLinux &&
                !SetHibernateEnabled(false))
            {
                await FailBiosPreparationAndRollbackAsync(
                    "Windows hibernation could not be disabled safely");
                return;
            }

            // Query SizeMin after disabling Fast Startup because hiberfil.sys is
            // unmovable and can otherwise make Windows report an artificially
            // small shrink range.
            Log("Checking available shrink space...");
            double maxShrinkMB = await QueryShrinkSpaceAsync();
            ThrowIfCancellationRequested();
            Log($"Maximum shrinkable space: {maxShrinkMB / 1024:N1}GB ({maxShrinkMB:N0}MB)");
            if (maxShrinkMB < requestedLinuxMB)
            {
                await FailBiosPreparationAndRollbackAsync(
                    "Windows does not expose enough shrinkable space for the requested Linux size");
                return;
            }

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

            // Windows cannot reliably format FAT32 above 32 GB, so large Linux
            // allocations use an 8 GB staging partition that the live expands.
            double biosStagingMB = installationSizes.StagingSizeMiB;
            UpdateProgress(
                30,
                Application.Current.Resources["ApplyChangesStep2"] as string
                    ?? "Creating FAT32 boot partition...");
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
            _biosInstallerDriveLetter = await CreateFat32PartitionSimpleAsync(biosStagingMB);
            ThrowIfCancellationRequested();
            if (string.IsNullOrWhiteSpace(_biosInstallerDriveLetter))
            {
                await FailBiosPreparationAndRollbackAsync("Failed to create FAT32 partition");
                return;
            }
            await UpdateInstallerPartitionIdentityAsync(_biosInstallerDriveLetter[0]);
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

            Log("Step 3: No second shrink needed; live partition will become the Linux partition.");
            UpdateProgress(50, Application.Current.Resources["ApplyChangesWaitDisk"] as string ?? "Waiting for disk update...");
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

            UpdateProgress(80, Localized("ApplyChangesCopyingIsoContents", "Copying ISO contents..."));
            Log($"Step 5: Mounting ISO and copying contents to {BiosInstallerRoot}...");
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

            try
            {
                if (File.Exists(tempIsoPath))
                    File.Delete(tempIsoPath);
            }
            catch
            {
                // Cleanup failure does not invalidate media already copied to
                // the staging volume, and rollback can remove it later.
            }

            // The large distribution ISO stays on NTFS because the FAT32
            // staging volume must remain small enough for Windows to format.
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

            // The live must consume the same validated plan that authorized the
            // Windows-side disk changes; no second shell contract is generated.
            UpdateProgress(95, Localized("ApplyChangesWritingConfiguration", "Writing configuration..."));
            PublishInstallationContextToLive(BiosInstallerRoot);
            Log($"Installation plan published to {BiosInstallerRoot}installation-plan.json.");
            CompleteExecutionStep(InstallationStep.WindowsLiveMediaPrepared);

            // GRUB4DOS is only a temporary Windows Boot Manager bridge. The
            // live installer removes these files before touching Linux.
            UpdateProgress(96, Localized("ApplyChangesDownloadingBootloader", "Downloading bootloader files..."));
            Log($"Step 8: Downloading GRUB4DOS files to {_storagePreflight.SystemDrive}\\...");
            StartExecutionStep(InstallationStep.WindowsTemporaryBootPrepared);

            string[] grubFiles = { "grldr", "grldr.mbr" };
            var grubHashes = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                ["grldr"] = Artifacts.Grub4Dos.LoaderSha256,
                ["grldr.mbr"] = Artifacts.Grub4Dos.MbrLoaderSha256
            };
            foreach (var file in grubFiles)
            {
                string url = $"{FilepoolConfig.BaseUrl}/{file}";
                string destPath = Path.Combine(_storagePreflight.SystemDrive + @"\", file);
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
                Log($"Ready: {file} at {_storagePreflight.SystemDrive}\\");
            }

            try
            {
                string menuPath = Path.Combine(_storagePreflight.SystemDrive + @"\", "menu.lst");
                string menu = LiveBootArguments
                    .LoadFromApplicationDirectory()
                    .CreateGrub4DosMenu();
                File.WriteAllText(menuPath, menu, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
                Log($"Ready: menu.lst at {_storagePreflight.SystemDrive}\\");
            }
            catch (Exception ex)
            {
                await FailBiosPreparationAndRollbackAsync(
                    $"Failed to create GRUB4DOS menu from shared boot arguments: {ex.Message}");
                return;
            }

            // A one-shot boot sequence keeps Windows as the default BCD entry
            // if the live installer cannot finish.
            UpdateProgress(98, Localized("ApplyChangesConfiguringBootEntry", "Configuring boot entry..."));
            Log("Step 9: Configuring GRUB4DOS boot entry...");

            bool bootConfigured = await ConfigureBootEntryAsync();
            ThrowIfCancellationRequested();
            if (!bootConfigured)
            {
                await FailBiosPreparationAndRollbackAsync("Failed to configure boot entry");
                return;
            }
            CompleteExecutionStep(InstallationStep.WindowsTemporaryBootPrepared);

            UpdateProgress(100, Application.Current.Resources["ApplyChangesComplete"] as string ?? "Partitioning complete!");
            Log("Installation preparation completed successfully!");
            Log($"- FAT32 live partition: {_biosInstallerDriveLetter}: ({biosStagingMB / 1024:N0}GB staging, {_linuxSizeGB:N0}GB reserved for Linux)");
            Log("- The live installer will expand it if needed, then reformat it as ext4 without deleting/recreating the MBR entry");
            Log($"- ISO contents copied to {_biosInstallerDriveLetter}:");
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
                    LocalizedFormat(
                        "ApplyChangesBiosRollbackIncompleteDetails",
                        "Preparation failed and automatic rollback could not be verified. Do not " +
                        "restart the installation; review {0}.",
                        Path.Combine(RecoveryRoot, "recovery.log")),
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

                string bcdeditPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Sysnative", "bcdedit.exe");

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

                await RunBcdeditCommandAsync(
                    bcdeditPath,
                    $"/set {guid} device partition={_storagePreflight.SystemDrive}");

                await RunBcdeditCommandAsync(bcdeditPath, $"/set {guid} path \\grldr.mbr");

                // Keep the entry visible in BCD metadata, but bootsequence makes
                // it one-shot. If the user reboots later, Windows is still default.
                await RunBcdeditCommandAsync(bcdeditPath, $"/displayorder {guid} /addlast");

                // Suppress the Windows selector for this automated run only.
                await RunBcdeditCommandAsync(bcdeditPath, "/set {bootmgr} displaybootmenu no");

                await RunBcdeditCommandAsync(bcdeditPath, "/timeout 0");

                await RunBcdeditCommandAsync(bcdeditPath, "/default {current}");

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
                    string scriptPath = Path.Combine(
                        AppDomain.CurrentDomain.BaseDirectory,
                        "Scripts",
                        "libertix-disk-image.ps1");

                    var mountResult = RunProcess(
                        "powershell.exe",
                        $"-NoProfile -ExecutionPolicy Bypass -File {QuoteArgument(scriptPath)} " +
                        $"-Action Mount -ImagePath {QuoteArgument(isoPath)}",
                        (int)WindowsProcessTimeouts.DiskImageOperation.TotalMilliseconds);
                    mountedDrive = mountResult.output.Trim();
                    if (mountResult.exitCode != 0 || string.IsNullOrEmpty(mountedDrive))
                    {
                        Dispatcher.Invoke(() => Log($"ERROR mounting ISO: {mountResult.error}"));
                        return false;
                    }

                    if (mountedDrive.Contains("\n"))
                    {
                        mountedDrive = mountedDrive.Split('\n')[0].Trim();
                    }

                    Dispatcher.Invoke(() => Log($"ISO mounted at {mountedDrive}:"));

                    string sourceDir = $"{mountedDrive}:\\";
                    string destDir = BiosInstallerRoot;

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
                    try
                    {
                        Dispatcher.Invoke(() => Log("Dismounting ISO..."));
                        var unmountResult = RunProcess(
                            "powershell.exe",
                            $"-NoProfile -ExecutionPolicy Bypass -File " +
                            $"{QuoteArgument(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Scripts", "libertix-disk-image.ps1"))} " +
                            $"-Action Dismount -ImagePath {QuoteArgument(isoPath)}",
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
            string retainedIsoPath = Path.Combine(
                _storagePreflight.SystemDrive + @"\",
                "libertix-live.iso");
            try
            {
                await Task.Run(() => File.Copy(verifiedIsoPath, retainedIsoPath, true));
                string expectedHash = _installationPlan?.Distribution?.LiveIsoSha256;
                if (!await VerifySha256Async(retainedIsoPath, expectedHash, "Libertix low-memory ISO"))
                    return false;

                string[] bootConfigs = Directory.GetFiles(BiosInstallerRoot, "*.cfg", SearchOption.AllDirectories);
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
