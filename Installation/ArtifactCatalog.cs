using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Libertix.Installation
{
    public sealed class ArtifactCatalog
    {
        [JsonPropertyName("aria2")]
        public Aria2Artifact Aria2 { get; set; }

        [JsonPropertyName("ext4Driver")]
        public Ext4DriverArtifact Ext4Driver { get; set; }

        [JsonPropertyName("grub4Dos")]
        public Grub4DosArtifact Grub4Dos { get; set; }

        public static ArtifactCatalog Load(string path)
        {
            ArtifactCatalog catalog = JsonSerializer.Deserialize<ArtifactCatalog>(
                File.ReadAllText(path)) ??
                throw new InvalidDataException("Artifact catalogue must contain a JSON object.");
            catalog.Validate();
            return catalog;
        }

        public static ArtifactCatalog LoadFromApplicationDirectory()
        {
            return Load(Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory,
                "Scripts",
                "config",
                "Libertix.Artifacts.json"));
        }

        private void Validate()
        {
            if (Aria2 == null || Ext4Driver == null || Grub4Dos == null)
                throw new InvalidDataException("Artifact catalogue is incomplete.");

            ValidateFileName(Aria2.ArchiveFileName, "aria2.archiveFileName");
            ValidateHash(Aria2.ArchiveSha256, "aria2.archiveSha256");
            ValidateHash(Aria2.ExecutableSha256, "aria2.executableSha256");
            ValidateFileName(Ext4Driver.FileName, "ext4Driver.fileName");
            ValidateHash(Ext4Driver.Sha256, "ext4Driver.sha256");
            if (Ext4Driver.AttachedContainerSize <= 0)
                throw new InvalidDataException(
                    "Artifact field 'ext4Driver.attachedContainerSize' must be positive.");
            ValidateFileName(Ext4Driver.WinFspPayloadName, "ext4Driver.winFspPayloadName");
            ValidateHash(Ext4Driver.WinFspPayloadSha256, "ext4Driver.winFspPayloadSha256");
            ValidateFileName(Ext4Driver.DriverPayloadName, "ext4Driver.driverPayloadName");
            ValidateHash(Ext4Driver.DriverPayloadSha256, "ext4Driver.driverPayloadSha256");
            ValidateFileName(Grub4Dos.LoaderFileName, "grub4Dos.loaderFileName");
            ValidateHash(Grub4Dos.LoaderSha256, "grub4Dos.loaderSha256");
            ValidateFileName(Grub4Dos.MbrLoaderFileName, "grub4Dos.mbrLoaderFileName");
            ValidateHash(Grub4Dos.MbrLoaderSha256, "grub4Dos.mbrLoaderSha256");
        }

        private static void ValidateFileName(string value, string name)
        {
            if (string.IsNullOrWhiteSpace(value) ||
                !string.Equals(Path.GetFileName(value), value, StringComparison.Ordinal))
            {
                throw new InvalidDataException($"Artifact field '{name}' must be a file name.");
            }
        }

        private static void ValidateHash(string value, string name)
        {
            if (string.IsNullOrWhiteSpace(value) || value.Length != 64)
                throw new InvalidDataException($"Artifact field '{name}' must be a SHA-256 hash.");
            foreach (char character in value)
            {
                if (!Uri.IsHexDigit(character))
                    throw new InvalidDataException($"Artifact field '{name}' must be hexadecimal.");
            }
        }
    }

    public sealed class Aria2Artifact
    {
        [JsonPropertyName("archiveFileName")]
        public string ArchiveFileName { get; set; }

        [JsonPropertyName("archiveSha256")]
        public string ArchiveSha256 { get; set; }

        [JsonPropertyName("executableSha256")]
        public string ExecutableSha256 { get; set; }
    }

    public class FileArtifact
    {
        [JsonPropertyName("fileName")]
        public string FileName { get; set; }

        [JsonPropertyName("sha256")]
        public string Sha256 { get; set; }
    }

    public sealed class Ext4DriverArtifact : FileArtifact
    {
        [JsonPropertyName("attachedContainerSize")]
        public long AttachedContainerSize { get; set; }

        [JsonPropertyName("winFspPayloadName")]
        public string WinFspPayloadName { get; set; }

        [JsonPropertyName("winFspPayloadSha256")]
        public string WinFspPayloadSha256 { get; set; }

        [JsonPropertyName("driverPayloadName")]
        public string DriverPayloadName { get; set; }

        [JsonPropertyName("driverPayloadSha256")]
        public string DriverPayloadSha256 { get; set; }
    }

    public sealed class Grub4DosArtifact
    {
        [JsonPropertyName("loaderFileName")]
        public string LoaderFileName { get; set; }

        [JsonPropertyName("loaderSha256")]
        public string LoaderSha256 { get; set; }

        [JsonPropertyName("mbrLoaderFileName")]
        public string MbrLoaderFileName { get; set; }

        [JsonPropertyName("mbrLoaderSha256")]
        public string MbrLoaderSha256 { get; set; }
    }
}
