using System;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Libertix.Tests
{
    [TestClass]
    public sealed class StartupValidationTests
    {
        [DataTestMethod]
        [DataRow(true)]
        [DataRow(false)]
        public async Task WindowCannotOpenBeforeVersionDecision(bool accepted)
        {
            var decision = new TaskCompletionSource<bool>();
            int windowsOpened = 0;
            Task startup = App.RunValidatedStartupAsync(() => decision.Task, () => windowsOpened++);
            Assert.IsFalse(startup.IsCompleted);
            Assert.AreEqual(0, windowsOpened);
            decision.SetResult(accepted);
            await startup;
            Assert.AreEqual(accepted ? 1 : 0, windowsOpened);
        }

        [TestMethod]
        public async Task FailedVersionCheckCannotOpenTheWindow()
        {
            int windowsOpened = 0;
            await Assert.ThrowsExceptionAsync<InvalidOperationException>(() =>
                App.RunValidatedStartupAsync(
                    () => Task.FromException<bool>(new InvalidOperationException("unavailable")),
                    () => windowsOpened++));
            Assert.AreEqual(0, windowsOpened);
        }
    }
}
