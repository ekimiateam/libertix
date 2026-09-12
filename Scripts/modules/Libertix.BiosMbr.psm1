Set-StrictMode -Version Latest

function Initialize-LibertixBiosMbrIo {
    <#
    .SYNOPSIS
    Makes the aligned, verified BIOS sector restoration API available in this process.
    #>
    if ("Libertix.BiosMbrIo" -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Libertix {
    public static class BiosMbrIo {
        public static void VerifyBootCode(string path, int sectorSize, byte[] backup) {
            if (sectorSize != 512 && sectorSize != 4096)
                throw new InvalidDataException("Unsupported BIOS disk sector size.");
            if (backup == null || backup.Length != 512 || backup[510] != 0x55 || backup[511] != 0xaa)
                throw new InvalidDataException("Invalid pre-GRUB MBR backup signature.");
            IntPtr buffer = VirtualAlloc(IntPtr.Zero, (UIntPtr)sectorSize, 0x3000, 4);
            if (buffer == IntPtr.Zero) Fail("allocate aligned BIOS sector");
            try {
                using (SafeFileHandle disk = CreateFile(path, 0x80000000, 3, IntPtr.Zero, 3, 0x20000000, IntPtr.Zero)) {
                    if (disk.IsInvalid) Fail("open BIOS disk for verification");
                    byte[] current = ReadSector(disk, buffer, sectorSize);
                    for (int i = 0; i < 440; i++) {
                        if (current[i] != backup[i])
                            throw new InvalidDataException("Restored BIOS boot code differs from its backup.");
                    }
                    if (current[510] != 0x55 || current[511] != 0xaa)
                        throw new InvalidDataException("Restored BIOS MBR signature is invalid.");
                }
            } finally { VirtualFree(buffer, UIntPtr.Zero, 0x8000); }
        }

        public static void Restore(string path, int sectorSize, byte[] backup) {
            if (sectorSize != 512 && sectorSize != 4096)
                throw new InvalidDataException("Unsupported BIOS disk sector size.");
            if (backup == null || backup.Length != 512 || backup[510] != 0x55 || backup[511] != 0xaa)
                throw new InvalidDataException("Invalid pre-GRUB MBR backup signature.");
            // VirtualAlloc provides page alignment for noncached disk I/O.
            IntPtr buffer = VirtualAlloc(IntPtr.Zero, (UIntPtr)sectorSize, 0x3000, 4);
            if (buffer == IntPtr.Zero) Fail("allocate aligned BIOS sector");
            try {
                using (SafeFileHandle disk = CreateFile(path, 0xc0000000, 3, IntPtr.Zero, 3, 0xa0000000, IntPtr.Zero)) {
                    if (disk.IsInvalid) Fail("open BIOS disk");
                    byte[] current = ReadSector(disk, buffer, sectorSize);
                    if (current[510] != 0x55 || current[511] != 0xaa)
                        throw new InvalidDataException("Current BIOS MBR signature is invalid.");
                    byte[] expected = (byte[])current.Clone();
                    // Preserve the disk signature, partition table, and all bytes beyond the MBR.
                    Array.Copy(backup, 0, expected, 0, 440);
                    if (!Equal(current, expected)) {
                        SeekStart(disk);
                        Marshal.Copy(expected, 0, buffer, sectorSize);
                        uint written;
                        if (!WriteFile(disk, buffer, (uint)sectorSize, out written, IntPtr.Zero))
                            Fail("write BIOS sector");
                        if (written != sectorSize) throw new IOException("Incomplete BIOS sector write.");
                        if (!FlushFileBuffers(disk)) Fail("flush BIOS sector");
                    }
                    if (!Equal(ReadSector(disk, buffer, sectorSize), expected))
                        throw new IOException("BIOS sector verification failed, including preserved partition bytes.");
                }
            } finally { VirtualFree(buffer, UIntPtr.Zero, 0x8000); }
        }

        private static byte[] ReadSector(SafeFileHandle disk, IntPtr buffer, int size) {
            SeekStart(disk);
            uint read;
            if (!ReadFile(disk, buffer, (uint)size, out read, IntPtr.Zero)) Fail("read BIOS sector");
            if (read != size) throw new IOException("Incomplete BIOS sector read.");
            byte[] bytes = new byte[size];
            Marshal.Copy(buffer, bytes, 0, size);
            return bytes;
        }
        private static void SeekStart(SafeFileHandle disk) {
            long position;
            if (!SetFilePointerEx(disk, 0, out position, 0)) Fail("seek BIOS sector");
        }
        private static bool Equal(byte[] left, byte[] right) {
            for (int i = 0; i < left.Length; i++) if (left[i] != right[i]) return false;
            return true;
        }
        private static void Fail(string operation) {
            int code = Marshal.GetLastWin32Error();
            throw new IOException("Cannot " + operation + " (Win32=" + code + ").", new Win32Exception(code));
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateFileW")]
        private static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool ReadFile(SafeFileHandle file, IntPtr buffer, uint size, out uint read, IntPtr overlapped);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool WriteFile(SafeFileHandle file, IntPtr buffer, uint size, out uint written, IntPtr overlapped);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetFilePointerEx(SafeFileHandle file, long offset, out long position, uint method);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool FlushFileBuffers(SafeFileHandle file);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr VirtualAlloc(IntPtr address, UIntPtr size, uint allocation, uint protection);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool VirtualFree(IntPtr address, UIntPtr size, uint freeType);
    }
}
'@
}

Export-ModuleMember -Function Initialize-LibertixBiosMbrIo
