using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Libertix.BootGuardian
{
    internal sealed class FirmwareEnvironment : IDisposable
    {
        private const string GlobalGuid = "{8BE4DF61-93CA-11D2-AA0D-00E098032B8C}";
        private const uint DefaultAttributes = 0x00000007;
        private IntPtr _token;

        internal FirmwareEnvironment()
        {
            if (!NativeMethods.OpenProcessToken(
                NativeMethods.GetCurrentProcess(),
                NativeMethods.TokenAdjustPrivileges | NativeMethods.TokenQuery,
                out _token))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            if (!NativeMethods.LookupPrivilegeValue(null, "SeSystemEnvironmentPrivilege", out NativeMethods.Luid luid))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            var privileges = new NativeMethods.TokenPrivileges
            {
                PrivilegeCount = 1,
                Luid = luid,
                Attributes = NativeMethods.SePrivilegeEnabled
            };
            NativeMethods.SetLastError(0);
            if (!NativeMethods.AdjustTokenPrivileges(
                _token, false, ref privileges, 0, IntPtr.Zero, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            int error = Marshal.GetLastWin32Error();
            if (error == NativeMethods.ErrorNotAllAssigned)
                throw new Win32Exception(error, "SeSystemEnvironmentPrivilege is not assigned.");
        }

        internal byte[] Read(string name, bool allowMissing = false)
        {
            int length = 256;
            while (length <= 1024 * 1024)
            {
                var buffer = new byte[length];
                uint read = NativeMethods.GetFirmwareEnvironmentVariableEx(
                    name, GlobalGuid, buffer, (uint)buffer.Length, out _);
                if (read > 0)
                {
                    var result = new byte[read];
                    Buffer.BlockCopy(buffer, 0, result, 0, (int)read);
                    return result;
                }
                int error = Marshal.GetLastWin32Error();
                if (allowMissing && error == NativeMethods.ErrorEnvVarNotFound)
                    return null;
                if (error != NativeMethods.ErrorInsufficientBuffer)
                    throw new Win32Exception(error, "Cannot read firmware variable " + name + ".");
                length = checked(length * 2);
            }
            throw new InvalidOperationException("Firmware variable exceeds the guarded size limit: " + name);
        }

        internal void Write(string name, byte[] value)
        {
            if (value == null || value.Length == 0)
                throw new ArgumentException("Firmware value must not be empty.", nameof(value));
            if (!NativeMethods.SetFirmwareEnvironmentVariableEx(
                name, GlobalGuid, value, (uint)value.Length, DefaultAttributes))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot write firmware variable " + name + ".");
        }

        internal static ushort[] ParseBootOrder(byte[] bytes)
        {
            if (bytes == null || bytes.Length == 0 || bytes.Length % 2 != 0)
                throw new InvalidOperationException("UEFI BootOrder has an invalid byte length.");
            var result = new ushort[bytes.Length / 2];
            for (int index = 0; index < result.Length; index++)
                result[index] = BitConverter.ToUInt16(bytes, index * 2);
            return result;
        }

        internal static byte[] EncodeBootOrder(IEnumerable<ushort> values)
        {
            var bytes = new List<byte>();
            foreach (ushort value in values)
                bytes.AddRange(BitConverter.GetBytes(value));
            if (bytes.Count == 0)
                throw new InvalidOperationException("UEFI BootOrder cannot be empty.");
            return bytes.ToArray();
        }

        public void Dispose()
        {
            if (_token != IntPtr.Zero)
            {
                NativeMethods.CloseHandle(_token);
                _token = IntPtr.Zero;
            }
        }
    }
}
