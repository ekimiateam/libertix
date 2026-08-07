using System;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading.Tasks;
using Libertix.Helpers;
using Libertix.Installation;

namespace Libertix.Pages
{
    /// <summary>
    /// Windows privilege, firmware, storage-preflight, and process helpers.
    /// Firmware-specific orchestrators call these shared helpers without
    /// duplicating the platform checks or native process contracts.
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

        private async Task<StoragePreflightInfo> RunStoragePreflightAsync(
            FirmwareType firmware,
            bool decryptBitLocker = true)
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
                (firmware == FirmwareType.Bios && decryptBitLocker ? "-DecryptBitLocker" : ""),
                firmware == FirmwareType.Bios && decryptBitLocker
                    ? (int)WindowsProcessTimeouts.InstallerOperation.TotalMilliseconds
                    : (int)WindowsProcessTimeouts.DiskOperation.TotalMilliseconds));

            if (!string.IsNullOrWhiteSpace(result.output))
                Log(result.output.Trim());
            if (!string.IsNullOrWhiteSpace(result.error))
                Log($"ERROR: {result.error.Trim()}");
            PowerShellJsonResult values = PowerShellJsonResult.ParseFinalObject(result.output);
            if (result.exitCode != 0 || !values.GetBoolean("preflightOk"))
                throw new InvalidOperationException(
                    $"Storage preflight failed with rc={result.exitCode}: " +
                    values.GetOptionalString("errorMessage", result.error));

            var info = new StoragePreflightInfo
            {
                Firmware = firmware,
                SystemDrive = values.GetString("systemDrive"),
                SystemDiskNumber = values.GetInt32("systemDiskNumber"),
                SystemPartitionNumber = values.GetInt32("systemPartitionNumber"),
                SystemPartitionOffset = values.GetInt64("systemPartitionOffset"),
                SystemPartitionSize = values.GetInt64("systemPartitionSize"),
                BootPartitionNumber = values.GetInt32("bootPartitionNumber"),
                BootPartitionOffset = values.GetInt64("bootPartitionOffset"),
                BootPartitionSize = values.GetInt64("bootPartitionSize"),
                SystemDiskUniqueId = values.GetString("systemDiskUniqueId"),
                SystemDiskSize = values.GetInt64("systemDiskSize"),
                LogicalSectorSize = values.GetInt32("logicalSectorSize"),
                PartitionStyle = values.GetString("partitionStyle"),
                RecoveryPartitionNumber = values.GetInt32("recoveryPartitionNumber"),
                RecoveryPartitionOffset = values.GetInt64("recoveryPartitionOffset"),
                RecoveryPartitionSize = values.GetInt64("recoveryPartitionSize"),
                BitLockerSafe = values.GetBoolean("bitLockerSafe"),
                BitLockerState = values.GetString("bitLockerState"),
                BitLockerConversionStatus = values.GetInt32("bitLockerConversionStatus"),
                BitLockerEncryptionPercentage = values.GetInt32("bitLockerEncryptionPercentage"),
                BitLockerProtectionStatus = values.GetInt32("bitLockerProtectionStatus"),
                InitialBitLockerConversionStatus = values.GetInt32("initialBitLockerConversionStatus"),
                InitialBitLockerEncryptionPercentage = values.GetInt32("initialBitLockerEncryptionPercentage"),
                InitialBitLockerProtectionStatus = values.GetInt32("initialBitLockerProtectionStatus")
            };

            if (firmware == FirmwareType.Bios && decryptBitLocker && !info.BitLockerSafe)
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
            return WindowsProcessRunner.QuoteArgument(value);
        }

        private static Encoding GetWindowsConsoleEncoding()
        {
            // Native Windows console tools such as bcdedit emit text in the
            // active OEM code page, not UTF-8 or the ANSI code page.
            return Encoding.GetEncoding(CultureInfo.CurrentCulture.TextInfo.OEMCodePage);
        }

        private (int exitCode, string output, string error) RunProcess(
            string fileName,
            string arguments,
            int waitMs,
            Encoding encoding = null)
        {
            WindowsProcessResult result = WindowsProcessRunner.Run(
                fileName,
                arguments,
                TimeSpan.FromMilliseconds(waitMs),
                encoding);
            string error = result.TimedOut
                ? $"Process timed out after {waitMs} ms. {result.StandardError}".Trim()
                : result.StandardError;
            return (result.ExitCode, result.StandardOutput, error);
        }
    }
}
