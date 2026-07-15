using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading.Tasks;
using Libertix.Helpers;

namespace Libertix.Pages
{
    /// <summary>
    /// Windows privilege, firmware, storage-preflight, and process helpers.
    /// This is a structural split only; the installation sequence remains in
    /// ApplyChanges.xaml.cs and calls these methods exactly as before.
    /// </summary>
    public partial class ApplyChanges
    {
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
                firmware == FirmwareType.Bios
                    ? (int)WindowsProcessTimeouts.InstallerOperation.TotalMilliseconds
                    : (int)WindowsProcessTimeouts.DiskOperation.TotalMilliseconds));

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
                "BITLOCKER_SAFE", "BITLOCKER_STATE", "BITLOCKER_CONVERSION_STATUS",
                "BITLOCKER_ENCRYPTION_PERCENTAGE", "BITLOCKER_PROTECTION_STATUS"
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
                BitLockerState = values["BITLOCKER_STATE"],
                BitLockerConversionStatus = int.Parse(
                    values["BITLOCKER_CONVERSION_STATUS"],
                    CultureInfo.InvariantCulture),
                BitLockerEncryptionPercentage = int.Parse(
                    values["BITLOCKER_ENCRYPTION_PERCENTAGE"],
                    CultureInfo.InvariantCulture),
                BitLockerProtectionStatus = int.Parse(
                    values["BITLOCKER_PROTECTION_STATUS"],
                    CultureInfo.InvariantCulture)
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
            WindowsProcessResult result = WindowsProcessRunner.Run(
                fileName,
                arguments,
                TimeSpan.FromMilliseconds(waitMs));
            string error = result.TimedOut
                ? $"Process timed out after {waitMs} ms. {result.StandardError}".Trim()
                : result.StandardError;
            return (result.ExitCode, result.StandardOutput, error);
        }
    }
}
