using System;

namespace Libertix.Models
{
    /// <summary>
    /// Typed state shared by one installer navigation flow.
    /// Pages receive this instance explicitly instead of using Application.Properties.
    /// </summary>
    public sealed class InstallationState
    {
        private bool _isInstallationRunning;

        public DistroInfo SelectedDistro { get; set; }
        public CompatibilityInfo Compatibility { get; set; }
        public SharingOptions Sharing { get; set; } = new SharingOptions();
        public AccountInfo Account { get; set; }
        public string UefiRecoveryStatePath { get; set; }

        public bool IsInstallationRunning => _isInstallationRunning;

        public event EventHandler InstallationRunningChanged;

        public void SetInstallationRunning(bool isRunning)
        {
            if (_isInstallationRunning == isRunning)
                return;

            _isInstallationRunning = isRunning;
            InstallationRunningChanged?.Invoke(this, EventArgs.Empty);
        }
    }
}
