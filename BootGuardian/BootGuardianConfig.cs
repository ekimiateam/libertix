using System;
using System.IO;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text.RegularExpressions;

namespace Libertix.BootGuardian
{
    [DataContract]
    public sealed class BootGuardianConfig
    {
        [DataMember(Name = "version", IsRequired = true)]
        public int Version { get; set; }

        [DataMember(Name = "runId", IsRequired = true)]
        public string RunId { get; set; }

        [DataMember(Name = "mode", IsRequired = true)]
        public string Mode { get; set; }

        [DataMember(Name = "esp", IsRequired = true)]
        public EspIdentity Esp { get; set; }

        [DataMember(Name = "logDirectory", IsRequired = true)]
        public string LogDirectory { get; set; }

        [DataMember(Name = "archiveDirectory", IsRequired = true)]
        public string ArchiveDirectory { get; set; }

        [DataMember(Name = "serviceSha256", IsRequired = true)]
        public string ServiceSha256 { get; set; }

        [DataMember(Name = "bootOrder", EmitDefaultValue = false)]
        public BootOrderContract BootOrder { get; set; }

        [DataMember(Name = "preferredPath", EmitDefaultValue = false)]
        public PreferredPathContract PreferredPath { get; set; }

        public static BootGuardianConfig Read(string path)
        {
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                var serializer = new DataContractJsonSerializer(typeof(BootGuardianConfig));
                var config = (BootGuardianConfig)serializer.ReadObject(stream);
                config.Validate();
                return config;
            }
        }

        public void Validate()
        {
            if (Version != 1)
                throw new InvalidDataException("Boot guardian configuration version is unsupported.");
            if (!Regex.IsMatch(RunId ?? string.Empty, "^[0-9a-f]{32}$"))
                throw new InvalidDataException("Boot guardian run identifier is invalid.");
            if (Mode != "firmware-boot-order" && Mode != "preferred-windows-path")
                throw new InvalidDataException("Boot guardian mode is invalid.");
            if (Esp == null)
                throw new InvalidDataException("Boot guardian ESP identity is missing.");
            Esp.Validate();
            RequireAbsolutePath(LogDirectory, "log directory");
            RequireAbsolutePath(ArchiveDirectory, "archive directory");
            if (!Hashing.IsSha256(ServiceSha256))
                throw new InvalidDataException("Boot guardian service hash is invalid.");
            if (Mode == "firmware-boot-order")
            {
                if (BootOrder == null || PreferredPath != null)
                    throw new InvalidDataException("BootOrder guardian contract is incomplete.");
                BootOrder.Validate();
            }
            else
            {
                if (PreferredPath == null || BootOrder != null)
                    throw new InvalidDataException("Preferred-path guardian contract is incomplete.");
                PreferredPath.Validate();
            }
        }

        private static void RequireAbsolutePath(string value, string name)
        {
            if (string.IsNullOrWhiteSpace(value) || !Path.IsPathRooted(value))
                throw new InvalidDataException("Boot guardian " + name + " is invalid.");
        }
    }

    [DataContract]
    public sealed class EspIdentity
    {
        [DataMember(Name = "volumePath", IsRequired = true)]
        public string VolumePath { get; set; }

        [DataMember(Name = "partitionNumber", IsRequired = true)]
        public int PartitionNumber { get; set; }

        [DataMember(Name = "partitionGuid", IsRequired = true)]
        public string PartitionGuid { get; set; }

        [DataMember(Name = "ownerMarker", IsRequired = true)]
        public string OwnerMarker { get; set; }

        public void Validate()
        {
            Match volume = Regex.Match(
                VolumePath ?? string.Empty,
                @"^\\\\\?\\Volume\{([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\}\\$");
            if (!volume.Success || !Guid.TryParseExact(volume.Groups[1].Value, "D", out _))
                throw new InvalidDataException("Boot guardian ESP volume path is invalid.");
            if (PartitionNumber <= 0 || !Guid.TryParseExact(PartitionGuid, "D", out _))
                throw new InvalidDataException("Boot guardian ESP partition identity is invalid.");
            if (string.IsNullOrEmpty(OwnerMarker) || OwnerMarker.IndexOf('\0') >= 0)
                throw new InvalidDataException("Boot guardian ESP owner marker is invalid.");
        }
    }

    [DataContract]
    public sealed class BootOrderContract
    {
        [DataMember(Name = "bootNumber", IsRequired = true)]
        public int BootNumber { get; set; }

        [DataMember(Name = "entryBytesBase64", IsRequired = true)]
        public string EntryBytesBase64 { get; set; }

        [DataMember(Name = "entrySha256", IsRequired = true)]
        public string EntrySha256 { get; set; }

        public byte[] GetEntryBytes()
        {
            try { return Convert.FromBase64String(EntryBytesBase64 ?? string.Empty); }
            catch (FormatException error) { throw new InvalidDataException("Boot guardian UEFI entry encoding is invalid.", error); }
        }

        public void Validate()
        {
            if (BootNumber < 0 || BootNumber > ushort.MaxValue)
                throw new InvalidDataException("Boot guardian UEFI boot number is invalid.");
            byte[] entry = GetEntryBytes();
            if (entry.Length < 8 || !Hashing.IsSha256(EntrySha256) ||
                !string.Equals(Hashing.Sha256(entry), EntrySha256, StringComparison.Ordinal))
                throw new InvalidDataException("Boot guardian UEFI entry hash is invalid.");
        }
    }

    [DataContract]
    public sealed class PreferredPathContract
    {
        [DataMember(Name = "manifestPath", IsRequired = true)]
        public string ManifestPath { get; set; }

        [DataMember(Name = "referenceRoot", IsRequired = true)]
        public string ReferenceRoot { get; set; }

        [DataMember(Name = "bootNumber", IsRequired = true)]
        public int BootNumber { get; set; }

        [DataMember(Name = "entryBytesBase64", IsRequired = true)]
        public string EntryBytesBase64 { get; set; }

        [DataMember(Name = "entrySha256", IsRequired = true)]
        public string EntrySha256 { get; set; }

        public byte[] GetEntryBytes()
        {
            try { return Convert.FromBase64String(EntryBytesBase64 ?? string.Empty); }
            catch (FormatException error) { throw new InvalidDataException("Boot guardian preferred UEFI entry encoding is invalid.", error); }
        }

        public void Validate()
        {
            ValidateRelative(ManifestPath, "manifest");
            ValidateRelative(ReferenceRoot, "reference root");
            if (BootNumber < 0 || BootNumber > ushort.MaxValue)
                throw new InvalidDataException("Boot guardian preferred UEFI boot number is invalid.");
            byte[] entry = GetEntryBytes();
            if (entry.Length < 8 || !Hashing.IsSha256(EntrySha256) ||
                !string.Equals(Hashing.Sha256(entry), EntrySha256, StringComparison.Ordinal))
                throw new InvalidDataException("Boot guardian preferred UEFI entry hash is invalid.");
        }

        internal static void ValidateRelative(string value, string name)
        {
            if (string.IsNullOrWhiteSpace(value) || Path.IsPathRooted(value))
                throw new InvalidDataException("Boot guardian " + name + " path is invalid.");
            string[] components = value.Split(new[] { '\\', '/' }, StringSplitOptions.None);
            foreach (string component in components)
            {
                if (string.IsNullOrWhiteSpace(component) || component == "." || component == ".." ||
                    component.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || component.Contains(":"))
                    throw new InvalidDataException("Boot guardian " + name + " path is invalid.");
            }
        }
    }

    [DataContract]
    internal sealed class PreferredManifest
    {
        [DataMember(Name = "version", IsRequired = true)] public int Version { get; set; }
        [DataMember(Name = "runId", IsRequired = true)] public string RunId { get; set; }
        [DataMember(Name = "status", IsRequired = true)] public string Status { get; set; }
        [DataMember(Name = "preferred", IsRequired = true)] public PreferredHashes Preferred { get; set; }

        public static PreferredManifest Read(string path)
        {
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                var serializer = new DataContractJsonSerializer(typeof(PreferredManifest));
                return (PreferredManifest)serializer.ReadObject(stream);
            }
        }
    }

    [DataContract]
    internal sealed class PreferredHashes
    {
        [DataMember(Name = "shimSha256", IsRequired = true)] public string ShimSha256 { get; set; }
        [DataMember(Name = "grubSha256", IsRequired = true)] public string GrubSha256 { get; set; }
        [DataMember(Name = "mokManagerSha256", IsRequired = true)] public string MokManagerSha256 { get; set; }
        [DataMember(Name = "grubConfigSha256", IsRequired = true)] public string GrubConfigSha256 { get; set; }
    }
}
