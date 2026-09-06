using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text;
using System.Text.RegularExpressions;

namespace Libertix.BootGuardian
{
    // This journal is shared with libertix-preferred-boot-path.py. Both runtimes
    // accept only the previous or prepared bytes at every destination.
    internal static class PreferredSynchronization
    {
        private const string ManifestRelative = @"EFI\Libertix\preferred-boot-path.json";
        private const string JournalName = "preferred-boot-path.sync.json";

        internal static void Replay(string esp, string runId, Action checkDeadline)
        {
            string manifestPath = Path.Combine(esp, ManifestRelative);
            string journalPath = Path.Combine(Path.GetDirectoryName(manifestPath), JournalName);
            if (!File.Exists(journalPath)) return;
            checkDeadline();
            SyncJournal journal = ReadJournal(journalPath);
            if (journal.Version != 1 || journal.RunId != runId ||
                !Regex.IsMatch(journal.Stage ?? "", "^\\.preferred-sync-[0-9a-f]{32}$") ||
                !Hashing.IsSha256(journal.BeforeManifest) || !Hashing.IsSha256(journal.AfterManifest))
                throw new InvalidDataException("Pending EFI synchronization identity is invalid.");
            string stage = Path.Combine(Path.GetDirectoryName(manifestPath), journal.Stage);
            string targetManifestPath = Path.Combine(stage, "manifest.json");
            AssertNoReparsePoints(stage);
            AssertNoReparsePoints(targetManifestPath);
            if (Hashing.Sha256File(targetManifestPath) != journal.AfterManifest)
                throw new InvalidDataException("Pending EFI manifest hash mismatch.");
            string currentManifestHash = Hashing.Sha256File(manifestPath);
            if (currentManifestHash != journal.BeforeManifest && currentManifestHash != journal.AfterManifest)
                throw new InvalidDataException("EFI manifest changed outside the pending synchronization.");
            PreferredManifest target = PreferredManifest.Read(targetManifestPath);
            if (target.Version != 1 || target.RunId != runId || target.Status != "installed")
                throw new InvalidDataException("Pending EFI manifest belongs to another installation.");
            Dictionary<string, string> expected = ExpectedFiles(target);
            if (journal.Entries == null || (journal.Entries.Length != 5 && journal.Entries.Length != 9))
                throw new InvalidDataException("Pending EFI file count is invalid.");
            if (journal.Entries.Length == 9)
            {
                string reference = Path.Combine(esp, @"EFI\Libertix\BootGuardianReference");
                AssertNoReparsePoints(reference);
                if (File.ReadAllText(Path.Combine(reference, ".libertix-owner")).Trim() != runId)
                    throw new InvalidDataException("Pending EFI repair reference ownership is invalid.");
                expected.Add("EFI/Libertix/BootGuardianReference/shimx64.efi", target.Preferred.ShimSha256);
                expected.Add("EFI/Libertix/BootGuardianReference/grubx64.efi", target.Preferred.GrubSha256);
                expected.Add("EFI/Libertix/BootGuardianReference/mmx64.efi", target.Preferred.MokManagerSha256);
                expected.Add("EFI/Libertix/BootGuardianReference/grub.cfg", target.Preferred.GrubConfigSha256);
            }
            string[] paths = journal.Entries.Select(entry => entry == null ? null : entry.Target).ToArray();
            if (paths.Any(path => path == null || !expected.ContainsKey(path)) ||
                paths.Distinct(StringComparer.Ordinal).Count() != expected.Count ||
                paths.Last() != "EFI/Microsoft/Boot/bootmgfw.efi")
                throw new InvalidDataException("Pending EFI destinations are invalid.");
            for (int index = 0; index < journal.Entries.Length; index++)
            {
                checkDeadline();
                SyncEntry entry = journal.Entries[index];
                string source = Path.Combine(stage, index.ToString(System.Globalization.CultureInfo.InvariantCulture));
                string destination = Path.Combine(esp, entry.Target.Replace('/', '\\'));
                AssertNoReparsePoints(source);
                AssertNoReparsePoints(destination);
                string hash = expected[entry.Target];
                if (!Hashing.IsSha256(hash) || Hashing.Sha256File(source) != hash)
                    throw new InvalidDataException("Pending EFI source hash mismatch.");
                string current = File.Exists(destination) ? Hashing.Sha256File(destination) : null;
                if (current != entry.Before && current != hash)
                    throw new InvalidDataException("EFI destination changed outside the pending synchronization.");
            }
            for (int index = 0; index < journal.Entries.Length; index++)
            {
                string destination = Path.Combine(esp, journal.Entries[index].Target.Replace('/', '\\'));
                AtomicFile.CopyVerified(Path.Combine(stage, index.ToString(System.Globalization.CultureInfo.InvariantCulture)),
                    destination, expected[journal.Entries[index].Target], checkDeadline);
            }
            AtomicFile.CopyVerified(targetManifestPath, manifestPath, journal.AfterManifest, checkDeadline);
            // Keep the verified staging files until removal of the journal is
            // durable on the ESP. Cleanup can be retried without changing boot.
            File.Delete(journalPath);
        }

        internal static void PublishWindowsLoaderUpdate(
            string esp, PreferredManifest manifest, string windowsSource, string referenceRoot,
            Action checkDeadline)
        {
            string manifestPath = Path.Combine(esp, ManifestRelative);
            if (File.Exists(Path.Combine(Path.GetDirectoryName(manifestPath), JournalName)))
                throw new InvalidDataException("Resume the pending EFI synchronization before preparing another update.");
            string stageName = ".preferred-sync-" + Guid.NewGuid().ToString("N");
            string stage = Path.Combine(Path.GetDirectoryName(manifestPath), stageName);
            Directory.CreateDirectory(stage);
            Dictionary<string, string> hashes = ExpectedFiles(manifest);
            string[] paths = {
                "EFI/Microsoft/Boot/bootmgfw.libertix-windows.efi", "EFI/Microsoft/Boot/grubx64.efi",
                "EFI/Microsoft/Boot/mmx64.efi", "EFI/Microsoft/Boot/grub.cfg", "EFI/Microsoft/Boot/bootmgfw.efi"
            };
            string[] sources = { windowsSource, Path.Combine(referenceRoot, "grubx64.efi"),
                Path.Combine(referenceRoot, "mmx64.efi"), Path.Combine(referenceRoot, "grub.cfg"),
                Path.Combine(referenceRoot, "shimx64.efi") };
            var entries = new SyncEntry[paths.Length];
            for (int index = 0; index < paths.Length; index++)
            {
                string destination = Path.Combine(esp, paths[index].Replace('/', '\\'));
                AtomicFile.CopyVerified(sources[index], Path.Combine(stage,
                    index.ToString(System.Globalization.CultureInfo.InvariantCulture)), hashes[paths[index]], checkDeadline);
                entries[index] = new SyncEntry { Target = paths[index],
                    Before = File.Exists(destination) ? Hashing.Sha256File(destination) : null };
            }
            string targetPath = Path.Combine(stage, "manifest.json");
            AtomicFile.WriteUtf8(targetPath, manifest.ToJson());
            var journal = new SyncJournal { Version = 1, RunId = manifest.RunId, Stage = stageName,
                BeforeManifest = Hashing.Sha256File(manifestPath), AfterManifest = Hashing.Sha256File(targetPath),
                Entries = entries };
            checkDeadline();
            using (var stream = new MemoryStream())
            {
                new DataContractJsonSerializer(typeof(SyncJournal)).WriteObject(stream, journal);
                AtomicFile.WriteUtf8(Path.Combine(Path.GetDirectoryName(manifestPath), JournalName),
                    Encoding.UTF8.GetString(stream.ToArray()));
            }
            Replay(esp, manifest.RunId, checkDeadline);
        }

        private static Dictionary<string, string> ExpectedFiles(PreferredManifest manifest)
        {
            if (manifest.WindowsLoader == null || manifest.Preferred == null ||
                manifest.WindowsLoader.ActivePath != @"\EFI\Microsoft\Boot\bootmgfw.efi" ||
                manifest.WindowsLoader.BackupPath != @"\EFI\Microsoft\Boot\bootmgfw.libertix-windows.efi")
                throw new InvalidDataException("Preferred Windows loader paths are invalid.");
            return new Dictionary<string, string>(StringComparer.Ordinal) {
                {"EFI/Microsoft/Boot/bootmgfw.libertix-windows.efi", manifest.WindowsLoader.Sha256},
                {"EFI/Microsoft/Boot/grubx64.efi", manifest.Preferred.GrubSha256},
                {"EFI/Microsoft/Boot/mmx64.efi", manifest.Preferred.MokManagerSha256},
                {"EFI/Microsoft/Boot/grub.cfg", manifest.Preferred.GrubConfigSha256},
                {"EFI/Microsoft/Boot/bootmgfw.efi", manifest.Preferred.ShimSha256}
            };
        }

        private static SyncJournal ReadJournal(string path)
        {
            AssertNoReparsePoints(path);
            using (FileStream stream = File.OpenRead(path))
            {
                if (stream.Length > 1024 * 1024) throw new InvalidDataException("Pending EFI journal is too large.");
                return (SyncJournal)new DataContractJsonSerializer(typeof(SyncJournal)).ReadObject(stream);
            }
        }

        private static void AssertNoReparsePoints(string path)
        {
            for (string current = Path.GetFullPath(path); current != null; current = Path.GetDirectoryName(current))
                if ((File.Exists(current) || Directory.Exists(current)) &&
                    (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException("EFI synchronization cannot traverse a reparse point.");
        }

        [DataContract]
        private sealed class SyncJournal
        {
            [DataMember(Name = "version", IsRequired = true)] public int Version;
            [DataMember(Name = "runId", IsRequired = true)] public string RunId;
            [DataMember(Name = "stage", IsRequired = true)] public string Stage;
            [DataMember(Name = "beforeManifest", IsRequired = true)] public string BeforeManifest;
            [DataMember(Name = "afterManifest", IsRequired = true)] public string AfterManifest;
            [DataMember(Name = "entries", IsRequired = true)] public SyncEntry[] Entries;
        }

        [DataContract]
        private sealed class SyncEntry
        {
            [DataMember(Name = "target", IsRequired = true)] public string Target;
            [DataMember(Name = "before", IsRequired = true)] public string Before;
        }
    }
}
