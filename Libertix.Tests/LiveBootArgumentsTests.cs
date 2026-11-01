using System;
using System.IO;
using Libertix.Installation;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Libertix.Tests
{
    [TestClass]
    public sealed class LiveBootArgumentsTests
    {
        [TestMethod]
        public void LowMemoryMenuLoadsOnlySquashFsWithoutChangingTheNormalMenu()
        {
            var arguments = LiveBootArguments.Load(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,
                "TestData", "Libertix.BootArguments.json"));
            string normal = arguments.CreateGrub4DosMenu();
            string lowMemory = arguments.CreateGrub4DosMenu(true);
            StringAssert.Contains(lowMemory, "toram=filesystem.squashfs");
            Assert.IsFalse(lowMemory.Contains(" toram "));
            StringAssert.Contains(lowMemory, "find --set-root /installation-plan.json");
            StringAssert.Contains(lowMemory, "initrd /live/initrd.img");
            Assert.AreEqual(normal, arguments.CreateGrub4DosMenu());
            StringAssert.Contains(normal, " toram ");
        }

        [TestMethod]
        public void LowMemoryMenuRejectsArgumentsWithoutARamLoadingContract()
        {
            string path = Path.GetTempFileName();
            try
            {
                File.WriteAllText(path, "{\"normal\":\"boot=live\",\"verbose\":\"boot=live\"}");
                var arguments = LiveBootArguments.Load(path);
                Assert.ThrowsException<InvalidDataException>(() => arguments.CreateGrub4DosMenu(true));
            }
            finally { File.Delete(path); }
        }
    }
}
