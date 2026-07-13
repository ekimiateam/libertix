using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using Libertix.Models;

namespace Libertix.Helpers
{
    public sealed class CompatibilityPreflightException : Exception
    {
        public CompatibilityPreflightException(string code, string message, string diagnostics)
            : base(message)
        {
            Code = code;
            Diagnostics = diagnostics;
        }

        public string Code { get; }
        public string Diagnostics { get; }
    }

    public static class CompatibilityPreflightRunner
    {
        public static async Task<CompatibilityInfo> RunAsync(Action<string> onOutput)
        {
            string scriptPath = Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory,
                "Scripts",
                "libertix-compatibility-preflight.ps1");
            if (!File.Exists(scriptPath))
                throw new CompatibilityPreflightException(
                    "COMPAT_E_SCRIPT_MISSING",
                    "Le composant de vérification de compatibilité est absent.",
                    scriptPath);

            return await Task.Run(() => RunProcess(scriptPath, onOutput));
        }

        private static CompatibilityInfo RunProcess(string scriptPath, Action<string> onOutput)
        {
            string powershell = ResolvePowerShell();
            var output = new StringBuilder();
            var error = new StringBuilder();
            var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            var warnings = new List<string>();

            var startInfo = new ProcessStartInfo
            {
                FileName = powershell,
                Arguments = "-NoProfile -ExecutionPolicy Bypass -File " + QuoteArgument(scriptPath),
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8
            };

            using (var process = new Process { StartInfo = startInfo })
            {
                process.OutputDataReceived += (_, args) =>
                {
                    if (args.Data == null) return;
                    string line = NormalizeUtf8Line(args.Data);
                    output.AppendLine(line);
                    ParseLine(line, values, warnings);
                    onOutput?.Invoke(line);
                };
                process.ErrorDataReceived += (_, args) =>
                {
                    if (args.Data == null) return;
                    string line = NormalizeUtf8Line(args.Data);
                    error.AppendLine(line);
                    onOutput?.Invoke(line);
                };

                if (!process.Start())
                    throw new CompatibilityPreflightException(
                        "COMPAT_E_PROCESS_START",
                        "La vérification de compatibilité n'a pas pu démarrer.",
                        powershell);
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                if (!process.WaitForExit((int)WindowsProcessTimeouts.CompatibilityPreflight.TotalMilliseconds))
                {
                    try { process.Kill(); } catch { }
                    throw new CompatibilityPreflightException(
                        "COMPAT_E_TIMEOUT",
                        "La vérification de compatibilité a dépassé dix minutes.",
                        output + error.ToString());
                }

                string diagnostics = output + error.ToString();
                if (process.ExitCode != 0 || !IsTrue(values, "PREFLIGHT_OK"))
                {
                    string code = Get(values, "ERROR_CODE", "COMPAT_E_UNKNOWN");
                    string message = Get(
                        values,
                        "ERROR_MESSAGE",
                        "La compatibilité de cette machine n'a pas pu être confirmée.");
                    throw new CompatibilityPreflightException(code, message, diagnostics);
                }
            }

            return new CompatibilityInfo
            {
                Firmware = Require(values, "FIRMWARE"),
                Architecture = Require(values, "ARCHITECTURE"),
                MemoryBytes = ParseLong(values, "MEMORY_BYTES"),
                LowMemoryMode = IsTrue(values, "LOW_MEMORY_MODE"),
                SystemDiskNumber = ParseInt(values, "SYSTEM_DISK_NUMBER"),
                SystemDiskUniqueId = Require(values, "SYSTEM_DISK_UNIQUE_ID"),
                SystemDiskSize = ParseLong(values, "SYSTEM_DISK_SIZE"),
                PartitionStyle = Require(values, "PARTITION_STYLE"),
                StorageBusType = Require(values, "STORAGE_BUS_TYPE"),
                LogicalSectorSize = ParseInt(values, "LOGICAL_SECTOR_SIZE"),
                PhysicalSectorSize = ParseInt(values, "PHYSICAL_SECTOR_SIZE"),
                ShrinkAvailableBytes = ParseLong(values, "SHRINK_AVAILABLE_BYTES"),
                BitLockerSafe = IsTrue(values, "BITLOCKER_SAFE"),
                BitLockerState = Require(values, "BITLOCKER_STATE"),
                SecureBootEnabled = IsTrue(values, "SECURE_BOOT_ENABLED"),
                NvramProbePassed = IsTrue(values, "NVRAM_PROBE_PASSED"),
                Warnings = warnings.ToArray()
            };
        }

        private static void ParseLine(
            string line,
            IDictionary<string, string> values,
            ICollection<string> warnings)
        {
            int separator = line.IndexOf('=');
            if (separator <= 0) return;
            string key = line.Substring(0, separator).Trim();
            string value = line.Substring(separator + 1).Trim();
            if (key.Equals("WARNING", StringComparison.OrdinalIgnoreCase))
                warnings.Add(value);
            else
                values[key] = value;
        }

        private static string NormalizeUtf8Line(string line)
        {
            // Windows PowerShell 5.1 can expose redirected UTF-8 bytes through
            // the active Windows code page even when StandardOutputEncoding is
            // configured. Repair only the unmistakable mojibake signatures so
            // already-correct Unicode output remains untouched.
            if (line.IndexOf('Ã') < 0 && line.IndexOf('Â') < 0 && line.IndexOf('â') < 0)
                return line;
            try
            {
                byte[] bytes = Encoding.GetEncoding(1252).GetBytes(line);
                return new UTF8Encoding(false, true).GetString(bytes);
            }
            catch (DecoderFallbackException)
            {
                return line;
            }
            catch (EncoderFallbackException)
            {
                return line;
            }
        }

        private static string ResolvePowerShell()
        {
            string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            foreach (string candidate in new[]
            {
                Path.Combine(windows, "Sysnative", "WindowsPowerShell", "v1.0", "powershell.exe"),
                Path.Combine(windows, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
            })
            {
                if (File.Exists(candidate)) return candidate;
            }
            return "powershell.exe";
        }

        private static string QuoteArgument(string value) => "\"" + value.Replace("\"", "\\\"") + "\"";
        private static bool IsTrue(IDictionary<string, string> values, string key) =>
            values.TryGetValue(key, out string value) &&
            value.Equals("true", StringComparison.OrdinalIgnoreCase);
        private static string Get(IDictionary<string, string> values, string key, string fallback) =>
            values.TryGetValue(key, out string value) && !string.IsNullOrWhiteSpace(value) ? value : fallback;
        private static string Require(IDictionary<string, string> values, string key) =>
            values.TryGetValue(key, out string value) && !string.IsNullOrWhiteSpace(value)
                ? value
                : throw new CompatibilityPreflightException(
                    "COMPAT_E_INVALID_RESULT",
                    "Le diagnostic de compatibilité est incomplet.",
                    "Missing " + key);
        private static long ParseLong(IDictionary<string, string> values, string key) =>
            long.Parse(Require(values, key), CultureInfo.InvariantCulture);
        private static int ParseInt(IDictionary<string, string> values, string key) =>
            int.Parse(Require(values, key), CultureInfo.InvariantCulture);
    }
}
