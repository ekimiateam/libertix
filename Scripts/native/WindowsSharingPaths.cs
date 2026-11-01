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

        private static readonly IntPtr UsersRoot = new IntPtr(unchecked((int)0x80000003));

        [StructLayout(LayoutKind.Sequential)]
        private struct Luid { public uint Low; public int High; }

        [StructLayout(LayoutKind.Sequential)]
        private struct TokenPrivilege
        {
            public uint Count;
            public Luid Id;
            public uint Attributes;
        }

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        private static extern int RegLoadKey(IntPtr root, string name, string path);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        private static extern int RegUnLoadKey(IntPtr root, string name);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool LookupPrivilegeValue(string system, string name, out Luid id);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool AdjustTokenPrivileges(SafeAccessTokenHandle token, bool disableAll,
            ref TokenPrivilege value, uint length, out TokenPrivilege previous, out uint returnedLength);

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
                // Recovery may replay hive logs. Keep every write on private copies.
                CopyProfileFile(hivePath, snapshot);
                foreach (string suffix in new[] { ".LOG1", ".LOG2" })
                    if (File.Exists(hivePath + suffix)) CopyProfileFile(hivePath + suffix, snapshot + suffix, true);
                return ReadOfflineProfile(snapshot);
            }
            finally
            {
                Directory.Delete(temporary, true);
            }
        }

        private static void CopyProfileFile(string source, string destination, bool allowEmpty = false)
        {
            using (var existing = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (var copy = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                if ((!allowEmpty && existing.Length == 0) || existing.Length > 256L * 1024 * 1024)
                    throw new IOException("Windows profile registry has an unsupported size.");
                existing.CopyTo(copy);
            }
        }

        private static TokenPrivilege SetPrivilege(SafeAccessTokenHandle token, TokenPrivilege value)
        {
            TokenPrivilege previous;
            uint length;
            if (!AdjustTokenPrivileges(token, false, ref value, (uint)Marshal.SizeOf(typeof(TokenPrivilege)),
                out previous, out length))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            int error = Marshal.GetLastWin32Error();
            if (error != 0) throw new Win32Exception(error);
            return previous;
        }

        private static Dictionary<string, string>[] ReadOfflineProfile(string snapshot)
        {
            string name = "Libertix-profile-" + Guid.NewGuid().ToString("N");
            using (var identity = WindowsIdentity.GetCurrent(TokenAccessLevels.AdjustPrivileges | TokenAccessLevels.Query))
            {
                var previous = new List<TokenPrivilege>();
                try
                {
                    foreach (string privilege in new[] { "SeBackupPrivilege", "SeRestorePrivilege" })
                    {
                        Luid id;
                        if (!LookupPrivilegeValue(null, privilege, out id))
                            throw new Win32Exception(Marshal.GetLastWin32Error());
                        previous.Add(SetPrivilege(identity.AccessToken,
                            new TokenPrivilege { Count = 1, Id = id, Attributes = 2 }));
                    }
                    // A normal user hive can contain different key permissions, which
                    // RegLoadAppKey explicitly does not support.
                    return ReadPrivateHive(name, snapshot);
                }
                finally
                {
                    previous.Reverse();
                    foreach (TokenPrivilege privilege in previous) SetPrivilege(identity.AccessToken, privilege);
                }
            }
        }

        private static Dictionary<string, string>[] ReadPrivateHive(string name, string snapshot)
        {
            int error = RegLoadKey(UsersRoot, name, snapshot);
            if (error != 0)
                throw new Win32Exception(error, "Cannot read the offline Windows profile registry (Win32 " + error + ").");
            try
            {
                using (RegistryKey root = Registry.Users.OpenSubKey(name, false))
                {
                    if (root == null) throw new IOException("The private profile registry is unavailable.");
                    return ReadProfile(root);
                }
            }
            finally
            {
                error = RegUnLoadKey(UsersRoot, name);
                if (error != 0) throw new Win32Exception(error, "Cannot unload the private Windows profile registry.");
            }
        }
    }
}
