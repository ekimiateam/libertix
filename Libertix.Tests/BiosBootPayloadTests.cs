using System;
using System.IO;
using System.Text.Json;
using Libertix.Installation;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Libertix.Tests
{
    [TestClass]
    public sealed class BiosBootPayloadTests
    {
        [TestMethod]
        public void PublicationPreservesPreexistingBootFiles()
        {
            string root = Path.Combine(Path.GetTempPath(), "libertix-bios-test-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            try
            {
                foreach (string name in BiosBootPayload.Names)
                {
                    string path = Path.Combine(root, name);
                    File.WriteAllText(path, "foreign");
                    Assert.ThrowsException<IOException>(() => BiosBootPayload.AssertDestinationsAbsent(root));
                    Assert.ThrowsException<IOException>(() => BiosBootPayload.Publish(root,
                        Path.Combine(root, "recovery"), new string('a', 32), Path.Combine(root, "prepared")));
                    Assert.AreEqual("foreign", File.ReadAllText(path));
                    Assert.IsFalse(Directory.Exists(Path.Combine(root, "recovery")));
                    File.Delete(path);
                }
            }
            finally { Directory.Delete(root, true); }
        }

        [TestMethod]
        public void PublicationRecordsAllHashesAndRefusesToOverwriteOnRetry()
        {
            string root = Path.Combine(Path.GetTempPath(), "libertix-bios-test-" + Guid.NewGuid().ToString("N"));
            string prepared = Path.Combine(root, "prepared");
            string recovery = Path.Combine(root, "recovery");
            Directory.CreateDirectory(prepared);
            try
            {
                foreach (string name in BiosBootPayload.Names) File.WriteAllText(Path.Combine(prepared, name), name);
                BiosBootPayload.Publish(root, recovery, new string('a', 32), prepared);
                using (JsonDocument manifest = JsonDocument.Parse(File.ReadAllText(Path.Combine(recovery, "bios-boot-payload.json"))))
                {
                    Assert.AreEqual(new string('a', 32), manifest.RootElement.GetProperty("planId").GetString());
                    foreach (string name in BiosBootPayload.Names)
                    {
                        Assert.AreEqual(name, File.ReadAllText(Path.Combine(root, name)));
                        Assert.AreEqual(64, manifest.RootElement.GetProperty("files").GetProperty(name).GetString().Length);
                    }
                }
                Assert.ThrowsException<IOException>(() => BiosBootPayload.Publish(root, recovery, new string('a', 32), prepared));
            }
            finally { Directory.Delete(root, true); }
        }
    }
}
