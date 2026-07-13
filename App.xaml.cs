using System;
using System.Collections.Generic;
using System.Configuration;
using System.Data;
using System.IO;
using System.Linq;
using System.Security.Principal;
using System.Threading.Tasks;
using System.Windows;
using Libertix.Models;

namespace Libertix
{
    /// <summary>
    /// Logique d'interaction pour App.xaml
    /// </summary>
    public partial class App : Application
    {
        public InstallationState InstallationState { get; } = new InstallationState();

        protected override void OnStartup(StartupEventArgs e)
        {
            if (!IsRunningAsAdministrator())
            {
                MessageBox.Show(
                    "Libertix doit être lancé en administrateur pour modifier les partitions et le démarrage Windows.",
                    "Libertix - droits administrateur requis",
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
            catch { }
            return null;
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
