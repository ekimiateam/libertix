using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Libertix.Installation;

namespace Libertix.Helpers
{
    public sealed class UnattendedOptions
    {
        private const int MaximumConfigBytes = 64 * 1024;

        public int SchemaVersion { get; set; }
        public string Distribution { get; set; }
        public int LinuxSizeGiB { get; set; }
        public string LinuxUsername { get; set; }
        public string LinuxPassword { get; set; }
        public string ComputerName { get; set; }
        public bool ShareWindowsFilesInLinux { get; set; }
        public bool ShareLinuxFilesInWindows { get; set; }
        public bool MigrateWindowsPreferences { get; set; }
        public string StatusPath { get; private set; }
        public string AcknowledgementPath { get; private set; }

        public void ClearPassword()
        {
            LinuxPassword = null;
        }

        internal static bool TryLoad(string path, out UnattendedOptions options, out string error)
        {
            options = null;
            error = null;
            string fullPath;
            try
            {
                fullPath = Path.GetFullPath(path ?? string.Empty);
            }
            catch (Exception exception) when (
                exception is ArgumentException ||
                exception is NotSupportedException ||
                exception is PathTooLongException)
            {
                error = "The unattended configuration path is invalid.";
                return false;
            }

            string root = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                "Libertix",
                "Automation") + Path.DirectorySeparatorChar;
            if (!fullPath.StartsWith(root, StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(Path.GetExtension(fullPath), ".json", StringComparison.OrdinalIgnoreCase))
            {
                error = "The unattended configuration must be a JSON file inside the Libertix automation directory.";
                return false;
            }

            try
            {
                var info = new FileInfo(fullPath);
                if (!info.Exists || info.Length <= 0 || info.Length > MaximumConfigBytes)
                {
                    error = "The unattended configuration is missing, empty or too large.";
                    return false;
                }

                string json = File.ReadAllText(fullPath);
                options = JsonSerializer.Deserialize<UnattendedOptions>(
                    json,
                    new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
                if (options == null || !options.Validate(out error))
                {
                    options = null;
                    return false;
                }

                string stem = Path.Combine(
                    Path.GetDirectoryName(fullPath),
                    Path.GetFileNameWithoutExtension(fullPath));
                options.StatusPath = stem + ".status.json";
                options.AcknowledgementPath = stem + ".ack";
                return true;
            }
            catch (Exception exception) when (
                exception is IOException ||
                exception is UnauthorizedAccessException ||
                exception is JsonException)
            {
                error = "The unattended configuration could not be read or parsed: " + exception.Message;
                options = null;
                return false;
            }
            finally
            {
                try
                {
                    File.Delete(fullPath);
                }
                catch (IOException)
                {
                }
                catch (UnauthorizedAccessException)
                {
                }
            }
        }

        private bool Validate(out string error)
        {
            error = null;
            if (SchemaVersion != 1)
                error = "The unattended configuration schemaVersion must be 1.";
            else if (!Regex.IsMatch(
                Distribution ?? string.Empty,
                "^[a-z0-9](?:[a-z0-9._-]{0,62}[a-z0-9])?$"))
                error = "The unattended distribution id is invalid.";
            else if (LinuxSizeGiB < InstallationSizePolicy.MinimumFinalSizeGiB)
                error = string.Format(
                    CultureInfo.InvariantCulture,
                    "The unattended Linux size must be at least {0} GiB.",
                    InstallationSizePolicy.MinimumFinalSizeGiB);
            else if (!AccountPolicy.IsValidUsernameSyntax(LinuxUsername) ||
                AccountPolicy.IsReservedUsername(LinuxUsername))
                error = "The unattended Linux username is invalid or reserved.";
            else if (string.IsNullOrEmpty(LinuxPassword) ||
                LinuxPassword.Length < AccountPolicy.MinimumPasswordLength ||
                LinuxPassword.Length > AccountPolicy.MaximumPasswordLength)
                error = "The unattended Linux password does not satisfy the installation policy.";
            else if (!AccountPolicy.IsValidComputerName(ComputerName))
                error = "The unattended Linux computer name is invalid.";
            return error == null;
        }
    }

    public static class UnattendedWorkflow
    {
        private const int AcknowledgementTimeoutSeconds = 45;
        private static readonly object Sync = new object();
        private static int _sequence;

        public static UnattendedOptions Current =>
            ((App)System.Windows.Application.Current).RuntimeOptions.Unattended;

        public static bool IsEnabled => Current != null;

        public static async Task PublishStageAndWaitAsync(
            string stage,
            int timeoutSeconds = AcknowledgementTimeoutSeconds)
        {
            UnattendedOptions options = Current;
            if (options == null)
                return;
            if (timeoutSeconds <= 0)
                throw new ArgumentOutOfRangeException(nameof(timeoutSeconds));

            int sequence;
            lock (Sync)
            {
                sequence = ++_sequence;
            }

            var status = new Dictionary<string, object>
            {
                ["schemaVersion"] = 1,
                ["sequence"] = sequence,
                ["stage"] = stage,
                ["updatedAtUtc"] = DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture)
            };
            AtomicJsonFile.Write(options.StatusPath, JsonSerializer.Serialize(status));
            ApplicationLogger.Write(
                string.Format(
                    CultureInfo.InvariantCulture,
                    "Unattended stage {0}: {1}",
                    sequence,
                    stage));

            DateTime deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
            while (DateTime.UtcNow < deadline)
            {
                try
                {
                    if (File.Exists(options.AcknowledgementPath) &&
                        int.TryParse(
                            ReadCoordinationFile(options.AcknowledgementPath).Trim(),
                            NumberStyles.None,
                            CultureInfo.InvariantCulture,
                            out int acknowledged) &&
                        acknowledged >= sequence)
                    {
                        return;
                    }
                }
                catch (IOException)
                {
                }
                catch (UnauthorizedAccessException)
                {
                }
                await Task.Delay(100).ConfigureAwait(true);
            }

            throw new TimeoutException(
                "The unattended controller did not acknowledge stage " + stage + ".");
        }

        private static string ReadCoordinationFile(string path)
        {
            using (var stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete))
            using (var reader = new StreamReader(stream))
            {
                return reader.ReadToEnd();
            }
        }

        public static void TryPublishFailure(string errorCode, string errorMessage)
        {
            try
            {
                UnattendedOptions options = Current;
                if (options == null)
                    return;

                int sequence;
                lock (Sync)
                {
                    sequence = ++_sequence;
                }

                string safeCode = string.IsNullOrWhiteSpace(errorCode)
                    ? "unattended-failure"
                    : errorCode.Trim();
                string safeMessage = (errorMessage ?? string.Empty)
                    .Replace("\r", " ")
                    .Replace("\n", " ")
                    .Trim();
                if (safeMessage.Length > 1024)
                    safeMessage = safeMessage.Substring(0, 1024);

                var status = new Dictionary<string, object>
                {
                    ["schemaVersion"] = 1,
                    ["sequence"] = sequence,
                    ["stage"] = "failed",
                    ["errorCode"] = safeCode,
                    ["errorMessage"] = safeMessage,
                    ["updatedAtUtc"] = DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture)
                };
                AtomicJsonFile.Write(options.StatusPath, JsonSerializer.Serialize(status));
                ApplicationLogger.Write(
                    string.Format(
                        CultureInfo.InvariantCulture,
                        "Unattended terminal failure {0}: {1}",
                        sequence,
                        safeCode));
            }
            catch (Exception exception)
            {
                ApplicationLogger.WriteException(
                    "Unattended terminal failure could not be published.",
                    exception);
            }
        }

        public static void Complete()
        {
            UnattendedOptions options = Current;
            if (options == null)
                return;

            DeleteCoordinationFile(options.StatusPath);
            DeleteCoordinationFile(options.AcknowledgementPath);
            ((App)System.Windows.Application.Current)
                .RuntimeOptions.CompleteUnattendedWorkflow();
        }

        private static void DeleteCoordinationFile(string path)
        {
            if (string.IsNullOrWhiteSpace(path))
                return;

            try
            {
                File.Delete(path);
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }
}
