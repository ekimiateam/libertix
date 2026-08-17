using System;
using System.ComponentModel;
using System.IO;

namespace Libertix.BootGuardian
{
    internal static class AtomicFile
    {
        internal static void WriteUtf8(string destination, string contents)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(destination));
            string temporary = Path.Combine(
                Path.GetDirectoryName(destination),
                "." + Path.GetFileName(destination) + "." + Guid.NewGuid().ToString("N") + ".tmp");
            try
            {
                File.WriteAllText(temporary, contents, new System.Text.UTF8Encoding(false));
                using (FileStream stream = new FileStream(temporary, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
                    stream.Flush(true);
                if (!NativeMethods.MoveFileEx(
                    temporary,
                    destination,
                    NativeMethods.MoveFileReplaceExisting | NativeMethods.MoveFileWriteThrough))
                    throw new Win32Exception(System.Runtime.InteropServices.Marshal.GetLastWin32Error());
            }
            finally
            {
                if (File.Exists(temporary))
                    File.Delete(temporary);
            }
        }

        internal static void CopyVerified(
            string source,
            string destination,
            string expectedHash,
            Action verifyCommitAllowed = null)
        {
            if (!File.Exists(source) || Hashing.Sha256File(source) != expectedHash)
                throw new InvalidDataException("Boot guardian repair source is missing or has an unexpected hash: " + source);
            Directory.CreateDirectory(Path.GetDirectoryName(destination));
            string temporary = Path.Combine(
                Path.GetDirectoryName(destination),
                "." + Path.GetFileName(destination) + "." + Guid.NewGuid().ToString("N") + ".tmp");
            try
            {
                File.Copy(source, temporary, false);
                using (FileStream stream = new FileStream(temporary, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
                    stream.Flush(true);
                if (Hashing.Sha256File(temporary) != expectedHash)
                    throw new InvalidDataException("Boot guardian staged repair file has an unexpected hash: " + destination);
                verifyCommitAllowed?.Invoke();
                if (!NativeMethods.MoveFileEx(
                    temporary,
                    destination,
                    NativeMethods.MoveFileReplaceExisting | NativeMethods.MoveFileWriteThrough))
                    throw new Win32Exception(System.Runtime.InteropServices.Marshal.GetLastWin32Error());
                if (Hashing.Sha256File(destination) != expectedHash)
                    throw new InvalidDataException("Boot guardian repaired file has an unexpected hash: " + destination);
            }
            finally
            {
                if (File.Exists(temporary))
                    File.Delete(temporary);
            }
        }
    }
}
