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

            SelectInstallationTarget(state, options.InstallationTarget);
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

        internal static void SelectInstallationTarget(InstallationState state, string mode)
        {
            if (mode == "windows")
            {
                state.SelectedInstallationTarget = null;
                return;
            }
            if (mode != "secondary")
                throw new InvalidOperationException("The unattended installation target is invalid.");
            var candidates = InstallationTargetSelection.ForFirmware(
                state.Compatibility.InstallationTargets, state.Compatibility.Firmware)
                .Where(target => !target.IsWindows).ToArray();
            if (candidates.Length != 1)
                throw new InvalidOperationException(
                    "Unattended secondary-disk installation requires exactly one verified secondary volume.");
            state.SelectedInstallationTarget = candidates[0];
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
            if (state.SelectedInstallationTarget is InstallationTargetInfo target)
            {
                if (initialFreeGiB < installerIsoGiB + InstallationSizePolicy.MinimumWindowsFreeSpaceGiB)
                    throw new InvalidOperationException(
                        "The Windows volume has insufficient space for the installer download.");
                initialFreeGiB = target.FreeBytes / (double)InstallationSizePolicy.BytesPerGiB;
                shrinkAvailableGiB = Math.Max(0,
                    target.SizeBytes - target.MinimumSizeBytes - InstallationSizePolicy.PartitionAlignmentBytes) /
                    (double)InstallationSizePolicy.BytesPerGiB;
                installerIsoGiB = 0;
            }
            double availableGiB = InstallationSizePolicy.AvailableLinuxSizeGiB(
                initialFreeGiB,
                shrinkAvailableGiB,
                installerIsoGiB);

            ValidateAvailableLinuxSize(requestedSizeGiB, availableGiB);
        }

        internal static void ValidateAvailableLinuxSize(int requestedSizeGiB, double availableGiB)
        {
            if (availableGiB < InstallationSizePolicy.MinimumFinalSizeGiB)
            {
                throw new InvalidOperationException(
                    string.Format(
                        System.Globalization.CultureInfo.InvariantCulture,
                        "Insufficient space on the selected installation volume: " +
                        "{0:F2} GiB is available for Linux after safety reserves; " +
                        "at least {1} GiB is required. No installation changes were started.",
                        availableGiB,
                        InstallationSizePolicy.MinimumFinalSizeGiB));
            }

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
