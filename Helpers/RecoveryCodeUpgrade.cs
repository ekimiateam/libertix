using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using Libertix.Installation;

namespace Libertix.Helpers
{
    internal static class RecoveryCodeUpgrade
    {
        internal static void Prepare(InstalledLinuxRecoveryCandidate candidate, string scriptsRoot)
        {
            string root = Path.GetFullPath(candidate.RecoveryRoot);
            bool uefi = candidate.Firmware == InstallationFirmware.Uefi;
            string payload = uefi
                ? Path.GetDirectoryName(Path.GetDirectoryName(candidate.RecoveryScriptPath))
                : root;
            string backupRoot = Path.Combine(root, "pre-uninstall-code");
            var sources = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (uefi)
            {
                foreach (string source in Directory.GetFiles(scriptsRoot, "*", SearchOption.AllDirectories)
                    .Where(path => path.EndsWith(".ps1", StringComparison.OrdinalIgnoreCase) ||
                        path.EndsWith(".psm1", StringComparison.OrdinalIgnoreCase)))
                    sources.Add(Path.Combine("Scripts", source.Substring(scriptsRoot.TrimEnd('\\').Length + 1)), source);
            }
            else
            {
                sources.Add("recover.ps1", Path.Combine(scriptsRoot, "libertix-recovery-guard.ps1"));
                foreach (string source in Directory.GetFiles(Path.Combine(scriptsRoot, "modules"), "*.psm1"))
                    sources.Add(Path.GetFileName(source), source);
            }
            if (sources.Count == 0 || sources.Values.Any(path => !File.Exists(path)))
                throw new InvalidOperationException("Current recovery code is incomplete.");

            string manifestPath = Path.Combine(root, "payload-manifest.json");
            JsonObject manifest = uefi ? JsonNode.Parse(File.ReadAllText(manifestPath)).AsObject() : null;
            if (uefi)
            {
                foreach (JsonObject item in manifest["Files"].AsArray())
                {
                    string relative = item["RelativePath"].GetValue<string>();
                    string target = CheckedPath(payload, relative);
                    string expected = item["Sha256"].GetValue<string>();
                    if (Hash(target) == expected) continue;
                    // An interrupted upgrade may have published code before its new manifest.
                    string backup = CheckedPath(backupRoot, relative);
                    if (!sources.TryGetValue(relative, out string source) ||
                        !File.Exists(backup) || Hash(backup) != expected || Hash(target) != Hash(source))
                        throw new InvalidOperationException("Archived recovery payload integrity mismatch: " + relative);
                }
            }

            bool manifestChanged = false;
            foreach (var entry in sources)
            {
                string target = CheckedPath(payload, entry.Key);
                string expected = Hash(entry.Value);
                if (!File.Exists(target) || Hash(target) != expected)
                {
                    string backup = CheckedPath(backupRoot, entry.Key);
                    Directory.CreateDirectory(Path.GetDirectoryName(backup));
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    if (File.Exists(target) && !File.Exists(backup)) File.Copy(target, backup);
                    string temporary = target + ".upgrade-" + Guid.NewGuid().ToString("N");
                    File.Copy(entry.Value, temporary);
                    using (var file = new FileStream(temporary, FileMode.Open, FileAccess.Write, FileShare.None))
                        file.Flush(true);
                    if (Hash(temporary) != expected) throw new IOException("Recovery code staging verification failed.");
                    AtomicJsonFile.Publish(temporary, target);
                    if (Hash(target) != expected) throw new IOException("Recovery code publication verification failed.");
                }
                if (uefi)
                {
                    JsonArray files = manifest["Files"].AsArray();
                    JsonObject item = files.OfType<JsonObject>().SingleOrDefault(value =>
                        string.Equals(value["RelativePath"].GetValue<string>(), entry.Key, StringComparison.OrdinalIgnoreCase));
                    if (item == null)
                    {
                        item = new JsonObject { ["RelativePath"] = entry.Key };
                        files.Add(item);
                    }
                    if (item["Sha256"]?.GetValue<string>() != expected ||
                        item["Length"]?.GetValue<long>() != new FileInfo(target).Length)
                        manifestChanged = true;
                    item["Length"] = new FileInfo(target).Length;
                    item["Sha256"] = expected;
                }
            }
            if (uefi && manifestChanged)
            {
                string backup = CheckedPath(backupRoot, "payload-manifest.json");
                Directory.CreateDirectory(backupRoot);
                if (!File.Exists(backup)) File.Copy(manifestPath, backup);
                AtomicJsonFile.Write(manifestPath, manifest.ToJsonString());
            }
        }

        private static string Hash(string path)
        {
            using (var stream = File.OpenRead(path))
            using (var sha = SHA256.Create())
                return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
        }

        private static string CheckedPath(string root, string relative)
        {
            string canonicalRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar);
            string path = Path.GetFullPath(Path.Combine(canonicalRoot, relative));
            if (!path.StartsWith(canonicalRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Recovery code path escapes its archive.");
            for (string current = path; current != null; current = Path.GetDirectoryName(current))
            {
                if ((File.Exists(current) || Directory.Exists(current)) &&
                    (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidOperationException("Recovery code path contains a reparse point.");
                if (string.Equals(current, canonicalRoot, StringComparison.OrdinalIgnoreCase)) break;
            }
            return path;
        }
    }
}
