using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text.Json;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Libertix.Helpers;
using Libertix.Models;
using Libertix.Pages;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Libertix.Tests
{
    [TestClass]
    public sealed class FallbackLifecycleTests
    {
        [TestMethod]
        public void FallbackAndRollbackKeepTheApplicationBusyUntilTheChildFinishes()
        {
            Exception failure = null;
            var thread = new Thread(() =>
            {
                try
                {
                    var application = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
                    SynchronizationContext.SetSynchronizationContext(
                        new DispatcherSynchronizationContext(Dispatcher.CurrentDispatcher));
                    application.Resources["ModernButton"] = new Style(typeof(Button));
                    application.Resources["BoolToVisibilityConverter"] = new BooleanToVisibilityConverter();
                    application.Resources["StringToVisibilityConverter"] = new Libertix.Converters.StringToVisibilityConverter();
                    Localization.SetLanguage("en");
                    VerifyResizeSelectionIsPreserved();
                    VerifySeparateDiskSelection();
                    string root = Path.Combine(Path.GetTempPath(), "Libertix-fallback-test-" + Guid.NewGuid().ToString("N"));
                    string scripts = Path.Combine(root, "Scripts");
                    Directory.CreateDirectory(scripts);
                    string marker = Path.Combine(root, "calls.txt");
                    string child = "Add-Content -LiteralPath '" + marker.Replace("'", "''") +
                        "' -Value started; Start-Sleep -Milliseconds 500; exit 1";
                    File.WriteAllText(Path.Combine(scripts, "libertix-uefi-install.ps1"), child);
                    File.WriteAllText(Path.Combine(scripts, "libertix-uefi-recovery-agent.ps1"), child);
                    int expectedCalls = 0;
                    foreach (string action in new[] { "FallbackButton_Click", "PreferredPath", "CancelButton_Click" })
                    {
                        string path = Path.Combine(root, "state.json");
                        File.WriteAllText(path, JsonSerializer.Serialize(new UefiRecoveryState
                        {
                            PayloadRoot = root,
                            ConfigPath = Path.Combine(root, "config.json"),
                            Phase = action == "PreferredPath" ? "PreferredPathPrompted" : "FallbackPrompted"
                        }));
                        var state = new InstallationState { UefiRecoveryStatePath = path };
                        var page = new UefiBootFallback(state);
                        string handler = action == "PreferredPath" ? "FallbackButton_Click" : action;
                        InvokeClick(page, handler);
                        Assert.IsTrue(state.IsInstallationRunning, action);
                        Assert.IsFalse(((Button)page.FindName("FallbackButton")).IsEnabled);
                        Assert.IsFalse(((Button)page.FindName("CancelButton")).IsEnabled);
                        InvokeClick(page, handler);
                        var timer = Stopwatch.StartNew();
                        while (state.IsInstallationRunning && timer.Elapsed < TimeSpan.FromSeconds(15))
                        {
                            var frame = new DispatcherFrame();
                            Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.Background,
                                new Action(() => frame.Continue = false));
                            Dispatcher.PushFrame(frame);
                            Thread.Sleep(10);
                        }
                        Assert.IsFalse(state.IsInstallationRunning, "Child completion must release the busy state.");
                        Assert.AreEqual(++expectedCalls, File.ReadAllLines(marker).Length,
                            "A repeated click must not launch a second writer.");
                        Assert.IsTrue(((Button)page.FindName("CancelButton")).IsEnabled);
                    }
                    string blockedPath = Path.Combine(root, "blocked.json");
                    File.WriteAllText(blockedPath, JsonSerializer.Serialize(new UefiRecoveryState
                    {
                        PayloadRoot = root, ConfigPath = "unused", Phase = "FallbackProcessStateUnknown"
                    }));
                    var blockedState = new InstallationState { UefiRecoveryStatePath = blockedPath };
                    var blockedPage = new UefiBootFallback(blockedState);
                    Assert.IsFalse(((Button)blockedPage.FindName("FallbackButton")).IsEnabled);
                    Assert.IsFalse(((Button)blockedPage.FindName("CancelButton")).IsEnabled);
                    InvokeClick(blockedPage, "FallbackButton_Click");
                    InvokeClick(blockedPage, "CancelButton_Click");
                    Assert.IsFalse(blockedState.IsInstallationRunning);
                    Assert.AreEqual(expectedCalls, File.ReadAllLines(marker).Length);
                    application.Shutdown();
                }
                catch (Exception ex) { failure = ex; }
            });
            thread.SetApartmentState(ApartmentState.STA);
            thread.IsBackground = true;
            thread.Start();
            Assert.IsTrue(thread.Join(TimeSpan.FromSeconds(60)), "WPF lifecycle test exceeded its deadline.");
            if (failure != null) throw new AssertFailedException(failure.ToString());
        }

        private static void InvokeClick(UefiBootFallback page, string handler)
        {
            typeof(UefiBootFallback).GetMethod(handler, BindingFlags.NonPublic | BindingFlags.Instance)
                .Invoke(page, new object[] { null, new RoutedEventArgs() });
        }

        private static void VerifyResizeSelectionIsPreserved()
        {
            const long gib = 1024L * 1024 * 1024;
            var state = new InstallationState
            {
                SelectedDistro = new DistroInfo { IsoInstallerSizeBytes = gib },
                Compatibility = new CompatibilityInfo { ShrinkAvailableBytes = 100 * gib },
                SelectedLinuxSizeGiB = 37
            };
            var page = new ResizeDisk(state, 500 * gib, 300 * gib);
            Assert.AreEqual(37d, page.SelectedSize, "Back navigation must retain the user's allocation.");
            Assert.AreEqual("37", page.ManualSize);
            Assert.AreNotEqual(page.RecommendedSize, page.SelectedSize);
            Assert.IsFalse(page.HasSizeError);

            page.ManualSize = "42";
            typeof(ResizeDisk).GetMethod("SaveState", BindingFlags.NonPublic | BindingFlags.Instance)
                .Invoke(page, null);
            var restored = new ResizeDisk(state, 500 * gib, 300 * gib);
            Assert.AreEqual(42d, restored.SelectedSize);
            Assert.AreEqual("42", restored.ManualSize);

            long reducedFree = (long)((30.8 + 1 +
                Libertix.Installation.InstallationSizePolicy.MinimumWindowsFreeSpaceGiB) * gib);
            var limited = new ResizeDisk(state, 500 * gib, reducedFree);
            Assert.AreEqual(30d, limited.SelectedSize, "A restored size must fit the new whole-GiB budget.");
            Assert.AreEqual("30", limited.ManualSize);
            Assert.IsFalse(limited.HasSizeError);
            state.SelectedLinuxSizeGiB = null;
            var fresh = new ResizeDisk(state, 500 * gib, reducedFree);
            Assert.AreEqual(fresh.RecommendedSize, fresh.SelectedSize);
            Assert.IsFalse(fresh.HasSizeError, "Recommendation must not round above the available budget.");
        }

        private static void VerifySeparateDiskSelection()
        {
            const long gib = 1024L * 1024 * 1024;
            var windows = new InstallationTargetInfo
            {
                Drive = "C:", IsWindows = true, DiskNumber = 0, PartitionStyle = "GPT",
                SizeBytes = 100 * gib, FreeBytes = 50 * gib, MinimumSizeBytes = 50 * gib
            };
            var data = new InstallationTargetInfo
            {
                Drive = "D:", DiskNumber = 1, PartitionStyle = "GPT",
                SizeBytes = 64 * gib, FreeBytes = 50 * gib, MinimumSizeBytes = 14 * gib
            };
            var state = new InstallationState
            {
                SelectedDistro = new DistroInfo { IsoInstallerSizeBytes = 4 * gib },
                SelectedLinuxSizeGiB = 20,
                Compatibility = new CompatibilityInfo
                {
                    Firmware = "UEFI", ShrinkAvailableBytes = 40 * gib,
                    InstallationTargets = new[] { windows, data }
                }
            };
            var page = new ResizeDisk(state, windows.SizeBytes, windows.FreeBytes);
            Assert.AreSame(windows, page.SelectedTarget);
            Assert.IsNull(state.SelectedInstallationTarget);
            Assert.IsTrue(page.HasMultipleTargets);
            Assert.IsFalse(page.IsSecondaryTarget);
            Assert.AreEqual(string.Empty, page.SecondaryDiskWarning);
            Assert.AreEqual(26d, page.WindowsFreeSpace);
            page.SelectedTarget = data;
            Assert.AreSame(data, state.SelectedInstallationTarget);
            Assert.IsFalse(page.IsWindowsTarget);
            Assert.IsTrue(page.IsSecondaryTarget);
            StringAssert.Contains(page.SecondaryDiskWarning, "D:");
            StringAssert.Contains(page.SecondaryDiskWarning, "C:");
            Assert.AreNotEqual("ResizeDiskSecondaryWarning", page.SecondaryDiskWarning);
            Assert.AreEqual("D:", page.RetainedVolumeName);
            Assert.AreEqual(30d, page.WindowsFreeSpace,
                "The ISO stays on Windows and must not consume the donor volume budget.");
            Assert.IsTrue(page.CanAllocateLinux);
            Assert.IsFalse(page.HasSizeError);
            string language = Localization.CurrentLanguage;
            foreach (string candidate in new[] { "en", "fr", "es" })
            {
                Localization.SetLanguage(candidate);
                page.Measure(new Size(1070, 530));
                page.Arrange(new Rect(0, 0, 1070, 530));
                page.UpdateLayout();
                var next = (Button)page.FindName("NextButton");
                Rect bounds = next.TransformToAncestor(page).TransformBounds(new Rect(next.RenderSize));
                Assert.IsTrue(bounds.Top >= 0 && bounds.Bottom <= 530,
                    "The secondary disk warning must not push navigation outside the page.");
                Assert.AreEqual(Visibility.Visible, ((Border)page.FindName("SecondaryDiskWarningPanel")).Visibility);
                StringAssert.Contains(page.SecondaryDiskWarning, "D:");
                Assert.IsFalse(page.SecondaryDiskWarning.Contains("{0}"));
                Assert.IsFalse(page.SecondaryDiskWarning.Contains("{1}"));
            }
            Localization.SetLanguage(language);
            var restored = new ResizeDisk(state, windows.SizeBytes, windows.FreeBytes);
            Assert.AreSame(data, restored.SelectedTarget);
            Assert.AreEqual(20d, restored.SelectedSize);
            Assert.ThrowsException<InvalidOperationException>(() =>
                restored.SelectedTarget = new InstallationTargetInfo { Drive = "E:" });
            windows.FreeBytes = 5 * gib;
            var noDownloadSpace = new ResizeDisk(state, windows.SizeBytes, windows.FreeBytes);
            Assert.IsFalse(noDownloadSpace.CanAllocateLinux);
            Assert.IsTrue(noDownloadSpace.HasError);
            Assert.IsTrue(noDownloadSpace.HasSizeError);
            Assert.AreEqual(Localization.GetString("ResizeDiskWindowsDownloadSpace"),
                noDownloadSpace.AdditionalSpaceNeeded);
            windows.FreeBytes = 50 * gib;
            restored.SelectedTarget = windows;
            Assert.IsNull(state.SelectedInstallationTarget);
            Assert.IsFalse(restored.IsSecondaryTarget);
            Assert.AreEqual(string.Empty, restored.SecondaryDiskWarning);
            Assert.AreEqual(26d, restored.WindowsFreeSpace);
            state.Compatibility.ShrinkAvailableBytes = 0;
            var secondaryOnly = new ResizeDisk(state, windows.SizeBytes, windows.FreeBytes);
            Assert.AreSame(windows, secondaryOnly.SelectedTarget);
            Assert.IsFalse(secondaryOnly.CanAllocateLinux);
            secondaryOnly.SelectedTarget = data;
            Assert.IsTrue(secondaryOnly.CanAllocateLinux);
            Assert.AreSame(data, state.SelectedInstallationTarget);
            secondaryOnly.SelectedTarget = windows;
            Assert.IsFalse(secondaryOnly.CanAllocateLinux);

            data.SizeBytes = gib;
            data.FreeBytes = gib / 2;
            data.MinimumSizeBytes = gib / 2;
            secondaryOnly.SelectedTarget = data;
            Assert.IsFalse(secondaryOnly.CanAllocateLinux);
            Assert.IsTrue(secondaryOnly.HasSizeError);
            Assert.IsTrue(secondaryOnly.HasError);
            Assert.AreEqual(100d, secondaryOnly.WindowsPartitionPercentage.Value,
                "An impossible allocation must keep the existing volume in the preview.");
            Assert.AreEqual(0d, secondaryOnly.LinuxPartitionPercentage.Value);
            state.Compatibility.ShrinkAvailableBytes = 40 * gib;
            secondaryOnly.SelectedTarget = windows;
            Assert.IsTrue(secondaryOnly.CanAllocateLinux);
            Assert.IsFalse(secondaryOnly.HasError);
            Assert.AreEqual(76d, secondaryOnly.WindowsPartitionPercentage.Value);
            Assert.AreEqual(20d, secondaryOnly.LinuxPartitionPercentage.Value);
        }
    }
}
