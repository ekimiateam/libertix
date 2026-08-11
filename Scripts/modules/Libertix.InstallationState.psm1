Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot "Libertix.AtomicFile.psm1") -Force -ErrorAction Stop

$script:ValidStatuses = @(
    "pending", "running", "failed", "rollback-running", "rolled-back", "succeeded"
)
$script:ValidPhases = @("windows", "live", "target", "rollback", "complete")
$script:TerminalStatuses = @("rolled-back", "succeeded")
$script:OrderedSteps = @(
    "windows.preflight-verified",
    "windows.artifacts-verified",
    "windows.recovery-armed",
    "windows.system-volume-shrunk",
    "windows.installer-partition-created",
    "windows.live-media-prepared",
    "windows.temporary-boot-prepared",
    "live.preflight-verified",
    "live.installer-partition-expanded",
    "live.target-filesystem-created",
    "live.distribution-extracted",
    "target.system-configured",
    "target.bootloader-installed",
    "target.installation-verified"
)
$script:CompensatableSteps = @(
    "windows.recovery-armed",
    "windows.system-volume-shrunk",
    "windows.installer-partition-created",
    "windows.live-media-prepared",
    "windows.temporary-boot-prepared",
    "live.installer-partition-expanded",
    "live.target-filesystem-created",
    "live.distribution-extracted",
    "target.system-configured",
    "target.bootloader-installed"
)
$script:InstallationStatePropertySets = [ordered]@{
    root = @(
        "schemaVersion", "planId", "revision", "status", "phase", "activeStep",
        "completedSteps", "compensatedSteps", "failure", "progress", "updatedAtUtc"
    )
    progress = @("stage", "overallPercent", "detailPercent")
    failure = @("code", "message", "component")
}

function Assert-LibertixExactStateProperties {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$PropertySet
    )

    $allowed = @($script:InstallationStatePropertySets[$PropertySet])
    if ($allowed.Count -eq 0) {
        throw "Unknown installation state property set: $PropertySet."
    }
    $propertyNames = if ($Object -is [Collections.IDictionary]) {
        @($Object.Keys)
    } else {
        @($Object.PSObject.Properties.Name)
    }
    $unexpected = @($propertyNames | Where-Object { $_ -notin $allowed })
    if ($unexpected.Count -gt 0) {
        throw "Installation state $Path contains unsupported field '$($unexpected[0])'."
    }
}

function Test-LibertixStateProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) {
        return $false
    }
    if ($Object -is [Collections.IDictionary]) {
        return $Object.Contains($Name)
    }
    return $Object.PSObject.Properties.Name -contains $Name
}

function Assert-LibertixExecutionStep {
    param([Parameter(Mandatory = $true)][string]$Step)

    if ($Step -notmatch '^(windows|live|target)\.[a-z0-9]+(?:-[a-z0-9]+)*$') {
        throw "Invalid Libertix installation step: $Step"
    }
    return $Step.Split('.')[0]
}

function Assert-LibertixExecutionState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$State)

    Assert-LibertixExactStateProperties -Object $State -Path "root" -PropertySet "root"

    if ([int]$State.schemaVersion -ne 1) {
        throw "Unsupported Libertix execution state schemaVersion."
    }
    if ([string]$State.planId -notmatch '^[0-9a-f]{32}$') {
        throw "Libertix execution state planId is invalid."
    }
    if ([int]$State.revision -lt 0) {
        throw "Libertix execution state revision cannot be negative."
    }
    if ((Test-LibertixStateProperty -Object $State -Name "progress") -and $null -ne $State.progress) {
        $progress = $State.progress
        Assert-LibertixExactStateProperties `
            -Object $progress `
            -Path "progress" `
            -PropertySet "progress"
        if ([string]$progress.stage -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
            throw "Libertix execution state progress stage is invalid."
        }
        $overallPercent = [int]$progress.overallPercent
        if ($overallPercent -lt 0 -or $overallPercent -gt 100) {
            throw "Libertix execution state overall progress is invalid."
        }
        if (
            (Test-LibertixStateProperty -Object $progress -Name "detailPercent") -and
            $null -ne $progress.detailPercent
        ) {
            $detailPercent = [int]$progress.detailPercent
            if ($detailPercent -lt 0 -or $detailPercent -gt 100) {
                throw "Libertix execution state detailed progress is invalid."
            }
        }
    }
    if ([string]$State.status -notin $script:ValidStatuses) {
        throw "Libertix execution state status is invalid."
    }
    if ([string]$State.phase -notin $script:ValidPhases) {
        throw "Libertix execution state phase is invalid."
    }
    [DateTimeOffset]$updatedAt = [DateTimeOffset]::MinValue
    if (
        -not [DateTimeOffset]::TryParse([string]$State.updatedAtUtc, [ref]$updatedAt) -or
        $updatedAt.Offset -ne [TimeSpan]::Zero
    ) {
        throw "Libertix execution state updatedAtUtc must be a valid UTC date-time."
    }

    $completed = @($State.completedSteps)
    $compensated = @($State.compensatedSteps)
    foreach ($step in @($completed + $compensated)) {
        $null = Assert-LibertixExecutionStep -Step ([string]$step)
    }
    if (@($completed | Select-Object -Unique).Count -ne $completed.Count) {
        throw "Libertix execution state contains duplicate completed steps."
    }
    if (@($compensated | Select-Object -Unique).Count -ne $compensated.Count) {
        throw "Libertix execution state contains duplicate compensated steps."
    }
    foreach ($step in $compensated) {
        if ($step -notin $completed) {
            throw "Libertix execution state compensates an incomplete step: $step"
        }
    }
    for ($index = 0; $index -lt $completed.Count; $index++) {
        if ($index -ge $script:OrderedSteps.Count -or [string]$completed[$index] -ne $script:OrderedSteps[$index]) {
            throw "Libertix execution state completedSteps is not an ordered workflow prefix."
        }
    }

    $activeStep = [string]$State.activeStep
    if (-not [string]::IsNullOrWhiteSpace($activeStep)) {
        $null = Assert-LibertixExecutionStep -Step $activeStep
        if ($completed.Count -ge $script:OrderedSteps.Count -or $activeStep -ne $script:OrderedSteps[$completed.Count]) {
            throw "Libertix execution state activeStep is not the next workflow step."
        }
    }
    if (
        [string]$State.status -in @("failed", "rollback-running", "rolled-back", "succeeded") -and
        -not [string]::IsNullOrWhiteSpace($activeStep)
    ) {
        throw "The current execution state cannot have an active step."
    }
    if ([string]$State.status -eq "rollback-running" -and [string]$State.phase -ne "rollback") {
        throw "A running rollback requires the rollback phase."
    }
    if ([string]$State.status -in $script:TerminalStatuses -and [string]$State.phase -ne "complete") {
        throw "A terminal execution state requires the complete phase."
    }
    if (
        [string]$State.status -eq "succeeded" -and
        ($completed.Count -ne $script:OrderedSteps.Count -or
         [string]$completed[-1] -ne $script:OrderedSteps[-1])
    ) {
        throw "A successful execution state requires every installation step."
    }
    if ([string]$State.status -eq "rolled-back") {
        $requiredCompensations = @($completed | Where-Object { $_ -in $script:CompensatableSteps })
        if (
            $compensated.Count -ne $requiredCompensations.Count -or
            @($requiredCompensations | Where-Object { $_ -notin $compensated }).Count -ne 0
        ) {
            throw "A rolled-back execution state requires every applicable compensation."
        }
    }
    if ([string]$State.status -eq "failed" -and $null -eq $State.failure) {
        throw "A failed execution state requires failure details."
    }
    if ($null -ne $State.failure) {
        Assert-LibertixExactStateProperties `
            -Object $State.failure `
            -Path "failure" `
            -PropertySet "failure"
        if (
            [string]::IsNullOrWhiteSpace([string]$State.failure.code) -or
            [string]::IsNullOrWhiteSpace([string]$State.failure.message) -or
            [string]$State.failure.component -notin @("windows", "live", "target", "rollback")
        ) {
            throw "Libertix execution state failure details are invalid."
        }
    }
    # Rollback states retain the originating failure as diagnostics. Pending,
    # running, and successful states cannot describe an inactive failure.
    if ([string]$State.status -in @("pending", "running", "succeeded") -and $null -ne $State.failure) {
        throw "Only failed and rollback execution states can carry failure details."
    }

    return $State
}

function Write-LibertixExecutionStateAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$State
    )

    $null = Assert-LibertixExecutionState -State $State
    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    if ([string]::IsNullOrWhiteSpace($directory)) {
        throw "Execution state path has no parent directory."
    }
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporaryPath = Join-Path $directory ".$(Split-Path -Leaf $fullPath).$([Guid]::NewGuid().ToString('N')).tmp"
    $backupPath = Join-Path $directory ".$(Split-Path -Leaf $fullPath).$([Guid]::NewGuid().ToString('N')).bak"
    try {
        $json = $State | ConvertTo-Json -Depth 8
        $encoding = New-Object Text.UTF8Encoding($false)
        $stream = New-Object IO.FileStream(
            $temporaryPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough
        )
        try {
            $writer = New-Object IO.StreamWriter($stream, $encoding)
            try {
                $writer.Write($json)
                $writer.Write("`n")
                $writer.Flush()
                $stream.Flush($true)
            } finally {
                $writer.Dispose()
            }
        } finally {
            $stream.Dispose()
        }

        Publish-LibertixFileAtomic `
            -TemporaryPath $temporaryPath `
            -DestinationPath $fullPath `
            -BackupPath $backupPath
    } finally {
        if ([IO.File]::Exists($temporaryPath)) {
            [IO.File]::Delete($temporaryPath)
        }
        if ([IO.File]::Exists($backupPath)) {
            [IO.File]::Delete($backupPath)
        }
    }
}

function Read-LibertixExecutionState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $state = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Cannot read Libertix execution state: $($_.Exception.Message)"
    }
    return Assert-LibertixExecutionState -State $state
}

function New-LibertixExecutionState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$PlanId
    )

    if ($PlanId -notmatch '^[0-9a-f]{32}$') {
        throw "PlanId must contain 32 lowercase hexadecimal characters."
    }
    $state = [ordered]@{
        schemaVersion = 1
        planId = $PlanId
        revision = 0
        status = "pending"
        phase = "windows"
        activeStep = $null
        completedSteps = @()
        compensatedSteps = @()
        failure = $null
        progress = [ordered]@{
            stage = "initializing"
            overallPercent = 0
        }
        updatedAtUtc = [DateTime]::UtcNow.ToString("o")
    }
    Write-LibertixExecutionStateAtomic -Path $Path -State $state
    return $state
}

function Update-LibertixExecutionState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][scriptblock]$Transition,
        [object[]]$TransitionArguments = @()
    )

    $state = Read-LibertixExecutionState -Path $Path
    & $Transition $state @TransitionArguments
    $state.revision = [int]$state.revision + 1
    $state.updatedAtUtc = [DateTime]::UtcNow.ToString("o")
    Write-LibertixExecutionStateAtomic -Path $Path -State $state
    return $state
}

function Start-LibertixExecutionStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Step
    )

    $phase = Assert-LibertixExecutionStep -Step $Step
    return Update-LibertixExecutionState -Path $Path -TransitionArguments @($Step, $phase) -Transition {
        param($state, $transitionStep, $transitionPhase)
        if ([string]$state.status -in $script:TerminalStatuses -or [string]$state.status -eq "rollback-running") {
            throw "The current execution state cannot start a step."
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$state.activeStep)) {
            throw "Step '$($state.activeStep)' is already active."
        }
        if ($transitionStep -in @($state.completedSteps)) {
            throw "Step '$transitionStep' is already complete."
        }
        $expectedIndex = @($state.completedSteps).Count
        $expectedStep = if ($expectedIndex -lt $script:OrderedSteps.Count) {
            $script:OrderedSteps[$expectedIndex]
        } else {
            "no further step"
        }
        if ($transitionStep -ne $expectedStep) {
            throw "Step '$transitionStep' is out of order; expected '$expectedStep'."
        }
        # A recovery retry may legitimately resume after a recorded failure.
        # Drop that failure here: without this, the ledger can reach 'succeeded'
        # while still carrying the diagnostics of a run that did not succeed.
        if ([string]$state.status -eq "failed") {
            $state.failure = $null
        }
        $state.status = "running"
        $state.phase = $transitionPhase
        $state.activeStep = $transitionStep
    }
}

function Set-LibertixExecutionProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
        [string]$Stage,
        [Parameter(Mandatory = $true)][ValidateRange(0, 100)][int]$OverallPercent,
        [ValidateRange(0, 100)][Nullable[int]]$DetailPercent = $null
    )

    return Update-LibertixExecutionState `
        -Path $Path `
        -TransitionArguments @($Stage, $OverallPercent, $DetailPercent) `
        -Transition {
            param($state, $progressStage, $progressOverall, $progressDetail)
            $progress = [ordered]@{
                stage = $progressStage
                overallPercent = $progressOverall
            }
            if ($null -ne $progressDetail) {
                $progress.detailPercent = [int]$progressDetail
            }
            if (Test-LibertixStateProperty -Object $state -Name "progress") {
                $state.progress = $progress
            } else {
                $state | Add-Member -NotePropertyName progress -NotePropertyValue $progress
            }
        }
}

function Complete-LibertixExecutionStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Step
    )

    $null = Assert-LibertixExecutionStep -Step $Step
    return Update-LibertixExecutionState -Path $Path -TransitionArguments @($Step) -Transition {
        param($state, $transitionStep)
        if ([string]$state.status -ne "running" -or [string]$state.activeStep -ne $transitionStep) {
            throw "Cannot complete '$transitionStep'; active step is '$($state.activeStep)'."
        }
        $state.completedSteps = @($state.completedSteps) + $transitionStep
        $state.activeStep = $null
    }
}

function Set-LibertixExecutionFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("windows", "live", "target", "rollback")]
        [string]$Component
    )

    return Update-LibertixExecutionState -Path $Path -TransitionArguments @($Code, $Message, $Component) -Transition {
        param($state, $failureCode, $failureMessage, $failureComponent)
        if ([string]$state.status -in $script:TerminalStatuses -or [string]$state.status -eq "rollback-running") {
            throw "The current execution state cannot transition to failed."
        }
        $state.status = "failed"
        $state.activeStep = $null
        $state.failure = [ordered]@{
            code = $failureCode
            message = $failureMessage
            component = $failureComponent
        }
    }
}

function Start-LibertixRollback {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    # Starting rollback clears any interrupted operation. The completed-step
    # ledger remains intact and determines which compensations are required.
    return Update-LibertixExecutionState -Path $Path -Transition {
        param($state)
        if ([string]$state.status -notin @("running", "failed")) {
            throw "Rollback can only begin from running or failed."
        }
        $state.status = "rollback-running"
        $state.phase = "rollback"
        $state.activeStep = $null
    }
}

function Complete-LibertixCompensation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Step
    )

    $null = Assert-LibertixExecutionStep -Step $Step
    return Update-LibertixExecutionState -Path $Path -TransitionArguments @($Step) -Transition {
        param($state, $transitionStep)
        if ([string]$state.status -ne "rollback-running") {
            throw "Compensation requires a running rollback."
        }
        if ($transitionStep -notin @($state.completedSteps)) {
            throw "Cannot compensate incomplete step '$transitionStep'."
        }
        if ($transitionStep -notin @($state.compensatedSteps)) {
            $state.compensatedSteps = @($state.compensatedSteps) + $transitionStep
        }
    }
}

function Complete-LibertixRollback {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    return Update-LibertixExecutionState -Path $Path -Transition {
        param($state)
        if ([string]$state.status -ne "rollback-running") {
            throw "No rollback is running."
        }
        foreach ($step in @($state.completedSteps)) {
            if ($step -in $script:CompensatableSteps -and $step -notin @($state.compensatedSteps)) {
                throw "Rollback cannot complete before compensating '$step'."
            }
        }
        $state.status = "rolled-back"
        $state.phase = "complete"
        $state.activeStep = $null
    }
}

function Complete-LibertixInstallation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    return Update-LibertixExecutionState -Path $Path -Transition {
        param($state)
        if ([string]$state.status -ne "running" -or -not [string]::IsNullOrWhiteSpace([string]$state.activeStep)) {
            throw "Installation can complete only between successful steps."
        }
        if (
            @($state.completedSteps).Count -ne $script:OrderedSteps.Count -or
            [string]$state.completedSteps[-1] -ne "target.installation-verified"
        ) {
            throw "Installation cannot complete before final target verification."
        }
        $state.status = "succeeded"
        $state.phase = "complete"
    }
}

Export-ModuleMember -Function `
    Assert-LibertixExecutionState, `
    Read-LibertixExecutionState, `
    Write-LibertixExecutionStateAtomic, `
    New-LibertixExecutionState, `
    Set-LibertixExecutionProgress, `
    Start-LibertixExecutionStep, `
    Complete-LibertixExecutionStep, `
    Set-LibertixExecutionFailure, `
    Start-LibertixRollback, `
    Complete-LibertixCompensation, `
    Complete-LibertixRollback, `
    Complete-LibertixInstallation
