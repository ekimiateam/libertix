using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Libertix.Helpers;

namespace Libertix.Pages
{
    public partial class ApplyChanges
    {
        private async Task<StreamingProcessResult> RunStreamingProcessAsync(
            string fileName,
            string arguments,
            TimeSpan timeout,
            Action<string> onLine,
            bool observeCancellation = true,
            Action<string> captureStandardOutput = null,
            Func<bool> policyLimitExceeded = null)
        {
            return await Task.Run(() =>
            {
                var psi = new ProcessStartInfo
                {
                    FileName = fileName,
                    Arguments = arguments,
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true,
                    StandardOutputEncoding = Encoding.UTF8,
                    StandardErrorEncoding = Encoding.UTF8
                };

                using (var process = new Process { StartInfo = psi, EnableRaisingEvents = true })
                {
                    var outputClosed = new TaskCompletionSource<bool>();
                    var errorClosed = new TaskCompletionSource<bool>();
                    process.OutputDataReceived += (_, e) =>
                    {
                        if (e.Data == null)
                        {
                            outputClosed.TrySetResult(true);
                        }
                        else
                        {
                            captureStandardOutput?.Invoke(e.Data);
                            Dispatcher.BeginInvoke(new Action(() => onLine(e.Data)));
                        }
                    };
                    process.ErrorDataReceived += (_, e) =>
                    {
                        if (e.Data == null)
                        {
                            errorClosed.TrySetResult(true);
                        }
                        else
                        {
                            Dispatcher.BeginInvoke(new Action(() => onLine($"ERROR: {e.Data}")));
                        }
                    };

                    if (!process.Start())
                        throw new InvalidOperationException($"Failed to start {fileName}");

                    SetActiveStreamingProcess(process);
                    try
                    {
                        process.BeginOutputReadLine();
                        process.BeginErrorReadLine();

                        var timer = Stopwatch.StartNew();
                        while (!process.WaitForExit(250))
                        {
                            if (policyLimitExceeded?.Invoke() == true)
                            {
                                bool stopped = WindowsProcessRunner.TerminateProcessTree(process);
                                return new StreamingProcessResult
                                {
                                    ExitCode = process.HasExited ? process.ExitCode : -1,
                                    Completion = stopped
                                        ? StreamingProcessCompletion.PolicyLimitExceeded
                                        : StreamingProcessCompletion.TerminationFailed
                                };
                            }

                            if (observeCancellation && _installationCancellation.IsCancellationRequested)
                            {
                                bool stopped = WindowsProcessRunner.TerminateProcessTree(process);
                                return new StreamingProcessResult
                                {
                                    ExitCode = process.HasExited ? process.ExitCode : -1,
                                    Completion = stopped
                                        ? StreamingProcessCompletion.Cancelled
                                        : StreamingProcessCompletion.TerminationFailed
                                };
                            }

                            if (timer.Elapsed > timeout)
                            {
                                bool stopped = WindowsProcessRunner.TerminateProcessTree(process);
                                Dispatcher.Invoke(() => Log($"ERROR: process timed out after {timeout.TotalMinutes:N0} minutes"));
                                return new StreamingProcessResult
                                {
                                    ExitCode = process.HasExited ? process.ExitCode : -1,
                                    Completion = stopped
                                        ? StreamingProcessCompletion.TimedOut
                                        : StreamingProcessCompletion.TerminationFailed
                                };
                            }
                        }

                        WindowsProcessRunner.WaitForRedirectedStreams(
                            outputClosed.Task,
                            errorClosed.Task);
                        return new StreamingProcessResult
                        {
                            ExitCode = process.ExitCode,
                            Completion = StreamingProcessCompletion.Exited
                        };
                    }
                    finally
                    {
                        ClearActiveStreamingProcess(process);
                    }
                }
            });
        }

        private async Task<bool> DownloadFileAsync(string url, string destinationPath)
        {
            try
            {
                using (var timeoutCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                    _installationCancellation.Token))
                {
                    timeoutCancellation.CancelAfter(WindowsProcessTimeouts.BootArtifactDownload);
                    using (var response = await SharedHttpClient.GetAsync(
                        url,
                        HttpCompletionOption.ResponseHeadersRead,
                        timeoutCancellation.Token))
                    {
                        response.EnsureSuccessStatusCode();
                        long contentLength = response.Content.Headers.ContentLength ?? 0;
                        if (contentLength > MaximumBootArtifactBytes)
                            throw new DownloadSizeLimitExceededException(
                                $"Boot artifact exceeds {MaximumBootArtifactBytes} bytes.");
                        using (var source = await response.Content.ReadAsStreamAsync())
                        using (var destination = new FileStream(
                            destinationPath,
                            FileMode.Create,
                            FileAccess.Write,
                            FileShare.None,
                            81920,
                            true))
                        {
                            var buffer = new byte[81920];
                            long totalRead = 0;
                            int bytesRead;
                            while ((bytesRead = await source.ReadAsync(
                                buffer,
                                0,
                                buffer.Length,
                                timeoutCancellation.Token)) > 0)
                            {
                                if (totalRead > MaximumBootArtifactBytes - bytesRead)
                                    throw new DownloadSizeLimitExceededException(
                                        $"Boot artifact exceeds {MaximumBootArtifactBytes} bytes.");
                                await destination.WriteAsync(
                                    buffer,
                                    0,
                                    bytesRead,
                                    timeoutCancellation.Token);
                                totalRead += bytesRead;
                            }
                        }
                    }
                    return true;
                }
            }
            catch (OperationCanceledException)
                when (!_installationCancellation.IsCancellationRequested)
            {
                DeleteDownloadArtifactBestEffort(destinationPath, "boot artifact");
                Dispatcher.Invoke(() =>
                    Log($"Boot artifact download timed out after 5 minutes: {url}"));
                return false;
            }
            catch (OperationCanceledException)
            {
                DeleteDownloadArtifactBestEffort(destinationPath, "boot artifact");
                throw;
            }
            catch (Exception ex)
            {
                DeleteDownloadArtifactBestEffort(destinationPath, "boot artifact");
                Dispatcher.Invoke(() => Log($"Download failed for {url}: {ex.Message}"));
                return false;
            }
        }

        private async Task<bool> VerifySha256Async(string path, string expectedHash, string label)
        {
            if (string.IsNullOrWhiteSpace(expectedHash) ||
                !Regex.IsMatch(expectedHash, "^[0-9a-fA-F]{64}$"))
            {
                Log($"ERROR: Missing or invalid SHA256 manifest entry for {label}.");
                return false;
            }
            if (!File.Exists(path))
            {
                Log($"ERROR: Cannot verify missing file for {label}: {path}");
                return false;
            }

            string actualHash = await Task.Run(() =>
            {
                using (var stream = File.OpenRead(path))
                using (var sha = SHA256.Create())
                {
                    return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
                }
            });
            bool valid = string.Equals(actualHash, expectedHash, StringComparison.OrdinalIgnoreCase);
            Log($"{label} SHA256: {actualHash} ({(valid ? "verified" : "MISMATCH")})");
            return valid;
        }

        private async Task RunBcdeditCommandAsync(string bcdeditPath, string arguments)
        {
            var result = await Task.Run(() => RunProcess(
                bcdeditPath,
                arguments,
                (int)WindowsProcessTimeouts.QuickCommand.TotalMilliseconds,
                GetWindowsConsoleEncoding()));
            if (!string.IsNullOrWhiteSpace(result.output))
                Log($"bcdedit output: {result.output.Trim()}");
            if (!string.IsNullOrWhiteSpace(result.error))
                Log($"bcdedit error: {result.error.Trim()}");

            Log($"bcdedit {arguments}: {(result.exitCode == 0 ? "OK" : "Failed")}");
            if (result.exitCode != 0)
            {
                throw new InvalidOperationException($"bcdedit {arguments} failed with rc={result.exitCode}");
            }
        }

    }
}
