using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Libertix.Installation;

namespace Libertix.Pages
{
    /// <summary>
    /// Download transports used by the installation workflow.
    /// Kept in this partial class so moving the code does not alter state,
    /// dispatching, progress reporting, or retry behavior.
    /// </summary>
    public partial class ApplyChanges
    {
        private async Task<bool> DownloadIsoAsync(string url, string destinationPath)
        {
            return await DownloadFileWithRetriesAsync(
                url,
                destinationPath,
                attempts: 3,
                timeout: TimeSpan.FromHours(2),
                bufferSize: 8192,
                progressStart: BiosProgress.LiveDownloadTransferStart,
                progressSpan: BiosProgress.LiveDownloadTransferSpan,
                label: "ISO",
                progressMessage: Localized("ApplyChangesDownloading", "Downloading..."),
                maximumBytes: MaximumLiveIsoBytes);
        }

        private async Task<bool> DownloadInstallerIsoAsync(string url, string destinationPath)
        {
            return await DownloadFileWithRetriesAsync(
                url,
                destinationPath,
                attempts: 3,
                timeout: TimeSpan.FromHours(4),
                bufferSize: 81920,
                progressStart: BiosProgress.DistributionDownload,
                progressSpan: BiosProgress.DistributionReady - BiosProgress.DistributionDownload,
                label: "Linux installer ISO",
                progressMessage: Localized(
                    "ApplyChangesDownloadingLinuxIso",
                    "Downloading Linux ISO..."),
                maximumBytes: MaximumInstallerIsoBytes);
        }

        private async Task<bool> DownloadFileWithRetriesAsync(
            string url,
            string destinationPath,
            int attempts,
            TimeSpan timeout,
            int bufferSize,
            int progressStart,
            int progressSpan,
            string label,
            string progressMessage,
            long maximumBytes)
        {
            if (maximumBytes <= 0)
                throw new ArgumentOutOfRangeException(nameof(maximumBytes));
            for (int attempt = 1; attempt <= attempts; attempt++)
            {
                try
                {
                    bool aria2Downloaded = await TryDownloadWithBundledAria2Async(
                        url,
                        destinationPath,
                        timeout,
                        progressStart,
                        progressSpan,
                        label,
                        progressMessage,
                        attempt,
                        attempts,
                        maximumBytes);
                    if (aria2Downloaded)
                    {
                        Dispatcher.Invoke(() => Log($"{label} download completed with aria2"));
                        return true;
                    }

                    await DownloadFileOnceAsync(
                        url,
                        destinationPath,
                        timeout,
                        bufferSize,
                        progressStart,
                        progressSpan,
                        label,
                        progressMessage,
                        attempt,
                        attempts,
                        maximumBytes);
                    Dispatcher.Invoke(() => Log($"{label} download completed"));
                    return true;
                }
                catch (OperationCanceledException)
                    when (!_installationCancellation.IsCancellationRequested)
                {
                    Dispatcher.Invoke(() =>
                        Log($"{label} download attempt {attempt}/{attempts} timed out."));
                    if (attempt == attempts)
                    {
                        DeleteDownloadArtifactBestEffort(destinationPath, label);
                        return false;
                    }
                    Dispatcher.Invoke(() =>
                        Log($"{label}: partial download retained for the next resume attempt."));
                    await Task.Delay(
                        TimeSpan.FromSeconds(10 * attempt),
                        _installationCancellation.Token);
                }
                catch (OperationCanceledException)
                {
                    DeleteDownloadArtifactBestEffort(destinationPath, label);
                    throw;
                }
                catch (DownloadSizeLimitExceededException ex)
                {
                    DeleteDownloadArtifactBestEffort(destinationPath, label);
                    Dispatcher.Invoke(() => Log($"{label} download rejected: {ex.Message}"));
                    return false;
                }
                catch (UnterminatedProcessException)
                {
                    throw;
                }
                catch (Exception ex)
                {
                    Dispatcher.Invoke(() => Log($"{label} download attempt {attempt}/{attempts} failed: {ex.Message}"));
                    if (attempt == attempts)
                    {
                        DeleteDownloadArtifactBestEffort(destinationPath, label);
                        return false;
                    }
                    Dispatcher.Invoke(() =>
                        Log($"{label}: partial download retained for the next resume attempt."));
                    await Task.Delay(
                        TimeSpan.FromSeconds(10 * attempt),
                        _installationCancellation.Token);
                }
            }

            return false;
        }

        private async Task<bool> TryDownloadWithBundledAria2Async(
            string url,
            string destinationPath,
            TimeSpan timeout,
            int progressStart,
            int progressSpan,
            string label,
            string progressMessage,
            int attempt,
            int attempts,
            long maximumBytes)
        {
            string aria2Path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Tools", "aria2", "aria2c.exe");
            if (!File.Exists(aria2Path))
            {
                Dispatcher.Invoke(() => Log($"{label}: bundled aria2 not found, using HTTP downloader"));
                return false;
            }
            if (!await VerifySha256Async(
                aria2Path,
                Artifacts.Aria2.ExecutableSha256,
                "bundled aria2c.exe"))
            {
                Dispatcher.Invoke(() =>
                    Log($"{label}: bundled aria2 hash mismatch, using HTTP downloader"));
                return false;
            }

            string destinationDir = Path.GetDirectoryName(destinationPath);
            if (string.IsNullOrWhiteSpace(destinationDir))
                destinationDir = Path.GetTempPath();

            string fileName = Path.GetFileName(destinationPath);
            string downloadDir = destinationDir;
            string aria2OutputPath = destinationPath;
            bool removeDownloadDirectory = false;

            // aria2 is less predictable when writing directly to a drive root
            // on Windows. Use a temp folder, then move the completed file.
            string root = Path.GetPathRoot(destinationDir);
            if (!string.IsNullOrEmpty(root) &&
                string.Equals(destinationDir.TrimEnd('\\'), root.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
            {
                downloadDir = Path.Combine(Path.GetTempPath(), "LibertixDownloads", Guid.NewGuid().ToString("N"));
                aria2OutputPath = Path.Combine(downloadDir, fileName);
                removeDownloadDirectory = true;
            }

            try
            {
                Directory.CreateDirectory(downloadDir);
                Directory.CreateDirectory(destinationDir);

                bool? byteRangeSupport = await TestHttpByteRangeSupportAsync(url);
                if (!byteRangeSupport.HasValue)
                {
                    throw new IOException(
                        $"{label}: byte-range support could not be checked because the server " +
                        "was unreachable; the partial download is retained for retry.");
                }
                bool supportsByteRanges = byteRangeSupport.Value;
                if (!supportsByteRanges)
                {
                    DeleteDownloadArtifactBestEffort(aria2OutputPath, label);
                    DeleteDownloadArtifactBestEffort(aria2OutputPath + ".aria2", label);
                    Dispatcher.Invoke(() => Log(
                        $"{label}: the server does not provide valid byte ranges; " +
                        "using one connection without resume"));
                }

                string[] args = CreateAria2DownloadArguments(
                    url,
                    downloadDir,
                    fileName,
                    supportsByteRanges,
                    Aria2MaxConnections);
                int connectionCount = supportsByteRanges ? Aria2MaxConnections : 1;

                Dispatcher.Invoke(() =>
                {
                    Log($"{label}: downloading with bundled aria2 ({connectionCount} " +
                        $"connection{(connectionCount == 1 ? string.Empty : "s")}, " +
                        $"attempt {attempt}/{attempts})");
                    UpdateProgress(progressStart, progressMessage);
                });

                StreamingProcessResult processResult = await RunStreamingProcessAsync(
                    aria2Path,
                    string.Join(" ", Array.ConvertAll(args, QuoteArgument)),
                    timeout,
                    line => HandleAria2DownloadOutput(
                        line,
                        label,
                        progressMessage,
                        progressStart,
                        progressSpan),
                    policyLimitExceeded: () =>
                        File.Exists(aria2OutputPath) &&
                        new FileInfo(aria2OutputPath).Length > maximumBytes);

                if (processResult.Completion == StreamingProcessCompletion.Cancelled)
                    throw new OperationCanceledException(_installationCancellation.Token);

                if (processResult.Completion == StreamingProcessCompletion.TerminationFailed)
                    throw new UnterminatedProcessException(
                        $"{label}: timed-out process tree could not be proven stopped.");

                if (processResult.Completion == StreamingProcessCompletion.PolicyLimitExceeded)
                    throw new DownloadSizeLimitExceededException(
                        $"{label} exceeds {maximumBytes} bytes.");

                if (processResult.Completion != StreamingProcessCompletion.Exited || processResult.ExitCode != 0)
                {
                    if (attempt < attempts)
                    {
                        throw new IOException(
                            $"{label}: aria2 failed with rc={processResult.ExitCode}; " +
                            "the partial file will be resumed.");
                    }
                    Dispatcher.Invoke(() => Log(
                        $"{label}: aria2 failed with rc={processResult.ExitCode} after " +
                        $"{attempts} attempts; using HTTP fallback"));
                    DeleteDownloadArtifactBestEffort(aria2OutputPath, label);
                    return false;
                }

                if (!File.Exists(aria2OutputPath) || new FileInfo(aria2OutputPath).Length == 0)
                {
                    Dispatcher.Invoke(() => Log($"{label}: aria2 output missing or empty, using HTTP fallback"));
                    return false;
                }
                if (new FileInfo(aria2OutputPath).Length > maximumBytes)
                    throw new DownloadSizeLimitExceededException(
                        $"{label} exceeds {maximumBytes} bytes.");

                if (!string.Equals(aria2OutputPath, destinationPath, StringComparison.OrdinalIgnoreCase))
                {
                    if (File.Exists(destinationPath))
                        File.Delete(destinationPath);
                    File.Move(aria2OutputPath, destinationPath);
                }

                return true;
            }
            finally
            {
                if (removeDownloadDirectory)
                    DeleteDownloadDirectoryBestEffort(downloadDir, label);
            }
        }

        private async Task<bool?> TestHttpByteRangeSupportAsync(string url)
        {
            using (var timeoutCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                _installationCancellation.Token))
            using (var request = new HttpRequestMessage(HttpMethod.Get, url))
            {
                timeoutCancellation.CancelAfter(TimeSpan.FromSeconds(15));
                request.Headers.Range = new RangeHeaderValue(0, 0);
                try
                {
                    using (var response = await SharedHttpClient.SendAsync(
                        request,
                        HttpCompletionOption.ResponseHeadersRead,
                        timeoutCancellation.Token))
                    {
                        return IsExactSingleByteRangeResponse(
                            response.StatusCode,
                            response.Content.Headers.ContentRange);
                    }
                }
                catch (OperationCanceledException)
                    when (!_installationCancellation.IsCancellationRequested)
                {
                    return null;
                }
                catch (HttpRequestException)
                {
                    return null;
                }
            }
        }

        internal static bool IsExactSingleByteRangeResponse(
            HttpStatusCode statusCode,
            ContentRangeHeaderValue contentRange)
        {
            return statusCode == HttpStatusCode.PartialContent &&
                contentRange != null &&
                contentRange.HasRange &&
                contentRange.From == 0 &&
                contentRange.To == 0 &&
                contentRange.Length.HasValue &&
                contentRange.Length.Value > 0;
        }

        internal static string[] CreateAria2DownloadArguments(
            string url,
            string downloadDir,
            string fileName,
            bool supportsByteRanges,
            int maximumConnections)
        {
            if (maximumConnections < 1)
                throw new ArgumentOutOfRangeException(nameof(maximumConnections));

            int connections = supportsByteRanges ? maximumConnections : 1;
            string continueDownload = supportsByteRanges ? "true" : "false";
            return new[]
            {
                "--allow-overwrite=true",
                "--auto-file-renaming=false",
                $"--continue={continueDownload}",
                $"--max-connection-per-server={connections}",
                $"--split={connections}",
                "--min-split-size=1M",
                "--max-tries=5",
                "--retry-wait=10",
                "--connect-timeout=30",
                "--timeout=60",
                "--summary-interval=2",
                "--console-log-level=warn",
                "--enable-color=false",
                "--check-certificate=true",
                $"--dir={downloadDir}",
                $"--out={fileName}",
                url
            };
        }

        private void DeleteDownloadArtifactBestEffort(string path, string label)
        {
            try
            {
                if (File.Exists(path))
                    File.Delete(path);
            }
            catch (Exception ex)
            {
                Dispatcher.Invoke(() =>
                    Log($"{label}: partial download cleanup failed: {ex.Message}"));
            }
        }

        private void DeleteDownloadDirectoryBestEffort(string path, string label)
        {
            try
            {
                if (Directory.Exists(path))
                    Directory.Delete(path, recursive: true);
            }
            catch (Exception ex)
            {
                Dispatcher.Invoke(() =>
                    Log($"{label}: temporary download directory cleanup failed: {ex.Message}"));
            }
        }

        private void CleanupTransactionDownloadsBestEffort()
        {
            if (_installationPlan == null ||
                string.IsNullOrWhiteSpace(_installationPlan.PlanId))
            {
                return;
            }

            try
            {
                string systemDriveRoot =
                    (_installationPlan.Disk.SystemDrive ?? WindowsSystemDrive) + @"\";
                InstallationTemporaryArtifacts.DeleteDownloadDirectory(
                    systemDriveRoot,
                    _installationPlan.PlanId);
                Log("Transaction download cleanup verified.");
            }
            catch (Exception ex)
            {
                Log($"Transaction download cleanup failed: {ex.Message}");
            }
        }

        private void HandleAria2DownloadOutput(
            string line,
            string label,
            string progressMessage,
            int progressStart,
            int progressSpan)
        {
            if (string.IsNullOrWhiteSpace(line))
                return;

            Log($"aria2 {label}: {line}");

            var match = Regex.Match(line, @"\((\d{1,3})%\)");
            if (!match.Success)
                match = Regex.Match(line, @"\b(\d{1,3})%");

            if (!match.Success || !int.TryParse(match.Groups[1].Value, out int percent))
                return;

            int clamped = Math.Max(0, Math.Min(100, percent));
            int overallProgress = progressStart + (clamped * progressSpan / 100);
            UpdateProgress(overallProgress, $"{progressMessage} {clamped}%");
        }

        private async Task DownloadFileOnceAsync(
            string url,
            string destinationPath,
            TimeSpan timeout,
            int bufferSize,
            int progressStart,
            int progressSpan,
            string label,
            string progressMessage,
            int attempt,
            int attempts,
            long maximumBytes)
        {
            using (var timeoutCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                _installationCancellation.Token))
            {
                timeoutCancellation.CancelAfter(timeout);
                using (var response = await SharedHttpClient.GetAsync(
                    url,
                    HttpCompletionOption.ResponseHeadersRead,
                    timeoutCancellation.Token))
                {
                    response.EnsureSuccessStatusCode();

                    var totalBytes = response.Content.Headers.ContentLength ?? 0;
                    if (totalBytes > maximumBytes)
                        throw new DownloadSizeLimitExceededException(
                            $"{label} exceeds {maximumBytes} bytes.");
                    var totalMB = totalBytes / 1024.0 / 1024.0;
                    Dispatcher.Invoke(() => Log($"{label} size: {totalMB:N0} MB (attempt {attempt}/{attempts})"));

                    using (var contentStream = await response.Content.ReadAsStreamAsync())
                    using (var fileStream = new FileStream(
                        destinationPath,
                        FileMode.Create,
                        FileAccess.Write,
                        FileShare.None,
                        bufferSize,
                        true))
                    {
                        var buffer = new byte[bufferSize];
                        long totalRead = 0;
                        int bytesRead;
                        var lastProgressUpdate = DateTime.Now;

                        while ((bytesRead = await contentStream.ReadAsync(
                            buffer,
                            0,
                            buffer.Length,
                            timeoutCancellation.Token)) > 0)
                        {
                            if (totalRead > maximumBytes - bytesRead)
                                throw new DownloadSizeLimitExceededException(
                                    $"{label} exceeds {maximumBytes} bytes.");
                            await fileStream.WriteAsync(
                                buffer,
                                0,
                                bytesRead,
                                timeoutCancellation.Token);
                            totalRead += bytesRead;

                            if ((DateTime.Now - lastProgressUpdate).TotalMilliseconds > 500)
                            {
                                var progressPercent = totalBytes > 0 ? (int)(totalRead * 100 / totalBytes) : 0;
                                var downloadedMB = totalRead / 1024.0 / 1024.0;
                                Dispatcher.Invoke(() =>
                                {
                                    var overallProgress = progressStart + (progressPercent * progressSpan / 100);
                                    UpdateProgress(
                                        overallProgress,
                                        $"{progressMessage} {downloadedMB:N0}/{totalMB:N0} MB "
                                        + $"({progressPercent}%)");
                                });
                                lastProgressUpdate = DateTime.Now;
                            }
                        }

                        if (totalBytes > 0 && totalRead != totalBytes)
                        {
                            throw new IOException(
                                $"Downloaded size mismatch for {url}: expected {totalBytes} bytes, "
                                + $"got {totalRead} bytes");
                        }
                    }
                }
            }
        }
    }
}
