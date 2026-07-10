using System.Text.Json.Serialization;

namespace Libertix.Models
{
    public class DistroInfoJson
    {
        [JsonPropertyName("name")]
        public string Name { get; set; }

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

        [JsonPropertyName("isoInstallerSha256")]
        public string IsoInstallerSha256 { get; set; }

        [JsonPropertyName("sizeInGB")]
        public double SizeInGB { get; set; }
    }
}
