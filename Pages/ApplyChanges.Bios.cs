// Windows-side BIOS installation workflow.
//
// This partial class verifies external artifacts before arming recovery, then
// creates the reusable FAT32 staging slot, publishes the validated installation
// plan, and installs the one-shot GRUB4DOS bridge. The live environment owns
// conversion to ext4, target extraction, final GRUB installation, verification,
// and live rollback.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows;
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

            if (!await PrepareBiosDistributionIsoAsync(distribution) ||
                !await PrepareBiosPartitionAsync(installationSizes) ||
                !await PrepareBiosLiveMediaAsync(distribution) ||
                !await PrepareBiosTemporaryBootAsync())
            {
                return;
            }

            UpdateProgress(BiosProgress.Complete, Localized("ApplyChangesComplete", "Partitioning complete!"));
            Log("Installation preparation completed successfully!");
            Log($"- FAT32 live partition: {_biosInstallerDriveLetter}: ({installationSizes.StagingSizeMiB / 1024:N0}GB staging, {_linuxSizeGB:N0}GB reserved for Linux)");
            Log("- The live installer will expand it if needed, then reformat it as ext4 without deleting/recreating the MBR entry");
            Log($"- ISO contents copied to {_biosInstallerDriveLetter}:");
            Log("- GRUB4DOS bootloader installed");
            Log("- Boot entry 'Install Linux' added to Windows Boot Manager");
            Log("- Next reboot will automatically boot the Linux installer");
            Log("- Layout: [Windows] [FAT32 live/future Linux] [Recovery]");

            RebootButton.Visibility = Visibility.Visible;
            FinishInstallation(enableBackButton: false);
        }

        private async Task<bool> PrepareBiosPartitionAsync(
            InstallationSizes installationSizes)
        {
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
                UpdateProgress(0, Localized("ApplyChangesError", "Error occurred"));
                FinishInstallation(enableBackButton: true);
                return false;
            }
            CompleteExecutionStep(InstallationStep.WindowsRecoveryArmed);

            // The initial wizard recheck is read-only. Decryption can take
            // hours and mutates persistent disk state, so only start it after
            // the recovery guard and its original-state metadata are durable.
            _storagePreflight = await RunStoragePreflightAsync(
                FirmwareType.Bios,
                decryptBitLocker: true);
            ThrowIfCancellationRequested();

            if (_installationState.Sharing.ShareWindowsFilesInLinux &&
                !SetHibernateEnabled(false))
            {
                await FailBiosPreparationAndRollbackAsync(
                    "Windows hibernation could not be disabled safely");
                return false;
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
                return false;
            }

            UpdateProgress(BiosProgress.ShrinkWindows, Localized("ApplyChangesStep1", "Shrinking Windows partition..."));
            Log($"Step 2: Shrinking Windows by {_linuxSizeGB:N0}GB for the reusable live/Linux partition...");
            StartExecutionStep(InstallationStep.WindowsSystemVolumeShrunk);
            bool shrinkSucceeded = await ShrinkWindowsPartitionAsync(requestedLinuxMB);
            ThrowIfCancellationRequested();
            if (!shrinkSucceeded)
            {
                await FailBiosPreparationAndRollbackAsync("Failed to shrink Windows partition (step 2)");
                return false;
            }
            CompleteExecutionStep(InstallationStep.WindowsSystemVolumeShrunk);

            // Windows cannot reliably format FAT32 above 32 GB, so large Linux
            // allocations use an 8 GB staging partition that the live expands.
            double biosStagingMB = installationSizes.StagingSizeMiB;
            UpdateProgress(
                BiosProgress.CreateInstallerPartition,
                Localized("ApplyChangesStep2", "Creating FAT32 boot partition..."));
            Log(
                biosStagingMB < requestedLinuxMB
                    ? $"Step 3: Creating {biosStagingMB / 1024:N0}GB FAT32 staging partition; the live will expand it to {_linuxSizeGB:N0}GB..."
                    : $"Step 3: Creating FAT32 live partition at final size ({_linuxSizeGB:N0}GB)...");

            StartExecutionStep(InstallationStep.WindowsInstallerPartitionCreated);
            _biosInstallerDriveLetter = await CreateFat32PartitionSimpleAsync(biosStagingMB);
            ThrowIfCancellationRequested();
            if (string.IsNullOrWhiteSpace(_biosInstallerDriveLetter))
            {
                await FailBiosPreparationAndRollbackAsync("Failed to create FAT32 partition");
                return false;
            }
            _executionLedger.SetMirrorPath(
                Path.Combine(BiosInstallerRoot, InstallationStateFileName));
            await UpdateInstallerPartitionIdentityAsync(_biosInstallerDriveLetter[0]);
            PublishObservedWindowsSharePartitionIdentity();
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
                return false;
            }

            Log("Step 4: No second shrink needed; live partition will become the Linux partition.");
            UpdateProgress(BiosProgress.PartitionReady, Localized("ApplyChangesWaitDisk", "Waiting for disk update..."));
            return true;
        }

        private async Task<bool> PrepareBiosLiveMediaAsync(
            InstallationDistribution distribution)
        {
            string isoUrl = distribution.LiveIsoUrl;
            if (string.IsNullOrEmpty(isoUrl))
            {
                await FailBiosPreparationAndRollbackAsync(
                    "No ISO URL found for selected distribution");
                return false;
            }

            UpdateProgress(BiosProgress.LiveDownload, Localized("ApplyChangesDownloadingIso", "Downloading ISO..."));
            Log($"Step 5: Downloading ISO from {isoUrl}...");
            StartExecutionStep(InstallationStep.WindowsLiveMediaPrepared);

            string tempIsoDirectory = InstallationTemporaryArtifacts.GetLiveMediaDirectory(
                (_installationPlan.Disk.SystemDrive ?? WindowsSystemDrive) + @"\",
                _installationPlan.PlanId);
            Directory.CreateDirectory(tempIsoDirectory);
            string tempIsoPath = Path.Combine(tempIsoDirectory, "bios-live.iso");
            try
            {
                string localIsoName = Path.GetFileName(new Uri(isoUrl).LocalPath);
                string localIsoPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, localIsoName);
                bool downloadSuccess;
                if (File.Exists(localIsoPath))
                {
                    Log($"Found local ISO: {localIsoName}, copying...");
                    await Task.Run(() => File.Copy(localIsoPath, tempIsoPath, true));
                    ThrowIfCancellationRequested();
                    downloadSuccess = true;
                    UpdateProgress(BiosProgress.LiveMediaCopy, Localized("ApplyChangesIsoCopied", "ISO copied from local folder"));
                }
                else
                {
                    downloadSuccess = await DownloadIsoAsync(isoUrl, tempIsoPath);
                }
                ThrowIfCancellationRequested();

                if (!downloadSuccess)
                {
                    await FailBiosPreparationAndRollbackAsync("Failed to download ISO");
                    return false;
                }
                if (!await VerifySha256Async(
                    tempIsoPath,
                    distribution.LiveIsoSha256,
                    "Libertix BIOS ISO"))
                {
                    await FailBiosPreparationAndRollbackAsync(
                        "Libertix BIOS ISO integrity verification failed");
                    return false;
                }
                ThrowIfCancellationRequested();
                UpdateProgress(BiosProgress.LiveMediaCopy, Localized("ApplyChangesCopyingIsoContents", "Copying ISO contents..."));
                Log($"Step 6: Mounting ISO and copying contents to {BiosInstallerRoot}...");
                bool copySucceeded = await MountAndCopyIsoAsync(tempIsoPath);
                ThrowIfCancellationRequested();
                if (!copySucceeded)
                {
                    await FailBiosPreparationAndRollbackAsync("Failed to copy ISO contents");
                    return false;
                }

                bool lowMemoryMode =
                    _installationState.Compatibility is CompatibilityInfo compatibility &&
                    compatibility.LowMemoryMode;
                if (lowMemoryMode && !ConfigureBiosLowMemoryBoot())
                {
                    await FailBiosPreparationAndRollbackAsync(
                        "Failed to configure low-memory live boot");
                    return false;
                }

                // The live must consume the same validated plan that authorized the
                // Windows-side disk changes; no second shell contract is generated.
                UpdateProgress(BiosProgress.InstallationContextReady, Localized("ApplyChangesWritingConfiguration", "Writing configuration..."));
                PublishInstallationContextToLive(BiosInstallerRoot);
                Log($"Installation plan published to {BiosInstallerRoot}installation-plan.json.");
                CompleteExecutionStep(InstallationStep.WindowsLiveMediaPrepared);
                return true;
            }
            finally
            {
                DeleteDownloadArtifactBestEffort(tempIsoPath, "Libertix BIOS ISO");
                DeleteDownloadDirectoryBestEffort(
                    tempIsoDirectory,
                    "Libertix BIOS ISO transaction");
                if (File.Exists(tempIsoPath) || Directory.Exists(tempIsoDirectory))
                    Log("WARNING: Libertix BIOS ISO transaction cleanup could not be verified.");
                else
                    Log("Libertix BIOS ISO transaction cleanup verified.");
            }
        }

        private async Task<bool> PrepareBiosDistributionIsoAsync(
            InstallationDistribution distribution)
        {
            // The large distribution ISO stays on NTFS because the FAT32
            // staging volume must remain small enough for Windows to format.
            // Acquire and verify it before arming recovery so a network or TLS
            // failure cannot require disk rollback.
            StartExecutionStep(InstallationStep.WindowsArtifactsVerified);
            if (string.IsNullOrEmpty(distribution.InstallerIsoUrl) ||
                string.IsNullOrEmpty(distribution.InstallerIsoFileName))
            {
                return FailBiosBeforeMutation("Linux installer ISO metadata is missing");
            }

            UpdateProgress(BiosProgress.DistributionDownload, Localized("ApplyChangesDownloadingLinuxIso", "Downloading Linux installer ISO..."));
            Log($"Step 1: Downloading Linux installer from {distribution.InstallerIsoUrl}...");

            string installerPath = distribution.InstallerIsoWindowsPath;
            Directory.CreateDirectory(Path.GetDirectoryName(installerPath));
            string localInstallerPath = Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory,
                distribution.InstallerIsoFileName);
            bool downloadSuccess;
            if (File.Exists(localInstallerPath))
            {
                Log($"Found local installer ISO: {distribution.InstallerIsoFileName}, copying...");
                await Task.Run(() => File.Copy(localInstallerPath, installerPath, true));
                ThrowIfCancellationRequested();
                downloadSuccess = true;
                UpdateProgress(BiosProgress.DistributionReady, Localized("ApplyChangesLinuxIsoCopied", "Linux installer copied from local folder"));
            }
            else
            {
                downloadSuccess = await DownloadInstallerIsoAsync(
                    distribution.InstallerIsoUrl,
                    installerPath);
            }
            ThrowIfCancellationRequested();

            if (!downloadSuccess)
            {
                return FailBiosBeforeMutation("Failed to download Linux installer ISO");
            }
            if (!await VerifySha256Async(
                installerPath,
                distribution.InstallerIsoSha256,
                "Linux installer ISO"))
            {
                return FailBiosBeforeMutation("Linux installer ISO integrity verification failed");
            }
            ThrowIfCancellationRequested();
            Log($"Linux installer saved to {installerPath}");
            CompleteExecutionStep(InstallationStep.WindowsArtifactsVerified);
            return true;
        }

        private bool FailBiosBeforeMutation(string reason)
        {
            RecordExecutionFailure("BIOS_ARTIFACT_PREPARATION_FAILED", reason, InstallationPhase.Windows);
            CleanupTransactionDownloadsBestEffort();
            Log($"ERROR: {reason}");
            UpdateProgress(0, Localized("ApplyChangesError", "Error occurred"));
            FinishInstallation(enableBackButton: true);
            return false;
        }

        private async Task<bool> PrepareBiosTemporaryBootAsync()
        {
            // GRUB4DOS is only a temporary Windows Boot Manager bridge. The
            // live installer removes these files before touching Linux.
            UpdateProgress(BiosProgress.BootloaderDownload, Localized("ApplyChangesDownloadingBootloader", "Downloading bootloader files..."));
            Log($"Step 7: Downloading GRUB4DOS files to {_storagePreflight.SystemDrive}\\...");
            StartExecutionStep(InstallationStep.WindowsTemporaryBootPrepared);

            string[] grubFiles = { "grldr", "grldr.mbr" };
            var grubHashes = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                ["grldr"] = Artifacts.Grub4Dos.LoaderSha256,
                ["grldr.mbr"] = Artifacts.Grub4Dos.MbrLoaderSha256
            };
            foreach (string file in grubFiles)
            {
                string destinationPath = Path.Combine(
                    _storagePreflight.SystemDrive + @"\",
                    file);
                string localPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, file);
                bool ready = false;
                if (File.Exists(localPath))
                {
                    Log($"Found local {file}, copying...");
                    try
                    {
                        File.Copy(localPath, destinationPath, true);
                        ready = true;
                    }
                    catch (Exception ex)
                    {
                        Log($"ERROR: Failed to copy local {file}: {ex.Message}");
                    }
                }
                if (!ready)
                {
                    ready = await DownloadFileAsync(
                        $"{Filepool.BaseUrl}/{file}",
                        destinationPath);
                }
                ThrowIfCancellationRequested();

                if (!ready)
                {
                    await FailBiosPreparationAndRollbackAsync($"Failed to obtain {file}");
                    return false;
                }
                if (!await VerifySha256Async(destinationPath, grubHashes[file], file))
                {
                    await FailBiosPreparationAndRollbackAsync(
                        $"Integrity verification failed for {file}");
                    return false;
                }
                Log($"Ready: {file} at {_storagePreflight.SystemDrive}\\");
            }

            try
            {
                string menuPath = Path.Combine(_storagePreflight.SystemDrive + @"\", "menu.lst");
                string menu = LiveBootArguments
                    .LoadFromApplicationDirectory()
                    .CreateGrub4DosMenu();
                File.WriteAllText(
                    menuPath,
                    menu,
                    new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
                Log($"Ready: menu.lst at {_storagePreflight.SystemDrive}\\");
            }
            catch (Exception ex)
            {
                await FailBiosPreparationAndRollbackAsync(
                    $"Failed to create GRUB4DOS menu from shared boot arguments: {ex.Message}");
                return false;
            }

            // A one-shot boot sequence keeps Windows as the default BCD entry
            // if the live installer cannot finish.
            UpdateProgress(BiosProgress.BootEntryReady, Localized("ApplyChangesConfiguringBootEntry", "Configuring boot entry..."));
            Log("Step 8: Configuring GRUB4DOS boot entry...");
            bool bootConfigured = await ConfigureBootEntryAsync();
            ThrowIfCancellationRequested();
            if (!bootConfigured)
            {
                await FailBiosPreparationAndRollbackAsync("Failed to configure boot entry");
                return false;
            }
            // Persist the final Windows-side transition to the live volume before
            // removing its drive letter. Every later transition is Windows-only;
            // keeping D:\ as a mirror after this point would make the next ledger
            // write fail because the access path intentionally no longer exists.
            CompleteExecutionStep(InstallationStep.WindowsTemporaryBootPrepared);
            _executionLedger.SetMirrorPath(null);
            if (!await RemoveBiosInstallerAccessPathAsync())
            {
                await FailBiosPreparationAndRollbackAsync(
                    "Failed to hide the prepared installer partition from Windows");
                return false;
            }
            return true;
        }

        private async Task<bool> RemoveBiosInstallerAccessPathAsync()
        {
            if (string.IsNullOrWhiteSpace(_biosInstallerDriveLetter))
                return false;

            char driveLetter = char.ToUpperInvariant(_biosInstallerDriveLetter[0]);
            string powershell = WindowsProcessRunner.ResolvePowerShell();
            string command =
                $"$p=Get-Partition -DriveLetter {driveLetter} -ErrorAction Stop; " +
                "$disk=[int]$p.DiskNumber; $number=[int]$p.PartitionNumber; " +
                $"Remove-PartitionAccessPath -InputObject $p -AccessPath '{driveLetter}:\\' " +
                "-ErrorAction Stop; Update-HostStorageCache -ErrorAction SilentlyContinue; " +
                "$verified=Get-Partition -DiskNumber $disk -PartitionNumber $number -ErrorAction Stop; " +
                "if ($verified.DriveLetter) { throw 'Installer partition drive letter remains assigned.' }";
            var result = await Task.Run(() => RunProcess(
                powershell,
                $"-NoProfile -Command {QuoteArgument(command)}",
                (int)WindowsProcessTimeouts.DiskOperation.TotalMilliseconds));
            if (result.exitCode != 0)
            {
                Log(
                    $"ERROR: Installer partition access-path removal failed rc={result.exitCode}: " +
                    $"{result.error}");
                return false;
            }

            Log("Prepared installer partition drive letter removed before reboot.");
            return true;
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
                    string powershell = WindowsProcessRunner.ResolvePowerShell();
                    StreamingProcessResult processResult = await RunStreamingProcessAsync(
                        powershell,
                        $"-NoProfile -ExecutionPolicy Bypass -File {QuoteArgument(recoveryScript)}",
                        TimeSpan.FromMinutes(10),
                        line => Log($"ROLLBACK: {line}"),
                        observeCancellation: false);
                    rollbackSucceeded =
                        processResult.Completion == StreamingProcessCompletion.Exited &&
                        processResult.ExitCode == 0;
                }
            }

            _biosRecoveryGuardInstalled = !rollbackSucceeded;
            if (rollbackSucceeded)
            {
                if (!await BitLockerMatchesInitialPreflightStateAfterRollbackAsync())
                {
                    CleanupPendingWindowsSharePayload();
                    CleanupTransactionDownloadsBestEffort();
                    ShowBitLockerRollbackIncomplete();
                    return;
                }
                CompleteExecutionRollback();
                CleanupPendingWindowsSharePayload();
                CleanupTransactionDownloadsBestEffort();
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
                        "ApplyChangesPreparationRollbackIncompleteDetails",
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

                // Bind the temporary entry to this recovery run. The live
                // cleanup accepts only this owned format and the legacy exact
                // name, both with the expected GRUB4DOS path.
                string bootDescription =
                    $"Libertix BIOS Installer {_installationPlan.Runtime.RecoveryRunId}";
                string guid = "";
                var createResult = await Task.Run(() =>
                    RunProcess(
                        bcdeditPath,
                        $"/create /d {QuoteArgument(bootDescription)} /application bootsector",
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

                MatchCollection guidMatches = Regex.Matches(
                    output ?? string.Empty,
                    @"\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}");
                if (guidMatches.Count == 1)
                {
                    guid = guidMatches[0].Value;
                    Log($"Found GUID: {guid}");
                }
                else
                {
                    Log($"ERROR: Expected one BCD GUID in output, found {guidMatches.Count}.");
                    return false;
                }

                await RunBcdeditCommandAsync(
                    bcdeditPath,
                    $"/set {guid} device partition={_storagePreflight.SystemDrive}");

                await RunBcdeditCommandAsync(bcdeditPath, $"/set {guid} path \\grldr.mbr");

                // Keep the entry visible in BCD metadata so offline cleanup can
                // remove it, while bootsequence makes the selection one-shot.
                await RunBcdeditCommandAsync(bcdeditPath, $"/displayorder {guid} /addlast");

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

        private async Task<bool> MountAndCopyIsoAsync(string isoPath)
        {
            string mountedDrive = "";
            bool imageMounted = false;
            string powershell = WindowsProcessRunner.ResolvePowerShell();
            string scriptPath = Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory,
                "Scripts",
                "libertix-disk-image.ps1");

            try
            {
                var mountOutput = new StringBuilder();
                object mountOutputLock = new object();
                StreamingProcessResult mountResult = await RunStreamingProcessAsync(
                    powershell,
                    $"-NoProfile -ExecutionPolicy Bypass -File {QuoteArgument(scriptPath)} " +
                    $"-Action Mount -ImagePath {QuoteArgument(isoPath)}",
                    WindowsProcessTimeouts.DiskImageOperation,
                    line => Log($"ISO mount: {line}"),
                    captureStandardOutput: line =>
                    {
                        lock (mountOutputLock)
                            mountOutput.AppendLine(line);
                    });
                if (mountResult.Completion == StreamingProcessCompletion.Cancelled)
                    throw new OperationCanceledException(_installationCancellation.Token);
                if (mountResult.Completion == StreamingProcessCompletion.TerminationFailed)
                    throw new UnterminatedProcessException(
                        "ISO mount process tree could not be proven stopped.");
                if (mountResult.Completion != StreamingProcessCompletion.Exited || mountResult.ExitCode != 0)
                    return false;
                imageMounted = true;

                string mountText;
                lock (mountOutputLock)
                    mountText = mountOutput.ToString();
                string[] driveLetters = mountText
                    .Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)
                    .Select(line => line.Trim())
                    .Where(line => Regex.IsMatch(line, "^[A-Za-z]$"))
                    .Distinct(StringComparer.OrdinalIgnoreCase)
                    .ToArray();
                if (driveLetters.Length != 1)
                {
                    Log($"ERROR: ISO mount returned {driveLetters.Length} drive letters.");
                    return false;
                }
                mountedDrive = driveLetters[0];
                Log($"ISO mounted at {mountedDrive}:");

                string sourceDir = $"{mountedDrive}:\\";
                string destDir = BiosInstallerRoot;
                if (!Directory.Exists(sourceDir))
                {
                    Log($"ERROR: Source directory not found: {sourceDir}");
                    return false;
                }

                Log($"Copying files from {sourceDir} to {destDir}...");
                var copyOutput = new StringBuilder();
                object copyOutputLock = new object();
                StreamingProcessResult copyResult = await RunStreamingProcessAsync(
                    "xcopy.exe",
                    $"{QuoteArgument(sourceDir + "*")} {QuoteArgument(destDir)} /E /H /Y /Q",
                    WindowsProcessTimeouts.FileCopy,
                    line => Log($"XCOPY: {line}"),
                    captureStandardOutput: line =>
                    {
                        lock (copyOutputLock)
                            copyOutput.AppendLine(line);
                    });
                if (copyResult.Completion == StreamingProcessCompletion.Cancelled)
                    throw new OperationCanceledException(_installationCancellation.Token);
                if (copyResult.Completion == StreamingProcessCompletion.TerminationFailed)
                    throw new UnterminatedProcessException(
                        "ISO copy process tree could not be proven stopped.");
                if (copyResult.Completion != StreamingProcessCompletion.Exited || copyResult.ExitCode != 0)
                {
                    Log($"Copy error (exit {copyResult.ExitCode}, {copyResult.Completion}).");
                    return false;
                }

                string copyText;
                lock (copyOutputLock)
                    copyText = copyOutput.ToString();
                string lastLine = copyText
                    .Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)
                    .Select(line => line.Trim())
                    .LastOrDefault() ?? "done";
                Log($"Copy completed: {lastLine}");

                NormalizeLiveBootNames(destDir);
                Log("Live boot directory and file name casing verified");
                Log("Files copied successfully");
                if (!await DismountBiosIsoAsync(powershell, scriptPath, isoPath))
                    return false;
                imageMounted = false;
                return true;
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (UnterminatedProcessException)
            {
                throw;
            }
            catch (Exception ex)
            {
                Log($"Mount/copy failed: {ex.Message}");
                return false;
            }
            finally
            {
                if (imageMounted)
                {
                    try
                    {
                        await DismountBiosIsoAsync(powershell, scriptPath, isoPath);
                    }
                    catch (UnterminatedProcessException)
                    {
                        throw;
                    }
                    catch (Exception unmountEx)
                    {
                        Log($"Warning: Could not dismount ISO: {unmountEx.Message}");
                    }
                }
            }
        }

        private async Task<bool> DismountBiosIsoAsync(
            string powershell,
            string scriptPath,
            string isoPath)
        {
            Log("Dismounting ISO...");
            StreamingProcessResult unmountResult = await RunStreamingProcessAsync(
                powershell,
                $"-NoProfile -ExecutionPolicy Bypass -File {QuoteArgument(scriptPath)} " +
                $"-Action Dismount -ImagePath {QuoteArgument(isoPath)}",
                WindowsProcessTimeouts.DiskImageOperation,
                line => Log($"ISO dismount: {line}"),
                observeCancellation: false);
            if (unmountResult.Completion == StreamingProcessCompletion.TerminationFailed)
            {
                throw new UnterminatedProcessException(
                    "ISO dismount process tree could not be proven stopped.");
            }
            if (unmountResult.Completion != StreamingProcessCompletion.Exited ||
                unmountResult.ExitCode != 0)
            {
                Log(
                    $"ERROR: ISO dismount failed with rc={unmountResult.ExitCode} " +
                    $"({unmountResult.Completion}).");
                return false;
            }
            Log("ISO dismounted");
            return true;
        }

        private bool ConfigureBiosLowMemoryBoot()
        {
            try
            {
                string[] bootConfigs = Directory.GetFiles(BiosInstallerRoot, "*.cfg", SearchOption.AllDirectories);
                int updatedCount = 0;
                foreach (string bootConfig in bootConfigs)
                {
                    string content = File.ReadAllText(bootConfig);
                    string updated = Regex.Replace(
                        content,
                        @"(?i)(^|\s)toram(?=\s|$)",
                        "$1toram=filesystem.squashfs");
                    if (updated == content) continue;
                    File.SetAttributes(bootConfig, FileAttributes.Normal);
                    File.WriteAllText(bootConfig, updated, new UTF8Encoding(false));
                    updatedCount++;
                }

                if (updatedCount == 0)
                {
                    Log("ERROR: No BIOS boot configuration accepted low-memory module mode.");
                    return false;
                }
                Log($"Low-memory SquashFS module boot configured in {updatedCount} BIOS boot files.");
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
