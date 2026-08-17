using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Windows.Forms;

namespace Libertix.Standalone
{
    internal static class Program
    {
        private const string PayloadResource = "Libertix.Standalone.Payload.zip";
        private const string ManifestResource = "Libertix.Standalone.PayloadManifest.json";

        [STAThread]
        private static int Main(string[] args)
        {
            try
            {
                string runtimeRoot = EnsureRuntime();
                string executable = Path.Combine(runtimeRoot, "Libertix.exe");
                var start = new ProcessStartInfo
                {
                    FileName = executable,
                    Arguments = string.Join(" ", args.Select(QuoteArgument)),
                    WorkingDirectory = runtimeRoot,
                    UseShellExecute = false
                };
                using (Process process = Process.Start(start))
                {
                    if (process == null)
                        throw new InvalidOperationException("The embedded Libertix runtime could not be started.");
                    process.WaitForExit();
                    return process.ExitCode;
                }
            }
            catch (Exception error)
            {
                string language = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName;
                string message = language == "fr"
                    ? "Libertix n'a pas pu préparer son environnement interne vérifié."
                    : language == "es"
                        ? "Libertix no pudo preparar su entorno interno verificado."
                        : "Libertix could not prepare its verified runtime.";
                MessageBox.Show(
                    message + "\r\n\r\n" + error,
                    "Libertix",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return 1;
            }
        }

        private static string EnsureRuntime()
        {
            Assembly assembly = Assembly.GetExecutingAssembly();
            PayloadManifest manifest = ReadManifest(assembly);
            byte[] payloadHash;
            using (Stream payload = RequireResource(assembly, PayloadResource))
                payloadHash = ComputeHash(payload);
            string identity = ToHex(payloadHash);
            string parent = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                "Libertix",
                "Runtime");
            ProtectDirectory(parent);
            using (FileStream runtimeLock = AcquireRuntimeLock(parent))
                return EnsureRuntimeLocked(assembly, manifest, identity, parent);
        }

        private static FileStream AcquireRuntimeLock(string parent)
        {
            string path = Path.Combine(parent, ".extraction.lock");
            Stopwatch clock = Stopwatch.StartNew();
            while (clock.Elapsed < TimeSpan.FromMinutes(2))
            {
                try
                {
                    return new FileStream(
                        path,
                        FileMode.OpenOrCreate,
                        FileAccess.ReadWrite,
                        FileShare.None);
                }
                catch (IOException)
                {
                    System.Threading.Thread.Sleep(100);
                }
            }
            throw new TimeoutException("Another Libertix launcher did not release the runtime extraction lock.");
        }

        private static string EnsureRuntimeLocked(
            Assembly assembly,
            PayloadManifest manifest,
            string identity,
            string parent)
        {
            string destination = Path.Combine(parent, identity);
            if (ValidateRuntime(destination, manifest))
                return destination;

            string staging = Path.Combine(parent, ".staging-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(staging);
            ProtectDirectory(staging);
            try
            {
                ExtractVerifiedPayload(assembly, staging, manifest);
                if (!ValidateRuntime(staging, manifest))
                    throw new InvalidDataException("The extracted Libertix runtime failed its final integrity check.");
                if (Directory.Exists(destination))
                {
                    string quarantine = Path.Combine(
                        parent,
                        ".invalid-" + identity + "-" + DateTime.UtcNow.ToString("yyyyMMddTHHmmss", CultureInfo.InvariantCulture));
                    Directory.Move(destination, quarantine);
                }
                try
                {
                    Directory.Move(staging, destination);
                    staging = null;
                }
                catch (IOException)
                {
                    if (!ValidateRuntime(destination, manifest))
                        throw;
                }
                return destination;
            }
            finally
            {
                if (!string.IsNullOrEmpty(staging) && Directory.Exists(staging))
                    Directory.Delete(staging, true);
            }
        }

        private static PayloadManifest ReadManifest(Assembly assembly)
        {
            using (Stream stream = RequireResource(assembly, ManifestResource))
            {
                var serializer = new DataContractJsonSerializer(typeof(PayloadManifest));
                var manifest = (PayloadManifest)serializer.ReadObject(stream);
                if (manifest == null || manifest.SchemaVersion != 1 || manifest.Files == null || manifest.Files.Length == 0)
                    throw new InvalidDataException("The embedded Libertix runtime manifest is invalid.");
                var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (PayloadFile file in manifest.Files)
                {
                    file.Path = NormalizeRelativePath(file.Path);
                    if (file.Size < 0 || !IsSha256(file.Sha256) || !seen.Add(file.Path))
                        throw new InvalidDataException("The embedded Libertix runtime manifest contains an invalid file.");
                }
                if (!seen.Contains("Libertix.exe") || !seen.Contains("Libertix.BootGuardian.exe"))
                    throw new InvalidDataException("The embedded Libertix runtime is incomplete.");
                return manifest;
            }
        }

        private static void ExtractVerifiedPayload(Assembly assembly, string root, PayloadManifest manifest)
        {
            var expected = manifest.Files.ToDictionary(file => file.Path, StringComparer.OrdinalIgnoreCase);
            var observed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            using (Stream stream = RequireResource(assembly, PayloadResource))
            using (var archive = new ZipArchive(stream, ZipArchiveMode.Read, false))
            {
                foreach (ZipArchiveEntry entry in archive.Entries)
                {
                    string relative = NormalizeRelativePath(entry.FullName);
                    if (!observed.Add(relative) || !expected.TryGetValue(relative, out PayloadFile contract))
                        throw new InvalidDataException("The embedded Libertix runtime contains an unexpected file.");
                    string destination = ResolveUnderRoot(root, relative);
                    Directory.CreateDirectory(Path.GetDirectoryName(destination));
                    string temporary = destination + "." + Guid.NewGuid().ToString("N") + ".tmp";
                    try
                    {
                        string extractedHash;
                        long extractedSize;
                        using (Stream source = entry.Open())
                            CopyAndHash(source, temporary, out extractedSize, out extractedHash);
                        var info = new FileInfo(temporary);
                        if (info.Length != extractedSize ||
                            extractedSize != contract.Size ||
                            !string.Equals(extractedHash, contract.Sha256, StringComparison.Ordinal))
                            throw new InvalidDataException("An extracted Libertix runtime file failed integrity validation: " + relative);
                        File.Move(temporary, destination);
                    }
                    finally
                    {
                        if (File.Exists(temporary))
                            File.Delete(temporary);
                    }
                }
            }
            if (observed.Count != expected.Count)
                throw new InvalidDataException("The embedded Libertix runtime payload is incomplete.");
        }

        private static bool ValidateRuntime(string root, PayloadManifest manifest)
        {
            try
            {
                if (!Directory.Exists(root))
                    return false;
                var expected = new HashSet<string>(
                    manifest.Files.Select(file =>
                        NormalizeRelativePath(file.Path).Replace('/', Path.DirectorySeparatorChar)),
                    StringComparer.OrdinalIgnoreCase);
                var observed = new HashSet<string>(
                    Directory.GetFiles(root, "*", SearchOption.AllDirectories).Select(path =>
                        path.Substring(Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar).Length + 1)),
                    StringComparer.OrdinalIgnoreCase);
                if (!expected.SetEquals(observed))
                    return false;
                foreach (PayloadFile file in manifest.Files)
                {
                    string path = ResolveUnderRoot(root, file.Path);
                    var info = new FileInfo(path);
                    if (!info.Exists || info.Length != file.Size || !string.Equals(Sha256File(path), file.Sha256, StringComparison.Ordinal))
                        return false;
                }
                return true;
            }
            catch (IOException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
        }

        private static void ProtectDirectory(string path)
        {
            Directory.CreateDirectory(path);
            var security = new DirectorySecurity();
            security.SetAccessRuleProtection(true, false);
            var inheritance = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
            foreach (string sidValue in new[] { "S-1-5-18", "S-1-5-32-544" })
            {
                security.AddAccessRule(new FileSystemAccessRule(
                    new SecurityIdentifier(sidValue),
                    FileSystemRights.FullControl,
                    inheritance,
                    PropagationFlags.None,
                    AccessControlType.Allow));
            }
            Directory.SetAccessControl(path, security);
        }

        private static string ResolveUnderRoot(string root, string relative)
        {
            relative = NormalizeRelativePath(relative).Replace('/', Path.DirectorySeparatorChar);
            string normalizedRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            string resolved = Path.GetFullPath(Path.Combine(normalizedRoot, relative));
            if (!resolved.StartsWith(normalizedRoot, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("An embedded Libertix runtime path escapes its protected root.");
            return resolved;
        }

        private static void ValidateRelativePath(string value)
        {
            if (string.IsNullOrWhiteSpace(value) || Path.IsPathRooted(value))
                throw new InvalidDataException("An embedded Libertix runtime path is invalid.");
            string[] parts = value.Split(new[] { '\\', '/' }, StringSplitOptions.None);
            if (parts.Any(part =>
                string.IsNullOrWhiteSpace(part) ||
                part == "." ||
                part == ".." ||
                part.Contains(":") ||
                part.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0))
                throw new InvalidDataException("An embedded Libertix runtime path is invalid.");
        }

        private static string NormalizeRelativePath(string value)
        {
            ValidateRelativePath(value);
            return string.Join(
                "/",
                value.Split(new[] { '\\', '/' }, StringSplitOptions.None));
        }

        private static void CopyAndHash(
            Stream source,
            string destination,
            out long size,
            out string sha256)
        {
            size = 0;
            using (SHA256 algorithm = SHA256.Create())
            using (var target = new FileStream(
                destination,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                65536,
                FileOptions.WriteThrough))
            {
                var buffer = new byte[65536];
                int read;
                while ((read = source.Read(buffer, 0, buffer.Length)) > 0)
                {
                    target.Write(buffer, 0, read);
                    algorithm.TransformBlock(buffer, 0, read, buffer, 0);
                    size += read;
                }
                algorithm.TransformFinalBlock(Array.Empty<byte>(), 0, 0);
                target.Flush(true);
                sha256 = ToHex(algorithm.Hash);
            }
        }

        private static Stream RequireResource(Assembly assembly, string name)
        {
            Stream stream = assembly.GetManifestResourceStream(name);
            if (stream == null)
                throw new InvalidDataException("Required embedded Libertix resource is missing: " + name);
            return stream;
        }

        private static byte[] ComputeHash(Stream stream)
        {
            using (SHA256 algorithm = SHA256.Create())
                return algorithm.ComputeHash(stream);
        }

        private static string Sha256File(string path)
        {
            using (SHA256 algorithm = SHA256.Create())
            using (FileStream stream = File.OpenRead(path))
                return ToHex(algorithm.ComputeHash(stream));
        }

        private static string ToHex(byte[] value)
        {
            return BitConverter.ToString(value).Replace("-", string.Empty).ToLowerInvariant();
        }

        private static bool IsSha256(string value)
        {
            return value != null && value.Length == 64 && value.All(character =>
                (character >= '0' && character <= '9') || (character >= 'a' && character <= 'f'));
        }

        private static string QuoteArgument(string value)
        {
            if (value.Length != 0 && value.All(character => !char.IsWhiteSpace(character) && character != '"'))
                return value;
            var quoted = new StringBuilder("\"");
            int slashes = 0;
            foreach (char character in value)
            {
                if (character == '\\')
                {
                    slashes++;
                    continue;
                }
                if (character == '"')
                {
                    quoted.Append('\\', slashes * 2 + 1);
                    quoted.Append('"');
                    slashes = 0;
                    continue;
                }
                quoted.Append('\\', slashes);
                slashes = 0;
                quoted.Append(character);
            }
            quoted.Append('\\', slashes * 2);
            quoted.Append('"');
            return quoted.ToString();
        }
    }

    [DataContract]
    internal sealed class PayloadManifest
    {
        [DataMember(Name = "schemaVersion", IsRequired = true)] public int SchemaVersion { get; set; }
        [DataMember(Name = "files", IsRequired = true)] public PayloadFile[] Files { get; set; }
    }

    [DataContract]
    internal sealed class PayloadFile
    {
        [DataMember(Name = "path", IsRequired = true)] public string Path { get; set; }
        [DataMember(Name = "size", IsRequired = true)] public long Size { get; set; }
        [DataMember(Name = "sha256", IsRequired = true)] public string Sha256 { get; set; }
    }
}
