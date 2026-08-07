using System;
using System.Diagnostics;
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
        public static async Task<CompatibilityInfo> RunAsync(
            Action<string> onOutput,
            bool skipNvramWriteProbe = false)
        {
            string scriptPath = Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory,
                "Scripts",
                "libertix-compatibility-preflight.ps1");
            if (!File.Exists(scriptPath))
                throw new CompatibilityPreflightException(
                    "COMPAT_E_SCRIPT_MISSING",
                    "The compatibility check component is missing.",
                    scriptPath);

            string languageCode = Localization.CurrentLanguage;
            return await Task.Run(() => RunProcess(
                scriptPath,
                languageCode,
                skipNvramWriteProbe,
                onOutput));
        }

        private static CompatibilityInfo RunProcess(
            string scriptPath,
            string languageCode,
            bool skipNvramWriteProbe,
            Action<string> onOutput)
        {
            string powershell = WindowsProcessRunner.ResolvePowerShell();
            var output = new StringBuilder();
            var error = new StringBuilder();

            string arguments = "-NoProfile -ExecutionPolicy Bypass -File " +
                WindowsProcessRunner.QuoteArgument(scriptPath) + " -LanguageCode " +
                WindowsProcessRunner.QuoteArgument(languageCode);
            if (skipNvramWriteProbe)
                arguments += " -SkipNvramWriteProbe";

            var startInfo = new ProcessStartInfo
            {
                FileName = powershell,
                Arguments = arguments,
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
                    output.AppendLine(args.Data);
                    onOutput?.Invoke(args.Data);
                };
                process.ErrorDataReceived += (_, args) =>
                {
                    if (args.Data == null) return;
                    error.AppendLine(args.Data);
                    onOutput?.Invoke(args.Data);
                };

                if (!process.Start())
                    throw new CompatibilityPreflightException(
                        "COMPAT_E_PROCESS_START",
                        "The compatibility check could not be started.",
                        powershell);
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                if (!process.WaitForExit((int)WindowsProcessTimeouts.CompatibilityPreflight.TotalMilliseconds))
                {
                    try
                    {
                        WindowsProcessRunner.TerminateProcessTree(process);
                    }
                    catch
                    {
                        // The process can exit after the timeout is observed
                        // but before the termination request reaches it.
                    }
                    throw new CompatibilityPreflightException(
                        "COMPAT_E_TIMEOUT",
                        "The compatibility check exceeded ten minutes.",
                        output + error.ToString());
                }

                // WaitForExit(timeout) only confirms that the process ended. The
                // parameterless call also waits for the asynchronous stdout/stderr
                // handlers to drain, so the final JSON object cannot be parsed
                // intermittently as an incomplete result.
                process.WaitForExit();

                string diagnostics = output.ToString() + error;
                PowerShellJsonResult values;
                try
                {
                    values = PowerShellJsonResult.ParseFinalObject(output.ToString());
                }
                catch (InvalidOperationException ex)
                {
                    throw new CompatibilityPreflightException(
                        "COMPAT_E_INVALID_RESULT",
                        "The compatibility diagnostic is incomplete.",
                        diagnostics + Environment.NewLine + ex.Message);
                }
                if (process.ExitCode != 0 || !values.GetBoolean("preflightOk"))
                {
                    string code = values.GetOptionalString("errorCode", "COMPAT_E_UNKNOWN");
                    string message = values.GetOptionalString(
                        "errorMessage",
                        "This machine's compatibility could not be confirmed.");
                    throw new CompatibilityPreflightException(code, message, diagnostics);
                }
                return new CompatibilityInfo
                {
                    Firmware = values.GetString("firmware"),
                    Architecture = values.GetString("architecture"),
                    MemoryBytes = values.GetInt64("memoryBytes"),
                    LowMemoryMode = values.GetBoolean("lowMemoryMode"),
                    SystemDiskNumber = values.GetInt32("systemDiskNumber"),
                    SystemDiskUniqueId = values.GetString("systemDiskUniqueId"),
                    SystemDiskSize = values.GetInt64("systemDiskSize"),
                    PartitionStyle = values.GetString("partitionStyle"),
                    StorageBusType = values.GetString("storageBusType"),
                    LogicalSectorSize = values.GetInt32("logicalSectorSize"),
                    PhysicalSectorSize = values.GetInt32("physicalSectorSize"),
                    ShrinkAvailableBytes = values.GetInt64("shrinkAvailableBytes"),
                    BitLockerSafe = values.GetBoolean("bitLockerSafe"),
                    BitLockerState = values.GetString("bitLockerState"),
                    SecureBootEnabled = values.GetBoolean("secureBootEnabled"),
                    NvramProbePassed = values.GetBoolean("nvramProbePassed"),
                    NvramProbeSkipped = values.GetBoolean("nvramProbeSkipped"),
                    Warnings = values.GetStringArray("warnings")
                };
            }
        }

    }
}
