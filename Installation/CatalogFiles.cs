using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Libertix.Helpers;
using Libertix.Models;

namespace Libertix.Installation
{
    public static class CatalogFiles
    {
        public static IReadOnlyList<CatalogArtifactJson> GetAll(DistributionCatalogJson catalog)
        {
            if (catalog == null || catalog.SchemaVersion != 1 ||
                catalog.Artifacts?.MiniIso == null || catalog.Artifacts.Support == null ||
                catalog.Distributions == null || catalog.Distributions.Count == 0)
                throw new InvalidDataException("Invalid filepool catalog.");

            var files = new List<CatalogArtifactJson>
            {
                catalog.Artifacts.Wpf, catalog.Artifacts.MiniIso.Bios,
                catalog.Artifacts.MiniIso.Uefi, catalog.Artifacts.Support.Aria2Archive,
                catalog.Artifacts.Support.Ext4Driver, catalog.Artifacts.Support.Grub4DosLoader,
                catalog.Artifacts.Support.Grub4DosMbr
            };
            files.AddRange(catalog.Distributions.Select(distribution => new CatalogArtifactJson
            {
                FileName = distribution.IsoInstallerFileName,
                Url = distribution.IsoInstaller,
                SizeBytes = distribution.IsoInstallerSizeBytes,
                Sha256 = distribution.IsoInstallerSha256
            }));
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var file in files)
            {
                if (file == null || file.SizeBytes <= 0 || !names.Add(file.FileName ?? ""))
                    throw new InvalidDataException("Missing or duplicate filepool artifact.");
                FilepoolProtocol.ArtifactPath(file.FileName, file.Sha256);
            }
            return files;
        }
    }
}
