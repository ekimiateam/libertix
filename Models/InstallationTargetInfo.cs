using System.Text.Json.Serialization;

namespace Libertix.Models
{
    public sealed class InstallationTargetInfo
    {
        [JsonPropertyName("drive")]
        public string Drive { get; set; }
        [JsonPropertyName("isWindows")]
        public bool IsWindows { get; set; }
        [JsonPropertyName("diskNumber")]
        public int DiskNumber { get; set; }
        [JsonPropertyName("diskUniqueId")]
        public string DiskUniqueId { get; set; }
        [JsonPropertyName("diskDevicePath")]
        public string DiskDevicePath { get; set; }
        [JsonPropertyName("diskSerialNumber")]
        public string DiskSerialNumber { get; set; }
        [JsonPropertyName("partitionTableId")]
        public string PartitionTableId { get; set; }
        [JsonPropertyName("diskSizeBytes")]
        public long DiskSizeBytes { get; set; }
        [JsonPropertyName("logicalSectorSizeBytes")]
        public int LogicalSectorSizeBytes { get; set; }
        [JsonPropertyName("partitionStyle")]
        public string PartitionStyle { get; set; }
        [JsonPropertyName("friendlyName")]
        public string FriendlyName { get; set; }
        [JsonPropertyName("busType")]
        public string BusType { get; set; }
        [JsonPropertyName("partitionNumber")]
        public int PartitionNumber { get; set; }
        [JsonPropertyName("offsetBytes")]
        public long OffsetBytes { get; set; }
        [JsonPropertyName("sizeBytes")]
        public long SizeBytes { get; set; }
        [JsonPropertyName("minimumSizeBytes")]
        public long MinimumSizeBytes { get; set; }
        [JsonPropertyName("freeBytes")]
        public long FreeBytes { get; set; }
        [JsonPropertyName("volumeId")]
        public string VolumeId { get; set; }
    }
}
