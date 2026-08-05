using System;
using System.Diagnostics;
using System.IO;
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
        private async Task<int> RunStreamingProcessAsync(
            string fileName,
            string arguments,
            TimeSpan timeout,
            Action<string> onLine,
            bool observeCancellation = true)
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
                    process.OutputDataReceived += (_, e) =>
                    {
                        if (e.Data != null)
                            Dispatcher.BeginInvoke(new Action(() => onLine(e.Data)));
                    };
                    process.ErrorDataReceived += (_, e) =>
                    {
                        if (e.Data != null)
                            Dispatcher.BeginInvoke(new Action(() => onLine($"ERROR: {e.Data}")));
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
                            if (observeCancellation && _installationCancellation.IsCancellationRequested)
                            {
                                StopProcessTree(process);
                                return -2;
                            }

                            if (timer.Elapsed > timeout)
                            {
                                StopProcessTree(process);
                                Dispatcher.Invoke(() => Log($"ERROR: process timed out after {timeout.TotalMinutes:N0} minutes"));
                                return -1;
                            }
                        }

                        process.WaitForExit();
                        return process.ExitCode;
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
                    timeoutCancellation.CancelAfter(TimeSpan.FromMinutes(5));
                    using (var response = await SharedHttpClient.GetAsync(url, timeoutCancellation.Token))
                    {
                        response.EnsureSuccessStatusCode();
                        var data = await response.Content.ReadAsByteArrayAsync();
                        ThrowIfCancellationRequested();
                        File.WriteAllBytes(destinationPath, data);
                    }
                    return true;
                }
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception ex)
            {
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
