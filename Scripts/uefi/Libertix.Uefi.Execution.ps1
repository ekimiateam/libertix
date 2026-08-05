#requires -Version 5.1

# Shared execution-state, diagnostics, and installation-context publication.

function Get-LibertixStagingGrubConfig {
    # Both the ESP fallback and the staging partition must start the same
    # one-shot live environment. Keeping the configuration here prevents a
    # boot-parameter fix from reaching only one of those two paths.
    $argumentsPath = Join-Path $PSScriptRoot "..\config\Libertix.BootArguments.json"
    if (-not (Test-Path -LiteralPath $argumentsPath -PathType Leaf)) {
        throw "Shared live boot arguments are missing: $argumentsPath"
    }
    $bootArguments = Get-Content -LiteralPath $argumentsPath -Raw -ErrorAction Stop |
        ConvertFrom-Json -ErrorAction Stop
    $normalArguments = [string]$bootArguments.normal
    if ([string]::IsNullOrWhiteSpace($normalArguments) -or $normalArguments -match "[`r`n]") {
        throw "Shared normal live boot arguments must be a non-empty single line."
    }

    return @"
set default=0
set timeout=0
set timeout_style=hidden
set hidden_timeout=0
set hidden_timeout_quiet=true

search --no-floppy --label $InstallerLabel --set=root

menuentry "Install Linux Mint (Automatic)" {
    linux /live/vmlinuz $normalArguments
    initrd /live/initrd.img
}
"@
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("Gray", "Cyan", "Green", "Yellow", "Red", "White")]
        [string]$Color = "Gray"
    )

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
}

function Write-LibertixProgress {
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9-]+$')][string]$Stage,
        [Parameter(Mandatory = $true)][ValidateRange(0, 100)][int]$Percent
    )

    # Human-readable logs are localized and may change wording. This stable
    # protocol lets the WPF UI react without parsing presentation text.
    Write-Output "LIBERTIX_PROGRESS $Stage $Percent"
}

function Test-LibertixTrackedExecution {
    # Revert can run from transaction state alone after the plan volume is no
    # longer available. Normal preparation always supplies both documents.
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
    # rollback: remove temporary boot state and live files before growing the
    # Windows system volume.
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
    # The plan and state are the only cross-environment contracts. Publishing
    # both prevents the live from reconstructing disk intent from probe order.
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
