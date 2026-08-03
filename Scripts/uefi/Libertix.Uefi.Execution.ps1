#requires -Version 5.1

# Shared execution-state, diagnostics, and live-config projections.

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("Gray", "Cyan", "Green", "Yellow", "Red", "White")]
        [string]$Color = "Gray"
    )

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
}

function Test-LibertixTrackedExecution {
    # State tracking is optional only for legacy direct invocations. The WPF
    # workflow always supplies both documents and therefore uses every guard.
    return (
        $null -ne $installationPlan -and
        -not [string]::IsNullOrWhiteSpace($ExecutionStatePath)
    )
}

function Start-LibertixTrackedStep {
    param([Parameter(Mandatory = $true)][string]$Step)

    if (-not (Test-LibertixTrackedExecution)) {
        return
    }
    $state = Read-LibertixExecutionState -Path $ExecutionStatePath
    # A recovery retry may resume after the operation completed or after its
    # start was persisted. Do not duplicate either transition.
    if ($Step -in @($state.completedSteps) -or [string]$state.activeStep -eq $Step) {
        return
    }
    $null = Start-LibertixExecutionStep -Path $ExecutionStatePath -Step $Step
}

function Complete-LibertixTrackedStep {
    param([Parameter(Mandatory = $true)][string]$Step)

    if (-not (Test-LibertixTrackedExecution)) {
        return
    }
    $state = Read-LibertixExecutionState -Path $ExecutionStatePath
    if ($Step -in @($state.completedSteps)) {
        return
    }
    $null = Complete-LibertixExecutionStep -Path $ExecutionStatePath -Step $Step
}

function Set-LibertixTrackedFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not (Test-LibertixTrackedExecution)) {
        return
    }
    $state = Read-LibertixExecutionState -Path $ExecutionStatePath
    if ([string]$state.status -in @("failed", "rollback-running", "rolled-back", "succeeded")) {
        return
    }
    $null = Set-LibertixExecutionFailure `
        -Path $ExecutionStatePath `
        -Code $Code `
        -Message $Message `
        -Component "windows"
}

function Start-LibertixTrackedRollback {
    if (-not (Test-LibertixTrackedExecution)) {
        return
    }
    $state = Read-LibertixExecutionState -Path $ExecutionStatePath
    if ([string]$state.status -eq "rollback-running") {
        return
    }
    if ([string]$state.status -in @("running", "failed")) {
        $null = Start-LibertixRollback -Path $ExecutionStatePath
    }
}

function Complete-LibertixTrackedRollback {
    if (-not (Test-LibertixTrackedExecution)) {
        return
    }
    $state = Read-LibertixExecutionState -Path $ExecutionStatePath
    if ([string]$state.status -ne "rollback-running") {
        return
    }
    # Compensations are recorded in reverse dependency order. This mirrors the
    # rollback: remove temporary boot state and live files before growing C:.
    foreach ($step in @(
        "windows.temporary-boot-prepared",
        "windows.live-media-prepared",
        "windows.installer-partition-created",
        "windows.system-volume-shrunk",
        "windows.recovery-armed"
    )) {
        if ($step -in @($state.completedSteps) -and $step -notin @($state.compensatedSteps)) {
            $null = Complete-LibertixCompensation -Path $ExecutionStatePath -Step $step
            $state = Read-LibertixExecutionState -Path $ExecutionStatePath
        }
    }
    $null = Complete-LibertixRollback -Path $ExecutionStatePath
}

function Update-LibertixInstallationPlanPartition {
    param([Parameter(Mandatory = $true)]$Partition)

    if ($null -eq $installationPlan) {
        return
    }
    if ([int]$Partition.DiskNumber -ne [int]$installationPlan.disk.number) {
        throw "Installer partition is not on the disk selected by the installation plan."
    }
    if ([int64]$Partition.Size -ne [int64]$installationPlan.disk.installer.stagingSizeBytes) {
        throw "Installer partition size does not match the installation plan staging size."
    }

    # Windows assigns the final GPT partition number only after creation and
    # formatting. Persist that observed identity before handing off to Linux.
    $installationPlan.disk.installer.number = [int]$Partition.PartitionNumber
    $installationPlan.disk.installer.offsetBytes = [int64]$Partition.Offset
    Write-LibertixInstallationPlanAtomic -Path $InstallationPlanPath -Plan $installationPlan
}

function Publish-LibertixInstallationContext {
    param([Parameter(Mandatory = $true)][string]$PartitionDrive)

    if (-not (Test-LibertixTrackedExecution)) {
        return
    }
    # The live environment reads the same plan and state that Windows used;
    # config.txt remains only as a temporary compatibility projection.
    Copy-Item `
        -LiteralPath $InstallationPlanPath `
        -Destination (Join-Path $PartitionDrive "installation-plan.json") `
        -Force
    Copy-Item `
        -LiteralPath $ExecutionStatePath `
        -Destination (Join-Path $PartitionDrive "installation-state.json") `
        -Force
}

function Write-ExceptionDiagnostics {
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    Write-Log "Exception type: $($ErrorRecord.Exception.GetType().FullName)" "Red"
    if ($ErrorRecord.FullyQualifiedErrorId) {
        Write-Log "Error id: $($ErrorRecord.FullyQualifiedErrorId)" "Red"
    }
    if ($ErrorRecord.InvocationInfo.PositionMessage) {
        Write-Log "Error position: $($ErrorRecord.InvocationInfo.PositionMessage.Trim())" "Red"
    }
    if ($ErrorRecord.ScriptStackTrace) {
        Write-Log "PowerShell stack: $($ErrorRecord.ScriptStackTrace)" "Red"
    }
}

function ConvertTo-ShellQuotedValue {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        $Value = ""
    }
    if ($Value -match "[`r`n]") {
        throw "Config values cannot contain newlines."
    }

    return "'" + $Value.Replace("'", "'\''") + "'"
}

function Test-LibertixLiveConfig {
    foreach ($item in @(
        @{ Name = "LinuxUsername"; Value = $LinuxUsername },
        @{ Name = "LinuxPasswordHash"; Value = $LinuxPasswordHash },
        @{ Name = "LinuxComputerName"; Value = $LinuxComputerName },
        @{ Name = "SystemLang"; Value = $SystemLang },
        @{ Name = "KeyboardLayout"; Value = $KeyboardLayout },
        @{ Name = "Timezone"; Value = $Timezone }
    )) {
        if ([string]::IsNullOrWhiteSpace([string]$item.Value)) {
            throw "Missing live installer config value: $($item.Name)"
        }
    }
    if ($LinuxPasswordHash -notmatch '^\$6\$') {
        throw "LinuxPasswordHash must use SHA-512 crypt."
    }
}

function Write-LibertixLiveConfig {
    param(
        [Parameter(Mandatory = $true)][string]$PartitionDrive
    )

    if (-not (Test-Path "$PartitionDrive\")) {
        throw "Cannot write live config because partition is not mounted: $PartitionDrive"
    }

    $systemPartition = Get-Partition -DriveLetter C -ErrorAction Stop
    $systemDisk = Get-Disk -Number $systemPartition.DiskNumber -ErrorAction Stop
    $installerLetter = $PartitionDrive.TrimEnd(":\")
    $installerPartition = Get-Partition -DriveLetter $installerLetter -ErrorAction Stop
    if ($installerPartition.DiskNumber -ne $systemPartition.DiskNumber) {
        throw "Installer partition is not on the Windows system disk."
    }
    $recoveryPartitions = @(
        Get-Partition -DiskNumber $systemPartition.DiskNumber -ErrorAction Stop |
            Where-Object {
                $_.GptType -eq "{de94bba4-06d1-4d40-a16a-bfd50179d6ac}" -or
                [int]$_.MbrType -eq 39 -or
                $_.Type -match "Recovery"
            }
    )
    if (@($recoveryPartitions).Count -ne 1) {
        throw "Exactly one Windows recovery partition is required; detected $(@($recoveryPartitions).Count)."
    }
    $recoveryPartition = $recoveryPartitions[0]

    # Re-read identities after partition creation. Partition numbers may move,
    # but stable offsets and sizes must still identify exactly the same slots.
    if ($installationPlan) {
        if ([int]$systemDisk.Number -ne [int]$installationPlan.disk.number) {
            throw "System disk number no longer matches the installation plan."
        }
        if (([string]$systemDisk.UniqueId).Trim() -ne ([string]$installationPlan.disk.uniqueId).Trim()) {
            throw "System disk identity no longer matches the installation plan."
        }
        if (
            [int]$systemPartition.PartitionNumber -ne [int]$installationPlan.disk.windows.number -or
            [int64]$systemPartition.Offset -ne [int64]$installationPlan.disk.windows.offsetBytes
        ) {
            throw "Windows partition identity no longer matches the installation plan."
        }
        if (
            [int64]$recoveryPartition.Offset -ne [int64]$installationPlan.disk.recovery.offsetBytes -or
            [int64]$recoveryPartition.Size -ne [int64]$installationPlan.disk.recovery.sizeBytes
        ) {
            throw "Recovery partition identity no longer matches the installation plan."
        }
        if ([int]$recoveryPartition.PartitionNumber -ne [int]$installationPlan.disk.recovery.number) {
            $installationPlan.disk.recovery.number = [int]$recoveryPartition.PartitionNumber
            Write-LibertixInstallationPlanAtomic -Path $InstallationPlanPath -Plan $installationPlan
        }
        if (
            [int]$installerPartition.PartitionNumber -ne [int]$installationPlan.disk.installer.number -or
            [int64]$installerPartition.Offset -ne [int64]$installationPlan.disk.installer.offsetBytes
        ) {
            throw "Installer partition identity no longer matches the installation plan."
        }
    }

    $configPath = Join-Path $PartitionDrive "config.txt"
    if (Test-Path $configPath) {
        attrib -R -S -H $configPath 2>$null
        Remove-Item -Path $configPath -Force
    }

    # Keep old live images bootable during the progressive migration. Values
    # come from the plan whenever it exists; runtime probing is legacy-only.
    $planId = if ($installationPlan) { [string]$installationPlan.planId } else { "" }
    $isoFileName = if ($installationPlan) {
        [string]$installationPlan.distribution.installerIsoFileName
    } else { "mint.iso" }
    $isoUrl = if ($installationPlan) {
        [string]$installationPlan.distribution.installerIsoUrl
    } else { $MintIsoUrl }
    $isoSha256 = if ($installationPlan) {
        [string]$installationPlan.distribution.installerIsoSha256
    } else { $MintIsoSha256 }
    $targetDiskNumber = if ($installationPlan) {
        [int]$installationPlan.disk.number
    } else { [int]$systemDisk.Number }
    $targetDiskUniqueId = if ($installationPlan) {
        [string]$installationPlan.disk.uniqueId
    } else { [string]$systemDisk.UniqueId }
    $logicalSectorSize = if ($installationPlan) {
        [int]$installationPlan.disk.logicalSectorSizeBytes
    } else { [int]$systemDisk.LogicalSectorSize }
    $windowsPartitionNumber = if ($installationPlan) {
        [int]$installationPlan.disk.windows.number
    } else { [int]$systemPartition.PartitionNumber }
    $bootPartitionNumber = if ($installationPlan) {
        [int]$installationPlan.disk.boot.number
    } else { 0 }
    $bootPartitionOffset = if ($installationPlan) {
        [int64]$installationPlan.disk.boot.offsetBytes
    } else { 0 }
    $installerFinalSize = if ($installationPlan) {
        [int64]$installationPlan.disk.installer.finalSizeBytes
    } else { [int64]$InstallerPartitionSizeGB * 1GB }
    $installerStagingSize = if ($installationPlan) {
        [int64]$installationPlan.disk.installer.stagingSizeBytes
    } else { [int64]$installerPartition.Size }

    $configLines = @(
        "INSTALLATION_PLAN_ID=$(ConvertTo-ShellQuotedValue $planId)",
        "LANGUAGE_CODE=$(ConvertTo-ShellQuotedValue $LanguageCode)",
        "SYSTEM_LANG=$(ConvertTo-ShellQuotedValue $SystemLang)",
        "KEYBOARD_LAYOUT=$(ConvertTo-ShellQuotedValue $KeyboardLayout)",
        "KEYBOARD_MODEL=$(ConvertTo-ShellQuotedValue $KeyboardModel)",
        "TIMEZONE=$(ConvertTo-ShellQuotedValue $Timezone)",
        "USERNAME=$(ConvertTo-ShellQuotedValue $LinuxUsername)",
        "PASSWORD_HASH=$(ConvertTo-ShellQuotedValue $LinuxPasswordHash)",
        "COMPUTER_NAME=$(ConvertTo-ShellQuotedValue $LinuxComputerName)",
        "ISO_FILENAME=$(ConvertTo-ShellQuotedValue $isoFileName)",
        "ISO_URL=$(ConvertTo-ShellQuotedValue $isoUrl)",
        "ISO_WINDOWS_PATH=$(ConvertTo-ShellQuotedValue $MintIsoPath)",
        "ISO_SHA256=$(ConvertTo-ShellQuotedValue $isoSha256)",
        "LINUX_SIZE_GB=$(ConvertTo-ShellQuotedValue ([string]$InstallerPartitionSizeGB))",
        "TARGET_DISK_NUMBER=$(ConvertTo-ShellQuotedValue ([string]$targetDiskNumber))",
        "TARGET_DISK_UNIQUE_ID=$(ConvertTo-ShellQuotedValue $targetDiskUniqueId)",
        "TARGET_DISK_SIZE_BYTES=$(ConvertTo-ShellQuotedValue ([string]$systemDisk.Size))",
        "TARGET_LOGICAL_SECTOR_SIZE_BYTES=$(ConvertTo-ShellQuotedValue ([string]$logicalSectorSize))",
        "WINDOWS_PARTITION_NUMBER=$(ConvertTo-ShellQuotedValue ([string]$windowsPartitionNumber))",
        "WINDOWS_PARTITION_OFFSET_BYTES=$(ConvertTo-ShellQuotedValue ([string]$systemPartition.Offset))",
        "WINDOWS_BOOT_PARTITION_NUMBER=$(ConvertTo-ShellQuotedValue ([string]$bootPartitionNumber))",
        "WINDOWS_BOOT_PARTITION_OFFSET_BYTES=$(ConvertTo-ShellQuotedValue ([string]$bootPartitionOffset))",
        "INSTALLER_PARTITION_NUMBER=$(ConvertTo-ShellQuotedValue ([string]$installerPartition.PartitionNumber))",
        "INSTALLER_PARTITION_OFFSET_BYTES=$(ConvertTo-ShellQuotedValue ([string]$installerPartition.Offset))",
        "INSTALLER_FINAL_SIZE_BYTES=$(ConvertTo-ShellQuotedValue ([string]$installerFinalSize))",
        "INSTALLER_STAGING_SIZE_BYTES=$(ConvertTo-ShellQuotedValue ([string]$installerStagingSize))",
        "EXPECTED_PARTITION_STYLE=$(ConvertTo-ShellQuotedValue ([string]$systemDisk.PartitionStyle))",
        "RECOVERY_PARTITION_NUMBER=$(ConvertTo-ShellQuotedValue ([string]$recoveryPartition.PartitionNumber))",
        "RECOVERY_PARTITION_OFFSET_BYTES=$(ConvertTo-ShellQuotedValue ([string]$recoveryPartition.Offset))",
        "RECOVERY_PARTITION_SIZE_BYTES=$(ConvertTo-ShellQuotedValue ([string]$recoveryPartition.Size))",
        "RECOVERY_ROOT_WINDOWS=$(ConvertTo-ShellQuotedValue $RecoveryRoot)",
        "RECOVERY_RUN_ID=$(ConvertTo-ShellQuotedValue $RecoveryRunId)",
        "LOW_MEMORY_MODE=$(ConvertTo-ShellQuotedValue $LowMemoryMode.ToString().ToLowerInvariant())",
        "SHARE_WINDOWS_FILES_IN_LINUX=$(ConvertTo-ShellQuotedValue $ShareWindowsFilesInLinux.ToString().ToLowerInvariant())",
        "SHARE_LINUX_FILES_IN_WINDOWS=$(ConvertTo-ShellQuotedValue $ShareLinuxFilesInWindows.ToString().ToLowerInvariant())",
        "WINDOWS_PROFILES_JSON_BASE64=$(ConvertTo-ShellQuotedValue $WindowsProfilesJsonBase64)"
    )

    Set-Content -Path $configPath -Value $configLines -Encoding ASCII

    $written = Get-Content -Path $configPath -Raw -ErrorAction Stop
    foreach ($requiredKey in @(
        "USERNAME=", "PASSWORD_HASH=", "COMPUTER_NAME=", "ISO_WINDOWS_PATH=", "LINUX_SIZE_GB=",
        "TARGET_DISK_NUMBER=", "TARGET_DISK_UNIQUE_ID=", "TARGET_DISK_SIZE_BYTES=",
        "WINDOWS_PARTITION_NUMBER=", "WINDOWS_PARTITION_OFFSET_BYTES=",
        "INSTALLER_PARTITION_NUMBER=", "INSTALLER_PARTITION_OFFSET_BYTES=", "EXPECTED_PARTITION_STYLE=",
        "RECOVERY_PARTITION_OFFSET_BYTES=", "RECOVERY_PARTITION_SIZE_BYTES=",
        "RECOVERY_ROOT_WINDOWS=", "RECOVERY_RUN_ID=", "LOW_MEMORY_MODE=",
        "SHARE_WINDOWS_FILES_IN_LINUX=", "SHARE_LINUX_FILES_IN_WINDOWS=",
        "WINDOWS_PROFILES_JSON_BASE64="
    )) {
        if ($written -notmatch [regex]::Escape($requiredKey)) {
            throw "Live config verification failed; missing $requiredKey in $configPath"
        }
    }

    Write-Log "Live config written to $configPath for user '$LinuxUsername'." "Green"
}
