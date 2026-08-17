using System;
using System.Diagnostics;
using System.IO;
using System.Linq;

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
                return process.ExitCode;
            }
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
