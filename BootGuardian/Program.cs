using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;

namespace Libertix.BootGuardian
{
    internal static class Program
    {
        private static int Main(string[] args)
        {
            try
            {
                if (args.Length == 0)
                {
                    ServiceHost.Run();
                    return 0;
                }
                if (args.Length == 1 && args[0] == "--install-service")
                {
                    ServiceHost.Install(System.Reflection.Assembly.GetExecutingAssembly().Location);
                    return 0;
                }
                if (args.Length == 1 && args[0] == "--uninstall-service")
                {
                    ServiceHost.Uninstall();
                    return 0;
                }
                if (args.Length == 1 && args[0] == "--repair-now")
                {
                    return new BootGuardianEngine().Execute(
                        ServiceHost.ConfigPath,
                        TimeSpan.FromMinutes(1)) ? 0 : 2;
                }
                if (args.Length >= 2 && args[0] == "--run-hidden-powershell")
                    return RunHiddenPowerShell(args.Skip(1).ToArray());
                return 64;
            }
            catch (Exception error)
            {
                try { RepairJournal.WriteUncorrelatedError(error); }
                catch { }
                return 1;
            }
        }

        private static int RunHiddenPowerShell(string[] arguments)
        {
            TrustedScripts.Verify(arguments);
            string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            string powerShell = Path.Combine(
                windows,
                "System32",
                "WindowsPowerShell",
                "v1.0",
                "powershell.exe");
            if (!File.Exists(powerShell))
                throw new FileNotFoundException("Windows PowerShell is missing.", powerShell);
            var startInfo = new ProcessStartInfo
            {
                FileName = powerShell,
                Arguments = string.Join(" ", arguments.Select(QuoteArgument)),
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            using (Process process = Process.Start(startInfo))
            {
                if (process == null)
                    throw new InvalidOperationException("The hidden PowerShell process could not start.");
                process.WaitForExit();
                if (process.ExitCode != 0)
                    RecordNonZeroExit(process.ExitCode, process.ExitTime - process.StartTime, startInfo.Arguments);
                return process.ExitCode;
            }
        }

        // Task Scheduler keeps only the last result code and this host discards the
        // script's error stream. One file per non-zero exit dates every failed or
        // interrupted script, including one stopped before it could write its own log.
        private static void RecordNonZeroExit(int exitCode, TimeSpan duration, string arguments)
        {
            try
            {
                string directory = Path.Combine(
                    Path.GetPathRoot(Environment.SystemDirectory),
                    "LibertixInstallLogs",
                    "Windows",
                    "HiddenPowerShell");
                Security.ProtectedFiles.CreateDirectory(directory);
                DateTime now = DateTime.UtcNow;
                string path = Path.Combine(
                    directory,
                    now.ToString("yyyyMMddTHHmmss.fffffffZ", CultureInfo.InvariantCulture) +
                    "-exit-" + exitCode.ToString(CultureInfo.InvariantCulture) +
                    "-" + Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture) + ".log");
                File.WriteAllText(
                    path,
                    string.Format(
                        CultureInfo.InvariantCulture,
                        "[{0:o}] exitCode={1} durationMs={2:F0} user={3} arguments={4}{5}",
                        now,
                        exitCode,
                        duration.TotalMilliseconds,
                        Environment.UserName,
                        arguments,
                        Environment.NewLine),
                    new UTF8Encoding(false));
            }
            // The record is diagnostic only; the task must still receive the script's own
            // exit code when a standard user cannot write to the log folder.
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        private static string QuoteArgument(string value)
        {
            if (string.IsNullOrEmpty(value))
                return "\"\"";
            if (value.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '\"' }) < 0)
                return value;

            var quoted = new System.Text.StringBuilder("\"");
            int backslashes = 0;
            foreach (char character in value)
            {
                if (character == '\\')
                {
                    backslashes++;
                    continue;
                }
                if (character == '\"')
                {
                    quoted.Append('\\', (backslashes * 2) + 1);
                    quoted.Append('\"');
                    backslashes = 0;
                    continue;
                }
                quoted.Append('\\', backslashes);
                backslashes = 0;
                quoted.Append(character);
            }
            quoted.Append('\\', backslashes * 2);
            quoted.Append('\"');
            return quoted.ToString();
        }
    }
}
