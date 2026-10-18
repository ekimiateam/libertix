using System.IO;
using System.Text.Json;

namespace Libertix.Installation
{
    /// <summary>
    /// Serializes a validated installation plan without exposing a partially
    /// written file to PowerShell, the live installer, or recovery tooling.
    /// </summary>
    public static class InstallationPlanSerializer
    {
        private static readonly JsonSerializerOptions SerializerOptions =
            new JsonSerializerOptions
            {
                WriteIndented = true
            };

        public static void WriteAtomic(string path, InstallationPlan plan)
        {
            InstallationPlanValidator.Validate(plan);
            AtomicJsonFile.Write(path, JsonSerializer.Serialize(plan, SerializerOptions));
        }

        public static InstallationPlan ReadValidated(string path)
        {
            InstallationPlan plan = JsonSerializer.Deserialize<InstallationPlan>(
                File.ReadAllText(path));
            InstallationPlanValidator.Validate(plan);
            return plan;
        }

        internal static InstallationPlan ReadForRecovery(string path, out bool upgraded)
        {
            InstallationPlan plan = JsonSerializer.Deserialize<InstallationPlan>(File.ReadAllText(path));
            upgraded = plan != null && plan.SchemaVersion == 3 && plan.Allocation == null &&
                plan.Features != null && plan.Features.WindowsPreferenceMigration == null;
            if (upgraded)
            {
                // Version 3 predates preference migration; its absence means disabled.
                plan.SchemaVersion = InstallationPlan.CurrentSchemaVersion;
                plan.Features.WindowsPreferenceMigration = new InstallationPreferenceMigration { Enabled = false };
            }
            InstallationPlanValidator.Validate(plan);
            return plan;
        }

        internal static void UpgradeRecoveryPlan(string path, string planId)
        {
            InstallationPlan plan = ReadForRecovery(path, out bool upgraded);
            if (plan.PlanId != planId)
                throw new System.InvalidOperationException("Recovery plan changed before its upgrade.");
            if (upgraded) WriteAtomic(path, plan);
        }
    }
}
