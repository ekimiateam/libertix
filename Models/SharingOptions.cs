namespace Libertix.Models
{
    public sealed class SharingOptions
    {
        public bool ShareWindowsFilesInLinux { get; set; } = true;
        public bool ShareLinuxFilesInWindows { get; set; } = true;
    }
}
