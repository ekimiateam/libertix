using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.AccessControl;
using System.Security.Principal;

namespace Libertix.Security
{
    public static class ProtectedFiles
    {
        internal static Func<string, bool> ConfirmPermissions { get; set; }
        private const FileSystemRights ReplacementRights = FileSystemRights.Delete |
            FileSystemRights.DeleteSubdirectoriesAndFiles | FileSystemRights.ChangePermissions |
            FileSystemRights.TakeOwnership;
        private const FileSystemRights WriteRights = ReplacementRights | FileSystemRights.Write;

        public static void CreateDirectory(string path, bool readableByUsers = false,
            Func<string, bool> confirmUnsafePermissions = null)
        {
            path = Path.GetFullPath(path);
            string parent = Path.GetDirectoryName(path);
            if (!Directory.Exists(path))
            {
                if (parent == null)
                    throw new IOException("A protected directory must be on an existing volume.");
                if (!Directory.Exists(parent))
                    CreateDirectory(parent, readableByUsers, confirmUnsafePermissions);
                RequireAncestors(parent, confirmUnsafePermissions: confirmUnsafePermissions);
                // Supply the ACL at creation: an inherited writable interval is unsafe.
                Directory.CreateDirectory(path, DirectorySecurity(readableByUsers));
            }
            string administrator = CurrentAdministrator();
            RequireTree(path, administrator, confirmUnsafePermissions);
            Directory.SetAccessControl(path, DirectorySecurity(readableByUsers));
            foreach (string child in Directory.GetFileSystemEntries(path))
                ProtectTree(child, readableByUsers);
        }

        internal static bool RepairDirectory(string path, bool readableByUsers = false,
            Func<string, bool> confirmUnsafePermissions = null)
        {
            path = Path.GetFullPath(path);
            var warnings = new List<string>();
            Func<string, bool> collect = warning => { warnings.Add(warning); return true; };
            if (!Directory.Exists(path))
                CreateDirectory(path, readableByUsers, collect);
            RequireAncestors(Path.GetDirectoryName(path), confirmUnsafePermissions: collect);
            var contentWarnings = new List<string>();
            InspectTree(path, null, warning => { contentWarnings.Add(warning); return true; });

            // A repaired executable cache still needs fresh, verified files: old handles survive ACL changes.
            bool untrustedContents = contentWarnings.Count != 0;
            try
            {
                ProtectTree(path, readableByUsers);
            }
            catch (UnauthorizedAccessException error)
            {
                warnings.Add("Could not protect a Libertix directory: " + path + " | error=" + error.Message);
            }
            catch (IOException error)
            {
                warnings.Add("Could not protect a Libertix directory: " + path + " | error=" + error.Message);
            }
            InspectTree(path, null, collect);
            ConfirmWarnings(warnings, confirmUnsafePermissions);
            return untrustedContents;
        }

        internal static void RequireRecoveryTree(string path)
        {
            RequireTree(path, CurrentAdministrator());
        }

        internal static void RequireTree(string path, string administrator = null,
            Func<string, bool> confirmUnsafePermissions = null)
        {
            var warnings = new List<string>();
            Func<string, bool> collect = warning => { warnings.Add(warning); return true; };
            RequireAncestors(Path.GetDirectoryName(Path.GetFullPath(path)), administrator, collect);
            InspectTree(path, administrator, collect);
            ConfirmWarnings(warnings, confirmUnsafePermissions);
        }

        private static void InspectTree(string path, string administrator, Func<string, bool> collect)
        {
            RequireItem(path, WriteRights, administrator, collect);
            if (!Directory.Exists(path))
                return;
            foreach (string child in Directory.GetFileSystemEntries(path))
                InspectTree(child, administrator, collect);
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

        private static void RequireAncestors(string path, string administrator = null,
            Func<string, bool> confirmUnsafePermissions = null)
        {
            for (string current = path; current != null; current = Path.GetDirectoryName(current))
                RequireItem(current, AncestorRights(current), administrator, confirmUnsafePermissions);
        }

        internal static FileSystemRights AncestorRights(string path)
        {
            // DELETE on the volume root is not permission to delete its children.
            return Path.GetDirectoryName(Path.GetFullPath(path)) == null
                ? ReplacementRights & ~FileSystemRights.Delete : ReplacementRights;
        }

        private static void ConfirmWarnings(IEnumerable<string> warnings, Func<string, bool> confirm)
        {
            string combined = string.Join(Environment.NewLine + Environment.NewLine, warnings.Distinct());
            if (combined.Length != 0)
                RequireConsent(combined, confirm);
        }

        private static void RequireItem(string path, FileSystemRights forbidden, string administrator = null,
            Func<string, bool> confirmUnsafePermissions = null)
        {
            FileAttributes attributes = File.GetAttributes(path);
            if ((attributes & FileAttributes.ReparsePoint) != 0)
                throw new UnauthorizedAccessException("A privileged path contains a reparse point: " + path);
            FileSystemSecurity security = (attributes & FileAttributes.Directory) != 0
                ? (FileSystemSecurity)Directory.GetAccessControl(path)
                : File.GetAccessControl(path);
            if (!IsTrusted(security.GetOwner(typeof(SecurityIdentifier)), administrator))
                RequireConsent("A privileged path has an untrusted owner: " + path +
                    " | owner=" + security.GetOwner(typeof(SecurityIdentifier)).Value, confirmUnsafePermissions);
            // Consent does not establish content integrity or revoke an earlier writer's open handles.
            var descriptor = new RawSecurityDescriptor(security.GetSecurityDescriptorBinaryForm(), 0);
            if (descriptor.DiscretionaryAcl == null)
            {
                RequireConsent("A privileged path has no access restrictions: " + path, confirmUnsafePermissions);
                return;
            }
            var inspected = new HashSet<SecurityIdentifier>();
            foreach (GenericAce entry in descriptor.DiscretionaryAcl)
            {
                var rule = entry as CommonAce;
                if (rule == null || rule.IsCallback ||
                    (rule.AceQualifier != AceQualifier.AccessAllowed && rule.AceQualifier != AceQualifier.AccessDenied))
                {
                    RequireConsent("A privileged path has permissions that cannot be evaluated: " + path,
                        confirmUnsafePermissions);
                    continue;
                }
                if (rule.AceQualifier != AceQualifier.AccessAllowed ||
                    (rule.AceFlags & AceFlags.InheritOnly) != 0 ||
                    IsTrusted(rule.SecurityIdentifier, administrator) || IsCapability(rule.SecurityIdentifier) ||
                    !inspected.Add(rule.SecurityIdentifier))
                    continue;
                FileSystemRights granted = GrantedRights(descriptor.DiscretionaryAcl, rule.SecurityIdentifier, forbidden);
                if (granted != 0)
                    RequireConsent("A privileged path may be writable by an untrusted account: " + path +
                        " | identity=" + rule.SecurityIdentifier.Value + " | rights=" + granted,
                        confirmUnsafePermissions);
            }
        }

        private static void RequireConsent(string warning, Func<string, bool> confirm)
        {
            confirm = confirm ?? ConfirmPermissions;
            if (confirm == null)
                throw new UnauthorizedAccessException(warning);
            if (!confirm(warning))
                throw new OperationCanceledException(warning);
        }

        private static bool IsCapability(SecurityIdentifier identity)
        {
            // Capabilities restrict an AppContainer in addition to its user's rights;
            // they cannot independently grant that user access to privileged files.
            return identity.Value.StartsWith("S-1-15-3-", StringComparison.Ordinal);
        }

        internal static FileSystemRights GrantedRights(RawAcl acl, SecurityIdentifier identity,
            FileSystemRights requested)
        {
            FileSystemRights remaining = requested;
            FileSystemRights granted = 0;
            foreach (GenericAce entry in acl)
            {
                var rule = entry as CommonAce;
                if (rule == null || rule.IsCallback || (rule.AceFlags & AceFlags.InheritOnly) != 0 ||
                    (rule.SecurityIdentifier != identity &&
                     !rule.SecurityIdentifier.IsWellKnown(WellKnownSidType.WorldSid)))
                    continue;
                FileSystemRights rights = ExpandRights(rule.AccessMask) & remaining;
                if (rule.AceQualifier == AceQualifier.AccessAllowed)
                    granted |= rights;
                if (rule.AceQualifier == AceQualifier.AccessAllowed || rule.AceQualifier == AceQualifier.AccessDenied)
                    remaining &= ~rights;
            }
            // Only unconditional denies covering this entire principal prove safety.
            // A deny for one user must not hide a grant to the rest of a group.
            return granted;
        }

        private static FileSystemRights ExpandRights(int mask)
        {
            FileSystemRights rights = (FileSystemRights)(mask & 0x0fffffff);
            if ((mask & unchecked((int)0x80000000)) != 0) rights |= FileSystemRights.Read;
            if ((mask & 0x40000000) != 0) rights |= FileSystemRights.Write;
            if ((mask & 0x20000000) != 0) rights |= FileSystemRights.ReadAndExecute;
            if ((mask & 0x10000000) != 0) rights |= FileSystemRights.FullControl;
            return rights;
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

        private static void ProtectTree(string path, bool readableByUsers)
        {
            bool directory = Directory.Exists(path);
            FileSystemSecurity expected;
            if (directory)
                expected = DirectorySecurity(readableByUsers);
            else
            {
                var security = new FileSecurity();
                security.SetOwner(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null));
                security.SetAccessRuleProtection(true, false);
                foreach (var sid in new[] { WellKnownSidType.LocalSystemSid, WellKnownSidType.BuiltinAdministratorsSid })
                    security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid, null),
                        FileSystemRights.FullControl, AccessControlType.Allow));
                if (readableByUsers)
                    security.AddAccessRule(new FileSystemAccessRule(
                        new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null),
                        FileSystemRights.ReadAndExecute, AccessControlType.Allow));
                expected = security;
            }
            FileSystemSecurity current = directory
                ? (FileSystemSecurity)Directory.GetAccessControl(path) : File.GetAccessControl(path);
            if (!SamePermissions(current, expected))
            {
                if (directory)
                    Directory.SetAccessControl(path, (DirectorySecurity)expected);
                else
                    File.SetAccessControl(path, (FileSecurity)expected);
            }
            if (directory)
                foreach (string child in Directory.GetFileSystemEntries(path))
                    ProtectTree(child, readableByUsers);
        }

        private static bool SamePermissions(FileSystemSecurity current, FileSystemSecurity expected)
        {
            var actual = new RawSecurityDescriptor(current.GetSecurityDescriptorBinaryForm(), 0);
            var required = new RawSecurityDescriptor(expected.GetSecurityDescriptorBinaryForm(), 0);
            if (actual.DiscretionaryAcl == null)
                return false;
            var actualAcl = new byte[actual.DiscretionaryAcl.BinaryLength];
            var requiredAcl = new byte[required.DiscretionaryAcl.BinaryLength];
            actual.DiscretionaryAcl.GetBinaryForm(actualAcl, 0);
            required.DiscretionaryAcl.GetBinaryForm(requiredAcl, 0);
            return actual.Owner == required.Owner && current.AreAccessRulesProtected == expected.AreAccessRulesProtected &&
                actualAcl.SequenceEqual(requiredAcl);
        }
    }
}
