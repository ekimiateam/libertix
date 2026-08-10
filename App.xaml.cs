using System;
using System.IO;
using System.Security.Principal;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using Libertix.Helpers;
using Libertix.Models;

namespace Libertix
{
    public partial class App : Application
    {
        private Mutex _singleInstanceMutex;
        private bool _ownsSingleInstanceMutex;
        public InstallationState InstallationState { get; } = new InstallationState();
        public StartupOptions RuntimeOptions { get; private set; } = new StartupOptions();
        public FilepoolConfig Filepool { get; private set; } = FilepoolConfig.Production;

        protected override void OnStartup(StartupEventArgs e)
        {
            _singleInstanceMutex = new Mutex(
                initiallyOwned: true,
                name: @"Global\Libertix.Installation",
                createdNew: out bool createdNew);
            _ownsSingleInstanceMutex = createdNew;
            if (!createdNew)
            {
                _singleInstanceMutex.Dispose();
                _singleInstanceMutex = null;
                MessageBox.Show(
                    Localization.GetBootstrapString(
                        "SingleInstanceRequired",
                        "Another Libertix instance is already running."),
                    "Libertix",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
                Shutdown(3);
                return;
            }
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

            string recoveryStatePath = TryGetUefiRecoveryStatePath(RuntimeOptions);
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
                string.Format(
                    Localization.GetBootstrapString(
                        "InvalidStartupOptionsMessage",
                        "Invalid startup option: {0}"),
                    error),
                Localization.GetBootstrapString(
                    "InvalidStartupOptionsTitle",
                    "Libertix - invalid startup option"),
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            Current.Shutdown(2);
        }

        protected override void OnExit(ExitEventArgs e)
        {
            ApplicationLogger.Write($"Libertix.exe exit, code={e.ApplicationExitCode}.");
            if (_singleInstanceMutex != null)
            {
                if (_ownsSingleInstanceMutex)
                    _singleInstanceMutex.ReleaseMutex();
                _singleInstanceMutex.Dispose();
                _singleInstanceMutex = null;
                _ownsSingleInstanceMutex = false;
            }
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

        private static string TryGetUefiRecoveryStatePath(StartupOptions options)
        {
            if (options == null ||
                !options.UefiBootNextFailed ||
                string.IsNullOrWhiteSpace(options.UefiRecoveryStatePath))
            {
                return null;
            }

            try
            {
                string path = Path.GetFullPath(options.UefiRecoveryStatePath);
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
            return Localization.GetBootstrapString(
                "AdministratorRequired",
                "Libertix must be run as administrator.");
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
