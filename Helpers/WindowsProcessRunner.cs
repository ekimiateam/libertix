using System;
using System.Diagnostics;
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
                    try { process.Kill(); } catch { }
                    Task.WaitAll(new Task[] { outputTask, errorTask }, 2000);
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
