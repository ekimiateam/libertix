using System;
using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace Libertix.Installation
{
    /// <summary>
    /// Durable snapshot of completed and compensated installation operations.
    /// </summary>
    public sealed class InstallationExecutionState
    {
        public const int CurrentSchemaVersion = 1;

        [JsonPropertyName("schemaVersion")]
        public int SchemaVersion { get; set; } = CurrentSchemaVersion;

        [JsonPropertyName("planId")]
        public string PlanId { get; set; }

        [JsonPropertyName("revision")]
        public int Revision { get; set; }

        [JsonPropertyName("status")]
        public string Status { get; set; }

        [JsonPropertyName("phase")]
        public string Phase { get; set; }

        [JsonPropertyName("activeStep")]
        public string ActiveStep { get; set; }

        [JsonPropertyName("completedSteps")]
        public List<string> CompletedSteps { get; set; } = new List<string>();

        [JsonPropertyName("compensatedSteps")]
        public List<string> CompensatedSteps { get; set; } = new List<string>();

        [JsonPropertyName("failure")]
        public InstallationFailure Failure { get; set; }

        [JsonPropertyName("updatedAtUtc")]
        public DateTimeOffset UpdatedAtUtc { get; set; }
    }

    public sealed class InstallationFailure
    {
        [JsonPropertyName("code")]
        public string Code { get; set; }

        [JsonPropertyName("message")]
        public string Message { get; set; }

        [JsonPropertyName("component")]
        public string Component { get; set; }
    }

    public static class InstallationStatus
    {
        public const string Pending = "pending";
        public const string Running = "running";
        public const string Failed = "failed";
        public const string RollbackRunning = "rollback-running";
        public const string RolledBack = "rolled-back";
        public const string Succeeded = "succeeded";
    }

    public static class InstallationPhase
    {
        public const string Windows = "windows";
        public const string Live = "live";
        public const string Target = "target";
        public const string Rollback = "rollback";
        public const string Complete = "complete";
    }

    /// <summary>
    /// Stable operation identifiers shared by BIOS and UEFI workflows.
    /// Firmware adapters may skip an operation, but must not rename it.
    /// </summary>
    public static class InstallationStep
    {
        public const string WindowsPreflightVerified = "windows.preflight-verified";
        public const string WindowsArtifactsVerified = "windows.artifacts-verified";
        public const string WindowsRecoveryArmed = "windows.recovery-armed";
        public const string WindowsSystemVolumeShrunk = "windows.system-volume-shrunk";
        public const string WindowsInstallerPartitionCreated = "windows.installer-partition-created";
        public const string WindowsLiveMediaPrepared = "windows.live-media-prepared";
        public const string WindowsTemporaryBootPrepared = "windows.temporary-boot-prepared";
        public const string LivePreflightVerified = "live.preflight-verified";
        public const string LiveInstallerPartitionExpanded = "live.installer-partition-expanded";
        public const string LiveTargetFilesystemCreated = "live.target-filesystem-created";
        public const string LiveDistributionExtracted = "live.distribution-extracted";
        public const string TargetSystemConfigured = "target.system-configured";
        public const string TargetBootloaderInstalled = "target.bootloader-installed";
        public const string TargetInstallationVerified = "target.installation-verified";
    }
}
