using System;

namespace Libertix.Installation
{
    /// <summary>
    /// Single source of truth for the final Linux allocation and the temporary
    /// FAT32 staging allocation used by both firmware workflows.
    /// </summary>
    public static class InstallationSizePolicy
    {
        public const int MinimumFinalSizeGiB = 20;
        public const int TargetWindowsFreeSpaceGiB = 10;
        public const int WindowsFreeSpaceToleranceGiB = 2;
        public const int MinimumWindowsFreeSpaceGiB =
            TargetWindowsFreeSpaceGiB - WindowsFreeSpaceToleranceGiB;
        public const int MaximumDirectFat32SizeGiB = 31;
        public const int LargeInstallationStagingSizeGiB = 8;
        public const long BytesPerGiB = 1024L * 1024L * 1024L;
        public const long MebibytesPerGiB = 1024L;

        public static InstallationSizes FromRequestedGigabytes(double requestedGigabytes)
        {
            if (double.IsNaN(requestedGigabytes) || double.IsInfinity(requestedGigabytes))
                throw new ArgumentOutOfRangeException(nameof(requestedGigabytes));

            int finalSizeGiB = Math.Max(
                MinimumFinalSizeGiB,
                checked((int)Math.Round(requestedGigabytes)));
            int stagingSizeGiB = finalSizeGiB > MaximumDirectFat32SizeGiB
                ? LargeInstallationStagingSizeGiB
                : finalSizeGiB;

            return new InstallationSizes(finalSizeGiB, stagingSizeGiB);
        }

        public static double AvailableLinuxSizeGiB(
            double initialWindowsFreeGiB,
            double shrinkAvailableGiB,
            double installerIsoGiB)
        {
            double windowsBudget =
                initialWindowsFreeGiB - installerIsoGiB - MinimumWindowsFreeSpaceGiB;
            return Math.Max(0, Math.Min(windowsBudget, shrinkAvailableGiB));
        }

        public static double RemainingWindowsFreeSpaceGiB(
            double initialWindowsFreeGiB,
            double installerIsoGiB,
            double linuxSizeGiB)
        {
            return initialWindowsFreeGiB - installerIsoGiB - linuxSizeGiB;
        }

    }

    public sealed class InstallationSizes
    {
        internal InstallationSizes(int finalSizeGiB, int stagingSizeGiB)
        {
            FinalSizeGiB = finalSizeGiB;
            StagingSizeGiB = stagingSizeGiB;
        }

        public int FinalSizeGiB { get; }
        public int StagingSizeGiB { get; }
        public long FinalSizeBytes => checked(FinalSizeGiB * InstallationSizePolicy.BytesPerGiB);
        public long StagingSizeBytes => checked(StagingSizeGiB * InstallationSizePolicy.BytesPerGiB);
        public double FinalSizeMiB => FinalSizeGiB * InstallationSizePolicy.MebibytesPerGiB;
        public double StagingSizeMiB => StagingSizeGiB * InstallationSizePolicy.MebibytesPerGiB;
    }
}
