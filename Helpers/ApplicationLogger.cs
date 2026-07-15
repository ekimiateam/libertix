using System;
using System.Diagnostics;
using System.IO;
using System.Text;

namespace Libertix.Helpers
{
    /// <summary>
    /// Persists the Libertix.exe lifecycle and errors beside the installation
    /// logs so one support bundle contains both application and installer data.
    /// Logging failures never interrupt the installation workflow.
    /// </summary>
    internal static class ApplicationLogger
    {
        private const string LogRoot = @"C:\LibertixInstallLogs";
        private static readonly object SyncRoot = new object();
        private static readonly Encoding Utf8WithoutBom = new UTF8Encoding(false);
        private static string _logPath;

        public static string LogPath
        {
            get
            {
                lock (SyncRoot)
                    return _logPath;
            }
        }

        public static void Initialize()
        {
            lock (SyncRoot)
            {
                if (!string.IsNullOrWhiteSpace(_logPath))
                    return;

                try
                {
                    Directory.CreateDirectory(LogRoot);
                    _logPath = Path.Combine(
                        LogRoot,
                        $"libertix-exe-{DateTime.Now:yyyyMMdd-HHmmss}-pid{Process.GetCurrentProcess().Id}.log");
                    File.WriteAllText(
                        _logPath,
                        $"===== Libertix.exe {DateTime.Now:O} ====={Environment.NewLine}" +
                        $"OS: {Environment.OSVersion}{Environment.NewLine}" +
                        $"64-bit process: {Environment.Is64BitProcess}{Environment.NewLine}",
                        Utf8WithoutBom);
                }
                catch
                {
                    _logPath = null;
                }
            }
        }

        public static void Write(string message)
        {
            if (string.IsNullOrWhiteSpace(LogPath))
                Initialize();

            lock (SyncRoot)
            {
                if (string.IsNullOrWhiteSpace(_logPath))
                    return;

                try
                {
                    File.AppendAllText(
                        _logPath,
                        $"[{DateTime.Now:HH:mm:ss.fff}] {message}{Environment.NewLine}",
                        Utf8WithoutBom);
                }
                catch
                {
                    // The application must remain usable if Windows refuses a log write.
                }
            }
        }

        public static void WriteException(string context, Exception exception)
        {
            Write($"{context}{Environment.NewLine}{exception}");
        }
    }
}
