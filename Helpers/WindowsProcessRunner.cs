using System;
using System.Diagnostics;
using System.IO;
using System.Text;
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
        public static readonly TimeSpan ServiceCommand = TimeSpan.FromMinutes(1);
        public static readonly TimeSpan DiskOperation = TimeSpan.FromMinutes(2);
        public static readonly TimeSpan DiskImageOperation = TimeSpan.FromMinutes(5);
        public static readonly TimeSpan CompatibilityPreflight = TimeSpan.FromMinutes(10);
        public static readonly TimeSpan RecoveryOperation = TimeSpan.FromMinutes(30);
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

    /// <summary>
    /// Executes a redirected Windows process without risking an infinite wait or
    /// a stdout/stderr pipe deadlock.
    /// </summary>
    public static class WindowsProcessRunner
    {
        private const int ProcessTreeTerminationWaitMilliseconds = 10000;

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
                if (process == null || process.HasExited)
                    return true;
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
                        throw new InvalidOperationException(
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

                // The second wait lets asynchronous redirected streams flush after
                // the process handle has been signalled.
                process.WaitForExit();
                Task.WaitAll(outputTask, errorTask);
                return new WindowsProcessResult
                {
                    ExitCode = process.ExitCode,
                    StandardOutput = outputTask.Result,
                    StandardError = errorTask.Result,
                    TimedOut = false
                };
            }
        }
    }
}
