using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Security.Principal;
using Libertix.Security;

namespace Libertix.BootGuardian
{
    internal static class TrustedScripts
    {
        internal static void Verify(string[] arguments)
        {
            string[] prefix = { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File" };
            if (arguments.Length < prefix.Length + 1 ||
                !arguments.Take(prefix.Length).SequenceEqual(prefix, StringComparer.OrdinalIgnoreCase))
                throw new InvalidDataException("The hidden host only accepts a deployed PowerShell file.");

            string root = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            VerifyPayload(root, arguments[prefix.Length]);
        }

        internal static void VerifyPayload(string root, string script)
        {
            root = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar);
            script = Path.GetFullPath(script);
            if (!script.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("The PowerShell script is outside the hidden host payload.");

            // Logon pinning also runs without elevation; it cannot inspect private parent ACLs.
            using (var identity = WindowsIdentity.GetCurrent())
                if (new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator))
                    ProtectedFiles.RequireTree(root);
            VerifyFile(script);
            foreach (string file in Directory.GetFiles(root))
                VerifyCodeFile(file);
            string scripts = Path.Combine(root, "Scripts");
            if (Directory.Exists(scripts))
                foreach (string file in Directory.GetFiles(scripts, "*", SearchOption.AllDirectories))
                    VerifyCodeFile(file);
        }

        private static void VerifyCodeFile(string path)
        {
            string extension = Path.GetExtension(path);
            if (extension.Equals(".ps1", StringComparison.OrdinalIgnoreCase) ||
                extension.Equals(".psm1", StringComparison.OrdinalIgnoreCase) ||
                extension.Equals(".cs", StringComparison.OrdinalIgnoreCase))
                VerifyFile(path);
        }

        private static void VerifyFile(string path)
        {
            string name = Path.GetFileName(path);
            if (name.Equals("recover.ps1", StringComparison.OrdinalIgnoreCase))
                name = "libertix-recovery-guard.ps1";
            else if (name.Equals("mount-linux-readonly.ps1", StringComparison.OrdinalIgnoreCase))
                name = "libertix-configure-windows-share.ps1";

            Assembly assembly = Assembly.GetExecutingAssembly();
            string resourceName = assembly.GetManifestResourceNames().SingleOrDefault(value =>
                value.Equals("Libertix.TrustedScripts." + name, StringComparison.OrdinalIgnoreCase));
            if (resourceName == null)
                throw new InvalidDataException("The hidden host does not recognize this script: " + path);
            using (Stream expected = assembly.GetManifestResourceStream(resourceName))
            using (SHA256 sha = SHA256.Create())
            {
                string hash = BitConverter.ToString(sha.ComputeHash(expected)).Replace("-", "").ToLowerInvariant();
                if (Hashing.Sha256File(path) != hash)
                    throw new InvalidDataException("The deployed script differs from the hidden host build: " + path);
            }
        }
    }
}
