extern alias Guardian;

using System;
using System.Diagnostics;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading;
using Libertix.BootGuardian;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using ProtectedFiles = Guardian::Libertix.Security.ProtectedFiles;
using Report = Guardian::Libertix.Support.SupportReport;

namespace Libertix.Tests
{
    [TestClass]
    public sealed class BootGuardianTests
    {
        [DataTestMethod]
        [DataRow("password=do-not-publish", "do-not-publish")]
        [DataRow("Authorization: Bearer private-token", "private-token")]
        [DataRow("--password \"secret phrase\"", "secret phrase")]
        [DataRow("<keyMaterial>wifi-secret</keyMaterial>", "wifi-secret")]
        [DataRow("https://person:private-value@example.org/file.iso", "private-value")]
        [DataRow("ghp_1234567890abcdef", "1234567890abcdef")]
        public void SupportReportHidesSecrets(string input, string secret)
        {
            Assert.IsFalse(Report.Redact(input).Contains(secret));
            StringAssert.Contains(Report.Redact("download failed: HTTP 503"), "HTTP 503");
        }

        [TestMethod]
        public void SupportReportIncludesLogsButNotPlans()
        {
            string root = Path.Combine(Path.GetTempPath(), "libertix-report-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            try
            {
                File.WriteAllText(Path.Combine(root, "boot-guardian.log"), "repair failed: test evidence\npassword=hidden-value");
                File.WriteAllText(Path.Combine(root, "installation-plan.json"), "must-not-be-copied");
                string report = Report.Create("installation", "ERROR test failure", new[] { root });
                StringAssert.Contains(report, "ERROR test failure");
                StringAssert.Contains(report, "repair failed: test evidence");
                Assert.IsFalse(report.Contains("hidden-value"));
                Assert.IsFalse(report.Contains("must-not-be-copied"));
            }
            finally { Directory.Delete(root, true); }
        }

        [DataTestMethod]
        [DataRow("en")]
        [DataRow("fr")]
        [DataRow("es")]
        [DataRow("ko")]
        public void SupportButtonsAreTranslated(string language)
        {
            var labels = Report.Labels(language);
            foreach (string key in new[] { "copy", "issue", "copied", "review", "failed", "close" })
                Assert.IsFalse(string.IsNullOrWhiteSpace(labels[key]), language + ":" + key);
            StringAssert.EndsWith(Report.IssueUrl, "template=bug_report.md");
        }

        [DataTestMethod]
        [DataRow("libertix-recovery-guard.ps1", "recover.ps1")]
        [DataRow("libertix-configure-windows-share.ps1", "mount-linux-readonly.ps1")]
        [DataRow("libertix-uefi-recovery-agent.ps1", "Scripts\\libertix-uefi-recovery-agent.ps1")]
        public void HiddenHostAcceptsOriginalCodeAndRejectsAnAlteredModule(string source, string relative)
        {
            string root = NewProtectedDirectory();
            try
            {
                string script = WriteEmbeddedScript(root, relative, source);
                string module = WriteEmbeddedScript(root, "Libertix.Process.psm1", "Libertix.Process.psm1");
                TrustedScripts.VerifyPayload(root, script);

                File.AppendAllText(module, "\r\n# modified module\r\n");
                Assert.ThrowsException<InvalidDataException>(() => TrustedScripts.VerifyPayload(root, script));
                WriteEmbeddedScript(root, "Libertix.Process.psm1", "Libertix.Process.psm1");
                File.AppendAllText(script, "\r\n# modified entry point\r\n");
                Assert.ThrowsException<InvalidDataException>(() => TrustedScripts.VerifyPayload(root, script));
            }
            finally { Directory.Delete(root, true); }
        }

        [TestMethod]
        public void HiddenHostRejectsUnknownCodeAndOutsideScripts()
        {
            string root = NewProtectedDirectory();
            try
            {
                string script = WriteEmbeddedScript(root, "recover.ps1", "libertix-recovery-guard.ps1");
                Assert.ThrowsException<InvalidDataException>(() =>
                    TrustedScripts.VerifyPayload(root, Path.Combine(root, "..", "recover.ps1")));
                File.WriteAllText(Path.Combine(root, "unrecognized.psm1"), "# unexpected code");
                Assert.ThrowsException<InvalidDataException>(() => TrustedScripts.VerifyPayload(root, script));
                Assert.ThrowsException<InvalidDataException>(() =>
                    TrustedScripts.Verify(new[] { "-NoProfile", "-Command", "exit 0" }));
            }
            finally { Directory.Delete(root, true); }
        }

        [TestMethod]
        public void ProtectedPayloadRejectsUserWriteAccessWithoutChangingPermissions()
        {
            string root = NewProtectedDirectory();
            try
            {
                string file = Path.Combine(root, "config.json");
                File.WriteAllText(file, "{}");
                ProtectedFiles.RequireTree(root);
                FileSecurity security = File.GetAccessControl(file);
                security.AddAccessRule(new FileSystemAccessRule(
                    new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null),
                    FileSystemRights.Modify, AccessControlType.Allow));
                File.SetAccessControl(file, security);
                string before = File.GetAccessControl(file).GetSecurityDescriptorSddlForm(AccessControlSections.All);

                Assert.ThrowsException<UnauthorizedAccessException>(() => ProtectedFiles.CreateDirectory(root, true));
                Assert.AreEqual(before, File.GetAccessControl(file).GetSecurityDescriptorSddlForm(AccessControlSections.All));
                Assert.AreEqual("{}", File.ReadAllText(file));
            }
            finally { Directory.Delete(root, true); }
        }

        private static string NewProtectedDirectory()
        {
            // Windows Temp allows untrusted writes on CI runners and is not a protected parent.
            string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                "libertix-security-test-" + Guid.NewGuid().ToString("N"));
            ProtectedFiles.CreateDirectory(root, true);
            Assert.AreEqual("S-1-5-32-544", Directory.GetAccessControl(root)
                .GetOwner(typeof(SecurityIdentifier)).Value);
            return root;
        }

        [DataTestMethod]
        [DataRow("D:(D;;0x2;;;BU)(A;;GW;;;BU)", false)]
        [DataRow("D:(A;;GW;;;BU)(D;;0x2;;;BU)", true)]
        [DataRow("D:(D;;0x2;;;WD)(A;;GW;;;BU)", false)]
        [DataRow("D:(D;;0x2;;;S-1-5-21-1-2-3-1001)(A;;GW;;;BU)", true)]
        [DataRow("D:(A;OICIIO;GA;;;BU)", false)]
        public void PermissionChecksRespectApplicableDenies(string sddl, bool writable)
        {
            var descriptor = new RawSecurityDescriptor(sddl);
            var users = new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null);
            Assert.AreEqual(writable ? FileSystemRights.WriteData : 0,
                ProtectedFiles.GrantedRights(descriptor.DiscretionaryAcl, users, FileSystemRights.WriteData));
        }

        [TestMethod]
        public void CapabilitiesDoNotAuthorizeOrdinaryUsers()
        {
            string root = NewProtectedDirectory();
            try
            {
                DirectorySecurity security = Directory.GetAccessControl(root);
                security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(
                    "S-1-15-3-65536-1888954469-739942743-1668119174-2468466756-4239452838-1296943325-355587736-700089176"),
                    FileSystemRights.FullControl, AccessControlType.Allow));
                Directory.SetAccessControl(root, security);
                ProtectedFiles.RequireTree(root);

                security.AddAccessRule(new FileSystemAccessRule(
                    new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null),
                    FileSystemRights.DeleteSubdirectoriesAndFiles, AccessControlType.Allow));
                Directory.SetAccessControl(root, security);
                var error = Assert.ThrowsException<UnauthorizedAccessException>(() => ProtectedFiles.RequireTree(root));
                StringAssert.Contains(error.Message, "identity=S-1-5-32-545");
                StringAssert.Contains(error.Message, "DeleteSubdirectoriesAndFiles");
            }
            finally { Directory.Delete(root, true); }
        }

        [TestMethod]
        public void PermissionConsentIsExplicitAndNotPersistent()
        {
            string root = NewProtectedDirectory();
            try
            {
                DirectorySecurity security = Directory.GetAccessControl(root);
                security.AddAccessRule(new FileSystemAccessRule(
                    new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null),
                    FileSystemRights.WriteData, AccessControlType.Allow));
                Directory.SetAccessControl(root, security);
                Assert.ThrowsException<OperationCanceledException>(() =>
                    ProtectedFiles.RequireTree(root, confirmUnsafePermissions: warning => false));
                int confirmations = 0;
                ProtectedFiles.RequireTree(root, confirmUnsafePermissions: warning =>
                {
                    StringAssert.Contains(warning, root);
                    confirmations++;
                    return true;
                });
                Assert.AreEqual(1, confirmations);
                Assert.ThrowsException<UnauthorizedAccessException>(() => ProtectedFiles.RequireTree(root));
            }
            finally { Directory.Delete(root, true); }
        }

        [TestMethod]
        public void RepairsExistingPermissionsAfterConsent()
        {
            string root = NewProtectedDirectory();
            try
            {
                string parent = Path.GetDirectoryName(root);
                string before = Directory.GetAccessControl(parent)
                    .GetSecurityDescriptorSddlForm(AccessControlSections.Access | AccessControlSections.Owner);
                string child = Path.Combine(root, "existing");
                Directory.CreateDirectory(child);
                string file = Path.Combine(child, "config.json");
                File.WriteAllText(file, "{}");
                FileSecurity security = File.GetAccessControl(file);
                security.SetAccessRuleProtection(true, true);
                security.AddAccessRule(new FileSystemAccessRule(
                    new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null),
                    FileSystemRights.Modify, AccessControlType.Allow));
                File.SetAccessControl(file, security);
                int confirmations = 0;

                ProtectedFiles.CreateDirectory(root, true, warning =>
                {
                    confirmations++;
                    return true;
                });

                Assert.IsTrue(confirmations > 0);
                ProtectedFiles.RequireTree(root);
                Assert.IsTrue(File.GetAccessControl(file).AreAccessRulesProtected);
                Assert.AreEqual("S-1-5-32-544", File.GetAccessControl(file)
                    .GetOwner(typeof(SecurityIdentifier)).Value);
                Assert.AreEqual("{}", File.ReadAllText(file));
                Assert.AreEqual(before, Directory.GetAccessControl(parent)
                    .GetSecurityDescriptorSddlForm(AccessControlSections.Access | AccessControlSections.Owner));
            }
            finally { Directory.Delete(root, true); }
        }

        [TestMethod]
        public void ProtectedDirectoryRejectsJunctionsWithoutTouchingTheirTarget()
        {
            string root = NewProtectedDirectory();
            string junction = Path.Combine(root, "junction");
            try
            {
                string target = Path.Combine(root, "target");
                Directory.CreateDirectory(target);
                string witness = Path.Combine(target, "witness.txt");
                File.WriteAllText(witness, "unchanged");
                using (var command = Process.Start(new ProcessStartInfo
                {
                    FileName = Path.Combine(Environment.SystemDirectory, "cmd.exe"),
                    Arguments = "/c mklink /J \"" + junction + "\" \"" + target + "\"",
                    UseShellExecute = false,
                    CreateNoWindow = true
                }))
                {
                    Assert.IsTrue(command.WaitForExit(10000), "The test junction must be created promptly.");
                    Assert.AreEqual(0, command.ExitCode);
                }
                Assert.ThrowsException<UnauthorizedAccessException>(() => ProtectedFiles.CreateDirectory(junction));
                Assert.ThrowsException<UnauthorizedAccessException>(() => ProtectedFiles.RepairDirectory(junction));
                Assert.ThrowsException<UnauthorizedAccessException>(() => ProtectedFiles.RepairDirectory(root));
                Assert.ThrowsException<UnauthorizedAccessException>(() => ProtectedFiles.RequireTree(root));
                Assert.AreEqual("unchanged", File.ReadAllText(witness));
            }
            finally
            {
                if (Directory.Exists(junction)) Directory.Delete(junction);
                Directory.Delete(root, true);
            }
        }

        [TestMethod]
        public void RepairsOwnedDirectoryBeforeWarning()
        {
            string root = NewProtectedDirectory();
            try
            {
                string parent = Path.GetDirectoryName(root);
                string parentPermissions = Directory.GetAccessControl(parent)
                    .GetSecurityDescriptorSddlForm(AccessControlSections.Owner | AccessControlSections.Access);
                DirectorySecurity directoryPermissions = Directory.GetAccessControl(root);
                directoryPermissions.AddAccessRule(new FileSystemAccessRule(
                    new SecurityIdentifier(WellKnownSidType.AuthenticatedUserSid, null),
                    FileSystemRights.Modify, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
                    PropagationFlags.None, AccessControlType.Allow));
                Directory.SetAccessControl(root, directoryPermissions);
                string file = Path.Combine(root, "existing.log");
                File.WriteAllText(file, "preserved");
                FileSecurity permissions = File.GetAccessControl(file);
                permissions.AddAccessRule(new FileSystemAccessRule(
                    new SecurityIdentifier(WellKnownSidType.AuthenticatedUserSid, null),
                    FileSystemRights.Modify, AccessControlType.Allow));
                File.SetAccessControl(file, permissions);

                bool repaired = ProtectedFiles.RepairDirectory(root, confirmUnsafePermissions: warning =>
                {
                    Assert.Fail("Repairable permissions must not require consent: " + warning);
                    return false;
                });

                Assert.IsTrue(repaired);
                ProtectedFiles.RequireTree(root);
                Assert.AreEqual("preserved", File.ReadAllText(file));
                Assert.AreEqual(parentPermissions, Directory.GetAccessControl(parent)
                    .GetSecurityDescriptorSddlForm(AccessControlSections.Owner | AccessControlSections.Access));
                var descriptor = new RawSecurityDescriptor(File.GetAccessControl(file)
                    .GetSecurityDescriptorBinaryForm(), 0);
                Assert.AreEqual((FileSystemRights)0, ProtectedFiles.GrantedRights(
                    descriptor.DiscretionaryAcl,
                    new SecurityIdentifier(WellKnownSidType.AuthenticatedUserSid, null),
                    FileSystemRights.FullControl));
                Assert.IsFalse(ProtectedFiles.RepairDirectory(root));
            }
            finally { Directory.Delete(root, true); }
        }

        [TestMethod]
        public void GroupsPermissionWarnings()
        {
            string root = NewProtectedDirectory();
            try
            {
                foreach (string name in new[] { "first.log", "second.log" })
                {
                    string file = Path.Combine(root, name);
                    File.WriteAllText(file, "preserved");
                    FileSecurity permissions = File.GetAccessControl(file);
                    permissions.AddAccessRule(new FileSystemAccessRule(
                        new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null),
                        FileSystemRights.Modify, AccessControlType.Allow));
                    File.SetAccessControl(file, permissions);
                }
                int confirmations = 0;
                ProtectedFiles.RequireTree(root, confirmUnsafePermissions: warning =>
                {
                    confirmations++;
                    StringAssert.Contains(warning, "first.log");
                    StringAssert.Contains(warning, "second.log");
                    return true;
                });
                Assert.AreEqual(1, confirmations);
                Assert.ThrowsException<OperationCanceledException>(() => ProtectedFiles.RequireTree(root,
                    confirmUnsafePermissions: warning => false));
                Assert.ThrowsException<UnauthorizedAccessException>(() => ProtectedFiles.RequireTree(root));
            }
            finally { Directory.Delete(root, true); }
        }

        [TestMethod]
        public void VolumeRootDeleteIsNotDeleteChild()
        {
            string volume = Path.GetPathRoot(Environment.SystemDirectory);
            var rights = FileSystemRights.DeleteSubdirectoriesAndFiles |
                FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership;
            Assert.AreEqual(rights, ProtectedFiles.AncestorRights(volume));
            Assert.AreEqual(rights | FileSystemRights.Delete,
                ProtectedFiles.AncestorRights(Path.Combine(volume, "Libertix")));
        }

        [TestMethod]
        public void RepairKeepsUnsafeParentWarning()
        {
            string parent = NewProtectedDirectory();
            try
            {
                string root = Path.Combine(parent, "logs");
                ProtectedFiles.CreateDirectory(root);
                DirectorySecurity permissions = Directory.GetAccessControl(parent);
                permissions.AddAccessRule(new FileSystemAccessRule(
                    new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null),
                    FileSystemRights.DeleteSubdirectoriesAndFiles, AccessControlType.Allow));
                Directory.SetAccessControl(parent, permissions);
                string before = Directory.GetAccessControl(parent)
                    .GetSecurityDescriptorSddlForm(AccessControlSections.Owner | AccessControlSections.Access);
                int confirmations = 0;

                ProtectedFiles.RepairDirectory(root, confirmUnsafePermissions: warning =>
                {
                    confirmations++;
                    StringAssert.Contains(warning, parent);
                    StringAssert.Contains(warning, "DeleteSubdirectoriesAndFiles");
                    return true;
                });

                Assert.AreEqual(1, confirmations);
                Assert.AreEqual(before, Directory.GetAccessControl(parent)
                    .GetSecurityDescriptorSddlForm(AccessControlSections.Owner | AccessControlSections.Access));
            }
            finally { Directory.Delete(parent, true); }
        }

        [TestMethod]
        public void MigratesLegacyAdminPermissions()
        {
            string root = NewProtectedDirectory();
            try
            {
                string path = Path.Combine(root, "state.json");
                File.WriteAllText(path, "original");
                using (var identity = WindowsIdentity.GetCurrent())
                {
                    FileSecurity security = File.GetAccessControl(path);
                    security.SetOwner(identity.User);
                    security.AddAccessRule(new FileSystemAccessRule(identity.User,
                        FileSystemRights.FullControl, AccessControlType.Allow));
                    File.SetAccessControl(path, security);
                    Assert.ThrowsException<UnauthorizedAccessException>(() => ProtectedFiles.RequireTree(root));

                    ProtectedFiles.CreateDirectory(root, true);

                    ProtectedFiles.RequireTree(root);
                    Assert.AreEqual("S-1-5-32-544", File.GetAccessControl(path)
                        .GetOwner(typeof(SecurityIdentifier)).Value);
                    Assert.AreEqual("original", File.ReadAllText(path));
                }
            }
            finally { Directory.Delete(root, true); }
        }

        private static string WriteEmbeddedScript(string root, string relative, string source)
        {
            string path = Path.Combine(root, relative);
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            using (Stream resource = typeof(BootGuardianEngine).Assembly
                .GetManifestResourceStream("Libertix.TrustedScripts." + source))
            using (Stream destination = File.Create(path))
            {
                Assert.IsNotNull(resource, "The real script must be embedded in the host.");
                resource.CopyTo(destination);
            }
            return path;
        }

        [TestMethod]
        public void PreferredWindowsUpdateResumesAtEveryCommitBoundary()
        {
            for (int interruptAt = 1; interruptAt <= 18; interruptAt++)
            {
                string root = Path.Combine(Path.GetTempPath(), "libertix-sync-test-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(root);
                try
                {
                    string efi = Path.Combine(root, @"EFI\Libertix");
                    string microsoft = Path.Combine(root, @"EFI\Microsoft\Boot");
                    string reference = Path.Combine(efi, "BootGuardianReference");
                    Directory.CreateDirectory(reference);
                    Directory.CreateDirectory(microsoft);
                    File.WriteAllText(Path.Combine(reference, ".libertix-owner"), new string('a', 32));
                    foreach (string name in new[] { "shimx64.efi", "grubx64.efi", "mmx64.efi", "grub.cfg" })
                        File.WriteAllText(Path.Combine(reference, name), name);
                    string active = Path.Combine(microsoft, "bootmgfw.efi");
                    string backup = Path.Combine(microsoft, "bootmgfw.libertix-windows.efi");
                    File.WriteAllText(active, "new-windows-loader");
                    File.WriteAllText(backup, "old-windows-loader");
                    string expectedWindows = Hashing.Sha256File(active);
                    var manifest = new PreferredManifest { Version = 1, RunId = new string('a', 32), Status = "installed",
                        WindowsLoader = new PreferredWindowsLoader { ActivePath = @"\EFI\Microsoft\Boot\bootmgfw.efi",
                            BackupPath = @"\EFI\Microsoft\Boot\bootmgfw.libertix-windows.efi", Sha256 = Hashing.Sha256File(backup) },
                        Preferred = new PreferredHashes { ShimSha256 = Hashing.Sha256File(Path.Combine(reference, "shimx64.efi")),
                            GrubSha256 = Hashing.Sha256File(Path.Combine(reference, "grubx64.efi")),
                            MokManagerSha256 = Hashing.Sha256File(Path.Combine(reference, "mmx64.efi")),
                            GrubConfigSha256 = Hashing.Sha256File(Path.Combine(reference, "grub.cfg")) } };
                    string manifestPath = Path.Combine(efi, "preferred-boot-path.json");
                    string json = manifest.ToJson();
                    File.WriteAllText(manifestPath, json.Substring(0, json.Length - 1) +
                        ",\"windowsBootEntry\":{\"name\":\"Boot0001\"},\"futureField\":{\"value\":42}}");
                    manifest = PreferredManifest.Read(manifestPath);
                    manifest.WindowsLoader.Sha256 = expectedWindows;
                    int calls = 0;
                    try
                    {
                        PreferredSynchronization.PublishWindowsLoaderUpdate(root, manifest, active, reference, () => {
                            if (++calls == interruptAt) throw new TimeoutException("simulated shutdown deadline");
                        });
                    }
                    catch (TimeoutException) { }
                    if (File.Exists(Path.Combine(efi, "preferred-boot-path.sync.json")))
                        PreferredSynchronization.Replay(root, manifest.RunId, () => { });
                    else
                        PreferredSynchronization.PublishWindowsLoaderUpdate(root, manifest, active, reference, () => { });
                    Assert.AreEqual(expectedWindows, Hashing.Sha256File(backup));
                    Assert.AreEqual(manifest.Preferred.ShimSha256, Hashing.Sha256File(active));
                    Assert.AreEqual(expectedWindows, PreferredManifest.Read(manifestPath).WindowsLoader.Sha256);
                    StringAssert.Contains(File.ReadAllText(manifestPath), "windowsBootEntry");
                    StringAssert.Contains(File.ReadAllText(manifestPath), "futureField");
                }
                finally { Directory.Delete(root, true); }
            }
        }

        [TestMethod]
        public void CurrentWindowsLoaderTrustRejectsUnrelatedFiles()
        {
            string candidate = typeof(BootGuardianTests).Assembly.Location;
            Assert.IsFalse(WindowsBootLoaderTrust.IsCurrentWindowsLoader(candidate, Hashing.Sha256File(candidate)));
        }

        [TestMethod]
        public void CurrentWindowsLoaderTrustAcceptsTheInstalledSignedLoader()
        {
            string candidate = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                @"Boot\EFI\bootmgfw.efi");
            Assert.IsTrue(File.Exists(candidate), "The Windows build host must expose its EFI boot loader.");
            Assert.IsTrue(WindowsBootLoaderTrust.IsCurrentWindowsLoader(candidate, Hashing.Sha256File(candidate)));
        }

        [TestMethod]
        public void BootOrderEncodingRoundTripsWithoutChangingOrder()
        {
            ushort[] expected = { 0x0007, 0x0001, 0xABCD };
            byte[] bytes = FirmwareEnvironment.EncodeBootOrder(expected);
            CollectionAssert.AreEqual(expected, FirmwareEnvironment.ParseBootOrder(bytes));
        }

        [TestMethod]
        public void BootOrderParsingRejectsOddByteLength()
        {
            Assert.ThrowsException<InvalidOperationException>(
                () => FirmwareEnvironment.ParseBootOrder(new byte[] { 1, 0, 2 }));
        }

        [TestMethod]
        public void DesiredBootOrderMakesOwnedEntryFirstAndRemovesDuplicates()
        {
            ushort[] desired = BootGuardianEngine.BuildDesiredBootOrder(
                0x0007,
                new ushort[] { 0x0001, 0x0007, 0x0001, 0x0002, 0x0007 });
            CollectionAssert.AreEqual(new ushort[] { 0x0007, 0x0001, 0x0002 }, desired);
        }

        [TestMethod]
        public void ConfigurationRejectsAHashThatDoesNotOwnTheEntry()
        {
            BootGuardianConfig config = NewBootOrderConfig();
            config.BootOrder.EntrySha256 = new string('0', 64);
            Assert.ThrowsException<InvalidDataException>(() => config.Validate());
        }

        [TestMethod]
        public void ConfigurationRequiresExactlyOneModeContract()
        {
            BootGuardianConfig config = NewBootOrderConfig();
            config.PreferredPath = new PreferredPathContract
            {
                ManifestPath = @"EFI\Libertix\preferred-boot-path.json",
                ReferenceRoot = @"EFI\Libertix\BootGuardianReference"
            };
            Assert.ThrowsException<InvalidDataException>(() => config.Validate());
        }

        [TestMethod]
        public void ConfigurationRejectsMalformedVolumeIdentity()
        {
            BootGuardianConfig config = NewBootOrderConfig();
            config.Esp.VolumePath = @"\\?\Volume{------------------------------------}\";
            Assert.ThrowsException<InvalidDataException>(() => config.Validate());
        }

        [TestMethod]
        public void ConfigurationRejectsAnInvalidServiceExecutableHash()
        {
            BootGuardianConfig config = NewBootOrderConfig();
            config.ServiceSha256 = "not-a-hash";
            Assert.ThrowsException<InvalidDataException>(() => config.Validate());
        }

        [TestMethod]
        public void RepairDeadlineUsesElapsedTimeAndExpires()
        {
            var deadline = new RepairDeadline(TimeSpan.FromMilliseconds(10));
            Assert.IsTrue(deadline.RemainingMilliseconds > 0);
            Thread.Sleep(30);
            Assert.ThrowsException<TimeoutException>(() => deadline.ThrowIfExpired());
        }

        [TestMethod]
        public void AttemptStateDetectsAndClearsAnInterruptedAttempt()
        {
            string root = Path.Combine(Path.GetTempPath(), "libertix-guardian-test-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            try
            {
                string configPath = Path.Combine(root, "config.json");
                BootGuardianConfig config = NewBootOrderConfig();
                GuardianAttemptState first = GuardianAttemptState.Begin(configPath, config);
                Assert.IsFalse(first.PreviousInterrupted);

                GuardianAttemptState resumed = GuardianAttemptState.Begin(configPath, config);
                Assert.IsTrue(resumed.PreviousInterrupted);
                resumed.Complete(false);

                GuardianAttemptState next = GuardianAttemptState.Begin(configPath, config);
                Assert.IsFalse(next.PreviousInterrupted);
                next.Complete(true);
                string state = File.ReadAllText(Path.Combine(root, "last-attempt.state"));
                StringAssert.Contains(state, "status=repaired");
                StringAssert.Contains(state, "runId=" + config.RunId);
            }
            finally
            {
                if (Directory.Exists(root))
                    Directory.Delete(root, true);
            }
        }

        [TestMethod]
        public void ConfigurationRejectsAlternateDataStreamInEfiPath()
        {
            BootGuardianConfig config = NewBootOrderConfig();
            config.Mode = "preferred-windows-path";
            config.BootOrder = null;
            config.PreferredPath = new PreferredPathContract
            {
                ManifestPath = @"EFI\Libertix\preferred-boot-path.json:extra",
                ReferenceRoot = @"EFI\Libertix\BootGuardianReference"
            };
            Assert.ThrowsException<InvalidDataException>(() => config.Validate());
        }

        [TestMethod]
        public void HealthyJournalDoesNotCreateALogDirectory()
        {
            string root = Path.Combine(Path.GetTempPath(), "libertix-guardian-test-" + Guid.NewGuid().ToString("N"));
            try
            {
                BootGuardianConfig config = NewBootOrderConfig();
                config.LogDirectory = Path.Combine(root, "logs");
                var journal = new RepairJournal(config);
                journal.Complete();
                Assert.IsFalse(Directory.Exists(config.LogDirectory));
            }
            finally
            {
                if (Directory.Exists(root))
                    Directory.Delete(root, true);
            }
        }

        [TestMethod]
        public void RepairJournalCreatesOneDetailedLog()
        {
            string root = Path.Combine(Path.GetTempPath(), "libertix-guardian-test-" + Guid.NewGuid().ToString("N"));
            try
            {
                BootGuardianConfig config = NewBootOrderConfig();
                config.LogDirectory = Path.Combine(root, "logs");
                var journal = new RepairJournal(config);
                journal.Repair("test repair");
                journal.Complete();
                string[] files = Directory.GetFiles(config.LogDirectory, "*.log");
                Assert.AreEqual(1, files.Length);
                string text = File.ReadAllText(files[0]);
                StringAssert.Contains(text, "REPAIR: test repair");
                StringAssert.Contains(text, "runId=" + config.RunId);
                StringAssert.Contains(text, "mode=firmware-boot-order");
            }
            finally
            {
                if (Directory.Exists(root))
                    Directory.Delete(root, true);
            }
        }

        [TestMethod]
        public void RecoveredInterruptedAttemptCreatesOneDetailedLogWithoutInventingARepair()
        {
            string root = Path.Combine(Path.GetTempPath(), "libertix-guardian-test-" + Guid.NewGuid().ToString("N"));
            try
            {
                BootGuardianConfig config = NewBootOrderConfig();
                config.LogDirectory = Path.Combine(root, "logs");
                var journal = new RepairJournal(config);
                journal.RecordInterruptedAttempt();
                journal.Complete();
                string[] files = Directory.GetFiles(config.LogDirectory, "*.log");
                Assert.AreEqual(1, files.Length);
                string text = File.ReadAllText(files[0]);
                StringAssert.Contains(text, "RECOVERY: the previous guardian attempt");
                Assert.IsFalse(text.Contains("REPAIR:"));
            }
            finally
            {
                if (Directory.Exists(root))
                    Directory.Delete(root, true);
            }
        }

        [TestMethod]
        public void AtomicRepairReplacesTheDestinationAndLeavesNoTemporaryFile()
        {
            string root = Path.Combine(Path.GetTempPath(), "libertix-guardian-test-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            try
            {
                string source = Path.Combine(root, "source.efi");
                string destination = Path.Combine(root, "destination.efi");
                File.WriteAllText(source, "verified");
                File.WriteAllText(destination, "changed");
                string hash = Hashing.Sha256File(source);

                AtomicFile.CopyVerified(source, destination, hash);

                Assert.AreEqual(hash, Hashing.Sha256File(destination));
                string[] files = Array.ConvertAll(Directory.GetFiles(root), Path.GetFileName);
                Array.Sort(files, StringComparer.Ordinal);
                CollectionAssert.AreEqual(new[] { "destination.efi", "source.efi" }, files);
            }
            finally
            {
                if (Directory.Exists(root))
                    Directory.Delete(root, true);
            }
        }

        [TestMethod]
        public void AtomicRepairRejectsAnInvalidSourceWithoutChangingDestination()
        {
            string root = Path.Combine(Path.GetTempPath(), "libertix-guardian-test-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            try
            {
                string source = Path.Combine(root, "source.efi");
                string destination = Path.Combine(root, "destination.efi");
                File.WriteAllText(source, "untrusted");
                File.WriteAllText(destination, "original");

                Assert.ThrowsException<InvalidDataException>(
                    () => AtomicFile.CopyVerified(source, destination, new string('0', 64)));
                Assert.AreEqual("original", File.ReadAllText(destination));
            }
            finally
            {
                if (Directory.Exists(root))
                    Directory.Delete(root, true);
            }
        }

        [TestMethod]
        public void AtomicRepairDoesNotCommitAfterItsDeadline()
        {
            string root = Path.Combine(Path.GetTempPath(), "libertix-guardian-test-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            try
            {
                string source = Path.Combine(root, "source.efi");
                string destination = Path.Combine(root, "destination.efi");
                File.WriteAllText(source, "verified");
                File.WriteAllText(destination, "original");
                string hash = Hashing.Sha256File(source);

                Assert.ThrowsException<TimeoutException>(() =>
                    AtomicFile.CopyVerified(
                        source,
                        destination,
                        hash,
                        () => { throw new TimeoutException("test deadline"); }));

                Assert.AreEqual("original", File.ReadAllText(destination));
                CollectionAssert.AreEquivalent(
                    new[] { "destination.efi", "source.efi" },
                    Array.ConvertAll(Directory.GetFiles(root), Path.GetFileName));
            }
            finally
            {
                if (Directory.Exists(root))
                    Directory.Delete(root, true);
            }
        }

        private static BootGuardianConfig NewBootOrderConfig()
        {
            byte[] entry = Encoding.ASCII.GetBytes("test-entry");
            return new BootGuardianConfig
            {
                Version = 1,
                RunId = new string('a', 32),
                Mode = "firmware-boot-order",
                Esp = new EspIdentity
                {
                    VolumePath = @"\\?\Volume{11111111-1111-1111-1111-111111111111}\",
                    PartitionNumber = 1,
                    PartitionGuid = "22222222-2222-2222-2222-222222222222",
                    OwnerMarker = "owner\n"
                },
                LogDirectory = @"C:\LibertixInstallLogs\Windows\test\BootGuardian",
                ArchiveDirectory = @"C:\ProgramData\Libertix\UefiRecovery\test\boot-guardian",
                ServiceSha256 = new string('f', 64),
                BootOrder = new BootOrderContract
                {
                    BootNumber = 7,
                    EntryBytesBase64 = Convert.ToBase64String(entry),
                    EntrySha256 = Hashing.Sha256(entry)
                }
            };
        }
    }
}
