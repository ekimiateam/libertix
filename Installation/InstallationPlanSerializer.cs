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
    }
}
