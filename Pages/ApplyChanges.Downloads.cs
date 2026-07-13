using System;
using System.IO;
using System.Net.Http;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

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
                progressStart: 60,
                progressSpan: 20,
                label: "ISO",
                progressMessage: "Downloading...");
        }

        private async Task<bool> DownloadInstallerIsoAsync(string url, string destinationPath)
        {
            return await DownloadFileWithRetriesAsync(
                url,
                destinationPath,
                attempts: 3,
                timeout: TimeSpan.FromHours(4),
                bufferSize: 81920,
                progressStart: 85,
                progressSpan: 10,
                label: "Linux installer ISO",
                progressMessage: "Downloading Linux ISO...");
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
            string progressMessage)
        {
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
                        attempts);
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
                        attempts);
                    Dispatcher.Invoke(() => Log($"{label} download completed"));
                    return true;
                }
                catch (Exception ex)
                {
                    try { if (File.Exists(destinationPath)) File.Delete(destinationPath); } catch { }
                    Dispatcher.Invoke(() => Log($"{label} download attempt {attempt}/{attempts} failed: {ex.Message}"));
                    if (attempt == attempts)
                        return false;
                    await Task.Delay(TimeSpan.FromSeconds(2 * attempt));
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
            int attempts)
        {
            string aria2Path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Tools", "aria2", "aria2c.exe");
            if (!File.Exists(aria2Path))
            {
                Dispatcher.Invoke(() => Log($"{label}: bundled aria2 not found, using HTTP downloader"));
                return false;
            }

            string destinationDir = Path.GetDirectoryName(destinationPath);
            if (string.IsNullOrWhiteSpace(destinationDir))
                destinationDir = Path.GetTempPath();

            string fileName = Path.GetFileName(destinationPath);
            string downloadDir = destinationDir;
            string aria2OutputPath = destinationPath;

            // aria2 is less predictable when writing directly to a drive root
            // on Windows. Use a temp folder, then move the completed file.
            string root = Path.GetPathRoot(destinationDir);
            if (!string.IsNullOrEmpty(root) &&
                string.Equals(destinationDir.TrimEnd('\\'), root.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
            {
                downloadDir = Path.Combine(Path.GetTempPath(), "LibertixDownloads", Guid.NewGuid().ToString("N"));
                aria2OutputPath = Path.Combine(downloadDir, fileName);
            }

            Directory.CreateDirectory(downloadDir);
            Directory.CreateDirectory(destinationDir);

            var args = new[]
            {
                "--allow-overwrite=true",
                "--auto-file-renaming=false",
                "--continue=true",
                $"--max-connection-per-server={Aria2MaxConnections}",
                $"--split={Aria2MaxConnections}",
                "--min-split-size=1M",
                "--summary-interval=2",
                "--console-log-level=warn",
                "--check-certificate=true",
                $"--dir={downloadDir}",
                $"--out={fileName}",
                url
            };

            Dispatcher.Invoke(() =>
            {
                Log($"{label}: downloading with bundled aria2 ({Aria2MaxConnections} connections, attempt {attempt}/{attempts})");
                UpdateProgress(progressStart, progressMessage);
            });

            int exitCode = await RunStreamingProcessAsync(
                aria2Path,
                string.Join(" ", Array.ConvertAll(args, QuoteArgument)),
                timeout,
                line => HandleAria2DownloadOutput(line, label, progressMessage, progressStart, progressSpan));

            if (exitCode != 0)
            {
                Dispatcher.Invoke(() => Log($"{label}: aria2 failed with rc={exitCode}, using HTTP fallback"));
                try { if (File.Exists(aria2OutputPath)) File.Delete(aria2OutputPath); } catch { }
                return false;
            }

            if (!File.Exists(aria2OutputPath) || new FileInfo(aria2OutputPath).Length == 0)
            {
                Dispatcher.Invoke(() => Log($"{label}: aria2 output missing or empty, using HTTP fallback"));
                return false;
            }

            if (!string.Equals(aria2OutputPath, destinationPath, StringComparison.OrdinalIgnoreCase))
            {
                if (File.Exists(destinationPath))
                    File.Delete(destinationPath);
                File.Move(aria2OutputPath, destinationPath);
                try { Directory.Delete(downloadDir, true); } catch { }
            }

            return true;
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
            int attempts)
        {
            using (var client = new HttpClient())
            {
                client.Timeout = timeout;
                using (var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead))
                {
                    response.EnsureSuccessStatusCode();

                    var totalBytes = response.Content.Headers.ContentLength ?? 0;
                    var totalMB = totalBytes / 1024.0 / 1024.0;
                    Dispatcher.Invoke(() => Log($"{label} size: {totalMB:N0} MB (attempt {attempt}/{attempts})"));

                    using (var contentStream = await response.Content.ReadAsStreamAsync())
                    using (var fileStream = new FileStream(destinationPath, FileMode.Create, FileAccess.Write, FileShare.None, bufferSize, true))
                    {
                        var buffer = new byte[bufferSize];
                        long totalRead = 0;
                        int bytesRead;
                        var lastProgressUpdate = DateTime.Now;

                        while ((bytesRead = await contentStream.ReadAsync(buffer, 0, buffer.Length)) > 0)
                        {
                            await fileStream.WriteAsync(buffer, 0, bytesRead);
                            totalRead += bytesRead;

                            if ((DateTime.Now - lastProgressUpdate).TotalMilliseconds > 500)
                            {
                                var progressPercent = totalBytes > 0 ? (int)(totalRead * 100 / totalBytes) : 0;
                                var downloadedMB = totalRead / 1024.0 / 1024.0;
                                Dispatcher.Invoke(() =>
                                {
                                    var overallProgress = progressStart + (progressPercent * progressSpan / 100);
                                    UpdateProgress(overallProgress, $"{progressMessage} {downloadedMB:N0}/{totalMB:N0} MB ({progressPercent}%)");
                                });
                                lastProgressUpdate = DateTime.Now;
                            }
                        }

                        if (totalBytes > 0 && totalRead != totalBytes)
                        {
                            throw new IOException($"Downloaded size mismatch for {url}: expected {totalBytes} bytes, got {totalRead} bytes");
                        }
                    }
                }
            }
        }
    }
}
