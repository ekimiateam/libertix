using System.Text.Json.Serialization;

namespace Libertix.Installation
{
    public enum FirmwareType
    {
        Unknown = 0,
        Bios = 1,
        Uefi = 2,
        Max = 3
    }

    /// <summary>
    /// Stable identity and geometry captured before any storage modification.
    /// </summary>
    public sealed class StoragePreflightInfo
    {
        public FirmwareType Firmware { get; set; }
        public string SystemDrive { get; set; }
        public int SystemDiskNumber { get; set; }
        public string SystemDiskUniqueId { get; set; }
        public string SystemDiskPartitionTableId { get; set; }
        public long SystemDiskSize { get; set; }
        public int LogicalSectorSize { get; set; }
        public string PartitionStyle { get; set; }
        public InstallationAllocation Allocation { get; set; }
        public VolumeEncryptionSnapshot AllocationEncryption { get; set; }
        public int SystemPartitionNumber { get; set; }
        public long SystemPartitionOffset { get; set; }
        public long SystemPartitionSize { get; set; }
        public int BootPartitionNumber { get; set; }
        public long BootPartitionOffset { get; set; }
        public long BootPartitionSize { get; set; }
        public int RecoveryPartitionNumber { get; set; }
        public long RecoveryPartitionOffset { get; set; }
        public long RecoveryPartitionSize { get; set; }
        public bool BitLockerSafe { get; set; }
        public string BitLockerState { get; set; }
        public int BitLockerConversionStatus { get; set; }
        public int BitLockerEncryptionPercentage { get; set; }
        public int BitLockerProtectionStatus { get; set; }
        public int InitialBitLockerConversionStatus { get; set; }
        public int InitialBitLockerEncryptionPercentage { get; set; }
        public int InitialBitLockerProtectionStatus { get; set; }

        public PartitionIdentity WindowsPartition => new PartitionIdentity
        {
            Number = SystemPartitionNumber,
            OffsetBytes = SystemPartitionOffset,
            SizeBytes = SystemPartitionSize
        };

        public PartitionIdentity BootPartition => new PartitionIdentity
        {
            Number = BootPartitionNumber,
            OffsetBytes = BootPartitionOffset,
            SizeBytes = BootPartitionSize
        };

        public PartitionIdentity RecoveryPartition => new PartitionIdentity
        {
            Number = RecoveryPartitionNumber,
            OffsetBytes = RecoveryPartitionOffset,
            SizeBytes = RecoveryPartitionSize
        };
    }

    public sealed class VolumeEncryptionSnapshot
    {
        [JsonPropertyName("state")]
        public string State { get; set; }
        [JsonPropertyName("conversionStatus")]
        public int ConversionStatus { get; set; }
        [JsonPropertyName("encryptionPercentage")]
        public int EncryptionPercentage { get; set; }
        [JsonPropertyName("protectionStatus")]
        public int ProtectionStatus { get; set; }

        public bool Matches(VolumeEncryptionSnapshot other)
        {
            return IsValid && other != null && other.IsValid && State == other.State && ConversionStatus == other.ConversionStatus &&
                EncryptionPercentage == other.EncryptionPercentage && ProtectionStatus == other.ProtectionStatus;
        }

        [JsonIgnore]
        public bool IsValid => ConversionStatus >= 0 && ConversionStatus <= 5 &&
            EncryptionPercentage >= 0 && EncryptionPercentage <= 100 &&
            ProtectionStatus >= 0 && ProtectionStatus <= 2 &&
            (State == InstallationBitLockerState.EncryptedOrProtected
                ? ConversionStatus != 0 || EncryptionPercentage != 0 || ProtectionStatus != 0
                : (State == InstallationBitLockerState.FullyDecrypted || State == InstallationBitLockerState.NotEncryptable) &&
                    ConversionStatus == 0 && EncryptionPercentage == 0 && ProtectionStatus == 0);
    }
}
