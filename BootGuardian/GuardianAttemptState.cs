using System;
using System.Globalization;
using System.IO;
using System.Text;

namespace Libertix.BootGuardian
{
    internal sealed class GuardianAttemptState
    {
        private readonly string _path;
        private readonly BootGuardianConfig _config;

        private GuardianAttemptState(string path, BootGuardianConfig config, bool previousInterrupted)
        {
            _path = path;
            _config = config;
            PreviousInterrupted = previousInterrupted;
        }

        internal bool PreviousInterrupted { get; }

        internal static GuardianAttemptState Begin(string configPath, BootGuardianConfig config)
        {
            string root = Path.GetDirectoryName(Path.GetFullPath(configPath));
            string path = Path.Combine(root, "last-attempt.state");
            bool interrupted = false;
            if (File.Exists(path))
            {
                string previous = File.ReadAllText(path, Encoding.UTF8);
                interrupted = previous.IndexOf("status=in-progress", StringComparison.Ordinal) >= 0;
            }
            var state = new GuardianAttemptState(path, config, interrupted);
            state.Write("in-progress", null);
            return state;
        }

        internal void Complete(bool repaired)
        {
            Write(repaired ? "repaired" : "healthy", null);
        }

        internal void Fail(Exception error)
        {
            Write("failed", error == null ? "unknown" : error.GetType().FullName);
        }

        private void Write(string status, string errorType)
        {
            var text = new StringBuilder();
            text.AppendLine("version=1");
            text.AppendLine("runId=" + _config.RunId);
            text.AppendLine("mode=" + _config.Mode);
            text.AppendLine("status=" + status);
            text.AppendLine("observedUtc=" + DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture));
            if (!string.IsNullOrEmpty(errorType))
                text.AppendLine("errorType=" + errorType);
            AtomicFile.WriteUtf8(_path, text.ToString());
        }
    }
}
