using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Libertix.Installation
{
    public sealed class WindowsSharingPlan
    {
        [JsonPropertyName("version")]
        public int Version { get; set; }
        [JsonPropertyName("volumes")]
        public WindowsSharingVolume[] Volumes { get; set; }
        [JsonPropertyName("folders")]
        public WindowsSharingFolder[] Folders { get; set; }

        public void Validate()
        {
            if (Version != 1 || Volumes == null || Folders == null || Volumes.Length > 64 || Folders.Length > 256)
                throw new InvalidDataException("Windows sharing inventory is incomplete or unsupported.");
            var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (WindowsSharingVolume volume in Volumes)
            {
                if (volume == null || !Regex.IsMatch(volume.NtfsUuid ?? "", "^[A-F0-9]{16}$") || !ids.Add(volume.NtfsUuid) ||
                    volume.NtfsUuid == "0000000000000000" || volume.Disk == null ||
                    volume.OffsetBytes <= 0 || volume.SizeBytes <= 0 ||
                    volume.OffsetBytes > volume.Disk.SizeBytes - volume.SizeBytes ||
                    !Regex.IsMatch(volume.WindowsDrive ?? "", "^[A-Z]:$"))
                    throw new InvalidDataException("Windows sharing volume identity is invalid or duplicated.");
                string prefix = volume.Disk.PartitionStyle == "GPT" ? "gpt:" : "mbr:";
                string identityPattern = prefix == "gpt:" ? "^gpt:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$" : "^mbr:[0-9a-f]{8}$";
                if ((volume.Disk.PartitionStyle != "GPT" && volume.Disk.PartitionStyle != "MBR") ||
                    !Regex.IsMatch(volume.Disk.PartitionTableId ?? "", identityPattern) ||
                    volume.Disk.SizeBytes <= 0 ||
                    (volume.Disk.LogicalSectorSizeBytes != 512 && volume.Disk.LogicalSectorSizeBytes != 4096) ||
                    !Regex.IsMatch(volume.WindowsVolumeId ?? "", @"^\\\\\?\\Volume\{[0-9a-fA-F-]{36}\}\\$"))
                    throw new InvalidDataException("Windows sharing disk identity is invalid.");
            }
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var referenced = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (WindowsSharingFolder folder in Folders)
            {
                if (folder == null || string.IsNullOrWhiteSpace(folder.Shortcut) || folder.Shortcut.Length > 180 ||
                    !folder.Shortcut.StartsWith("User_", StringComparison.Ordinal) ||
                    Regex.IsMatch(folder.Shortcut, @"[\x00-\x1f/\\]") || !names.Add(folder.Shortcut) ||
                    !Regex.IsMatch(folder.ProfileSid ?? "", @"^S-1-5-21-(?:\d+-){3}\d+$") ||
                    !ids.Contains(folder.NtfsUuid ?? "") || string.IsNullOrEmpty(folder.RelativePath) ||
                    folder.RelativePath.Length > 32767 || Regex.IsMatch(folder.RelativePath, @"[\x00-\x1f\\:]") ||
                    folder.RelativePath.Split('/').Any(part => part.Length == 0 || part == "." || part == ".."))
                    throw new InvalidDataException("Windows sharing folder path, identity or shortcut is invalid.");
                referenced.Add(folder.NtfsUuid);
            }
            if (!referenced.SetEquals(ids))
                throw new InvalidDataException("Windows sharing must not include unrelated volumes.");
        }
    }

    public sealed class WindowsSharingVolume
    {
        [JsonPropertyName("ntfsUuid")]
        public string NtfsUuid { get; set; }
        [JsonPropertyName("disk")]
        public WindowsSharingDisk Disk { get; set; }
        [JsonPropertyName("offsetBytes")]
        public long OffsetBytes { get; set; }
        [JsonPropertyName("sizeBytes")]
        public long SizeBytes { get; set; }
        [JsonPropertyName("windowsVolumeId")]
        public string WindowsVolumeId { get; set; }
        [JsonPropertyName("windowsDrive")]
        public string WindowsDrive { get; set; }
    }

    public sealed class WindowsSharingDisk
    {
        [JsonPropertyName("partitionTableId")]
        public string PartitionTableId { get; set; }
        [JsonPropertyName("partitionStyle")]
        public string PartitionStyle { get; set; }
        [JsonPropertyName("sizeBytes")]
        public long SizeBytes { get; set; }
        [JsonPropertyName("logicalSectorSizeBytes")]
        public int LogicalSectorSizeBytes { get; set; }
    }

    public sealed class WindowsSharingFolder
    {
        [JsonPropertyName("shortcut")]
        public string Shortcut { get; set; }
        [JsonPropertyName("profileSid")]
        public string ProfileSid { get; set; }
        [JsonPropertyName("ntfsUuid")]
        public string NtfsUuid { get; set; }
        [JsonPropertyName("relativePath")]
        public string RelativePath { get; set; }
    }
}
