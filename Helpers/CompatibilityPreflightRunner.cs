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
            string connectivityUrl,
            Action<string> onOutput,
            bool skipNvramWriteProbe = false)
        {
            if (!Uri.TryCreate(connectivityUrl, UriKind.Absolute, out Uri connectivityUri) ||
                (connectivityUri.Scheme != Uri.UriSchemeHttp &&
                 connectivityUri.Scheme != Uri.UriSchemeHttps))
            {
                throw new ArgumentException(
                    "The compatibility connectivity URL must be an absolute HTTP(S) URL.",
                    nameof(connectivityUrl));
            }

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
            ApplicationLogger.Write(
                $"COMPATIBILITY: preflight started; skipNvramWriteProbe={skipNvramWriteProbe}.");
            try
            {
                EnsureAcPowerIfPortable(onOutput);
                CompatibilityInfo result = await Task.Run(() => RunProcess(
                    scriptPath,
                    languageCode,
                    connectivityUri.AbsoluteUri,
                    skipNvramWriteProbe,
                    onOutput));
                ApplicationLogger.Write("COMPATIBILITY: preflight completed successfully.");
                return result;
            }
            catch (Exception ex)
            {
                ApplicationLogger.WriteException("COMPATIBILITY: preflight failed.", ex);
                throw;
            }
        }

        private static void EnsureAcPowerIfPortable(Action<string> onOutput)
        {
            string checkMessage = Localization.GetString(
                "CompatibilityPowerCheck",
                "Checking the power source");
            onOutput?.Invoke("CHECK=COMPAT_025_POWER: " + checkMessage);

            SystemPowerSnapshot power = SystemPowerProbe.Read();
            ApplicationLogger.Write(
                "COMPATIBILITY: power state=" + power.State +
                "; acLineStatus=" + power.AcLineStatus +
                "; batteryFlag=" + power.BatteryFlag +
                "; getSystemPowerStatusError=" + power.GetSystemPowerStatusErrorCode +
                "; systemBatteryStateStatus=" + power.SystemBatteryStateStatus +
                "; usedSystemBatteryState=" + power.UsedSystemBatteryState + ".");
            if (power.State != SystemPowerState.AcDisconnected)
                return;

            throw new CompatibilityPreflightException(
                "COMPAT_E_AC_POWER_REQUIRED",
                Localization.GetString(
                    "CompatibilityAcPowerRequired",
                    "This computer is not connected to AC power. Connect it to AC power, then choose Try again."),
                "powerState=" + power.State +
                "; acLineStatus=" + power.AcLineStatus +
                "; batteryFlag=" + power.BatteryFlag +
                "; systemBatteryStateStatus=" + power.SystemBatteryStateStatus +
                "; usedSystemBatteryState=" + power.UsedSystemBatteryState + ".");
        }

        private static CompatibilityInfo RunProcess(
            string scriptPath,
            string languageCode,
            string connectivityUrl,
            bool skipNvramWriteProbe,
            Action<string> onOutput)
        {
            string powershell = WindowsProcessRunner.ResolvePowerShell();
            var output = new StringBuilder();
            var error = new StringBuilder();

            string arguments = "-NoProfile -ExecutionPolicy Bypass -File " +
                WindowsProcessRunner.QuoteArgument(scriptPath) + " -LanguageCode " +
                WindowsProcessRunner.QuoteArgument(languageCode) + " -ConnectivityUrl " +
                WindowsProcessRunner.QuoteArgument(connectivityUrl);
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
                var outputClosed = new TaskCompletionSource<bool>();
                var errorClosed = new TaskCompletionSource<bool>();
                process.OutputDataReceived += (_, args) =>
                {
                    if (args.Data == null)
                    {
                        outputClosed.TrySetResult(true);
                        return;
                    }
                    output.AppendLine(args.Data);
                    ApplicationLogger.Write("COMPATIBILITY STDOUT: " + args.Data);
                    onOutput?.Invoke(args.Data);
                };
                process.ErrorDataReceived += (_, args) =>
                {
                    if (args.Data == null)
                    {
                        errorClosed.TrySetResult(true);
                        return;
                    }
                    error.AppendLine(args.Data);
                    ApplicationLogger.Write("COMPATIBILITY STDERR: " + args.Data);
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
                    bool stopped;
                    try
                    {
                        stopped = WindowsProcessRunner.TerminateProcessTree(process);
                    }
                    catch
                    {
                        stopped = false;
                    }
                    if (!stopped)
                    {
                        throw new CompatibilityPreflightException(
                            "COMPAT_E_TERMINATION_FAILED",
                            "The compatibility process could not be proven stopped.",
                            output + error.ToString());
                    }
                    throw new CompatibilityPreflightException(
                        "COMPAT_E_TIMEOUT",
                        "The compatibility check exceeded ten minutes.",
                        output + error.ToString());
                }

                WindowsProcessRunner.WaitForRedirectedStreams(
                    outputClosed.Task,
                    errorClosed.Task);

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
                    TrustedMicrosoftUefiAuthorities =
                        values.GetStringArray("trustedMicrosoftUefiAuthorities"),
                    NvramProbePassed = values.GetBoolean("nvramProbePassed"),
                    NvramProbeSkipped = values.GetBoolean("nvramProbeSkipped"),
                    Warnings = values.GetStringArray("warnings")
                };
            }
        }

    }
}
