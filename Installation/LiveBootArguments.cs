using System;
using System.IO;
using System.Text.Json;

namespace Libertix.Installation
{
    public sealed class LiveBootArguments
    {
        public string Normal { get; private set; }
        public string Verbose { get; private set; }

        public static LiveBootArguments Load(string path)
        {
            if (string.IsNullOrWhiteSpace(path))
                throw new ArgumentException("Boot argument path is required.", nameof(path));

            using (JsonDocument document = JsonDocument.Parse(File.ReadAllText(path)))
            {
                JsonElement root = document.RootElement;
                return new LiveBootArguments
                {
                    Normal = ReadSingleLine(root, "normal"),
                    Verbose = ReadSingleLine(root, "verbose")
                };
            }
        }

        public static LiveBootArguments LoadFromApplicationDirectory()
        {
            return Load(Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory,
                "Scripts",
                "config",
                "Libertix.BootArguments.json"));
        }

        public string CreateGrub4DosMenu()
        {
            return string.Join("\n", new[]
            {
                "timeout 0",
                "default 0",
                "title Libertix Installer",
                // Windows partition numbers cannot be converted mechanically
                // to GRUB4DOS indexes: logical MBR partitions start at index 4
                // even when Windows reports a different sequential number.
                // The plan is unique to the prepared staging volume, so finding
                // it also selects the volume that owns the live kernel.
                "find --set-root /installation-plan.json",
                $"kernel /live/vmlinuz {Normal}",
                "initrd /live/initrd.img",
                string.Empty
            });
        }

        private static string ReadSingleLine(JsonElement root, string propertyName)
        {
            if (!root.TryGetProperty(propertyName, out JsonElement value) ||
                value.ValueKind != JsonValueKind.String)
            {
                throw new InvalidDataException($"Boot argument '{propertyName}' is missing.");
            }

            string text = value.GetString();
            if (string.IsNullOrWhiteSpace(text) || text.IndexOfAny(new[] { '\r', '\n' }) >= 0)
                throw new InvalidDataException($"Boot argument '{propertyName}' must be one line.");
            return text;
        }
    }
}
