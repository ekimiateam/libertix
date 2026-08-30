using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32;
using Libertix.Installation;

namespace Libertix.Helpers
{
    internal sealed class WindowsPreferenceBundle
    {
        public int SchemaVersion { get; set; }
        public string PlanId { get; set; }
        public WindowsDesktopPreferences Preferences { get; set; }
        public IReadOnlyList<WindowsWifiProfile> WifiProfiles { get; set; }
    }

    internal sealed class WindowsDesktopPreferences
    {
        public WindowsPreferenceAsset Wallpaper { get; set; }
        public bool? DarkMode { get; set; }
        public WindowsPreferenceAsset AccountImage { get; set; }
        public bool AutoLockAfterInactivity { get; set; }
        public uint? AutoLockTimeoutSeconds { get; set; }
        public bool? LockOnWakeAc { get; set; }
        public bool? LockOnWakeBattery { get; set; }
        public uint? ScreenTimeoutAcSeconds { get; set; }
        public uint? ScreenTimeoutBatterySeconds { get; set; }
        public uint? SleepTimeoutAcSeconds { get; set; }
        public uint? SleepTimeoutBatterySeconds { get; set; }
        public string LidCloseActionAc { get; set; }
        public string LidCloseActionBattery { get; set; }
        public string PrimaryMouseButton { get; set; }
        public bool? MouseNaturalScroll { get; set; }
        public bool? TouchpadNaturalScroll { get; set; }
        public bool? TouchpadTapToClick { get; set; }
        public uint? KeyboardRepeatDelayMilliseconds { get; set; }
        public uint? KeyboardRepeatIntervalMilliseconds { get; set; }
    }

    internal sealed class WindowsPreferenceAsset
    {
        public string FileName { get; set; }
        public string Sha256 { get; set; }
        public string ContentBase64 { get; set; }
    }

    internal static class WindowsPreferenceCollector
    {
        private const int SmSwapButton = 23;
        private const uint SpiGetKeyboardSpeed = 0x000A;
        private const uint SpiGetKeyboardDelay = 0x0016;
        private const long MaximumWallpaperBytes = 64L * 1024L * 1024L;
        private const long MaximumAccountImageBytes = 16L * 1024L * 1024L;

        private static readonly Guid VideoSubgroup =
            new Guid("7516b95f-f776-4464-8c53-06167f40cc99");
        private static readonly Guid VideoIdle =
            new Guid("3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e");
        private static readonly Guid SleepSubgroup =
            new Guid("238c9fa8-0aad-41ed-83f4-97be242c8f20");
        private static readonly Guid StandbyIdle =
            new Guid("29f6c1db-86da-48c5-9fdb-f2b67b1f44da");
        private static readonly Guid SystemButtonSubgroup =
            new Guid("4f971e89-eebd-4455-a8de-9e59040e7347");
        private static readonly Guid LidCloseAction =
            new Guid("5ca83367-6e45-459f-a27b-476b1d01c936");
        private static readonly Guid NoSubgroup =
            new Guid("fea3413e-7e05-4911-9a71-700331f1c294");
        private static readonly Guid ConsoleLock =
            new Guid("0e796bdb-100d-47d6-a2d5-f7d2daa51f51");

        [DllImport("powrprof.dll")]
        private static extern uint PowerGetActiveScheme(
            IntPtr userRootPowerKey,
            out IntPtr activePolicyGuid);

        [DllImport("powrprof.dll")]
        private static extern uint PowerReadACValueIndex(
            IntPtr rootPowerKey,
            ref Guid schemeGuid,
            ref Guid subgroupGuid,
            ref Guid powerSettingGuid,
            out uint valueIndex);

        [DllImport("powrprof.dll")]
        private static extern uint PowerReadDCValueIndex(
            IntPtr rootPowerKey,
            ref Guid schemeGuid,
            ref Guid subgroupGuid,
            ref Guid powerSettingGuid,
            out uint valueIndex);

        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr memory);

        [DllImport("user32.dll")]
        private static extern int GetSystemMetrics(int index);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SystemParametersInfo(
            uint action,
            uint parameter,
            out uint value,
            uint updateFlags);

        public static string Serialize(string planId, out int wifiProfileCount)
        {
            if (string.IsNullOrWhiteSpace(planId))
                throw new ArgumentException("A plan identifier is required.", nameof(planId));

            IReadOnlyList<WindowsWifiProfile> wifiProfiles = WindowsWifiProfileReader.ReadAll();
            wifiProfileCount = wifiProfiles.Count;
            var bundle = new WindowsPreferenceBundle
            {
                SchemaVersion = WindowsPreferenceMigrationContract.BundleSchemaVersion,
                PlanId = planId,
                Preferences = CollectDesktopPreferences(),
                WifiProfiles = wifiProfiles
            };
            string json = JsonSerializer.Serialize(
                bundle,
                new JsonSerializerOptions
                {
                    PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
                    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
                });
            if (Encoding.UTF8.GetByteCount(json) > WindowsPreferenceMigrationContract.MaximumBundleBytes)
            {
                throw new InvalidOperationException(
                    "The Windows preference migration bundle exceeds the supported size.");
            }
            return json;
        }

        private static WindowsDesktopPreferences CollectDesktopPreferences()
        {
            uint? keyboardDelay = ReadRegistryUInt32(
                    Registry.CurrentUser,
                    @"Control Panel\Keyboard",
                    "KeyboardDelay") ??
                ReadSystemParameter(SpiGetKeyboardDelay);
            uint? keyboardSpeed = ReadRegistryUInt32(
                    Registry.CurrentUser,
                    @"Control Panel\Keyboard",
                    "KeyboardSpeed") ??
                ReadSystemParameter(SpiGetKeyboardSpeed);
            bool autoLock = ReadRegistryBoolean(
                    Registry.CurrentUser,
                    @"Control Panel\Desktop",
                    "ScreenSaveActive",
                    defaultValue: false) &&
                ReadRegistryBoolean(
                    Registry.CurrentUser,
                    @"Control Panel\Desktop",
                    "ScreenSaverIsSecure",
                    defaultValue: false);
            uint? autoLockTimeout = autoLock
                ? ReadRegistryUInt32(
                    Registry.CurrentUser,
                    @"Control Panel\Desktop",
                    "ScreenSaveTimeOut")
                : null;

            using (var powerScheme = ActivePowerScheme.TryOpen())
            {
                return new WindowsDesktopPreferences
                {
                    Wallpaper = ReadAsset(ResolveWallpaperPath(), "wallpaper", MaximumWallpaperBytes),
                    DarkMode = ReadDarkMode(),
                    AccountImage = ReadAsset(
                        ResolveAccountImagePath(),
                        "account-image",
                        MaximumAccountImageBytes),
                    AutoLockAfterInactivity = autoLock,
                    AutoLockTimeoutSeconds = autoLockTimeout,
                    LockOnWakeAc = powerScheme?.ReadAc(NoSubgroup, ConsoleLock) is uint lockAc
                        ? lockAc != 0
                        : (bool?)null,
                    LockOnWakeBattery = powerScheme?.ReadDc(NoSubgroup, ConsoleLock) is uint lockDc
                        ? lockDc != 0
                        : (bool?)null,
                    ScreenTimeoutAcSeconds = powerScheme?.ReadAc(VideoSubgroup, VideoIdle),
                    ScreenTimeoutBatterySeconds = powerScheme?.ReadDc(VideoSubgroup, VideoIdle),
                    SleepTimeoutAcSeconds = powerScheme?.ReadAc(SleepSubgroup, StandbyIdle),
                    SleepTimeoutBatterySeconds = powerScheme?.ReadDc(SleepSubgroup, StandbyIdle),
                    LidCloseActionAc = MapLidAction(powerScheme?.ReadAc(
                        SystemButtonSubgroup,
                        LidCloseAction)),
                    LidCloseActionBattery = MapLidAction(powerScheme?.ReadDc(
                        SystemButtonSubgroup,
                        LidCloseAction)),
                    PrimaryMouseButton = GetSystemMetrics(SmSwapButton) == 0 ? "left" : "right",
                    MouseNaturalScroll = ReadMouseNaturalScroll(),
                    TouchpadNaturalScroll = ReadTouchpadSetting("ScrollDirection", 0),
                    TouchpadTapToClick = ReadTouchpadSetting("TapsEnabled", 1),
                    KeyboardRepeatDelayMilliseconds = keyboardDelay.HasValue && keyboardDelay <= 3
                        ? (keyboardDelay.Value + 1) * 250
                        : (uint?)null,
                    KeyboardRepeatIntervalMilliseconds = keyboardSpeed.HasValue && keyboardSpeed <= 31
                        ? ConvertKeyboardSpeedToInterval(keyboardSpeed.Value)
                        : (uint?)null
                };
            }
        }

        private static string ResolveWallpaperPath()
        {
            using (RegistryKey desktop = Registry.CurrentUser.OpenSubKey(@"Control Panel\Desktop"))
            {
                string path = desktop?.GetValue("WallPaper") as string;
                if (!string.IsNullOrWhiteSpace(path) && File.Exists(path))
                    return path;
            }

            string transcoded = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "Microsoft",
                "Windows",
                "Themes",
                "TranscodedWallpaper");
            return File.Exists(transcoded) ? transcoded : null;
        }

        private static bool? ReadDarkMode()
        {
            int? value = ReadRegistryInt32(
                Registry.CurrentUser,
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                "AppsUseLightTheme");
            return value.HasValue ? value.Value == 0 : (bool?)null;
        }

        private static string ResolveAccountImagePath()
        {
            string sid = WindowsIdentity.GetCurrent()?.User?.Value;
            if (string.IsNullOrEmpty(sid))
                return null;

            using (RegistryKey localMachine = RegistryKey.OpenBaseKey(
                RegistryHive.LocalMachine,
                RegistryView.Registry64))
            using (RegistryKey key = localMachine.OpenSubKey(
                @"SOFTWARE\Microsoft\Windows\CurrentVersion\AccountPicture\Users\" + sid))
            {
                if (key == null)
                    return null;

                return key.GetValueNames()
                    .Where(name => name.StartsWith("Image", StringComparison.OrdinalIgnoreCase))
                    .Select(name => new
                    {
                        Name = name,
                        Size = int.TryParse(
                            name.Substring("Image".Length),
                            NumberStyles.None,
                            CultureInfo.InvariantCulture,
                            out int size) ? size : 0,
                        Path = key.GetValue(name) as string
                    })
                    .Where(candidate => !string.IsNullOrWhiteSpace(candidate.Path) &&
                        File.Exists(candidate.Path))
                    .OrderByDescending(candidate => candidate.Size)
                    .Select(candidate => candidate.Path)
                    .FirstOrDefault();
            }
        }

        private static WindowsPreferenceAsset ReadAsset(
            string path,
            string baseName,
            long maximumBytes)
        {
            if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
                return null;

            var info = new FileInfo(path);
            if (info.Length <= 0 || info.Length > maximumBytes)
                return null;

            byte[] content = File.ReadAllBytes(path);
            string extension = DetectImageExtension(path, content);
            if (extension == null)
                return null;

            string hash;
            using (var sha256 = System.Security.Cryptography.SHA256.Create())
            {
                hash = BitConverter.ToString(sha256.ComputeHash(content))
                    .Replace("-", string.Empty)
                    .ToLowerInvariant();
            }
            return new WindowsPreferenceAsset
            {
                FileName = baseName + extension,
                Sha256 = hash,
                ContentBase64 = Convert.ToBase64String(content)
            };
        }

        private static string DetectImageExtension(string path, byte[] content)
        {
            string extension = Path.GetExtension(path)?.ToLowerInvariant();
            if (new[] { ".jpg", ".jpeg", ".png", ".bmp", ".gif", ".webp", ".tif", ".tiff" }
                .Contains(extension, StringComparer.Ordinal))
            {
                return extension == ".jpeg" ? ".jpg" : extension;
            }
            if (content.Length >= 3 && content[0] == 0xff && content[1] == 0xd8 && content[2] == 0xff)
                return ".jpg";
            if (content.Length >= 8 && content.Take(8).SequenceEqual(
                new byte[] { 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a }))
                return ".png";
            if (content.Length >= 2 && content[0] == 0x42 && content[1] == 0x4d)
                return ".bmp";
            if (content.Length >= 6 && Encoding.ASCII.GetString(content, 0, 6).StartsWith("GIF8"))
                return ".gif";
            if (content.Length >= 12 && Encoding.ASCII.GetString(content, 0, 4) == "RIFF" &&
                Encoding.ASCII.GetString(content, 8, 4) == "WEBP")
                return ".webp";
            return null;
        }

        private static bool? ReadMouseNaturalScroll()
        {
            var values = new HashSet<int>();
            try
            {
                using (RegistryKey localMachine = RegistryKey.OpenBaseKey(
                    RegistryHive.LocalMachine,
                    RegistryView.Registry64))
                using (RegistryKey hid = localMachine.OpenSubKey(
                    @"SYSTEM\CurrentControlSet\Enum\HID"))
                {
                    if (hid == null)
                        return null;
                    foreach (string hardwareName in hid.GetSubKeyNames())
                    using (RegistryKey hardware = hid.OpenSubKey(hardwareName))
                    {
                        if (hardware == null)
                            continue;
                        foreach (string instanceName in hardware.GetSubKeyNames())
                        using (RegistryKey instance = hardware.OpenSubKey(instanceName))
                        {
                            if (instance == null || IsTouchpadDevice(instance))
                                continue;
                            using (RegistryKey parameters = instance.OpenSubKey("Device Parameters"))
                            {
                                int? value = ConvertRegistryInt32(parameters?.GetValue("FlipFlopWheel"));
                                if (value == 0 || value == 1)
                                    values.Add(value.Value);
                            }
                        }
                    }
                }
            }
            catch (Exception exception) when (
                exception is UnauthorizedAccessException ||
                exception is System.Security.SecurityException ||
                exception is IOException)
            {
                return null;
            }
            return values.Count == 1 ? values.Single() == 1 : (bool?)null;
        }

        private static bool IsTouchpadDevice(RegistryKey instance)
        {
            string text = string.Join(
                " ",
                new[]
                {
                    instance.GetValue("FriendlyName") as string,
                    instance.GetValue("DeviceDesc") as string
                }.Where(value => !string.IsNullOrWhiteSpace(value)))
                .ToLowerInvariant();
            return text.Contains("touchpad") ||
                text.Contains("touch pad") ||
                text.Contains("trackpad") ||
                text.Contains("clickpad");
        }

        private static bool? ReadTouchpadSetting(string name, int defaultValue)
        {
            using (RegistryKey key = Registry.CurrentUser.OpenSubKey(
                @"SOFTWARE\Microsoft\Windows\CurrentVersion\PrecisionTouchPad"))
            {
                if (key == null)
                    return null;
                int? value = ConvertRegistryInt32(key.GetValue(name));
                int effective = value ?? defaultValue;
                return effective != 0;
            }
        }

        internal static uint ConvertKeyboardSpeedToInterval(uint speed)
        {
            double repetitionsPerSecond = 2.5 + speed * (27.5 / 31.0);
            return (uint)Math.Max(1, Math.Round(1000.0 / repetitionsPerSecond));
        }

        private static string MapLidAction(uint? action)
        {
            switch (action)
            {
                case 0: return "nothing";
                case 1: return "suspend";
                case 2: return "hibernate";
                case 3: return "shutdown";
                default: return null;
            }
        }

        private static uint? ReadSystemParameter(uint action)
        {
            return SystemParametersInfo(action, 0, out uint value, 0) ? value : (uint?)null;
        }

        private static bool ReadRegistryBoolean(
            RegistryKey root,
            string path,
            string name,
            bool defaultValue)
        {
            int? value = ReadRegistryInt32(root, path, name);
            return value.HasValue ? value.Value != 0 : defaultValue;
        }

        private static uint? ReadRegistryUInt32(RegistryKey root, string path, string name)
        {
            int? value = ReadRegistryInt32(root, path, name);
            return value.HasValue && value.Value >= 0 ? (uint)value.Value : (uint?)null;
        }

        private static int? ReadRegistryInt32(RegistryKey root, string path, string name)
        {
            using (RegistryKey key = root.OpenSubKey(path))
                return ConvertRegistryInt32(key?.GetValue(name));
        }

        private static int? ConvertRegistryInt32(object value)
        {
            if (value is int integer)
                return integer;
            if (value is long longValue && longValue >= int.MinValue && longValue <= int.MaxValue)
                return (int)longValue;
            if (int.TryParse(
                value as string,
                NumberStyles.Integer,
                CultureInfo.InvariantCulture,
                out int parsed))
            {
                return parsed;
            }
            return null;
        }

        private sealed class ActivePowerScheme : IDisposable
        {
            private readonly IntPtr _nativeGuid;
            private readonly Guid _schemeGuid;

            private ActivePowerScheme(IntPtr nativeGuid, Guid schemeGuid)
            {
                _nativeGuid = nativeGuid;
                _schemeGuid = schemeGuid;
            }

            public static ActivePowerScheme TryOpen()
            {
                uint result = PowerGetActiveScheme(IntPtr.Zero, out IntPtr pointer);
                if (result != 0 || pointer == IntPtr.Zero)
                    return null;
                return new ActivePowerScheme(pointer, Marshal.PtrToStructure<Guid>(pointer));
            }

            public uint? ReadAc(Guid subgroup, Guid setting)
            {
                Guid scheme = _schemeGuid;
                uint result = PowerReadACValueIndex(
                    IntPtr.Zero,
                    ref scheme,
                    ref subgroup,
                    ref setting,
                    out uint value);
                return result == 0 ? value : (uint?)null;
            }

            public uint? ReadDc(Guid subgroup, Guid setting)
            {
                Guid scheme = _schemeGuid;
                uint result = PowerReadDCValueIndex(
                    IntPtr.Zero,
                    ref scheme,
                    ref subgroup,
                    ref setting,
                    out uint value);
                return result == 0 ? value : (uint?)null;
            }

            public void Dispose()
            {
                if (_nativeGuid != IntPtr.Zero)
                    LocalFree(_nativeGuid);
            }
        }
    }
}
