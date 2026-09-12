using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using Libertix.Installation;

namespace Libertix.Helpers
{
    internal enum InstalledLinuxRecoveryStatus
    {
        None,
        Available,
        Blocked
    }

    internal sealed class InstalledLinuxRecoveryCandidate
    {
        public string Firmware { get; set; }
        public string PlanId { get; set; }
        public string DistributionName { get; set; }
        public string RecoveryRoot { get; set; }
        public string RecoveryScriptPath { get; set; }
        public string RecoveryStatePath { get; set; }
        public string ExecutionStatePath { get; set; }
        public bool RollbackInProgress { get; set; }
    }

    internal sealed class InstalledLinuxRecoveryDetection
    {
        private InstalledLinuxRecoveryDetection(
            InstalledLinuxRecoveryStatus status,
            InstalledLinuxRecoveryCandidate candidate,
            string diagnostic)
        {
            Status = status;
            Candidate = candidate;
            Diagnostic = diagnostic;
        }

        public InstalledLinuxRecoveryStatus Status { get; }
        public InstalledLinuxRecoveryCandidate Candidate { get; }
        public string Diagnostic { get; }

        public static InstalledLinuxRecoveryDetection None() =>
            new InstalledLinuxRecoveryDetection(InstalledLinuxRecoveryStatus.None, null, null);

        public static InstalledLinuxRecoveryDetection Available(
            InstalledLinuxRecoveryCandidate candidate) =>
            new InstalledLinuxRecoveryDetection(
                InstalledLinuxRecoveryStatus.Available,
                candidate ?? throw new ArgumentNullException(nameof(candidate)),
                null);

        public static InstalledLinuxRecoveryDetection Blocked(string diagnostic) =>
            new InstalledLinuxRecoveryDetection(
                InstalledLinuxRecoveryStatus.Blocked,
                null,
                diagnostic);
    }

    /// <summary>
    /// Finds only installations whose durable transaction and verification records
    /// agree. The UEFI uninstall agent also proves the current partition identity
    /// before removing boot maintenance or changing disk state.
    /// </summary>
    internal static class InstalledLinuxRecoveryLocator
    {
        private static readonly string[] CommonChecks =
        {
            "execution-ledger",
            "installed-linux-boot",
            "disk-geometry",
            "windows-read-only-linux-share",
            "windows-health",
            "boot-configuration",
            "temporary-boot-cleanup",
            "permanent-recovery-archive"
        };

        public static InstalledLinuxRecoveryDetection Find()
        {
            string systemRoot = Path.GetPathRoot(Environment.SystemDirectory);
            string programData = Environment.GetFolderPath(
                Environment.SpecialFolder.CommonApplicationData);
            return Find(systemRoot, programData);
        }

        internal static InstalledLinuxRecoveryDetection Find(
            string systemRoot,
            string programData)
        {
            if (string.IsNullOrWhiteSpace(systemRoot) ||
                string.IsNullOrWhiteSpace(programData))
            {
                return InstalledLinuxRecoveryDetection.Blocked(
                    "Windows recovery roots could not be resolved.");
            }

            var candidates = new List<InstalledLinuxRecoveryCandidate>();
            var blockers = new List<string>();
            InspectRoot(
                Path.Combine(systemRoot, RuntimeNames.BiosRecoveryDirectory),
                InstallationFirmware.Bios,
                candidates,
                blockers);

            string uefiRoot = Path.Combine(programData, "Libertix", "UefiRecovery");
            if (Directory.Exists(uefiRoot))
            {
                try
                {
                    foreach (string root in Directory.EnumerateDirectories(uefiRoot))
                    {
                        InspectRoot(
                            root,
                            InstallationFirmware.Uefi,
                            candidates,
                            blockers);
                    }
                }
                catch (Exception ex)
                {
                    blockers.Add("UEFI recovery directory enumeration failed: " + ex.Message);
                }
            }

            if (candidates.Count > 1)
            {
                return InstalledLinuxRecoveryDetection.Blocked(
                    "Multiple verified installed transactions were found.");
            }
            if (candidates.Count == 1 && blockers.Count == 0)
                return InstalledLinuxRecoveryDetection.Available(candidates[0]);
            if (blockers.Count > 0)
                return InstalledLinuxRecoveryDetection.Blocked(string.Join(" | ", blockers));
            return InstalledLinuxRecoveryDetection.None();
        }

        internal static void VerifyRollbackResult(
            InstalledLinuxRecoveryCandidate candidate,
            InstallationExecutionState execution)
        {
            if (candidate == null)
                throw new ArgumentNullException(nameof(candidate));
            InstallationStateMachine.ValidateState(execution);
            if (execution.Status != InstallationStatus.RolledBack ||
                InstallationStateMachine.GetRollbackProgressPercent(execution) != 100 ||
                !string.Equals(candidate.PlanId, execution.PlanId, StringComparison.Ordinal))
            {
                throw new InvalidOperationException(
                    "The rollback result cannot be closed before the execution ledger proves completion.");
            }

            string resultPath = Path.Combine(
                candidate.RecoveryRoot,
                "post-install-verification.json");
            JsonObject result = JsonNode.Parse(File.ReadAllText(resultPath)) as JsonObject ??
                throw new InvalidOperationException(
                    "The post-install verification result is not a JSON object.");
            if (result["schemaVersion"]?.GetValue<int>() != 1 ||
                !string.Equals(
                    result["planId"]?.GetValue<string>(),
                    candidate.PlanId,
                    StringComparison.Ordinal) ||
                !string.Equals(
                    result["firmware"]?.GetValue<string>(),
                    candidate.Firmware,
                    StringComparison.Ordinal))
            {
                throw new InvalidOperationException(
                    "The post-install verification result belongs to another recovery transaction.");
            }

            string status = result["status"]?.GetValue<string>();
            if (string.Equals(status, "rolled-back", StringComparison.Ordinal))
            {
                if (result["rollbackAvailable"]?.GetValue<bool>() != false ||
                    result["rollbackExecutionRevision"]?.GetValue<int>() != execution.Revision ||
                    string.IsNullOrWhiteSpace(
                        result["rolledBackAtUtc"]?.GetValue<string>()))
                {
                    throw new InvalidOperationException(
                        "The completed rollback result does not match its execution ledger.");
                }
                return;
            }
            throw new InvalidOperationException(
                "The recovery agent has not published a completed rollback result.");
        }

        private static void InspectRoot(
            string root,
            string firmware,
            ICollection<InstalledLinuxRecoveryCandidate> candidates,
            ICollection<string> blockers)
        {
            if (!Directory.Exists(root))
                return;

            string executionPath = Path.Combine(root, "installation-state.json");
            string verificationPath = Path.Combine(root, "post-install-verification.json");
            InstallationExecutionState execution;
            try
            {
                if (!File.Exists(executionPath))
                {
                    if (File.Exists(verificationPath))
                    {
                        blockers.Add(
                            $"Missing {firmware} execution state for a post-install result.");
                    }
                    return;
                }
                execution = InstallationStateStore.Read(executionPath);
            }
            catch (Exception ex)
            {
                if (File.Exists(verificationPath))
                    blockers.Add($"Unreadable {firmware} execution state: {ex.Message}");
                return;
            }

            bool uninstallableState =
                execution.Status == InstallationStatus.Succeeded ||
                execution.Status == InstallationStatus.RollbackRunning ||
                execution.Status == InstallationStatus.RolledBack;
            if (execution.Status == InstallationStatus.RolledBack &&
                !File.Exists(verificationPath))
            {
                return;
            }
            if (!uninstallableState)
            {
                if (File.Exists(verificationPath))
                {
                    blockers.Add(
                        $"Unexpected {firmware} execution status '{execution.Status}' " +
                        "for a post-install result.");
                }
                return;
            }

            try
            {
                string canonicalRoot = Path.GetFullPath(root).TrimEnd(
                    Path.DirectorySeparatorChar,
                    Path.AltDirectorySeparatorChar);
                if ((File.GetAttributes(canonicalRoot) & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidOperationException("Recovery root is a reparse point.");

                string planPath = Path.Combine(canonicalRoot, "installation-plan.json");
                InstallationPlan plan = InstallationPlanSerializer.ReadValidated(planPath);
                if (!string.Equals(plan.PlanId, execution.PlanId, StringComparison.Ordinal) ||
                    !string.Equals(plan.Firmware, firmware, StringComparison.Ordinal) ||
                    !string.Equals(
                        plan.Runtime?.RecoveryRunId,
                        execution.PlanId,
                        StringComparison.Ordinal) ||
                    !PathsEqual(plan.Runtime?.RecoveryRootWindows, canonicalRoot))
                {
                    throw new InvalidOperationException(
                        "Installation plan and execution state do not identify the same recovery transaction.");
                }

                if (execution.Status == InstallationStatus.RolledBack &&
                    IsClosedRollbackResult(canonicalRoot, plan, execution))
                {
                    return;
                }

                ValidateLinuxBootEvidence(canonicalRoot, plan);
                ValidatePostInstallResult(canonicalRoot, plan);
                string statePath = null;
                string scriptPath;
                if (firmware == InstallationFirmware.Uefi)
                {
                    statePath = Path.Combine(canonicalRoot, "state.json");
                    scriptPath = ValidateUefiRecoveryState(canonicalRoot, plan, statePath);
                }
                else
                {
                    scriptPath = Path.Combine(canonicalRoot, "recover.ps1");
                    ValidateRequiredFiles(canonicalRoot, new[]
                    {
                        "pending.env",
                        "install-success.env",
                        "recover.ps1",
                        "Libertix.InstallationState.psm1",
                        "Libertix.AtomicFile.psm1",
                        "Libertix.InstallationPolicy.json",
                        "Libertix.TemporaryArtifacts.psm1",
                        "Libertix.PostInstallVerification.psm1",
                        "Libertix.Rollback.psm1",
                        "Libertix.StorageTargets.psm1",
                        "Libertix.Process.psm1",
                        "Libertix.WindowsProfiles.psm1",
                        "Libertix.BiosMbr.psm1",
                        "bcd-backup",
                        Path.Combine("mbr-backup", "mbr-before-grub.bin"),
                        Path.Combine("mbr-backup", "mbr-before-grub.sha256")
                    });
                    ValidateBiosPending(canonicalRoot, plan.PlanId);
                }

                candidates.Add(new InstalledLinuxRecoveryCandidate
                {
                    Firmware = firmware,
                    PlanId = plan.PlanId,
                    DistributionName = plan.Distribution.Name,
                    RecoveryRoot = canonicalRoot,
                    RecoveryScriptPath = scriptPath,
                    RecoveryStatePath = statePath,
                    ExecutionStatePath = executionPath,
                    RollbackInProgress = execution.Status != InstallationStatus.Succeeded
                });
            }
            catch (Exception ex)
            {
                blockers.Add($"Invalid {firmware} recovery archive '{root}': {ex.Message}");
            }
        }

        private static void ValidateLinuxBootEvidence(string root, InstallationPlan plan)
        {
            using (JsonDocument document = ReadJsonObject(
                Path.Combine(root, "installed-linux-boot.json"),
                "installed Linux boot evidence"))
            {
                JsonElement value = document.RootElement;
                if (ReadInt(value, "schemaVersion") != 1 ||
                    !string.Equals(ReadString(value, "planId"), plan.PlanId, StringComparison.Ordinal) ||
                    !string.Equals(ReadString(value, "recoveryRunId"), plan.PlanId, StringComparison.Ordinal) ||
                    !string.Equals(ReadString(value, "firmware"), plan.Firmware, StringComparison.Ordinal))
                {
                    throw new InvalidOperationException(
                        "Installed Linux boot evidence belongs to another transaction.");
                }
            }
        }

        private static void ValidatePostInstallResult(string root, InstallationPlan plan)
        {
            using (JsonDocument document = ReadJsonObject(
                Path.Combine(root, "post-install-verification.json"),
                "post-install verification result"))
            {
                JsonElement value = document.RootElement;
                if (ReadInt(value, "schemaVersion") != 1 ||
                    !string.Equals(ReadString(value, "planId"), plan.PlanId, StringComparison.Ordinal) ||
                    !string.Equals(ReadString(value, "firmware"), plan.Firmware, StringComparison.Ordinal) ||
                    !string.Equals(ReadString(value, "status"), "succeeded", StringComparison.Ordinal) ||
                    !ReadBoolean(value, "rollbackAvailable"))
                {
                    throw new InvalidOperationException(
                        "Post-install verification did not authorize rollback of this transaction.");
                }

                if (!value.TryGetProperty("activeAttemptId", out JsonElement activeAttempt) ||
                    activeAttempt.ValueKind != JsonValueKind.Null)
                {
                    throw new InvalidOperationException(
                        "Post-install verification still has an active attempt.");
                }

                if (!value.TryGetProperty("checks", out JsonElement checks) ||
                    checks.ValueKind != JsonValueKind.Array)
                {
                    throw new InvalidOperationException("Post-install checks are missing.");
                }
                var observed = new HashSet<string>(StringComparer.Ordinal);
                foreach (JsonElement check in checks.EnumerateArray())
                {
                    string name = ReadString(check, "name");
                    if (!observed.Add(name) || !ReadBoolean(check, "passed"))
                    {
                        throw new InvalidOperationException(
                            "Post-install checks are duplicated or contain a failure.");
                    }
                }
                IEnumerable<string> required = plan.Firmware == InstallationFirmware.Uefi
                    ? CommonChecks.Concat(new[] { "boot-guardian" })
                    : CommonChecks;
                if (required.Any(check => !observed.Contains(check)))
                    throw new InvalidOperationException("A required post-install check is missing.");

                if (!value.TryGetProperty("attempts", out JsonElement attempts) ||
                    attempts.ValueKind != JsonValueKind.Array ||
                    !attempts.EnumerateArray().Any(attempt =>
                        string.Equals(
                            ReadString(attempt, "outcome"),
                            "succeeded",
                            StringComparison.Ordinal)))
                {
                    throw new InvalidOperationException(
                        "No completed post-install verification attempt was recorded.");
                }
            }
        }

        private static bool IsClosedRollbackResult(
            string root,
            InstallationPlan plan,
            InstallationExecutionState execution)
        {
            using (JsonDocument document = ReadJsonObject(
                Path.Combine(root, "post-install-verification.json"),
                "post-install verification result"))
            {
                JsonElement value = document.RootElement;
                string status = ReadString(value, "status");
                if (!string.Equals(status, "rolled-back", StringComparison.Ordinal))
                    return false;

                if (ReadInt(value, "schemaVersion") != 1 ||
                    !string.Equals(ReadString(value, "planId"), plan.PlanId, StringComparison.Ordinal) ||
                    !string.Equals(ReadString(value, "firmware"), plan.Firmware, StringComparison.Ordinal) ||
                    ReadBoolean(value, "rollbackAvailable") ||
                    ReadInt(value, "rollbackExecutionRevision") != execution.Revision ||
                    string.IsNullOrWhiteSpace(ReadString(value, "rolledBackAtUtc")))
                {
                    throw new InvalidOperationException(
                        "The completed rollback result does not match its execution ledger.");
                }
                return true;
            }
        }

        private static string ValidateUefiRecoveryState(
            string root,
            InstallationPlan plan,
            string statePath)
        {
            UefiRecoveryState state = JsonSerializer.Deserialize<UefiRecoveryState>(
                File.ReadAllText(statePath));
            if (state == null ||
                !string.Equals(state.RunId, plan.PlanId, StringComparison.Ordinal) ||
                !string.Equals(state.PlanId, plan.PlanId, StringComparison.Ordinal) ||
                !string.Equals(state.Phase, "Verified", StringComparison.Ordinal) ||
                !PathsEqual(state.RecoveryRoot, root) ||
                !IsPathInside(state.PayloadRoot, root))
            {
                throw new InvalidOperationException(
                    "UEFI recovery state is not the verified state for this transaction.");
            }

            ValidateRequiredFiles(root, new[]
            {
                "payload-manifest.json",
                "uefi-transaction.json",
                Path.Combine("payload", "Scripts", "libertix-uefi-recovery-agent.ps1"),
                Path.Combine("payload", "Scripts", "libertix-uefi-install.ps1"),
                Path.Combine("payload", "Scripts", "modules", "Libertix.InstallationState.psm1"),
                Path.Combine("payload", "Scripts", "modules", "Libertix.PostInstallVerification.psm1"),
                Path.Combine("payload", "Scripts", "modules", "Libertix.Rollback.psm1")
            });
            return Path.Combine(
                state.PayloadRoot,
                "Scripts",
                "libertix-uefi-recovery-agent.ps1");
        }

        private static void ValidateBiosPending(string root, string planId)
        {
            var values = File.ReadLines(Path.Combine(root, "pending.env"))
                .Where(line => line.Contains("="))
                .Select(line => line.Split(new[] { '=' }, 2))
                .GroupBy(parts => parts[0], StringComparer.Ordinal)
                .ToDictionary(group => group.Key, group => group.Single()[1], StringComparer.Ordinal);
            if (!values.TryGetValue("PLAN_ID", out string pendingPlanId) ||
                !values.TryGetValue("RECOVERY_RUN_ID", out string recoveryRunId) ||
                !string.Equals(pendingPlanId, planId, StringComparison.Ordinal) ||
                !string.Equals(recoveryRunId, planId, StringComparison.Ordinal))
            {
                throw new InvalidOperationException(
                    "BIOS recovery metadata belongs to another transaction.");
            }
        }

        private static void ValidateRequiredFiles(string root, IEnumerable<string> relativePaths)
        {
            foreach (string relativePath in relativePaths)
            {
                if (!File.Exists(Path.Combine(root, relativePath)))
                    throw new FileNotFoundException("Required recovery file is missing.", relativePath);
            }
        }

        private static JsonDocument ReadJsonObject(string path, string description)
        {
            if (!File.Exists(path))
                throw new FileNotFoundException(description + " is missing.", path);
            var info = new FileInfo(path);
            if (info.Length <= 0 || info.Length > 4 * 1024 * 1024)
                throw new InvalidOperationException(description + " has an invalid size.");
            JsonDocument document = JsonDocument.Parse(File.ReadAllText(path));
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                document.Dispose();
                throw new InvalidOperationException(description + " is not a JSON object.");
            }
            return document;
        }

        private static string ReadString(JsonElement value, string name)
        {
            if (!value.TryGetProperty(name, out JsonElement property) ||
                property.ValueKind != JsonValueKind.String)
            {
                throw new InvalidOperationException($"Required string '{name}' is missing.");
            }
            return property.GetString();
        }

        private static int ReadInt(JsonElement value, string name)
        {
            if (!value.TryGetProperty(name, out JsonElement property) ||
                property.ValueKind != JsonValueKind.Number ||
                !property.TryGetInt32(out int result))
            {
                throw new InvalidOperationException($"Required integer '{name}' is missing.");
            }
            return result;
        }

        private static bool ReadBoolean(JsonElement value, string name)
        {
            if (!value.TryGetProperty(name, out JsonElement property) ||
                (property.ValueKind != JsonValueKind.True &&
                 property.ValueKind != JsonValueKind.False))
            {
                throw new InvalidOperationException($"Required boolean '{name}' is missing.");
            }
            return property.GetBoolean();
        }

        private static bool PathsEqual(string left, string right)
        {
            if (string.IsNullOrWhiteSpace(left) || string.IsNullOrWhiteSpace(right))
                return false;
            return string.Equals(
                Path.GetFullPath(left).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                Path.GetFullPath(right).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                StringComparison.OrdinalIgnoreCase);
        }

        private static bool IsPathInside(string path, string root)
        {
            if (string.IsNullOrWhiteSpace(path))
                return false;
            string canonicalRoot = Path.GetFullPath(root).TrimEnd(
                Path.DirectorySeparatorChar,
                Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
            string canonicalPath = Path.GetFullPath(path);
            return canonicalPath.StartsWith(canonicalRoot, StringComparison.OrdinalIgnoreCase);
        }
    }
}
