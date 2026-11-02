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
                    VerifyFixedAndUnavailableAllocation();
                    InstallationTargetTests.FullWindowsMbrRefusesOnlyTheWindowsDestination();
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
            AssertBoundaryModelIsConsistent(page);
            AssertThumbFollowsBoundary(page, "Windows volume, no inventory");
            page.SelectedSize = 37;

            page.ManualSize = "42";
            typeof(ResizeDisk).GetMethod("SaveState", BindingFlags.NonPublic | BindingFlags.Instance)
                .Invoke(page, null);
            var restored = new ResizeDisk(state, 500 * gib, 300 * gib);
            Assert.AreEqual(42d, restored.SelectedSize);
            Assert.AreEqual("42", restored.ManualSize);

            long reducedFree = (long)((30.8 + 1 +
                Libertix.Installation.InstallationSizePolicy.MinimumWindowsFreeSpaceGiB) * gib);
            var limited = new ResizeDisk(state, 500 * gib, reducedFree);
            Assert.AreEqual(31d, limited.SelectedSize, "A restored size must fit the new whole-GiB budget.");
            Assert.AreEqual("31", limited.ManualSize);
            Assert.IsFalse(limited.HasSizeError);
            state.SelectedLinuxSizeGiB = null;
            var fresh = new ResizeDisk(state, 500 * gib, reducedFree);
            Assert.AreEqual(fresh.RecommendedSize, fresh.SelectedSize);
            Assert.IsFalse(fresh.HasSizeError, "Recommendation must not round above the available budget.");
        }

        // Model check only: the three range columns and the two bar columns are two
        // formulas over the same properties, and must agree on where the boundary is.
        // It does not measure anything rendered; AssertThumbCentreIsOnRenderedBoundary does.
        private static void AssertBoundaryModelIsConsistent(ResizeDisk page)
        {
            Assert.IsTrue(page.MaximumSize > page.MinimumSize);
            foreach (double size in new[] { page.MinimumSize, Math.Floor((page.MinimumSize + page.MaximumSize) / 2), page.MaximumSize })
            {
                page.SelectedSize = size;
                double fixedPart = page.FixedVolumePercentage.Value;
                double range = page.AdjustableRangePercentage.Value;
                double handle = (fixedPart + range * (page.MaximumSize - size) / (page.MaximumSize - page.MinimumSize)) /
                    (fixedPart + range + page.MinimumLinuxPercentage.Value);
                double boundary = page.WindowsPartitionPercentage.Value /
                    (page.WindowsPartitionPercentage.Value + page.LinuxPartitionPercentage.Value);
                Assert.AreEqual(boundary, handle, 1e-9, $"Model boundary mismatch at {size} GiB.");
                Assert.IsFalse(page.HasSizeError);
            }
        }

        // Layout check: lays the page out at the window's client size and compares the
        // rendered Thumb's centre with the right edge of the rendered Windows column, both
        // transformed into page coordinates. Layout rounding is off, so 0.5 DIP is ample.
        private static void AssertThumbCentreIsOnRenderedBoundary(ResizeDisk page, double size, string label)
        {
            page.SelectedSize = size;
            page.Measure(new Size(1054, 591));
            page.Arrange(new Rect(0, 0, 1054, 591));
            page.UpdateLayout();
            var slider = (Slider)page.FindName("PartitionSlider");
            var bar = (Grid)page.FindName("DiskVisualization");
            var track = (System.Windows.Controls.Primitives.Track)slider.Template.FindName("PART_Track", slider);
            Assert.IsNotNull(track, label);
            var thumb = track.Thumb;
            Assert.IsTrue(thumb.ActualWidth > 0 && bar.ActualWidth > 0, label);
            double thumbCentre = thumb.TransformToAncestor(page).Transform(new Point(thumb.ActualWidth / 2, 0)).X;
            double boundary = bar.TransformToAncestor(page).Transform(
                new Point(bar.ColumnDefinitions[0].ActualWidth, 0)).X;
            Assert.AreEqual(boundary, thumbCentre, 0.5,
                $"{label}: thumb centre {thumbCentre:F2} vs boundary {boundary:F2} DIP at {size} GiB.");
            Assert.AreEqual(size, page.SelectedSize, label);
            Assert.AreEqual(size, slider.Value, label);
        }

        private static void AssertThumbFollowsBoundary(ResizeDisk page, string label)
        {
            double middle = Math.Floor((page.MinimumSize + page.MaximumSize) / 2);
            foreach (double size in new[] { page.MinimumSize, middle, page.MaximumSize })
                AssertThumbCentreIsOnRenderedBoundary(page, size, label);
            // Typed sizes move the same boundary.
            page.ManualSize = middle.ToString(System.Globalization.CultureInfo.InvariantCulture);
            Assert.IsFalse(page.HasSizeError, label);
            AssertThumbCentreIsOnRenderedBoundary(page, middle, label + " typed");
        }

        private static void VerifyFixedAndUnavailableAllocation()
        {
            const long gib = 1024L * 1024 * 1024;
            var state = new InstallationState
            {
                SelectedDistro = new DistroInfo { IsoInstallerSizeBytes = gib },
                Compatibility = new CompatibilityInfo { ShrinkAvailableBytes = 50 * gib }
            };
            // 28.5 GiB free leaves 20.5 GiB after the Windows reserve: exactly the minimum.
            long fixedFree = (long)((Libertix.Installation.InstallationSizePolicy.MinimumFinalSizeGiB + 0.5 +
                Libertix.Installation.InstallationSizePolicy.MinimumWindowsFreeSpaceGiB) * gib);
            var fixedPage = new ResizeDisk(state, 100 * gib, fixedFree);
            Assert.IsTrue(fixedPage.CanAllocateLinux);
            Assert.AreEqual(fixedPage.MinimumSize, fixedPage.MaximumSize);
            AssertThumbCentreIsOnRenderedBoundary(fixedPage, fixedPage.MinimumSize, "minimum equals maximum");
            fixedPage.ManualSize = "21";
            Assert.IsTrue(fixedPage.HasSizeError, "One GiB over the only possible size must be refused.");
            fixedPage.ManualSize = "20";
            Assert.IsFalse(fixedPage.HasSizeError);

            long tooLittle = (long)((Libertix.Installation.InstallationSizePolicy.MinimumFinalSizeGiB - 1 +
                Libertix.Installation.InstallationSizePolicy.MinimumWindowsFreeSpaceGiB) * gib);
            var unavailable = new ResizeDisk(state, 100 * gib, tooLittle);
            unavailable.Measure(new Size(1054, 591));
            unavailable.Arrange(new Rect(0, 0, 1054, 591));
            unavailable.UpdateLayout();
            Assert.IsFalse(unavailable.CanAllocateLinux);
            Assert.IsTrue(unavailable.HasError);
            Assert.AreEqual(Visibility.Collapsed, ((Grid)unavailable.FindName("BoundaryRange")).Visibility,
                "No handle may be offered when Linux cannot be allocated.");
            Assert.IsFalse(((Slider)unavailable.FindName("PartitionSlider")).IsEnabled);
            Assert.IsFalse(((TextBox)unavailable.FindName("ManualSizeBox")).IsEnabled);
            Assert.IsFalse(((Button)unavailable.FindName("NextButton")).IsEnabled);
            Assert.AreEqual(0d, ((Grid)unavailable.FindName("DiskVisualization")).ColumnDefinitions[1].ActualWidth, 0.01);
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
            Assert.AreEqual(30d, page.WindowsFreeSpace,
                "The transaction ISO is removed before the final Windows free-space state.");
            AssertThumbFollowsBoundary(page, "C: before switching");
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
            AssertBoundaryModelIsConsistent(page);
            AssertThumbFollowsBoundary(page, "D: after switching");
            page.SelectedSize = 20;
            StringAssert.Contains(page.AllocationSummary, "D:");
            StringAssert.Contains(page.AllocationSummary, page.SelectedSize.ToString("N0"));
            string language = Localization.CurrentLanguage;
            foreach (string candidate in new[] { "en", "fr", "es", "ko" })
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
            Assert.AreEqual(30d, restored.WindowsFreeSpace);
            state.Compatibility.ShrinkAvailableBytes = 0;
            var secondaryOnly = new ResizeDisk(state, windows.SizeBytes, windows.FreeBytes);
            Assert.IsNull(secondaryOnly.SelectedTarget);
            Assert.IsFalse(secondaryOnly.HasSelectedTarget);
            Assert.IsTrue(secondaryOnly.IsWindowsTargetUnavailable);
            StringAssert.Contains(secondaryOnly.WindowsTargetUnavailableMessage, "C:");
            Assert.IsFalse(secondaryOnly.CanAllocateLinux);
            secondaryOnly.SelectedTarget = data;
            Assert.IsTrue(secondaryOnly.CanAllocateLinux);
            Assert.AreSame(data, state.SelectedInstallationTarget);
            Assert.ThrowsException<InvalidOperationException>(() => secondaryOnly.SelectedTarget = windows);
            Assert.AreSame(data, secondaryOnly.SelectedTarget);
            Assert.IsTrue(secondaryOnly.CanAllocateLinux);

            data.SizeBytes = gib;
            data.FreeBytes = gib / 2;
            data.MinimumSizeBytes = gib / 2;
            secondaryOnly = new ResizeDisk(state, windows.SizeBytes, windows.FreeBytes);
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
            Assert.AreEqual(80d, secondaryOnly.WindowsPartitionPercentage.Value);
            Assert.AreEqual(20d, secondaryOnly.LinuxPartitionPercentage.Value);

            state.Compatibility.Firmware = "BIOS";
            state.Compatibility.WindowsPartitionSlotAvailable = false;
            windows.PartitionStyle = data.PartitionStyle = "MBR";
            var fullMbr = new ResizeDisk(state, windows.SizeBytes, windows.FreeBytes);
            Assert.IsTrue(fullMbr.IsWindowsTargetUnavailable);
            Assert.IsNull(fullMbr.SelectedTarget);
            Assert.IsFalse(fullMbr.CanAllocateLinux);
            Assert.ThrowsException<InvalidOperationException>(() => fullMbr.SelectedTarget = windows);
            StringAssert.Contains(fullMbr.WindowsTargetUnavailableMessage, "MBR");
        }
    }
}
