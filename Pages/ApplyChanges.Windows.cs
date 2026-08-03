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
        private static string GetWindowsProfilesJsonBase64()
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
                foreach (string profilePath in Directory.GetDirectories(usersRoot))
                {
                    try
                    {
                        if (!File.Exists(Path.Combine(profilePath, "NTUSER.DAT"))) continue;
                        string profileName = Path.GetFileName(profilePath);
                        if (excludedProfiles.Contains(profileName)) continue;
                        profiles.Add(profileName);
                    }
                    catch (UnauthorizedAccessException) { }
                    catch (IOException) { }
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

                string setupPath = Path.Combine(WindowsShareRoot, Ext4SetupFileName);
                if (options.ShareLinuxFilesInWindows)
                {
                    bool setupReady = File.Exists(setupPath) &&
                        await VerifySha256Async(setupPath, Ext4SetupSha256, "ext4 Windows setup cache");
                    if (!setupReady)
                    {
                        string setupUrl = $"{FilepoolConfig.BaseUrl}/{Ext4SetupFileName}";
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
                                "Preparing Windows file sharing...")))
                            return false;
                        if (!await VerifySha256Async(setupPath, Ext4SetupSha256, "ext4 Windows setup"))
                            return false;
                    }
                }

                long expectedLinuxSize = checked(
                    (long)Math.Max(20, (int)Math.Round(_linuxSizeGB)) * 1024L * 1024L * 1024L);
                string configPath = Path.Combine(WindowsShareRoot, "config.json");
                File.WriteAllText(
                    configPath,
                    JsonSerializer.Serialize(new
                    {
                        Enabled = options.ShareLinuxFilesInWindows,
                        SystemDiskNumber = _storagePreflight.SystemDiskNumber,
                        ExpectedLinuxPartitionSize = expectedLinuxSize,
                        LinuxUsername = account.Username,
                        SetupPath = setupPath,
                        SetupSha256 = Ext4SetupSha256
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
            catch { }
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
                        $"CREATED_UTC={DateTime.UtcNow:O}"
                    });
                    File.WriteAllText(metadataPath, metadata + Environment.NewLine);

                    string taskCommand = $"powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File '{targetScript}'";
                    string args = $"/Create /TN \"{RecoveryTaskName}\" /SC ONSTART /RU SYSTEM /RL HIGHEST /TR \"{taskCommand}\" /F";
                    var result = RunProcess(
                        "schtasks.exe",
                        args,
                        waitMs: (int)WindowsProcessTimeouts.QuickCommand.TotalMilliseconds);
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

                var status = RunProcess(
                    "reagentc.exe",
                    "/info",
                    waitMs: (int)WindowsProcessTimeouts.ServiceCommand.TotalMilliseconds);
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
    }
}
