using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;

namespace Libertix.BootGuardian
{
    public sealed class BootGuardianEngine
    {
        public bool Execute(string configPath, DateTime deadlineUtc)
        {
            RepairJournal journal = null;
            try
            {
                BootGuardianConfig config = BootGuardianConfig.Read(configPath);
                journal = new RepairJournal(config);
                EnsureBeforeDeadline(deadlineUtc);
                if (config.Mode == "firmware-boot-order")
                    RepairBootOrder(config, journal, deadlineUtc);
                else
                    RepairPreferredPath(config, journal, deadlineUtc);
                journal.Complete();
                return true;
            }
            catch (Exception error)
            {
                try
                {
                    if (journal == null)
                        RepairJournal.WriteUncorrelatedError(error);
                    else
                        journal.Fail(error);
                }
                catch { }
                return false;
            }
        }

        private static void RepairBootOrder(
            BootGuardianConfig config,
            RepairJournal journal,
            DateTime deadlineUtc)
        {
            ushort owned = checked((ushort)config.BootOrder.BootNumber);
            string entryName = "Boot" + owned.ToString("X4", CultureInfo.InvariantCulture);
            byte[] expectedEntry = config.BootOrder.GetEntryBytes();
            using (var firmware = new FirmwareEnvironment())
            {
                byte[] observedEntry = firmware.Read(entryName, allowMissing: true);
                if (observedEntry == null || Hashing.Sha256(observedEntry) != config.BootOrder.EntrySha256)
                {
                    EnsureBeforeDeadline(deadlineUtc);
                    string observedHash = observedEntry == null ? "missing" : Hashing.Sha256(observedEntry);
                    journal.Repair(
                        entryName + " is missing or changed; restoring the exact owned load option. " +
                        "observedSha256=" + observedHash + " expectedSha256=" +
                        config.BootOrder.EntrySha256 + ".");
                    firmware.Write(entryName, expectedEntry);
                    byte[] verifiedEntry = firmware.Read(entryName);
                    if (Hashing.Sha256(verifiedEntry) != config.BootOrder.EntrySha256)
                        throw new InvalidOperationException(entryName + " did not retain the restored value.");
                }

                byte[] currentBytes = firmware.Read("BootOrder", allowMissing: true);
                ushort[] current = currentBytes == null
                    ? new ushort[0]
                    : FirmwareEnvironment.ParseBootOrder(currentBytes);
                ushort[] desired = BuildDesiredBootOrder(owned, current);
                if (!current.SequenceEqual(desired))
                {
                    EnsureBeforeDeadline(deadlineUtc);
                    journal.Repair(
                        "BootOrder changed from " + FormatOrder(current) + " to " + FormatOrder(desired) + ".");
                    byte[] desiredBytes = FirmwareEnvironment.EncodeBootOrder(desired);
                    firmware.Write("BootOrder", desiredBytes);
                    ushort[] verified = FirmwareEnvironment.ParseBootOrder(firmware.Read("BootOrder"));
                    if (!verified.SequenceEqual(desired))
                        throw new InvalidOperationException("Firmware did not retain the repaired BootOrder.");
                }
            }
        }

        private static void RepairPreferredPath(
            BootGuardianConfig config,
            RepairJournal journal,
            DateTime deadlineUtc)
        {
            using (var mount = new EspMount(config.Esp.VolumePath))
            {
                string ownerPath = ResolveUnderRoot(mount.Root, "EFI\\Libertix\\.libertix-owner");
                string owner = File.ReadAllText(ownerPath, Encoding.UTF8);
                if (!string.Equals(owner, config.Esp.OwnerMarker, StringComparison.Ordinal))
                    throw new InvalidOperationException("ESP ownership marker differs from the recorded installation.");

                string manifestPath = ResolveUnderRoot(mount.Root, config.PreferredPath.ManifestPath);
                PreferredManifest manifest = PreferredManifest.Read(manifestPath);
                if (manifest == null || manifest.Version != 1 || manifest.RunId != config.RunId ||
                    manifest.Status != "installed" || manifest.Preferred == null)
                    throw new InvalidDataException("Preferred boot manifest identity or status is invalid.");

                string referenceRoot = ResolveUnderRoot(mount.Root, config.PreferredPath.ReferenceRoot);
                var files = new[]
                {
                    new RepairFile("grubx64.efi", @"EFI\Microsoft\Boot\grubx64.efi", manifest.Preferred.GrubSha256),
                    new RepairFile("mmx64.efi", @"EFI\Microsoft\Boot\mmx64.efi", manifest.Preferred.MokManagerSha256),
                    new RepairFile("grub.cfg", @"EFI\Microsoft\Boot\grub.cfg", manifest.Preferred.GrubConfigSha256),
                    new RepairFile("shimx64.efi", @"EFI\Microsoft\Boot\bootmgfw.efi", manifest.Preferred.ShimSha256)
                };
                foreach (RepairFile file in files)
                {
                    if (!Hashing.IsSha256(file.Hash))
                        throw new InvalidDataException("Preferred boot manifest contains an invalid hash for " + file.ReferenceName + ".");
                    string source = ResolveUnderRoot(referenceRoot, file.ReferenceName);
                    string destination = ResolveUnderRoot(mount.Root, file.ActivePath);
                    if (!File.Exists(source) || Hashing.Sha256File(source) != file.Hash)
                        throw new InvalidDataException("Preferred boot repair reference is missing or corrupted: " + file.ReferenceName);
                    string observedHash = File.Exists(destination) ? Hashing.Sha256File(destination) : string.Empty;
                    if (observedHash == file.Hash)
                        continue;
                    EnsureBeforeDeadline(deadlineUtc);
                    string archive = File.Exists(destination)
                        ? ArchiveUnexpected(config, destination, observedHash, file.ReferenceName)
                        : "not-required";
                    journal.Repair(
                        file.ActivePath + " differs from the verified reference; restoring it atomically. " +
                        "observedSha256=" + (string.IsNullOrEmpty(observedHash) ? "missing" : observedHash) +
                        " expectedSha256=" + file.Hash + " archive=" + archive + ".");
                    AtomicFile.CopyVerified(source, destination, file.Hash);
                }
            }
        }

        private static string ArchiveUnexpected(
            BootGuardianConfig config,
            string source,
            string hash,
            string name)
        {
            if (!Hashing.IsSha256(hash))
                throw new InvalidDataException("Cannot archive an unhashable EFI file: " + source);
            string directory = Path.Combine(config.ArchiveDirectory, "unexpected-efi");
            Directory.CreateDirectory(directory);
            string destination = Path.Combine(directory, name + "-" + hash + ".bin");
            if (File.Exists(destination))
            {
                if (Hashing.Sha256File(destination) != hash)
                    throw new InvalidDataException("Existing unexpected-file archive has the wrong hash: " + destination);
                return destination;
            }
            AtomicFile.CopyVerified(source, destination, hash);
            return destination;
        }

        private static string ResolveUnderRoot(string root, string relative)
        {
            PreferredPathContract.ValidateRelative(relative, "EFI");
            string normalizedRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            string path = Path.GetFullPath(Path.Combine(normalizedRoot, relative));
            if (!path.StartsWith(normalizedRoot, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Boot guardian EFI path escapes the recorded volume.");
            return path;
        }

        private static void EnsureBeforeDeadline(DateTime deadlineUtc)
        {
            if (DateTime.UtcNow >= deadlineUtc)
                throw new TimeoutException("Boot guardian reached its preshutdown repair deadline.");
        }

        private static string FormatOrder(IEnumerable<ushort> order)
        {
            return string.Join(",", order.Select(value => "Boot" + value.ToString("X4", CultureInfo.InvariantCulture)));
        }

        internal static ushort[] BuildDesiredBootOrder(ushort owned, IEnumerable<ushort> current)
        {
            var desired = new List<ushort> { owned };
            foreach (ushort value in current)
            {
                if (value != owned && !desired.Contains(value))
                    desired.Add(value);
            }
            return desired.ToArray();
        }

        private sealed class RepairFile
        {
            internal RepairFile(string referenceName, string activePath, string hash)
            {
                ReferenceName = referenceName;
                ActivePath = activePath;
                Hash = hash;
            }
            internal string ReferenceName { get; }
            internal string ActivePath { get; }
            internal string Hash { get; }
        }
    }
}
