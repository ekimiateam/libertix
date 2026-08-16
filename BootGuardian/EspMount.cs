using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace Libertix.BootGuardian
{
    internal sealed class EspMount : IDisposable
    {
        private readonly string _mountPoint;
        private bool _mounted;

        internal EspMount(string volumePath)
        {
            _mountPoint = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                "Libertix",
                "BootGuardian",
                "EspMount") + Path.DirectorySeparatorChar;
            Directory.CreateDirectory(_mountPoint);
            var existing = new StringBuilder(64);
            if (NativeMethods.GetVolumeNameForVolumeMountPoint(
                _mountPoint, existing, (uint)existing.Capacity))
            {
                if (!string.Equals(existing.ToString(), volumePath, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Boot guardian mount point belongs to another volume.");
                _mounted = true;
                return;
            }
            if (!NativeMethods.SetVolumeMountPoint(_mountPoint, volumePath))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot mount the recorded ESP volume.");
            _mounted = true;
        }

        internal string Root => _mountPoint;

        public void Dispose()
        {
            if (_mounted)
            {
                if (!NativeMethods.DeleteVolumeMountPoint(_mountPoint))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot unmount the recorded ESP volume.");
                _mounted = false;
            }
        }
    }
}
