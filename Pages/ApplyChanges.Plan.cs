using System;
using System.Globalization;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using Libertix.Helpers;
using Libertix.Installation;
using Libertix.Models;

namespace Libertix.Pages
{
    /// <summary>
    /// Owns the firmware-neutral installation contract and durable execution
    /// ledger used by the Windows, live, target, and rollback stages.
    /// </summary>
    public partial class ApplyChanges
    {
        private const string InstallationPlanFileName = "installation-plan.json";
        private const string InstallationStateFileName = "installation-state.json";

        private InstallationPlan _installationPlan;
        private InstallationExecutionLedger _executionLedger;
        private string _installationPlanPath;

        private void InitializeInstallationContext(
            FirmwareType firmware,
            string persistenceRoot,
            string recoveryRoot,
            string recoveryRunId)
        {
            if (_storagePreflight == null)
                throw new InvalidOperationException("Storage preflight is required before creating the installation plan.");
            if (!(_installationState.SelectedDistro is DistroInfo distribution))
                throw new InvalidOperationException("A distribution is required before creating the installation plan.");
            if (!(_installationState.Account is AccountInfo account))
                throw new InvalidOperationException("A Linux account is required before creating the installation plan.");

            // User input is normalized exactly once. Every later component
            // consumes the resulting byte counts from the persisted plan.
            InstallationSizes sizes = InstallationSizePolicy.FromRequestedGigabytes(_linuxSizeGB);
            string systemDriveRoot =
                (Environment.GetEnvironmentVariable("SystemDrive") ?? WindowsSystemDrive)
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) +
                Path.DirectorySeparatorChar;
            string passwordHashWindowsPath = Path.Combine(persistenceRoot, "account-secret.env");
            string passwordHash = LinuxPasswordHasher.Hash(account.Password);

            string planId = !string.IsNullOrWhiteSpace(recoveryRunId)
                ? recoveryRunId
                : Guid.NewGuid().ToString("N");
            LinuxKeyboardConfiguration keyboard = WindowsKeyboardLayout.ResolveActive(
                Localization.GetKeyboardLayout());
            StartupOptions startupOptions = ((App)Application.Current).RuntimeOptions;
            _installationPlan = InstallationPlanFactory.Create(new InstallationPlanCreationOptions
            {
                PlanId = planId,
                Firmware = firmware,
                Distribution = distribution,
                Account = account,
                Sharing = _installationState.Sharing,
                Compatibility = _installationState.Compatibility,
                Storage = _storagePreflight,
                Sizes = sizes,
                Keyboard = keyboard,
                StartupOptions = startupOptions,
                LanguageCode = Localization.CurrentLanguage,
                SystemLanguage = Localization.GetLinuxLocale(),
                Timezone = Localization.GetWindowsTimezoneAsLinux(),
                SystemDriveRoot = systemDriveRoot,
                PasswordHashWindowsPath = passwordHashWindowsPath,
                WindowsProfilesJsonBase64 = GetWindowsProfilesJsonBase64(),
                RecoveryRootWindows = recoveryRoot,
                RecoveryRunId = recoveryRunId
            });

            ProtectDirectoryForInstallerAndSystem(persistenceRoot);
            // The live reads this file as a POSIX line. A Windows CRLF leaves
            // a carriage return in the crypt hash after Bash strips only LF.
            WriteProtectedInstallerFile(passwordHashWindowsPath, passwordHash + "\n");
            _installationPlanPath = Path.Combine(persistenceRoot, InstallationPlanFileName);
            InstallationPlanSerializer.WriteAtomic(_installationPlanPath, _installationPlan);

            _executionLedger = InstallationExecutionLedger.Create(
                planId,
                Path.Combine(persistenceRoot, InstallationStateFileName));
            // The protected hash and validated plan are now durable. Keeping
            // the clear-text password referenced cannot help recovery or retry.
            account.ClearPassword();
            StartExecutionStep(InstallationStep.WindowsPreflightVerified);
            CompleteExecutionStep(InstallationStep.WindowsPreflightVerified);
            Log($"Installation plan created: {planId}, firmware={_installationPlan.Firmware}, " +
                $"final={sizes.FinalSizeGiB}GiB, staging={sizes.StagingSizeGiB}GiB, " +
                $"keyboard={keyboard.Layout}{FormatKeyboardVariant(keyboard.Variant)}, " +
                $"windowsKlid={keyboard.WindowsKeyboardIdentifier}, fallback={keyboard.UsedFallback}.");
        }

        private static string FormatKeyboardVariant(string variant)
        {
            return string.IsNullOrEmpty(variant) ? string.Empty : $"({variant})";
        }

        private async Task UpdateInstallerPartitionIdentityAsync(char driveLetter)
        {
            if (_installationPlan == null)
                throw new InvalidOperationException("Installation plan is not initialized.");

            string powershell = WindowsProcessRunner.ResolvePowerShell();
            string command =
                $"$p=Get-Partition -DriveLetter {char.ToUpperInvariant(driveLetter)} -ErrorAction Stop; " +
                "[Console]::Out.WriteLine(('{0}|{1}|{2}' -f $p.PartitionNumber,$p.Offset,$p.Size))";
            var result = await Task.Run(() => RunProcess(
                powershell,
                $"-NoProfile -Command {QuoteArgument(command)}",
                (int)WindowsProcessTimeouts.QuickCommand.TotalMilliseconds));
            if (result.exitCode != 0)
                throw new InvalidOperationException($"Installer partition identity query failed: {result.error}");

            string[] fields = result.output.Trim().Split('|');
            if (fields.Length != 3 ||
                !int.TryParse(fields[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out int number) ||
                !long.TryParse(fields[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out long offset) ||
                !long.TryParse(fields[2], NumberStyles.Integer, CultureInfo.InvariantCulture, out long size) ||
                number <= 0 || offset <= 0 || size <= 0)
            {
                throw new InvalidOperationException(
                    $"Installer partition identity query returned invalid data: {result.output.Trim()}");
            }

            // The partition number and offset do not exist until Windows has
            // created the staging volume. Persist the observed identity before
            // the live environment is allowed to consume the plan.
            InstallerPartitionPlan installer = _installationPlan.Disk.Installer;
            installer.Number = number;
            installer.OffsetBytes = offset;
            // MSFT_Disk.CreatePartition treats Size as an exact request and
            // returns an error when that extent cannot be created. Accepting a
            // different size here would hide a provider or geometry mismatch.
            if (size != installer.StagingSizeBytes)
            {
                throw new InvalidOperationException(
                    $"Installer staging size mismatch: expected {installer.StagingSizeBytes}, got {size}.");
            }
            InstallationPlanSerializer.WriteAtomic(_installationPlanPath, _installationPlan);
        }

        private void SetInstallationResizeMode(string resizeMode)
        {
            if (_installationPlan?.Disk?.Installer == null)
                throw new InvalidOperationException("Installation plan is not initialized.");
            if (resizeMode != InstallationResizeMode.WindowsOnline &&
                resizeMode != InstallationResizeMode.LiveOffline)
            {
                throw new ArgumentOutOfRangeException(nameof(resizeMode));
            }
            if (_installationPlan.Disk.Installer.Number.HasValue)
            {
                throw new InvalidOperationException(
                    "Resize mode cannot change after the staging partition exists.");
            }

            _installationPlan.Disk.Installer.ResizeMode = resizeMode;
            InstallationPlanValidator.Validate(_installationPlan);
            InstallationPlanSerializer.WriteAtomic(_installationPlanPath, _installationPlan);
            Log($"NTFS resize mode selected: {resizeMode}.");
        }

        private void PublishInstallationContextToLive(string liveRoot)
        {
            if (_installationPlan == null || _executionLedger == null)
                throw new InvalidOperationException("Installation context is not initialized.");

            // Publishing both documents together lets the live stage verify
            // intent and resume from the exact Windows-side transition ledger.
            InstallationPlanSerializer.WriteAtomic(
                Path.Combine(liveRoot, InstallationPlanFileName),
                _installationPlan);
            _executionLedger.Publish(Path.Combine(liveRoot, InstallationStateFileName));
        }

        private void StartExecutionStep(string step)
        {
            _executionLedger?.StartStep(step);
        }

        private void CompleteExecutionStep(string step)
        {
            _executionLedger?.CompleteStep(step);
        }

        private void RecordExecutionFailure(string code, string message, string component)
        {
            _executionLedger?.RecordFailure(code, message, component);
        }

        private void BeginExecutionRollback()
        {
            _executionLedger?.BeginRollback();
        }

        private void CompleteExecutionRollback()
        {
            _executionLedger?.CompleteRollback();
        }

        private void ReloadExecutionState()
        {
            _executionLedger?.Reload();
        }
    }
}
