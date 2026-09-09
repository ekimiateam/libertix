using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

namespace Libertix.Native
{
    public static class WindowsSharingPaths
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(string name, uint access, uint share,
            IntPtr security, uint creation, uint flags, IntPtr template);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle,
            StringBuilder path, uint capacity, uint flags);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        private static extern int RegLoadAppKey(string path, out SafeRegistryHandle key,
            uint access, uint options, uint reserved);

        public static string ResolveDirectory(string path)
        {
            if (!Directory.Exists(path))
                throw new IOException("The shared Windows directory is unavailable: " + path);
            using (SafeFileHandle handle = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero))
            {
                if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                var buffer = new StringBuilder(32768);
                uint length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 1);
                if (length == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
                if (length >= buffer.Capacity) throw new IOException("Shared directory path is too long.");
                return buffer.ToString();
            }
        }

        private static Dictionary<string, string> ReadValues(RegistryKey root, string path)
        {
            var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            using (RegistryKey key = root.OpenSubKey(path, false))
            {
                if (key == null) return values;
                foreach (string name in key.GetValueNames())
                {
                    object value = key.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
                    if (value is string) values[name] = (string)value;
                }
            }
            return values;
        }

        private static Dictionary<string, string>[] ReadProfile(RegistryKey root)
        {
            return new[] {
                ReadValues(root, @"Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"),
                ReadValues(root, "Environment")
            };
        }

        public static Dictionary<string, string>[] ReadProfile(string sid, string profilePath)
        {
            using (RegistryKey loaded = Registry.Users.OpenSubKey(sid, false))
            {
                if (loaded != null) return ReadProfile(loaded);
            }
            string hivePath = Path.Combine(profilePath, "NTUSER.DAT");
            string temporary = Path.Combine(Path.GetTempPath(), "Libertix-profile-" + Guid.NewGuid().ToString("N"));
            var security = new DirectorySecurity();
            security.SetAccessRuleProtection(true, false);
            foreach (var identity in new[] {
                new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
                new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null)
            })
                security.AddAccessRule(new FileSystemAccessRule(identity, FileSystemRights.FullControl,
                    InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
                    PropagationFlags.None, AccessControlType.Allow));
            Directory.CreateDirectory(temporary, security);
            try
            {
                string snapshot = Path.Combine(temporary, "NTUSER.DAT");
                // RegLoadAppKey requires an exclusive open and can create or recover a hive.
                // Load only a private copy, never the user's original registry file.
                using (var existing = new FileStream(hivePath, FileMode.Open, FileAccess.Read, FileShare.Read))
                using (var copy = new FileStream(snapshot, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    if (existing.Length == 0 || existing.Length > 256L * 1024 * 1024)
                        throw new IOException("Windows profile registry has an unsupported size.");
                    existing.CopyTo(copy);
                }
                SafeRegistryHandle handle;
                int error = RegLoadAppKey(snapshot, out handle, 0x20019, 1, 0);
                if (error != 0)
                {
                    if (handle != null) handle.Dispose();
                    throw new Win32Exception(error, "Cannot read the offline Windows profile registry (Win32 " + error + ").");
                }
                using (handle)
                using (RegistryKey root = RegistryKey.FromHandle(handle)) return ReadProfile(root);
            }
            finally
            {
                Directory.Delete(temporary, true);
            }
        }
    }
}
