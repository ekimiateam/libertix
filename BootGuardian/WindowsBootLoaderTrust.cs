using System;
using System.IO;
using System.Runtime.InteropServices;

namespace Libertix.BootGuardian
{
    internal static class WindowsBootLoaderTrust
    {
        internal static bool IsCurrentWindowsLoader(string candidate, string expectedHash)
        {
            string windowsLoader = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"Boot\EFI\bootmgfw.efi");
            if (!File.Exists(windowsLoader) || Hashing.Sha256File(windowsLoader) != expectedHash ||
                Hashing.Sha256File(candidate) != expectedHash)
                return false;
            return VerifySignature(candidate);
        }

        private static bool VerifySignature(string path)
        {
            var file = new TrustFile { Size = (uint)Marshal.SizeOf(typeof(TrustFile)), Path = path };
            IntPtr filePointer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(TrustFile)));
            Marshal.StructureToPtr(file, filePointer, false);
            var data = new TrustData {
                Size = (uint)Marshal.SizeOf(typeof(TrustData)), UiChoice = 2, UnionChoice = 1,
                File = filePointer, StateAction = 1,
                // Preshutdown validation must never wait on certificate downloads.
                ProviderFlags = 0x1000 | 0x2000
            };
            Guid action = new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");
            try
            {
                return WinVerifyTrust(new IntPtr(-1), ref action, ref data) == 0;
            }
            finally
            {
                data.StateAction = 2;
                WinVerifyTrust(new IntPtr(-1), ref action, ref data);
                Marshal.DestroyStructure(filePointer, typeof(TrustFile));
                Marshal.FreeHGlobal(filePointer);
            }
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct TrustFile
        {
            internal uint Size;
            [MarshalAs(UnmanagedType.LPWStr)] internal string Path;
            internal IntPtr FileHandle;
            internal IntPtr KnownSubject;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct TrustData
        {
            internal uint Size;
            internal IntPtr PolicyCallback;
            internal IntPtr SipClientData;
            internal uint UiChoice;
            internal uint RevocationChecks;
            internal uint UnionChoice;
            internal IntPtr File;
            internal uint StateAction;
            internal IntPtr StateData;
            internal IntPtr UrlReference;
            internal uint ProviderFlags;
            internal uint UiContext;
            internal IntPtr SignatureSettings;
        }

        [DllImport("wintrust.dll", ExactSpelling = true)]
        private static extern int WinVerifyTrust(IntPtr window, ref Guid action, ref TrustData data);
    }
}
