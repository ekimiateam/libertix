using System;
using System.IO;
using System.Linq;
using System.Security.AccessControl;
using System.Security.Principal;

namespace Libertix.Security
{
    public static class ProtectedFiles
    {
        private const FileSystemRights ReplacementRights = FileSystemRights.Delete |
            FileSystemRights.DeleteSubdirectoriesAndFiles | FileSystemRights.ChangePermissions |
            FileSystemRights.TakeOwnership;
        private const FileSystemRights WriteRights = ReplacementRights | FileSystemRights.Write;

        public static void CreateDirectory(string path, bool readableByUsers = false)
        {
            path = Path.GetFullPath(path);
            string parent = Path.GetDirectoryName(path);
            if (!Directory.Exists(path))
            {
                if (parent == null)
                    throw new IOException("A protected directory must be on an existing volume.");
                if (!Directory.Exists(parent))
                    CreateDirectory(parent, readableByUsers);
                RequireAncestors(parent);
                // Supply the ACL at creation: an inherited writable interval is unsafe.
                Directory.CreateDirectory(path, DirectorySecurity(readableByUsers));
            }
            string administrator = CurrentAdministrator();
            RequireTree(path, administrator);
            ProtectLegacyOwnership(path, administrator, readableByUsers);
            Directory.SetAccessControl(path, DirectorySecurity(readableByUsers));
        }

        internal static void RequireRecoveryTree(string path)
        {
            RequireTree(path, CurrentAdministrator());
        }

        internal static void RequireTree(string path, string administrator = null)
        {
            RequireAncestors(Path.GetDirectoryName(Path.GetFullPath(path)), administrator);
            RequireItem(path, WriteRights, administrator);
            foreach (string child in Directory.GetFileSystemEntries(path))
            {
                RequireItem(child, WriteRights, administrator);
                if (Directory.Exists(child))
                    RequireTree(child, administrator);
            }
        }

        internal static void RequireDirectory(string path)
        {
            RequireAncestors(Path.GetDirectoryName(Path.GetFullPath(path)));
            RequireItem(path, WriteRights);
        }

        internal static void RequireFile(string path)
        {
            RequireAncestors(Path.GetDirectoryName(Path.GetFullPath(path)));
            RequireItem(path, WriteRights);
        }

        private static DirectorySecurity DirectorySecurity(bool readableByUsers)
        {
            var security = new DirectorySecurity();
            security.SetAccessRuleProtection(true, false);
            security.SetOwner(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null));
            var inheritance = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
            foreach (var sid in new[] { WellKnownSidType.LocalSystemSid, WellKnownSidType.BuiltinAdministratorsSid })
                security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid, null),
                    FileSystemRights.FullControl, inheritance, PropagationFlags.None, AccessControlType.Allow));
            if (readableByUsers)
                security.AddAccessRule(new FileSystemAccessRule(
                    new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null),
                    FileSystemRights.ReadAndExecute, inheritance, PropagationFlags.None, AccessControlType.Allow));
            return security;
        }

        private static void RequireAncestors(string path, string administrator = null)
        {
            for (string current = path; current != null; current = Path.GetDirectoryName(current))
                RequireItem(current, ReplacementRights, administrator);
        }

        private static void RequireItem(string path, FileSystemRights forbidden, string administrator = null)
        {
            FileAttributes attributes = File.GetAttributes(path);
            if ((attributes & FileAttributes.ReparsePoint) != 0)
                throw new UnauthorizedAccessException("A privileged path contains a reparse point: " + path);
            FileSystemSecurity security = (attributes & FileAttributes.Directory) != 0
                ? (FileSystemSecurity)Directory.GetAccessControl(path)
                : File.GetAccessControl(path);
            if (!IsTrusted(security.GetOwner(typeof(SecurityIdentifier)), administrator))
                throw new UnauthorizedAccessException("A privileged path has an untrusted owner: " + path);
            // Do not adopt an existing writable object: an earlier writer may still hold it open.
            var descriptor = new RawSecurityDescriptor(security.GetSecurityDescriptorBinaryForm(), 0);
            if (descriptor.DiscretionaryAcl == null)
                throw new UnauthorizedAccessException("A privileged path has no access restrictions: " + path);
            foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
            {
                if (rule.AccessControlType == AccessControlType.Allow &&
                    (rule.PropagationFlags & PropagationFlags.InheritOnly) == 0 &&
                    !IsTrusted(rule.IdentityReference, administrator) && (rule.FileSystemRights & forbidden) != 0)
                    throw new UnauthorizedAccessException("A privileged path is writable by an untrusted account: " + path);
            }
        }

        private static bool IsTrusted(IdentityReference identity, string administrator = null)
        {
            string sid = identity.Value;
            return sid == administrator || sid == "S-1-5-18" || sid == "S-1-5-32-544" ||
                sid == "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464";
        }

        private static string CurrentAdministrator()
        {
            using (var identity = WindowsIdentity.GetCurrent())
                return !identity.User.IsWellKnown(WellKnownSidType.LocalSystemSid) &&
                    new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator)
                    ? identity.User.Value : null;
        }

        private static void ProtectLegacyOwnership(string path, string administrator, bool readableByUsers)
        {
            if (administrator == null)
                return;
            bool directory = Directory.Exists(path);
            FileSystemSecurity security = directory
                ? (FileSystemSecurity)Directory.GetAccessControl(path) : File.GetAccessControl(path);
            // Older recovery archives granted their installing administrator an explicit SID.
            // Migrate only that authenticated administrator, never an arbitrary previous owner.
            if (security.GetOwner(typeof(SecurityIdentifier)).Value == administrator ||
                security.GetAccessRules(true, true, typeof(SecurityIdentifier))
                    .Cast<FileSystemAccessRule>().Any(rule => rule.IdentityReference.Value == administrator))
            {
                if (directory)
                    Directory.SetAccessControl(path, DirectorySecurity(readableByUsers));
                else
                {
                    var fileSecurity = new FileSecurity();
                    fileSecurity.SetOwner(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null));
                    fileSecurity.SetAccessRuleProtection(false, false);
                    File.SetAccessControl(path, fileSecurity);
                }
            }
            if (directory)
                foreach (string child in Directory.GetFileSystemEntries(path))
                    ProtectLegacyOwnership(child, administrator, readableByUsers);
        }
    }
}
