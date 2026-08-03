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
        private InstallationStateMachine _executionStateMachine;
        private string _installationPlanPath;
        private string _executionStatePath;

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
            bool isUefi = firmware == FirmwareType.Uefi;
            string systemDriveRoot =
                (Environment.GetEnvironmentVariable("SystemDrive") ?? "C:")
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) +
                Path.DirectorySeparatorChar;
            string installerIsoPath = isUefi
                ? Path.Combine(
                    systemDriveRoot,
                    distribution.IsoInstallerFileName)
                : Path.Combine(
                    Path.GetTempPath(),
                    "Libertix",
                    distribution.IsoInstallerFileName);

            string planId = !string.IsNullOrWhiteSpace(recoveryRunId)
                ? recoveryRunId
                : Guid.NewGuid().ToString("N");
            _installationPlan = new InstallationPlan
            {
                PlanId = planId,
                CreatedAtUtc = DateTimeOffset.UtcNow,
                Firmware = isUefi ? InstallationFirmware.Uefi : InstallationFirmware.Bios,
                Distribution = new InstallationDistribution
                {
                    Name = distribution.Name,
                    InstallerIsoFileName = distribution.IsoInstallerFileName,
                    InstallerIsoUrl = distribution.IsoInstaller,
                    InstallerIsoWindowsPath = installerIsoPath,
                    InstallerIsoSha256 = distribution.IsoInstallerSha256.ToLowerInvariant(),
                    LiveIsoUrl = isUefi ? distribution.UefiIsoUrl : distribution.IsoUrl,
                    LiveIsoSha256 = (isUefi ? distribution.UefiIsoSha256 : distribution.IsoSha256)
                        .ToLowerInvariant()
                },
                Locale = new InstallationLocale
                {
                    LanguageCode = Localization.CurrentLanguage,
                    SystemLanguage = Localization.GetLinuxLocale(),
                    KeyboardLayout = Localization.GetKeyboardLayout(),
                    KeyboardModel = "pc105",
                    Timezone = Localization.GetWindowsTimezoneAsLinux()
                },
                Account = new InstallationAccount
                {
                    Username = account.Username,
                    PasswordHash = LinuxPasswordHasher.Hash(account.Password),
                    ComputerName = account.ComputerName
                },
                Disk = new InstallationDisk
                {
                    Number = _storagePreflight.SystemDiskNumber,
                    UniqueId = _storagePreflight.SystemDiskUniqueId.Trim(),
                    SizeBytes = _storagePreflight.SystemDiskSize,
                    LogicalSectorSizeBytes = _storagePreflight.LogicalSectorSize,
                    PartitionStyle = _storagePreflight.PartitionStyle,
                    SystemDrive = _storagePreflight.SystemDrive.ToUpperInvariant(),
                    Windows = _storagePreflight.WindowsPartition,
                    Boot = _storagePreflight.BootPartition,
                    Recovery = _storagePreflight.RecoveryPartition,
                    Installer = new InstallerPartitionPlan
                    {
                        FinalSizeBytes = sizes.FinalSizeBytes,
                        StagingSizeBytes = sizes.StagingSizeBytes
                    }
                },
                Features = new InstallationFeatures
                {
                    ShareWindowsFilesInLinux = _installationState.Sharing.ShareWindowsFilesInLinux,
                    ShareLinuxFilesInWindows = _installationState.Sharing.ShareLinuxFilesInWindows,
                    WindowsProfilesJsonBase64 = GetWindowsProfilesJsonBase64()
                },
                Runtime = new InstallationRuntime
                {
                    LowMemoryMode =
                        _installationState.Compatibility is CompatibilityInfo compatibility &&
                        compatibility.LowMemoryMode,
                    BootStrategy = isUefi
                        ? InstallationBootStrategy.UefiBootNext
                        : InstallationBootStrategy.BiosGrub4Dos,
                    RecoveryRootWindows = recoveryRoot,
                    RecoveryRunId = recoveryRunId
                }
            };

            Directory.CreateDirectory(persistenceRoot);
            _installationPlanPath = Path.Combine(persistenceRoot, InstallationPlanFileName);
            _executionStatePath = Path.Combine(persistenceRoot, InstallationStateFileName);
            InstallationPlanSerializer.WriteAtomic(_installationPlanPath, _installationPlan);

            _executionStateMachine = InstallationStateMachine.Create(planId);
            InstallationStateStore.WriteAtomic(_executionStatePath, _executionStateMachine.State);
            StartExecutionStep(InstallationStep.WindowsPreflightVerified);
            CompleteExecutionStep(InstallationStep.WindowsPreflightVerified);
            Log($"Installation plan created: {planId}, firmware={_installationPlan.Firmware}, " +
                $"final={sizes.FinalSizeGiB}GiB, staging={sizes.StagingSizeGiB}GiB.");
        }

        private async Task UpdateInstallerPartitionIdentityAsync(char driveLetter)
        {
            if (_installationPlan == null)
                throw new InvalidOperationException("Installation plan is not initialized.");

            string powershell = ResolveSystemExecutable(
                "WindowsPowerShell\\v1.0\\powershell.exe",
                "powershell.exe");
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
            if (size != installer.StagingSizeBytes)
            {
                throw new InvalidOperationException(
                    $"Installer staging size mismatch: expected {installer.StagingSizeBytes}, got {size}.");
            }
            InstallationPlanSerializer.WriteAtomic(_installationPlanPath, _installationPlan);
        }

        private void PublishInstallationContextToLive(string liveRoot)
        {
            if (_installationPlan == null || _executionStateMachine == null)
                throw new InvalidOperationException("Installation context is not initialized.");

            // Publishing both documents together lets the live stage verify
            // intent and resume from the exact Windows-side transition ledger.
            InstallationPlanSerializer.WriteAtomic(
                Path.Combine(liveRoot, InstallationPlanFileName),
                _installationPlan);
            InstallationStateStore.WriteAtomic(
                Path.Combine(liveRoot, InstallationStateFileName),
                _executionStateMachine.State);
        }

        private void StartExecutionStep(string step)
        {
            if (_executionStateMachine == null)
                return;
            _executionStateMachine.StartStep(step);
            PersistExecutionState();
        }

        private void CompleteExecutionStep(string step)
        {
            if (_executionStateMachine == null)
                return;
            _executionStateMachine.CompleteStep(step);
            PersistExecutionState();
        }

        private void RecordExecutionFailure(string code, string message, string component)
        {
            if (_executionStateMachine == null)
                return;
            if (_executionStateMachine.State.Status == InstallationStatus.RollbackRunning ||
                _executionStateMachine.State.Status == InstallationStatus.RolledBack ||
                _executionStateMachine.State.Status == InstallationStatus.Succeeded)
            {
                return;
            }
            _executionStateMachine.Fail(code, message, component);
            PersistExecutionState();
        }

        private void BeginExecutionRollback()
        {
            if (_executionStateMachine == null)
                return;
            if (_executionStateMachine.State.Status == InstallationStatus.Running ||
                _executionStateMachine.State.Status == InstallationStatus.Failed)
            {
                _executionStateMachine.BeginRollback();
                PersistExecutionState();
            }
        }

        private void CompleteExecutionRollback()
        {
            if (_executionStateMachine == null ||
                _executionStateMachine.State.Status != InstallationStatus.RollbackRunning)
            {
                return;
            }

            string[] compensatableSteps =
            {
                InstallationStep.WindowsTemporaryBootPrepared,
                InstallationStep.WindowsLiveMediaPrepared,
                InstallationStep.WindowsInstallerPartitionCreated,
                InstallationStep.WindowsSystemVolumeShrunk,
                InstallationStep.WindowsRecoveryArmed
            };
            foreach (string step in compensatableSteps)
            {
                if (_executionStateMachine.State.CompletedSteps.Contains(step))
                    _executionStateMachine.CompleteCompensation(step);
            }
            _executionStateMachine.CompleteRollback();
            PersistExecutionState();
        }

        private void PersistExecutionState()
        {
            InstallationStateStore.WriteAtomic(_executionStatePath, _executionStateMachine.State);
            if (Directory.Exists(@"Z:\"))
            {
                InstallationStateStore.WriteAtomic(
                    Path.Combine(@"Z:\", InstallationStateFileName),
                    _executionStateMachine.State);
            }
        }

        private void ReloadExecutionState()
        {
            if (string.IsNullOrWhiteSpace(_executionStatePath) || !File.Exists(_executionStatePath))
                return;

            // PowerShell can advance the same state file while the GUI waits.
            // Always rehydrate before the GUI performs a later transition.
            _executionStateMachine = new InstallationStateMachine(
                InstallationStateStore.Read(_executionStatePath));
        }
    }
}
