using System;
using System.IO;
using System.Net.Http;
using Libertix.Installation;

namespace Libertix.Pages
{
    public partial class ApplyChanges
    {
        private enum StreamingProcessCompletion
        {
            Exited,
            TimedOut,
            Cancelled,
            PolicyLimitExceeded,
            TerminationFailed
        }

        private sealed class DownloadSizeLimitExceededException : IOException
        {
            public DownloadSizeLimitExceededException(string message)
                : base(message)
            {
            }
        }

        private sealed class UnterminatedProcessException : InvalidOperationException
        {
            public UnterminatedProcessException(string message)
                : base(message)
            {
            }
        }

        private sealed class StreamingProcessResult
        {
            public int ExitCode { get; set; }
            public StreamingProcessCompletion Completion { get; set; }
        }

        private static class BiosProgress
        {
            public const int DistributionDownload = 2;
            public const int DistributionReady = 8;
            public const int ShrinkWindows = 10;
            public const int CreateInstallerPartition = 30;
            public const int PartitionReady = 50;
            public const int LiveDownload = 55;
            public const int LiveDownloadTransferStart = 60;
            public const int LiveDownloadTransferSpan = 20;
            public const int LiveMediaCopy = 80;
            public const int InstallationContextReady = 95;
            public const int BootloaderDownload = 96;
            public const int BootEntryReady = 98;
            public const int Complete = 100;
        }

        private static readonly HttpClient SharedHttpClient = new HttpClient
        {
            Timeout = System.Threading.Timeout.InfiniteTimeSpan
        };

        private const long MaximumLiveIsoBytes = 2L * 1024 * 1024 * 1024;
        private const long MaximumInstallerIsoBytes = 8L * 1024 * 1024 * 1024;
        private const long MaximumSupportArtifactBytes = 512L * 1024 * 1024;
        private const long MaximumBootArtifactBytes = 16L * 1024 * 1024;

        private static bool GetFirmwareType(out FirmwareType firmwareType)
        {
            return FirmwareInterop.TryGetFirmwareType(out firmwareType);
        }
    }
}
