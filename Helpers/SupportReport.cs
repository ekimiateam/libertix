using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text;
using System.Text.RegularExpressions;

namespace Libertix.Support
{
    public static class SupportReport
    {
        public const string IssueUrl = "https://github.com/ekimiateam/libertix/issues/new?template=bug_report.md";
        private const int MaxLogFiles = 24;
        private const int MaxFileBytes = 256 * 1024;

        public static string Create(string context, string details)
        {
            return Create(context, details, new[] {
                Path.Combine(Path.GetPathRoot(Environment.SystemDirectory), "LibertixInstallLogs") });
        }

        public static string Create(string context, string details, IEnumerable<string> logPaths)
        {
            var report = new StringBuilder();
            report.AppendLine("Libertix support report");
            report.AppendLine("UTC: " + DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture));
            report.AppendLine("Version: " + FileVersionInfo.GetVersionInfo(
                Assembly.GetExecutingAssembly().Location).ProductVersion);
            report.AppendLine("Windows: " + Environment.OSVersion);
            report.AppendLine("Architecture: " + (Environment.Is64BitOperatingSystem ? "x64" : "x86") +
                "; process=" + (Environment.Is64BitProcess ? "x64" : "x86"));
            report.AppendLine("Context: " + context);
            report.AppendLine(details);
            var files = new Dictionary<string, DateTime>(StringComparer.OrdinalIgnoreCase);
            foreach (string path in logPaths.Where(path => !string.IsNullOrWhiteSpace(path)).Distinct())
                FindLogs(path, files, report);
            string[] selected = files.OrderByDescending(file => file.Value)
                .Take(MaxLogFiles).Select(file => file.Key).ToArray();
            report.AppendLine("Logs: newest " + MaxLogFiles + " files maximum; last " + MaxFileBytes + " bytes per file.");
            foreach (string path in selected)
            {
                report.AppendLine("\n=== " + path + " ===");
                try
                {
                    using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                        FileShare.ReadWrite | FileShare.Delete))
                    {
                        if (stream.Length > MaxFileBytes)
                        {
                            stream.Seek(-MaxFileBytes, SeekOrigin.End);
                            report.AppendLine("[earlier log content omitted]");
                        }
                        var bytes = new byte[MaxFileBytes];
                        int count = 0;
                        int read;
                        while (count < bytes.Length && (read = stream.Read(bytes, count, bytes.Length - count)) > 0)
                            count += read;
                        report.AppendLine(Encoding.UTF8.GetString(bytes, 0, count));
                    }
                }
                catch (IOException error) { report.AppendLine("[log unavailable: " + error.Message + "]"); }
                catch (UnauthorizedAccessException error) { report.AppendLine("[log unavailable: " + error.Message + "]"); }
            }
            return Redact(report.ToString());
        }

        private static void FindLogs(string path, Dictionary<string, DateTime> files, StringBuilder report)
        {
            try
            {
                if (!File.Exists(path) && !Directory.Exists(path))
                    return;
                if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                    return;
                if (File.Exists(path))
                {
                    if (Path.GetExtension(path).Equals(".log", StringComparison.OrdinalIgnoreCase) ||
                        Path.GetExtension(path).Equals(".txt", StringComparison.OrdinalIgnoreCase))
                        files[path] = File.GetLastWriteTimeUtc(path);
                    return;
                }
                foreach (string child in Directory.GetFileSystemEntries(path))
                    FindLogs(child, files, report);
            }
            catch (IOException error) { report.AppendLine("[logs unavailable: " + error.Message + "]"); }
            catch (UnauthorizedAccessException error) { report.AppendLine("[logs unavailable: " + error.Message + "]"); }
        }

        public static string Redact(string value)
        {
            string text = value ?? string.Empty;
            text = Regex.Replace(text, @"-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?-----END [^-]*PRIVATE KEY-----", "[private key hidden]");
            text = Regex.Replace(text, @"(?im)^.*(?:password|passwd|passwordHash|secret|token|authorization|credential|\bpsk\b|keyMaterial)\s*[""']?\s*[:=].*$", "[sensitive line hidden]");
            text = Regex.Replace(text, @"(?i)\bBearer\s+\S+|\bgh[pousr]_[A-Za-z0-9]+|\bsk-[A-Za-z0-9_-]{16,}|\$6\$[^\s""']+", "[secret hidden]");
            text = Regex.Replace(text, @"(?is)<keyMaterial>.*?</keyMaterial>", "<keyMaterial>[hidden]</keyMaterial>");
            text = Regex.Replace(text, @"(?i)(--?(?:password|passwd|token|secret)\s+)(?:""[^""]*""|'[^']*'|\S+)", "$1[hidden]");
            text = Regex.Replace(text, @"(?i)(https?://)[^/\s@]+@", "$1[credentials hidden]@");
            foreach (string name in new[] { Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                Environment.UserName, Environment.MachineName })
                if (!string.IsNullOrWhiteSpace(name))
                    text = Regex.Replace(text, Regex.Escape(name), "[hidden]", RegexOptions.IgnoreCase);
            return text;
        }

        public static Dictionary<string, string> Labels(string language)
        {
            using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Libertix.SupportTranslations.json"))
            {
                var serializer = new DataContractJsonSerializer(typeof(Catalogue),
                    new DataContractJsonSerializerSettings { UseSimpleDictionaryFormat = true });
                var catalogue = (Catalogue)serializer.ReadObject(stream);
                Language selected;
                if (!catalogue.Languages.TryGetValue(language ?? "en", out selected))
                    selected = catalogue.Languages["en"];
                return selected.Support;
            }
        }

        public static void OpenIssue()
        {
            Process.Start(new ProcessStartInfo(IssueUrl) { UseShellExecute = true });
        }

        [DataContract]
        private sealed class Catalogue
        {
            [DataMember(Name = "languages")] public Dictionary<string, Language> Languages { get; set; }
        }

        [DataContract]
        private sealed class Language
        {
            [DataMember(Name = "support")] public Dictionary<string, string> Support { get; set; }
        }
    }
}
