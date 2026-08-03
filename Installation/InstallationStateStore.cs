using System;
using System.IO;
using System.Text.Json;

namespace Libertix.Installation
{
    public static class InstallationStateStore
    {
        private static readonly JsonSerializerOptions SerializerOptions =
            new JsonSerializerOptions
            {
                WriteIndented = true
            };

        public static InstallationExecutionState Read(string path)
        {
            if (string.IsNullOrWhiteSpace(path))
                throw new ArgumentException("An execution state path is required.", nameof(path));

            InstallationExecutionState state = JsonSerializer.Deserialize<InstallationExecutionState>(
                File.ReadAllText(path),
                SerializerOptions);
            InstallationStateMachine.ValidateState(state);
            return state;
        }

        public static void WriteAtomic(string path, InstallationExecutionState state)
        {
            InstallationStateMachine.ValidateState(state);
            AtomicJsonFile.Write(path, JsonSerializer.Serialize(state, SerializerOptions));
        }
    }
}
