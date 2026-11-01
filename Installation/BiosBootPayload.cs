using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Libertix.Installation
{
    internal static class BiosBootPayload
    {
        internal static readonly string[] Names = { "grldr", "grldr.mbr", "menu.lst" };

        internal static void AssertDestinationsAbsent(string systemRoot)
        {
            foreach (string name in Names)
            {
                string path = Path.Combine(systemRoot, name);
                try { File.GetAttributes(path); }
                catch (FileNotFoundException) { continue; }
                catch (DirectoryNotFoundException) { continue; }
                throw new IOException("A pre-existing boot file must not be overwritten: " + path);
            }
        }

        internal static void Publish(string systemRoot, string recoveryRoot, string planId, string preparedRoot)
        {
            if (!Regex.IsMatch(planId ?? "", "^[0-9a-f]{32}$"))
                throw new InvalidDataException("Invalid BIOS boot payload installation identity.");
            AssertDestinationsAbsent(systemRoot);
            var hashes = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (string name in Names)
            {
                string source = Path.Combine(preparedRoot, name);
                if ((File.GetAttributes(source) & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException("The prepared boot payload cannot be a reparse point.");
                using (var stream = new FileStream(source, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
                using (var sha = SHA256.Create())
                {
                    stream.Flush(true);
                    hashes.Add(name, BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant());
                }
            }
            // Recovery must know every expected hash before the first root file appears.
            AtomicJsonFile.Write(Path.Combine(recoveryRoot, "bios-boot-payload.json"),
                JsonSerializer.Serialize(new { version = 1, planId, files = hashes }));
            foreach (string name in Names)
                File.Move(Path.Combine(preparedRoot, name), Path.Combine(systemRoot, name));
        }
    }
}
