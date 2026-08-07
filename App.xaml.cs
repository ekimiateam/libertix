using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Principal;
using System.Threading.Tasks;
using System.Windows;
using Libertix.Helpers;
using Libertix.Models;

namespace Libertix
{
    public partial class App : Application
    {
        public InstallationState InstallationState { get; } = new InstallationState();
        public StartupOptions RuntimeOptions { get; private set; } = new StartupOptions();
        public FilepoolConfig Filepool { get; private set; } = FilepoolConfig.Production;

        protected override void OnStartup(StartupEventArgs e)
        {
            ApplicationLogger.Initialize();
            ApplicationLogger.Write("Libertix.exe startup.");
            RegisterApplicationErrorLogging();

            if (!TryConfigureStartupOptions(e.Args))
                return;

            if (!IsRunningAsAdministrator())
            {
                ApplicationLogger.Write("Startup refused: administrator privileges are missing.");
                // This runs before the language dictionary is merged, so the
                // message is resolved from the Windows UI language directly.
                MessageBox.Show(
                    AdministratorRequiredMessage(),
                    "Libertix",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);

                Shutdown(1);
                return;
            }

            string recoveryStatePath = TryGetUefiRecoveryStatePath(e.Args);
            if (!string.IsNullOrWhiteSpace(recoveryStatePath))
                InstallationState.UefiRecoveryStatePath = recoveryStatePath;

            base.OnStartup(e);
        }

        private bool TryConfigureStartupOptions(string[] args)
        {
            if (!StartupOptions.TryParse(args, out StartupOptions options, out string error))
            {
                RejectInvalidStartupOptions(error);
                return false;
            }

            FilepoolConfig filepool = FilepoolConfig.Production;
            if (!string.IsNullOrWhiteSpace(options.FilepoolBaseUrlOverride) &&
                !FilepoolConfig.TryCreate(
                    options.FilepoolBaseUrlOverride,
                    out filepool,
                    out error))
            {
                RejectInvalidStartupOptions(error);
                return false;
            }

            Filepool = filepool;

            RuntimeOptions = options;
            ApplicationLogger.Write($"Filepool base URL: {Filepool.BaseUrl}");
            if (!string.IsNullOrEmpty(options.DevelopmentSshStaticIpv4Address))
            {
                ApplicationLogger.Write(
                    "Development SSH/static network enabled for " +
                    options.DevelopmentSshStaticIpv4Address + "/" +
                    options.DevelopmentSshStaticIpv4PrefixLength + ".");
            }
            return true;
        }

        private static void RejectInvalidStartupOptions(string error)
        {
            ApplicationLogger.Write("Startup refused: " + error);
            MessageBox.Show(
                error,
                "Libertix - invalid startup option",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            Current.Shutdown(2);
        }

        protected override void OnExit(ExitEventArgs e)
        {
            ApplicationLogger.Write($"Libertix.exe exit, code={e.ApplicationExitCode}.");
            base.OnExit(e);
        }

        private void RegisterApplicationErrorLogging()
        {
            DispatcherUnhandledException += (_, args) =>
                ApplicationLogger.WriteException("Unhandled WPF dispatcher exception.", args.Exception);
            AppDomain.CurrentDomain.UnhandledException += (_, args) =>
                ApplicationLogger.Write(
                    "Unhandled AppDomain exception." + Environment.NewLine +
                    (args.ExceptionObject?.ToString() ?? "No exception details."));
            TaskScheduler.UnobservedTaskException += (_, args) =>
                ApplicationLogger.WriteException("Unobserved task exception.", args.Exception);
        }

        private static string TryGetUefiRecoveryStatePath(string[] args)
        {
            if (args == null || !args.Contains("--uefi-bootnext-failed"))
                return null;

            int stateIndex = Array.IndexOf(args, "--uefi-recovery-state");
            if (stateIndex < 0 || stateIndex + 1 >= args.Length)
                return null;

            try
            {
                string path = Path.GetFullPath(args[stateIndex + 1]);
                string root = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                    "Libertix",
                    "UefiRecovery") + Path.DirectorySeparatorChar;
                if (path.StartsWith(root, StringComparison.OrdinalIgnoreCase) && File.Exists(path))
                    return path;
            }
            catch
            {
                // Invalid or inaccessible command-line paths are rejected like
                // paths outside the protected recovery directory.
            }
            return null;
        }

        private static string AdministratorRequiredMessage()
        {
            return Localization.GetBootstrapString("AdministratorRequired");
        }

        private static bool IsRunningAsAdministrator()
        {
            using (var identity = WindowsIdentity.GetCurrent())
            {
                var principal = new WindowsPrincipal(identity);
                return principal.IsInRole(WindowsBuiltInRole.Administrator);
            }
        }
    }
}
