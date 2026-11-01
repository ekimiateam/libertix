using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using Libertix.Models;

namespace Libertix.Installation
{
    public static class InstallationTargetSelection
    {
        public static InstallationTargetInfo[] ValidateInventory(
            InstallationTargetInfo[] targets,
            string systemDrive,
            int systemDiskNumber,
            string systemPartitionTableId)
        {
            if (targets == null || targets.Length == 0)
                throw new InvalidOperationException("The installation target inventory is empty.");

            var drives = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var tableDisks = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            foreach (InstallationTargetInfo target in targets)
            {
                if (target == null || target.Drive == null ||
                    !Regex.IsMatch(target.Drive, @"\A[A-Z]:\z") || !drives.Add(target.Drive) ||
                    target.DiskNumber < 0 || target.PartitionNumber <= 0 ||
                    string.IsNullOrWhiteSpace(target.DiskUniqueId) ||
                    string.IsNullOrWhiteSpace(target.DiskDevicePath) ||
                    string.IsNullOrWhiteSpace(target.VolumeId) ||
                    !HasPartitionTableIdentity(target) ||
                    !HasSupportedBus(target) || !HasValidGeometry(target))
                {
                    throw new InvalidOperationException("The installation target inventory is invalid or ambiguous.");
                }
                if (tableDisks.TryGetValue(target.PartitionTableId, out int diskNumber) &&
                    diskNumber != target.DiskNumber)
                    throw new InvalidOperationException("Multiple physical disks expose the same partition-table identity.");
                tableDisks[target.PartitionTableId] = target.DiskNumber;

                bool isWindowsDisk = target.DiskNumber == systemDiskNumber;
                if (target.IsWindows != isWindowsDisk ||
                    (isWindowsDisk && (!string.Equals(target.Drive, systemDrive, StringComparison.OrdinalIgnoreCase) ||
                        !string.Equals(target.PartitionTableId, systemPartitionTableId, StringComparison.OrdinalIgnoreCase))))
                {
                    throw new InvalidOperationException("A target does not match its declared Windows disk identity.");
                }
            }
            if (targets.Count(target => target.IsWindows) != 1)
                throw new InvalidOperationException("Exactly one Windows installation target is required.");

            return targets.OrderByDescending(target => target.IsWindows)
                .ThenBy(target => target.DiskNumber)
                .ThenBy(target => target.OffsetBytes).ToArray();
        }

        public static InstallationTargetInfo Select(
            InstallationTargetInfo[] validatedTargets,
            string requestedDrive = null)
        {
            InstallationTargetInfo[] matches = (validatedTargets ?? new InstallationTargetInfo[0])
                .Where(target => target != null && (string.IsNullOrEmpty(requestedDrive)
                    ? target.IsWindows
                    : string.Equals(target.Drive, requestedDrive, StringComparison.OrdinalIgnoreCase)))
                .ToArray();
            if (matches.Length != 1)
                throw new InvalidOperationException("The requested installation volume is not an available target.");
            return matches[0];
        }

        public static InstallationTargetInfo[] ForFirmware(InstallationTargetInfo[] validatedTargets, string firmware)
        {
            string style;
            if (string.Equals(firmware, "UEFI", StringComparison.OrdinalIgnoreCase))
                style = InstallationPartitionStyle.Gpt;
            else if (string.Equals(firmware, "BIOS", StringComparison.OrdinalIgnoreCase))
                style = InstallationPartitionStyle.Mbr;
            else
                throw new InvalidOperationException("The installation target firmware is unknown.");
            return (validatedTargets ?? new InstallationTargetInfo[0])
                .Where(target => target != null && target.PartitionStyle == style).ToArray();
        }

        private static bool HasPartitionTableIdentity(InstallationTargetInfo target)
        {
            string identity = target.PartitionTableId ?? string.Empty;
            if (target.PartitionStyle == InstallationPartitionStyle.Gpt)
                return identity.StartsWith("gpt:", StringComparison.Ordinal) &&
                    Guid.TryParseExact(identity.Substring(4), "D", out Guid guid) && guid != Guid.Empty;
            return target.PartitionStyle == InstallationPartitionStyle.Mbr &&
                target.PartitionNumber <= 4 && Regex.IsMatch(identity, @"\Ambr:[0-9a-f]{8}\z");
        }

        private static bool HasSupportedBus(InstallationTargetInfo target)
        {
            return new[] { "SATA", "ATA", "NVMe", "SAS", "SCSI" }.Contains(target.BusType) ||
                (target.IsWindows && target.BusType == "MMC");
        }

        private static bool HasValidGeometry(InstallationTargetInfo target)
        {
            int sectorSize = target.LogicalSectorSizeBytes;
            return (sectorSize == 512 || sectorSize == 4096) && target.DiskSizeBytes > 0 &&
                target.DiskSizeBytes % sectorSize == 0 &&
                target.OffsetBytes > 0 && target.SizeBytes > 0 &&
                target.OffsetBytes <= target.DiskSizeBytes &&
                target.SizeBytes <= target.DiskSizeBytes - target.OffsetBytes &&
                target.OffsetBytes % sectorSize == 0 && target.SizeBytes % sectorSize == 0 &&
                target.MinimumSizeBytes > 0 && target.MinimumSizeBytes <= target.SizeBytes &&
                target.FreeBytes >= 0 && target.FreeBytes <= target.SizeBytes;
        }
    }
}
