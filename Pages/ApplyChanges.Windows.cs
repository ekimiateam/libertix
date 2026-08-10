using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using Libertix.Helpers;
using Libertix.Installation;
using Libertix.Models;

namespace Libertix.Pages
{
    public partial class ApplyChanges
    {
        private string GetWindowsProfilesJsonBase64()
        {
            var profiles = new List<string>();
            var excludedProfiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            {
                "All Users",
                "Default",
                "Default User",
                "defaultuser0",
                "Public",
                "WDAGUtilityAccount"
            };
            string usersRoot = Path.Combine(
                Path.GetPathRoot(Environment.GetFolderPath(Environment.SpecialFolder.Windows)),
                "Users");
            if (Directory.Exists(usersRoot))
            {
                string[] profilePaths;
                try
                {
                    profilePaths = Directory.GetDirectories(usersRoot);
                }
                catch (Exception error) when (
                    error is UnauthorizedAccessException ||
                    error is IOException)
                {
                    Log($"WARNING: Windows profiles could not be enumerated: {error.Message}");
                    profilePaths = Array.Empty<string>();
                }

                foreach (string profilePath in profilePaths)
                {
                    try
                    {
                        if (!File.Exists(Path.Combine(profilePath, "NTUSER.DAT"))) continue;
                        string profileName = Path.GetFileName(profilePath);
                        if (excludedProfiles.Contains(profileName)) continue;
                        profiles.Add(profileName);
                    }
                    catch (UnauthorizedAccessException error)
                    {
                        Log($"WARNING: Windows profile was skipped because access was denied: " +
                            $"{profilePath}: {error.Message}");
                    }
                    catch (IOException error)
                    {
                        Log($"WARNING: Windows profile changed during enumeration and was skipped: " +
                            $"{profilePath}: {error.Message}");
                    }
                }
            }
            profiles.Sort(StringComparer.OrdinalIgnoreCase);
            string json = JsonSerializer.Serialize(profiles.ToArray());
            return Convert.ToBase64String(Encoding.UTF8.GetBytes(json));
        }

        private async Task<bool> PrepareWindowsSharePayloadAsync()
        {
            if (_storagePreflight == null)
                return false;
            if (!(_installationState.Account is AccountInfo account) ||
                string.IsNullOrWhiteSpace(account.Username))
                return false;

            SharingOptions options = _installationState.Sharing;
            try
            {
                Directory.CreateDirectory(WindowsShareRoot);
                string sourceScript = Path.Combine(
                    AppDomain.CurrentDomain.BaseDirectory,
                    "Scripts",
                    "libertix-configure-windows-share.ps1");
                string targetScript = Path.Combine(WindowsShareRoot, "mount-linux-readonly.ps1");
                if (!File.Exists(sourceScript))
                    throw new FileNotFoundException("Windows sharing script is missing.", sourceScript);
                File.Copy(sourceScript, targetScript, true);

                string setupPath = Path.Combine(WindowsShareRoot, Artifacts.Ext4Driver.FileName);
                if (options.ShareLinuxFilesInWindows)
                {
                    bool setupReady = File.Exists(setupPath) &&
                        await VerifySha256Async(
                            setupPath,
                            Artifacts.Ext4Driver.Sha256,
                            "ext4 Windows setup cache");
                    if (!setupReady)
                    {
                        string setupUrl =
                            $"{Filepool.BaseUrl}/{Artifacts.Ext4Driver.FileName}";
                        if (!await DownloadFileWithRetriesAsync(
                            setupUrl,
                            setupPath,
                            attempts: 3,
                            timeout: TimeSpan.FromMinutes(20),
                            bufferSize: 81920,
                            progressStart: 5,
                            progressSpan: 3,
                            label: "ext4 Windows read-only support",
                            progressMessage: Localized(
                                "ApplyChangesPreparingWindowsShare",
                                "Preparing Windows file sharing..."),
                            maximumBytes: MaximumSupportArtifactBytes))
                            return false;
                        if (!await VerifySha256Async(
                            setupPath,
                            Artifacts.Ext4Driver.Sha256,
                            "ext4 Windows setup"))
                            return false;
                    }
                }

                long expectedLinuxSize = InstallationSizePolicy
                    .FromRequestedGigabytes(_linuxSizeGB)
                    .FinalSizeBytes;
                long originalWindowsEnd = checked(
                    _storagePreflight.SystemPartitionOffset +
                    _storagePreflight.SystemPartitionSize);
                long alignmentPadding = originalWindowsEnd % (1024L * 1024L);
                long expectedLinuxOffset = checked(
                    originalWindowsEnd - expectedLinuxSize - alignmentPadding);
                string configPath = Path.Combine(WindowsShareRoot, "config.json");
                File.WriteAllText(
                    configPath,
                    JsonSerializer.Serialize(new
                    {
                        Enabled = options.ShareLinuxFilesInWindows,
                        SystemDiskNumber = _storagePreflight.SystemDiskNumber,
                        SystemDiskUniqueId = _storagePreflight.SystemDiskUniqueId,
                        ExpectedLinuxPartitionOffset = expectedLinuxOffset,
                        ExpectedLinuxPartitionSize = expectedLinuxSize,
                        LinuxUsername = account.Username,
                        ShortcutDescription = Localized(
                            "WindowsShareShortcutDescription",
                            "Linux files (read-only)"),
                        SetupPath = setupPath,
                        SetupSha256 = Artifacts.Ext4Driver.Sha256
                    }),
                    new UTF8Encoding(false));
                File.WriteAllText(
                    Path.Combine(WindowsShareRoot, "pending.marker"),
                    DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture),
                    new UTF8Encoding(false));
                Log($"Windows read-only sharing payload prepared: enabled={options.ShareLinuxFilesInWindows}.");
                return true;
            }
            catch (Exception ex)
            {
                Log($"Windows sharing payload preparation failed: {ex.Message}");
                return false;
            }
        }

        private static void CleanupPendingWindowsSharePayload()
        {
            try
            {
                string marker = Path.Combine(WindowsShareRoot, "pending.marker");
                if (File.Exists(marker) && Directory.Exists(WindowsShareRoot))
                    Directory.Delete(WindowsShareRoot, true);
            }
            catch
            {
                // The installed sharing task also removes stale payloads. A
                // locked file here must not hide the primary rollback result.
            }
        }

        private static string FormatOptionalBool(bool? value)
        {
            return value.HasValue ? (value.Value ? "true" : "false") : "unknown";
        }

        /// <summary>
        /// Reads whether Windows hibernation (and therefore Fast Startup) is on.
        /// The registry value is used instead of parsing `powercfg /a`, whose
        /// output is localized. Returns null when the state cannot be read.
        /// </summary>
        private static bool? GetHibernateEnabled()
        {
            try
            {
                using (var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(
                    @"SYSTEM\CurrentControlSet\Control\Power"))
                {
                    object value = key?.GetValue("HibernateEnabled");
                    if (value == null)
                        return null;
                    return Convert.ToInt32(value, CultureInfo.InvariantCulture) != 0;
                }
            }
            catch
            {
                return null;
            }
        }

        /// <summary>
        /// Turns hibernation, and with it Windows Fast Startup, on or off.
        /// Fast Startup turns "shut down" into a kernel hibernation: the NTFS
        /// volume stays marked in-use with its metadata cached by Windows. The
        /// installed system mounts Windows read-write from /etc/fstab when file
        /// sharing is enabled, and writing to a hibernated NTFS volume corrupts
        /// it once Windows resumes on its stale metadata. It must therefore stay
        /// off for as long as Linux is installed, and only be restored by the
        /// recovery guard when the installation is rolled back.
        /// </summary>
        private bool SetHibernateEnabled(bool enabled)
        {
            var result = RunProcess(
                ResolveSystemExecutable("powercfg.exe", "powercfg.exe"),
                enabled ? "/hibernate on" : "/hibernate off",
                waitMs: (int)WindowsProcessTimeouts.QuickCommand.TotalMilliseconds,
                encoding: GetWindowsConsoleEncoding());
            Log($"Windows hibernation and Fast Startup set to {(enabled ? "on" : "off")}: " +
                $"{(result.exitCode == 0 ? "OK" : "rc=" + result.exitCode)}");
            bool? observed = GetHibernateEnabled();
            if (result.exitCode != 0 || observed != enabled)
            {
                Log($"ERROR: Windows did not apply the requested hibernation state: " +
                    $"requested={enabled}, observed={observed?.ToString() ?? "unknown"}.");
                return false;
            }
            return true;
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
                    string stateModuleSource = Path.Combine(
                        AppDomain.CurrentDomain.BaseDirectory,
                        "Scripts",
                        "modules",
                        "Libertix.InstallationState.psm1");
                    string stateModuleTarget = Path.Combine(
                        RecoveryRoot,
                        "Libertix.InstallationState.psm1");
                    if (!File.Exists(stateModuleSource))
                    {
                        Dispatcher.Invoke(() => Log(
                            $"ERROR: Recovery state module missing: {stateModuleSource}"));
                        return false;
                    }
                    File.Copy(stateModuleSource, stateModuleTarget, true);

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
                        waitMs: (int)WindowsProcessTimeouts.QuickCommand.TotalMilliseconds,
                        encoding: GetWindowsConsoleEncoding());
                    if (bcdBackup.exitCode != 0 || !File.Exists(bcdBackupPath))
                    {
                        Dispatcher.Invoke(() => Log(
                            $"ERROR: BCD backup failed rc={bcdBackup.exitCode}: {bcdBackup.error}"));
                        return false;
                    }

                    // pending.env lets the startup guard identify the expected
                    // temporary partition size without hardcoding UI choices.
                    string metadataPath = Path.Combine(RecoveryRoot, "pending.env");
                    double stagingSizeMB = InstallationSizePolicy
                        .FromRequestedGigabytes(_linuxSizeGB)
                        .StagingSizeMiB;
                    string metadata = string.Join(Environment.NewLine, new[]
                    {
                        "LIBERTIX_INSTALL_PENDING=true",
                        $"LINUX_SIZE_MB={requestedLinuxMB:F0}",
                        $"STAGING_SIZE_MB={stagingSizeMB:F0}",
                        $"SYSTEM_DRIVE={_storagePreflight.SystemDrive}",
                        $"SYSTEM_DISK_NUMBER={_storagePreflight.SystemDiskNumber}",
                        $"SYSTEM_PARTITION_NUMBER={_storagePreflight.SystemPartitionNumber}",
                        $"SYSTEM_PARTITION_OFFSET={_storagePreflight.SystemPartitionOffset}",
                        $"SYSTEM_PARTITION_SIZE_BYTES={_storagePreflight.SystemPartitionSize}",
                        $"SYSTEM_DISK_UNIQUE_ID={_storagePreflight.SystemDiskUniqueId}",
                        $"RECOVERY_PARTITION_NUMBER={_storagePreflight.RecoveryPartitionNumber}",
                        $"RECOVERY_PARTITION_OFFSET_BYTES={_storagePreflight.RecoveryPartitionOffset}",
                        $"RECOVERY_PARTITION_SIZE_BYTES={_storagePreflight.RecoveryPartitionSize}",
                        $"RECOVERY_RUN_ID={_installationPlan.Runtime.RecoveryRunId}",
                        $"PLAN_ID={_installationPlan.PlanId}",
                        // Captured before Fast Startup is disabled so a rollback
                        // can put the user's original setting back.
                        $"ORIGINAL_HIBERNATE_ENABLED={FormatOptionalBool(GetHibernateEnabled())}",
                        $"CREATED_UTC={DateTime.UtcNow:O}"
                    });
                    File.WriteAllText(metadataPath, metadata + Environment.NewLine);

                    string registrationScript = Path.Combine(
                        AppDomain.CurrentDomain.BaseDirectory,
                        "Scripts",
                        "libertix-register-bios-recovery-task.ps1");
                    if (!File.Exists(registrationScript))
                    {
                        Dispatcher.Invoke(() => Log(
                            $"ERROR: BIOS recovery task registration script missing: " +
                            registrationScript));
                        return false;
                    }

                    // schtasks stamps ONSTART triggers with the current local time. A
                    // dual-boot clock correction can move the next Windows boot before
                    // that boundary and silently suppress recovery. The ScheduledTasks
                    // API creates a boot trigger without a wall-clock dependency.
                    string powershell = WindowsProcessRunner.ResolvePowerShell();
                    string args = $"-NoProfile -ExecutionPolicy Bypass -File " +
                        $"{QuoteArgument(registrationScript)} " +
                        $"-TaskName {QuoteArgument(RuntimeNames.BiosRecoveryTask)} " +
                        $"-RecoveryScriptPath {QuoteArgument(targetScript)}";
                    var result = RunProcess(
                        powershell,
                        args,
                        waitMs: (int)WindowsProcessTimeouts.QuickCommand.TotalMilliseconds);
                    Dispatcher.Invoke(() =>
                    {
                        Log($"BIOS recovery task registration: " +
                            $"{(result.exitCode == 0 ? "OK" : "Failed")}");
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



        private async Task<double> QueryShrinkSpaceAsync()
        {
            using (JsonDocument result = await RunBiosStorageActionAsync("QueryShrink"))
                return result.RootElement.GetProperty("MaximumShrinkBytes").GetInt64() / 1048576d;
        }

        private async Task<bool> ShrinkWindowsPartitionAsync(double shrinkSizeMB)
        {
            try
            {
                long sizeBytes = checked((long)Math.Round(shrinkSizeMB * 1024d * 1024d));
                using (await RunBiosStorageActionAsync("Shrink", sizeBytes)) { }
                return true;
            }
            catch (Exception ex)
            {
                Log($"ERROR: Windows shrink failed: {ex.Message}");
                return false;
            }
        }

        private async Task<bool> RefreshWindowsRecoveryRegistrationAsync()
        {
            return await Task.Run(() =>
            {
                var disable = RunProcess(
                    "reagentc.exe",
                    "/disable",
                    waitMs: (int)WindowsProcessTimeouts.ServiceCommand.TotalMilliseconds);
                if (disable.exitCode != 0)
                {
                    Log($"WinRE disable was not required: {disable.output} {disable.error}".Trim());
                }

                var enable = RunProcess(
                    "reagentc.exe",
                    "/enable",
                    waitMs: (int)WindowsProcessTimeouts.ServiceCommand.TotalMilliseconds);
                if (enable.exitCode != 0)
                {
                    Log($"ERROR: reagentc /enable failed rc={enable.exitCode}: {enable.output} {enable.error}".Trim());
                    return false;
                }

                // reagentc localizes every status label. Its documented exit
                // code is the stable contract for /enable, while the storage
                // preflight separately verifies the Recovery partition itself.
                Log("Windows Recovery Environment is enabled on the final partition layout.");
                return true;
            });
        }

        private async Task<string> CreateFat32PartitionSimpleAsync(double sizeMB)
        {
            try
            {
                long sizeBytes = checked((long)Math.Round(sizeMB * 1024d * 1024d));
                using (JsonDocument result = await RunBiosStorageActionAsync("CreateStaging", sizeBytes))
                    return result.RootElement.GetProperty("DriveLetter").GetString();
            }
            catch (Exception ex)
            {
                Log($"ERROR: FAT32 staging partition creation failed: {ex.Message}");
                return null;
            }
        }

        private async Task<JsonDocument> RunBiosStorageActionAsync(
            string action,
            long sizeBytes = 0)
        {
            if (_storagePreflight == null)
                throw new InvalidOperationException("Storage preflight is missing.");

            string scriptPath = Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory,
                "Scripts",
                "libertix-bios-storage.ps1");
            if (!File.Exists(scriptPath))
                throw new FileNotFoundException("BIOS storage helper is missing.", scriptPath);

            string powershell = WindowsProcessRunner.ResolvePowerShell();
            string arguments =
                $"-NoProfile -ExecutionPolicy Bypass -File {QuoteArgument(scriptPath)} " +
                $"-Action {QuoteArgument(action)} " +
                $"-SystemDrive {QuoteArgument(_storagePreflight.SystemDrive)} " +
                $"-DiskNumber {_storagePreflight.SystemDiskNumber} " +
                $"-DiskUniqueId {QuoteArgument(_storagePreflight.SystemDiskUniqueId)} " +
                $"-WindowsPartitionOffsetBytes {_storagePreflight.SystemPartitionOffset} " +
                $"-RecoveryPartitionOffsetBytes {_storagePreflight.RecoveryPartitionOffset} " +
                $"-SizeBytes {sizeBytes}";
            var processResult = await Task.Run(() => RunProcess(
                powershell,
                arguments,
                (int)WindowsProcessTimeouts.DiskOperation.TotalMilliseconds,
                GetWindowsConsoleEncoding()));
            if (processResult.exitCode != 0)
            {
                throw new InvalidOperationException(
                    $"BIOS storage action {action} failed with rc={processResult.exitCode}: " +
                    $"{processResult.error} {processResult.output}".Trim());
            }

            string json = processResult.output?.Trim();
            if (string.IsNullOrWhiteSpace(json))
                throw new InvalidOperationException($"BIOS storage action {action} returned no result.");
            return JsonDocument.Parse(json);
        }
    }
}
