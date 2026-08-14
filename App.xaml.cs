using System;
using System.IO;
using System.Diagnostics;
using System.Security.Principal;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using Libertix.Helpers;
using Libertix.Installation;
using Libertix.Models;

namespace Libertix
{
    public partial class App : Application
    {
        private Mutex _singleInstanceMutex;
        private bool _ownsSingleInstanceMutex;
        public InstallationState InstallationState { get; } = new InstallationState();
        public StartupOptions RuntimeOptions { get; private set; } = new StartupOptions();
        public ApplicationBuild Build { get; } = ApplicationBuild.Current;
        public FilepoolConfig Filepool { get; private set; } =
            FilepoolConfig.ForBuild(ApplicationBuild.Current);

        protected override async void OnStartup(StartupEventArgs e)
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

            if (!await ValidatePublishedVersionAsync())
                return;

            base.OnStartup(e);
        }

        private bool TryConfigureStartupOptions(string[] args)
        {
            if (!StartupOptions.TryParse(args, out StartupOptions options, out string error))
            {
                RejectInvalidStartupOptions(error);
                return false;
            }

            FilepoolConfig filepool = FilepoolConfig.ForBuild(Build);
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

            bool usesPublishedDevelopmentChannel =
                Build.IsDevelopment &&
                string.Equals(
                    Filepool.BaseUrl,
                    Build.MetadataBaseUrl,
                    StringComparison.OrdinalIgnoreCase);
            if (options.Unattended != null &&
                !Filepool.IsDevelopmentMode &&
                !usesPublishedDevelopmentChannel)
            {
                RejectInvalidStartupOptions(
                    "Unattended mode requires a development build channel or " +
                    "an explicit development filepool URL.");
                return false;
            }

            RuntimeOptions = options;
            ApplicationLogger.Write($"Filepool base URL: {Filepool.BaseUrl}");
            ApplicationLogger.Write($"Build version: {Build.Version}; channel={Build.Channel}.");
            if (!string.IsNullOrEmpty(options.DevelopmentSshStaticIpv4Address))
            {
                ApplicationLogger.Write(
                    "Development SSH/static network enabled for " +
                    options.DevelopmentSshStaticIpv4Address + "/" +
                    options.DevelopmentSshStaticIpv4PrefixLength + ".");
            }
            if (options.Unattended != null)
                ApplicationLogger.Write("Unattended development workflow enabled.");
            return true;
        }

        private async Task<bool> ValidatePublishedVersionAsync()
        {
            ReleaseCheckResult result = await ReleaseMetadataClient.CheckAsync(Build, Filepool);
            if (result.IsCurrent)
                return true;

            if (!string.IsNullOrWhiteSpace(result.Error))
            {
                ApplicationLogger.Write("Published version check failed: " + result.Error);
                MessageBox.Show(
                    string.Format(
                        Localization.GetBootstrapString(
                            "ReleaseCheckFailedMessage",
                            "Libertix could not verify the current published version: {0}"),
                        result.Error),
                    Localization.GetBootstrapString(
                        "ReleaseCheckFailedTitle",
                        "Libertix - version verification failed"),
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
                Shutdown(4);
                return false;
            }

            ApplicationLogger.Write(
                $"Startup refused: build {Build.Version} is older than {result.LatestVersion}.");
            MessageBoxResult response = MessageBox.Show(
                string.Format(
                    Localization.GetBootstrapString(
                        "ReleaseUpdateRequiredMessage",
                        "This Libertix version ({0}) is no longer current. The latest version is {1}. " +
                        "Download the current release before continuing. Open the download page now?"),
                    Build.Version,
                    result.LatestVersion),
                Localization.GetBootstrapString(
                    "ReleaseUpdateRequiredTitle",
                    "Libertix - update required"),
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning);
            if (response == MessageBoxResult.Yes)
            {
                try
                {
                    Process.Start(result.ReleaseUrl);
                }
                catch (Exception exception) when (
                    exception is InvalidOperationException ||
                    exception is System.ComponentModel.Win32Exception)
                {
                    ApplicationLogger.WriteException(
                        "The current release URL could not be opened.",
                        exception);
                }
            }
            Shutdown(5);
            return false;
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
            {
                UnattendedWorkflow.TryPublishFailure(
                    "wpf-dispatcher-unhandled",
                    args.Exception?.Message);
                ApplicationLogger.WriteException(
                    "Unhandled WPF dispatcher exception.",
                    args.Exception);
            };
            AppDomain.CurrentDomain.UnhandledException += (_, args) =>
            {
                UnattendedWorkflow.TryPublishFailure(
                    "appdomain-unhandled",
                    (args.ExceptionObject as Exception)?.Message ??
                    "Unhandled AppDomain exception.");
                ApplicationLogger.Write(
                    "Unhandled AppDomain exception." + Environment.NewLine +
                    (args.ExceptionObject?.ToString() ?? "No exception details."));
            };
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
