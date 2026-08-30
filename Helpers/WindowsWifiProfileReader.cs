using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Runtime.InteropServices;
using System.Xml.Linq;
using Libertix.Installation;

namespace Libertix.Helpers
{
    internal sealed class WindowsWifiProfile
    {
        public string Id { get; set; }
        public string Ssid { get; set; }
        public string Security { get; set; }
        public string Secret { get; set; }
        public bool Hidden { get; set; }
        public bool AutoConnect { get; set; }
    }

    internal static class WindowsWifiProfileReader
    {
        private const uint WlanClientVersionLonghorn = 2;
        private const uint WlanProfileGetPlaintextKey = 4;
        private const int ErrorSuccess = 0;
        private const int ErrorAccessDenied = 5;
        private const int ErrorServiceNotActive = 1062;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct WlanInterfaceInfo
        {
            public Guid InterfaceGuid;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
            public string Description;

            public int State;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct WlanProfileInfo
        {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
            public string ProfileName;

            public uint Flags;
        }

        [DllImport("wlanapi.dll")]
        private static extern int WlanOpenHandle(
            uint clientVersion,
            IntPtr reserved,
            out uint negotiatedVersion,
            out IntPtr clientHandle);

        [DllImport("wlanapi.dll")]
        private static extern int WlanCloseHandle(IntPtr clientHandle, IntPtr reserved);

        [DllImport("wlanapi.dll")]
        private static extern int WlanEnumInterfaces(
            IntPtr clientHandle,
            IntPtr reserved,
            out IntPtr interfaceList);

        [DllImport("wlanapi.dll", CharSet = CharSet.Unicode)]
        private static extern int WlanGetProfileList(
            IntPtr clientHandle,
            ref Guid interfaceGuid,
            IntPtr reserved,
            out IntPtr profileList);

        [DllImport("wlanapi.dll", CharSet = CharSet.Unicode)]
        private static extern int WlanGetProfile(
            IntPtr clientHandle,
            ref Guid interfaceGuid,
            string profileName,
            IntPtr reserved,
            out IntPtr profileXml,
            ref uint flags,
            out uint grantedAccess);

        [DllImport("wlanapi.dll")]
        private static extern void WlanFreeMemory(IntPtr memory);

        public static IReadOnlyList<WindowsWifiProfile> ReadAll()
        {
            int result = WlanOpenHandle(
                WlanClientVersionLonghorn,
                IntPtr.Zero,
                out _,
                out IntPtr clientHandle);
            if (result == ErrorServiceNotActive)
                return Array.Empty<WindowsWifiProfile>();
            ThrowIfError(result, "Windows Wi-Fi profile access could not be initialized.");

            try
            {
                var profiles = new Dictionary<string, WindowsWifiProfile>(StringComparer.Ordinal);
                foreach (Guid interfaceGuid in EnumerateInterfaces(clientHandle))
                {
                    foreach (string profileName in EnumerateProfileNames(clientHandle, interfaceGuid))
                    {
                        WindowsWifiProfile profile = ReadProfile(
                            clientHandle,
                            interfaceGuid,
                            profileName);
                        if (profile == null)
                            continue;

                        string identity = profile.Security + "\n" + profile.Ssid;
                        if (profiles.TryGetValue(identity, out WindowsWifiProfile existing))
                        {
                            if (!string.Equals(existing.Secret, profile.Secret, StringComparison.Ordinal))
                            {
                                throw new InvalidOperationException(
                                    "Two saved personal Wi-Fi profiles use the same network identity with different secrets.");
                            }
                            existing.AutoConnect = existing.AutoConnect || profile.AutoConnect;
                            existing.Hidden = existing.Hidden || profile.Hidden;
                            continue;
                        }

                        profiles.Add(identity, profile);
                        if (profiles.Count > WindowsPreferenceMigrationContract.MaximumWifiProfiles)
                        {
                            throw new InvalidOperationException(
                                "The saved personal Wi-Fi profile count exceeds the supported limit.");
                        }
                    }
                }
                return profiles.Values
                    .OrderBy(profile => profile.Id, StringComparer.Ordinal)
                    .ToArray();
            }
            finally
            {
                WlanCloseHandle(clientHandle, IntPtr.Zero);
            }
        }

        private static IEnumerable<Guid> EnumerateInterfaces(IntPtr clientHandle)
        {
            int result = WlanEnumInterfaces(clientHandle, IntPtr.Zero, out IntPtr list);
            ThrowIfError(result, "Windows Wi-Fi interfaces could not be enumerated.");
            try
            {
                int count = Marshal.ReadInt32(list, 0);
                int itemSize = Marshal.SizeOf<WlanInterfaceInfo>();
                long itemAddress = list.ToInt64() + 8;
                for (int index = 0; index < count; index++)
                {
                    var item = Marshal.PtrToStructure<WlanInterfaceInfo>(
                        new IntPtr(itemAddress + (long)index * itemSize));
                    yield return item.InterfaceGuid;
                }
            }
            finally
            {
                WlanFreeMemory(list);
            }
        }

        private static IEnumerable<string> EnumerateProfileNames(
            IntPtr clientHandle,
            Guid interfaceGuid)
        {
            int result = WlanGetProfileList(
                clientHandle,
                ref interfaceGuid,
                IntPtr.Zero,
                out IntPtr list);
            ThrowIfError(result, "Windows Wi-Fi profiles could not be enumerated.");
            try
            {
                int count = Marshal.ReadInt32(list, 0);
                int itemSize = Marshal.SizeOf<WlanProfileInfo>();
                long itemAddress = list.ToInt64() + 8;
                for (int index = 0; index < count; index++)
                {
                    var item = Marshal.PtrToStructure<WlanProfileInfo>(
                        new IntPtr(itemAddress + (long)index * itemSize));
                    if (!string.IsNullOrWhiteSpace(item.ProfileName))
                        yield return item.ProfileName;
                }
            }
            finally
            {
                WlanFreeMemory(list);
            }
        }

        private static WindowsWifiProfile ReadProfile(
            IntPtr clientHandle,
            Guid interfaceGuid,
            string profileName)
        {
            uint flags = WlanProfileGetPlaintextKey;
            int result = WlanGetProfile(
                clientHandle,
                ref interfaceGuid,
                profileName,
                IntPtr.Zero,
                out IntPtr xmlPointer,
                ref flags,
                out _);
            if (result == ErrorAccessDenied)
            {
                flags = 0;
                result = WlanGetProfile(
                    clientHandle,
                    ref interfaceGuid,
                    profileName,
                    IntPtr.Zero,
                    out xmlPointer,
                    ref flags,
                    out _);
            }
            ThrowIfError(result, "A saved Windows Wi-Fi profile could not be read.");

            try
            {
                string xml = Marshal.PtrToStringUni(xmlPointer);
                WindowsWifiProfile profile = ParseProfile(profileName, xml);
                if (profile != null &&
                    profile.Security != "open" &&
                    profile.Security != "owe" &&
                    string.IsNullOrEmpty(profile.Secret))
                {
                    throw new InvalidOperationException(
                        "A saved personal Wi-Fi profile did not expose its stored secret.");
                }
                return profile;
            }
            finally
            {
                WlanFreeMemory(xmlPointer);
            }
        }

        internal static WindowsWifiProfile ParseProfile(string profileName, string xml)
        {
            XDocument document;
            try
            {
                document = XDocument.Parse(xml ?? string.Empty, LoadOptions.None);
            }
            catch (Exception exception) when (
                exception is System.Xml.XmlException ||
                exception is ArgumentException)
            {
                throw new InvalidOperationException(
                    "A saved Windows Wi-Fi profile contains invalid XML.",
                    exception);
            }

            string authentication = ElementValue(document, "authentication");
            string encryption = ElementValue(document, "encryption");
            if (string.Equals(
                ElementValue(document, "useOneX"),
                "true",
                StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }
            if (string.Equals(encryption, "WEP", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(encryption, "WEP40", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(encryption, "WEP104", StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }

            string security;
            if (string.Equals(authentication, "open", StringComparison.OrdinalIgnoreCase) &&
                string.Equals(encryption, "none", StringComparison.OrdinalIgnoreCase))
            {
                security = "open";
            }
            else if (string.Equals(authentication, "OWE", StringComparison.OrdinalIgnoreCase))
            {
                security = "owe";
            }
            else if (
                string.Equals(authentication, "WPAPSK", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(authentication, "WPA2PSK", StringComparison.OrdinalIgnoreCase))
            {
                security = "wpa-psk";
            }
            else if (string.Equals(authentication, "WPA3SAE", StringComparison.OrdinalIgnoreCase))
            {
                security = "sae";
            }
            else
            {
                return null;
            }

            string ssid = document.Descendants()
                .Where(element => element.Name.LocalName == "SSID")
                .SelectMany(element => element.Elements())
                .FirstOrDefault(element => element.Name.LocalName == "name")
                ?.Value;
            if (string.IsNullOrEmpty(ssid) ||
                System.Text.Encoding.UTF8.GetByteCount(ssid) > 32 ||
                ssid.IndexOf('\0') >= 0)
            {
                throw new InvalidOperationException(
                    "A saved Windows Wi-Fi profile contains an invalid SSID.");
            }

            string secret = security == "open" || security == "owe"
                ? null
                : ElementValue(document, "keyMaterial");
            if (secret != null && !string.Equals(
                ElementValue(document, "protected"),
                "false",
                StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException(
                    "A saved personal Wi-Fi profile did not expose its stored secret in plaintext.");
            }
            if (security == "wpa-psk" && !IsValidWpaPsk(secret))
            {
                throw new InvalidOperationException(
                    "A saved WPA/WPA2 Personal profile contains an invalid stored secret.");
            }
            if (security == "sae" &&
                (string.IsNullOrEmpty(secret) || secret.Length > 63 || HasControlCharacter(secret)))
            {
                throw new InvalidOperationException(
                    "A saved WPA3 Personal profile contains an invalid stored secret.");
            }

            return new WindowsWifiProfile
            {
                Id = string.IsNullOrWhiteSpace(profileName) ? ssid : profileName,
                Ssid = ssid,
                Security = security,
                Secret = secret,
                Hidden = string.Equals(
                    ElementValue(document, "nonBroadcast"),
                    "true",
                    StringComparison.OrdinalIgnoreCase),
                AutoConnect = !string.Equals(
                    ElementValue(document, "connectionMode"),
                    "manual",
                    StringComparison.OrdinalIgnoreCase)
            };
        }

        private static string ElementValue(XDocument document, string localName)
        {
            return document.Descendants()
                .FirstOrDefault(element => element.Name.LocalName == localName)
                ?.Value;
        }

        private static bool IsValidWpaPsk(string secret)
        {
            if (string.IsNullOrEmpty(secret) || HasControlCharacter(secret))
                return false;
            if (secret.Length == 64)
                return secret.All(character => Uri.IsHexDigit(character));
            return secret.Length >= 8 && secret.Length <= 63;
        }

        private static bool HasControlCharacter(string value)
        {
            return value.Any(char.IsControl);
        }

        private static void ThrowIfError(int error, string message)
        {
            if (error != ErrorSuccess)
                throw new Win32Exception(error, message);
        }
    }
}
