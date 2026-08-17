using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace Libertix.BootGuardian
{
    internal sealed class RepairJournal
    {
        private readonly BootGuardianConfig _config;
        private readonly List<string> _lines = new List<string>();
        private bool _repairRequired;
        private bool _interruptedAttemptRecovered;

        internal RepairJournal(BootGuardianConfig config)
        {
            _config = config;
            Add("Guardian check started.");
            Add("runId=" + config.RunId);
            Add("mode=" + config.Mode);
            Add("machine=" + Environment.MachineName);
            Add("os=" + Environment.OSVersion);
            Add("processArchitecture=" + (Environment.Is64BitProcess ? "x64" : "x86"));
            Add("processPath=" + System.Reflection.Assembly.GetExecutingAssembly().Location);
            Add("processVersion=" + System.Reflection.Assembly.GetExecutingAssembly().GetName().Version);
            Add("espVolume=" + config.Esp.VolumePath);
            Add("espPartition=" + config.Esp.PartitionNumber);
            Add("espGuid=" + config.Esp.PartitionGuid);
        }

        internal void Add(string message)
        {
            _lines.Add("[" + DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture) + "] " + message);
        }

        internal void Repair(string message)
        {
            _repairRequired = true;
            Add("REPAIR: " + message);
        }

        internal bool RepairRequired => _repairRequired;

        internal void RecordInterruptedAttempt()
        {
            _interruptedAttemptRecovered = true;
            Add("RECOVERY: the previous guardian attempt did not publish a terminal state; all boot invariants are being rechecked.");
        }

        internal void Complete()
        {
            Add("Guardian check completed successfully.");
            if (_repairRequired || _interruptedAttemptRecovered)
                Flush("repair");
        }

        internal void Fail(Exception error)
        {
            Add("ERROR: " + error);
            Flush("error");
        }

        internal static void WriteUncorrelatedError(Exception error)
        {
            string directory = Path.Combine(
                Path.GetPathRoot(Environment.SystemDirectory),
                "LibertixInstallLogs",
                "Windows",
                "BootGuardian-Uncorrelated");
            Directory.CreateDirectory(directory);
            string path = Path.Combine(
                directory,
                DateTime.UtcNow.ToString("yyyyMMddTHHmmss.fffffffZ", CultureInfo.InvariantCulture) +
                "-error-" + System.Diagnostics.Process.GetCurrentProcess().Id + ".log");
            File.WriteAllText(
                path,
                "[" + DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture) + "] ERROR: " +
                error + Environment.NewLine,
                new UTF8Encoding(false));
        }

        private void Flush(string outcome)
        {
            Directory.CreateDirectory(_config.LogDirectory);
            string path = Path.Combine(
                _config.LogDirectory,
                DateTime.UtcNow.ToString("yyyyMMddTHHmmss.fffffffZ", CultureInfo.InvariantCulture) +
                "-" + outcome + "-" + System.Diagnostics.Process.GetCurrentProcess().Id + ".log");
            string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                File.WriteAllText(temporary, string.Join(Environment.NewLine, _lines) + Environment.NewLine, new UTF8Encoding(false));
                using (FileStream stream = new FileStream(temporary, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
                    stream.Flush(true);
                File.Move(temporary, path);
            }
            finally
            {
                if (File.Exists(temporary))
                    File.Delete(temporary);
            }
        }
    }
}
