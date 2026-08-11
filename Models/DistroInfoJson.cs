using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace Libertix.Models
{
    public sealed class CatalogArtifactJson
    {
        [JsonPropertyName("fileName")]
        public string FileName { get; set; }

        [JsonPropertyName("url")]
        public string Url { get; set; }

        [JsonPropertyName("sha256")]
        public string Sha256 { get; set; }

        [JsonPropertyName("sizeBytes")]
        public long SizeBytes { get; set; }
    }

    public sealed class MiniIsoArtifactsJson
    {
        [JsonPropertyName("bios")]
        public CatalogArtifactJson Bios { get; set; }

        [JsonPropertyName("uefi")]
        public CatalogArtifactJson Uefi { get; set; }
    }

    public sealed class SupportArtifactsJson
    {
        [JsonPropertyName("aria2Archive")]
        public CatalogArtifactJson Aria2Archive { get; set; }

        [JsonPropertyName("ext4Driver")]
        public CatalogArtifactJson Ext4Driver { get; set; }

        [JsonPropertyName("grub4DosLoader")]
        public CatalogArtifactJson Grub4DosLoader { get; set; }

        [JsonPropertyName("grub4DosMbr")]
        public CatalogArtifactJson Grub4DosMbr { get; set; }
    }

    public sealed class DistributionCatalogArtifactsJson
    {
        [JsonPropertyName("wpf")]
        public CatalogArtifactJson Wpf { get; set; }

        [JsonPropertyName("miniIso")]
        public MiniIsoArtifactsJson MiniIso { get; set; }

        [JsonPropertyName("support")]
        public SupportArtifactsJson Support { get; set; }
    }

    public sealed class DistributionCatalogJson
    {
        [JsonPropertyName("schemaVersion")]
        public int SchemaVersion { get; set; }

        [JsonPropertyName("artifacts")]
        public DistributionCatalogArtifactsJson Artifacts { get; set; }

        [JsonPropertyName("distributions")]
        public List<DistroInfoJson> Distributions { get; set; }
    }

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

        [JsonPropertyName("isoInstaller")]
        public string IsoInstaller { get; set; }

        [JsonPropertyName("isoInstallerFileName")]
        public string IsoInstallerFileName { get; set; }

        [JsonPropertyName("isoInstallerSha256")]
        public string IsoInstallerSha256 { get; set; }

        [JsonPropertyName("isoInstallerSizeBytes")]
        public long IsoInstallerSizeBytes { get; set; }

        [JsonPropertyName("sizeInGB")]
        public double SizeInGB { get; set; }
    }
}
