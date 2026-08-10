using System.Text.Json.Serialization;

namespace Libertix.Models
{
    public class DistroInfoJson
    {
        [JsonPropertyName("id")]
        public string Id { get; set; }

        [JsonPropertyName("name")]
        public string Name { get; set; }

        [JsonPropertyName("osReleaseId")]
        public string OsReleaseId { get; set; }

        [JsonPropertyName("grubDisplayName")]
        public string GrubDisplayName { get; set; }

        [JsonPropertyName("grubIcon")]
        public string GrubIcon { get; set; }

        [JsonPropertyName("description")]
        public string Description { get; set; }

        [JsonPropertyName("imageUrl")]
        public string ImageUrl { get; set; }

        [JsonPropertyName("isoUrl")]
        public string IsoUrl { get; set; }

        [JsonPropertyName("isoInstaller")]
        public string IsoInstaller { get; set; }

        [JsonPropertyName("isoInstallerFileName")]
        public string IsoInstallerFileName { get; set; }

        [JsonPropertyName("isoSha256")]
        public string IsoSha256 { get; set; }

        [JsonPropertyName("uefiIsoUrl")]
        public string UefiIsoUrl { get; set; }

        [JsonPropertyName("uefiIsoSha256")]
        public string UefiIsoSha256 { get; set; }

        [JsonPropertyName("isoInstallerSha256")]
        public string IsoInstallerSha256 { get; set; }

        [JsonPropertyName("isoInstallerSizeBytes")]
        public long IsoInstallerSizeBytes { get; set; }

        [JsonPropertyName("sizeInGB")]
        public double SizeInGB { get; set; }
    }
}
