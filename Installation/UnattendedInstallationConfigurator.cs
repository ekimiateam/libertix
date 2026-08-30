using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Libertix.Helpers;
using Libertix.Models;

namespace Libertix.Installation
{
    public static class UnattendedInstallationConfigurator
    {
        public static async Task ConfigureAsync(
            InstallationState state,
            FilepoolConfig filepool)
        {
            if (state == null)
                throw new ArgumentNullException(nameof(state));
            if (state.Compatibility == null)
                throw new InvalidOperationException(
                    "Compatibility must be proven before unattended configuration.");

            UnattendedOptions options = UnattendedWorkflow.Current ??
                throw new InvalidOperationException(
                    "Unattended configuration is not available.");
            var distributions = await DistributionCatalogLoader.LoadAsync(filepool);
            DistroInfo distribution = distributions.SingleOrDefault(
                item => string.Equals(
                    item.Id,
                    options.Distribution,
                    StringComparison.Ordinal));
            if (distribution == null)
                throw new InvalidOperationException(
                    "The unattended distribution is not present in the loaded catalog.");

            state.SelectedDistro = distribution;
            await UnattendedWorkflow.PublishStageAndWaitAsync(
                "configuration-distribution-applied");

            ValidateLinuxSize(state, distribution, options.LinuxSizeGiB);
            state.SelectedLinuxSizeGiB = options.LinuxSizeGiB;
            await UnattendedWorkflow.PublishStageAndWaitAsync(
                "configuration-disk-size-applied");

            state.Sharing = new SharingOptions
            {
                ShareWindowsFilesInLinux = options.ShareWindowsFilesInLinux,
                ShareLinuxFilesInWindows = options.ShareLinuxFilesInWindows,
                MigrateWindowsPreferences = options.MigrateWindowsPreferences
            };
            await UnattendedWorkflow.PublishStageAndWaitAsync(
                "configuration-sharing-applied");

            state.Account = new AccountInfo
            {
                Username = options.LinuxUsername,
                Password = options.LinuxPassword,
                ComputerName = options.ComputerName
            };
            options.ClearPassword();
            await UnattendedWorkflow.PublishStageAndWaitAsync(
                "configuration-account-applied");
        }

        private static void ValidateLinuxSize(
            InstallationState state,
            DistroInfo distribution,
            int requestedSizeGiB)
        {
            string systemRoot = Path.GetPathRoot(Environment.SystemDirectory);
            DriveInfo systemDrive = DriveInfo.GetDrives().FirstOrDefault(
                drive => drive.IsReady && string.Equals(
                    drive.Name,
                    systemRoot,
                    StringComparison.OrdinalIgnoreCase));
            if (systemDrive == null)
                throw new InvalidOperationException("The Windows system drive was not found.");

            double initialFreeGiB = systemDrive.AvailableFreeSpace /
                (double)InstallationSizePolicy.BytesPerGiB;
            double shrinkAvailableGiB = state.Compatibility.ShrinkAvailableBytes /
                (double)InstallationSizePolicy.BytesPerGiB;
            double installerIsoGiB = distribution.IsoInstallerSizeBytes /
                (double)InstallationSizePolicy.BytesPerGiB;
            double availableGiB = InstallationSizePolicy.AvailableLinuxSizeGiB(
                initialFreeGiB,
                shrinkAvailableGiB,
                installerIsoGiB);

            if (requestedSizeGiB < InstallationSizePolicy.MinimumFinalSizeGiB ||
                requestedSizeGiB > availableGiB)
            {
                throw new InvalidOperationException(
                    string.Format(
                        System.Globalization.CultureInfo.InvariantCulture,
                        "The unattended Linux size {0} GiB is outside the valid range " +
                        "{1}-{2:F2} GiB for this machine.",
                        requestedSizeGiB,
                        InstallationSizePolicy.MinimumFinalSizeGiB,
                        availableGiB));
            }
        }
    }
}
