using System;
using System.Globalization;
using System.Text.Json;

namespace Libertix.Helpers
{
    internal sealed class PowerShellJsonResult
    {
        private readonly JsonElement _root;

        private PowerShellJsonResult(JsonElement root)
        {
            _root = root;
        }

        public static PowerShellJsonResult ParseFinalObject(string standardOutput)
        {
            string[] lines = (standardOutput ?? string.Empty).Split(
                new[] { '\r', '\n' },
                StringSplitOptions.RemoveEmptyEntries);
            for (int index = lines.Length - 1; index >= 0; index--)
            {
                string candidate = lines[index].Trim();
                if (!candidate.StartsWith("{", StringComparison.Ordinal) ||
                    !candidate.EndsWith("}", StringComparison.Ordinal))
                    continue;
                try
                {
                    using (JsonDocument document = JsonDocument.Parse(candidate))
                    {
                        if (document.RootElement.ValueKind == JsonValueKind.Object)
                            return new PowerShellJsonResult(document.RootElement.Clone());
                    }
                }
                catch (JsonException)
                {
                    // Progress and native diagnostics can contain braces. Only
                    // a complete final JSON object is the script contract.
                }
            }
            throw new InvalidOperationException("PowerShell did not return a final JSON object.");
        }

        public bool GetBoolean(string name) => Get(name).GetBoolean();
        public string GetString(string name)
        {
            string value = Get(name).GetString();
            return !string.IsNullOrWhiteSpace(value)
                ? value
                : throw new InvalidOperationException($"PowerShell returned an empty {name} value.");
        }
        public int GetInt32(string name) => Get(name).GetInt32();
        public long GetInt64(string name) => Get(name).GetInt64();

        public string[] GetStringArray(string name)
        {
            JsonElement value = Get(name);
            if (value.ValueKind != JsonValueKind.Array)
                throw new InvalidOperationException($"PowerShell returned a non-array {name} value.");
            var result = new string[value.GetArrayLength()];
            int index = 0;
            foreach (JsonElement item in value.EnumerateArray())
                result[index++] = item.GetString() ?? string.Empty;
            return result;
        }

        public string GetOptionalString(string name, string fallback)
        {
            if (!_root.TryGetProperty(name, out JsonElement value) ||
                value.ValueKind != JsonValueKind.String)
                return fallback;
            return value.GetString() ?? fallback;
        }

        private JsonElement Get(string name)
        {
            if (_root.TryGetProperty(name, out JsonElement value))
                return value;
            throw new InvalidOperationException(
                string.Format(CultureInfo.InvariantCulture, "PowerShell result is missing {0}.", name));
        }
    }
}
