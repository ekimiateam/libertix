using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace Libertix.Helpers
{
    /// <summary>
    /// Shared timeout policy for Windows processes started by the installer.
    /// Every blocking process must use one of these bounded durations.
    /// </summary>
    public static class WindowsProcessTimeouts
    {
        public static readonly TimeSpan QuickCommand = TimeSpan.FromSeconds(30);
        public static readonly TimeSpan RedirectedStreamDrain = TimeSpan.FromSeconds(10);
        public static readonly TimeSpan ServiceCommand = TimeSpan.FromMinutes(1);
        public static readonly TimeSpan DiskOperation = TimeSpan.FromMinutes(2);
        public static readonly TimeSpan DiskImageOperation = TimeSpan.FromMinutes(5);
        public static readonly TimeSpan BootArtifactDownload = TimeSpan.FromMinutes(5);
        public static readonly TimeSpan CompatibilityPreflight = TimeSpan.FromMinutes(10);
        public static readonly TimeSpan SupportArtifactDownload = TimeSpan.FromMinutes(20);
        public static readonly TimeSpan RecoveryOperation = TimeSpan.FromMinutes(30);
        public static readonly TimeSpan LiveIsoDownload = TimeSpan.FromHours(2);
        public static readonly TimeSpan DistributionIsoDownload = TimeSpan.FromHours(4);
        public static readonly TimeSpan FileCopy = TimeSpan.FromHours(4);
        public static readonly TimeSpan InstallerOperation = TimeSpan.FromHours(6.5);
    }

    public sealed class WindowsProcessResult
    {
        public int ExitCode { get; set; }
        public string StandardOutput { get; set; }
        public string StandardError { get; set; }
        public bool TimedOut { get; set; }
    }

    public sealed class UnterminatedProcessException : InvalidOperationException
    {
        public UnterminatedProcessException(string message) : base(message) { }
    }

    /// <summary>
    /// Executes a redirected Windows process without risking an infinite wait or
    /// a stdout/stderr pipe deadlock.
    /// </summary>
    public static class WindowsProcessRunner
    {
        public const int UnverifiedTerminationExitCode = 173;

        public static void AssertSafeExitCode(int exitCode)
        {
            if (exitCode == UnverifiedTerminationExitCode)
                throw new UnterminatedProcessException(
                    "The child reported an unverified process-tree termination. Rollback is blocked.");
        }
        private const int ProcessTreeTerminationWaitMilliseconds = 10000;
        private static readonly Regex TerminalEscapeSequence = new Regex(
            @"\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1B\\))",
            RegexOptions.Compiled | RegexOptions.CultureInvariant);

        public static string NormalizeTerminalText(string value)
        {
            return string.IsNullOrEmpty(value)
                ? value
                : TerminalEscapeSequence.Replace(value, string.Empty);
        }

        public static string ResolvePowerShell()
        {
            string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            foreach (string candidate in new[]
            {
                Path.Combine(windows, "Sysnative", "WindowsPowerShell", "v1.0", "powershell.exe"),
                Path.Combine(windows, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
            })
            {
                if (File.Exists(candidate))
                    return candidate;
            }
            return "powershell.exe";
        }

        public static string QuoteArgument(string value)
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

        public static bool TerminateProcessTree(Process process)
        {
            int processId;
            bool treeTerminationProven = false;
            try
            {
                if (process == null)
                    return true;
                if (process.HasExited)
                    return false;
                processId = process.Id;
            }
            catch
            {
                return false;
            }

            try
            {
                using (var taskKill = Process.Start(new ProcessStartInfo
                {
                    FileName = "taskkill.exe",
                    Arguments = $"/PID {processId} /T /F",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                }))
                {
                    if (taskKill != null)
                    {
                        bool taskKillCompleted = taskKill.WaitForExit(
                            ProcessTreeTerminationWaitMilliseconds);
                        process.WaitForExit(ProcessTreeTerminationWaitMilliseconds);
                        treeTerminationProven =
                            taskKillCompleted && taskKill.ExitCode == 0 && process.HasExited;
                        if (treeTerminationProven)
                            return true;
                    }
                }
            }
            catch
            {
                // Fall through to the direct-process fallback below.
            }
            try
            {
                if (!process.HasExited)
                {
                    process.Kill();
                    process.WaitForExit(ProcessTreeTerminationWaitMilliseconds);
                }
            }
            catch
            {
                // The process may exit between the taskkill attempt and fallback.
            }
            // Killing only the parent is a useful last resort, but it does
            // not prove that descendants stopped. Callers must therefore
            // fail closed instead of beginning rollback over unknown writers.
            return treeTerminationProven;
        }

        public static WindowsProcessResult Run(
            string fileName,
            string arguments,
            TimeSpan timeout,
            Encoding encoding = null)
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = fileName,
                Arguments = arguments,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            };
            if (encoding != null)
            {
                startInfo.StandardOutputEncoding = encoding;
                startInfo.StandardErrorEncoding = encoding;
            }
            return Run(startInfo, timeout);
        }

        public static WindowsProcessResult Run(ProcessStartInfo startInfo, TimeSpan timeout)
        {
            using (var process = Process.Start(startInfo))
            {
                if (process == null)
                    throw new InvalidOperationException($"Failed to start {startInfo.FileName}.");

                Task<string> outputTask = process.StandardOutput.ReadToEndAsync();
                Task<string> errorTask = process.StandardError.ReadToEndAsync();
                if (!process.WaitForExit(checked((int)timeout.TotalMilliseconds)))
                {
                    bool stopped = TerminateProcessTree(process);
                    Task.WaitAll(new Task[] { outputTask, errorTask }, 2000);
                    if (!stopped)
                    {
                        throw new UnterminatedProcessException(
                            $"Timed-out process tree could not be proven stopped: {startInfo.FileName}.");
                    }
                    return new WindowsProcessResult
                    {
                        ExitCode = -1,
                        StandardOutput = outputTask.IsCompleted ? outputTask.Result : string.Empty,
                        StandardError = errorTask.IsCompleted ? errorTask.Result : string.Empty,
                        TimedOut = true
                    };
                }

                WaitForRedirectedStreams(outputTask, errorTask);
                AssertSafeExitCode(process.ExitCode);
                return new WindowsProcessResult
                {
                    ExitCode = process.ExitCode,
                    StandardOutput = outputTask.Result,
                    StandardError = errorTask.Result,
                    TimedOut = false
                };
            }
        }

        public static WindowsProcessResult RunStreaming(
            ProcessStartInfo startInfo,
            TimeSpan timeout,
            Action<string> onStandardOutput,
            Action<string> onStandardError)
        {
            using (var process = new Process { StartInfo = startInfo })
            {
                var output = new StringBuilder();
                var error = new StringBuilder();
                var outputClosed = new TaskCompletionSource<bool>();
                var errorClosed = new TaskCompletionSource<bool>();
                bool started = false;
                process.OutputDataReceived += (_, data) =>
                {
                    if (data.Data == null)
                    {
                        outputClosed.TrySetResult(true);
                        return;
                    }
                    lock (output)
                        output.AppendLine(data.Data);
                    onStandardOutput?.Invoke(data.Data);
                };
                process.ErrorDataReceived += (_, data) =>
                {
                    if (data.Data == null)
                    {
                        errorClosed.TrySetResult(true);
                        return;
                    }
                    lock (error)
                        error.AppendLine(data.Data);
                    onStandardError?.Invoke(data.Data);
                };
                try
                {
                    if (!process.Start())
                        throw new InvalidOperationException(
                            $"The process could not be started: {startInfo.FileName}.");
                    started = true;
                    process.BeginOutputReadLine();
                    process.BeginErrorReadLine();
                    if (!process.WaitForExit(checked((int)timeout.TotalMilliseconds)))
                    {
                        bool stopped = TerminateProcessTree(process);
                        Task.WaitAll(
                            new Task[] { outputClosed.Task, errorClosed.Task },
                            checked((int)WindowsProcessTimeouts.RedirectedStreamDrain.TotalMilliseconds));
                        if (!stopped)
                        {
                            throw new UnterminatedProcessException(
                                $"Timed-out process tree could not be proven stopped: {startInfo.FileName}.");
                        }
                        return CreateStreamingResult(-1, true, output, error);
                    }
                    WaitForRedirectedStreams(outputClosed.Task, errorClosed.Task);
                    AssertSafeExitCode(process.ExitCode);
                    return CreateStreamingResult(process.ExitCode, false, output, error);
                }
                catch
                {
                    if (started && IsRunning(process) && !TerminateProcessTree(process))
                    {
                        throw new UnterminatedProcessException(
                            $"Failed process tree could not be proven stopped: {startInfo.FileName}.");
                    }
                    throw;
                }
            }
        }

        private static WindowsProcessResult CreateStreamingResult(
            int exitCode,
            bool timedOut,
            StringBuilder output,
            StringBuilder error)
        {
            string standardOutput;
            string standardError;
            lock (output)
                standardOutput = output.ToString();
            lock (error)
                standardError = error.ToString();
            return new WindowsProcessResult
            {
                ExitCode = exitCode,
                StandardOutput = standardOutput,
                StandardError = standardError,
                TimedOut = timedOut
            };
        }

        private static bool IsRunning(Process process)
        {
            try
            {
                return !process.HasExited;
            }
            catch
            {
                return true;
            }
        }

        internal static void WaitForRedirectedStreams(params Task[] streamTasks)
        {
            WaitForRedirectedStreams(WindowsProcessTimeouts.RedirectedStreamDrain, streamTasks);
        }

        internal static void WaitForRedirectedStreams(
            TimeSpan timeout,
            params Task[] streamTasks)
        {
            if (streamTasks == null || streamTasks.Length == 0)
                return;
            if (!Task.WaitAll(streamTasks, timeout))
            {
                throw new UnterminatedProcessException(
                    "Redirected process streams did not close after the process exited.");
            }
        }
    }
}
