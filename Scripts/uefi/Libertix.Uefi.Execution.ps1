#requires -Version 5.1

# Shared execution-state, diagnostics, and installation-context publication.

function Get-LibertixStagingGrubConfig {
    param([Parameter(Mandatory = $true)][bool]$UseLowMemoryMode)

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
    $verboseArguments = [string]$bootArguments.verbose
    if ($UseLowMemoryMode) {
        $normalArguments = $normalArguments -replace `
            '(?i)(^|\s)toram(?=\s|$)',
            '$1toram=filesystem.squashfs'
        $verboseArguments = $verboseArguments -replace `
            '(?i)(^|\s)toram(?=\s|$)',
            '$1toram=filesystem.squashfs'
        if (
            $normalArguments -notmatch '(^|\s)toram=filesystem\.squashfs(?=\s|$)' -or
            $verboseArguments -notmatch '(^|\s)toram=filesystem\.squashfs(?=\s|$)'
        ) {
            throw "Shared live boot arguments cannot be converted to low-memory module mode."
        }
    }
    foreach ($entry in @(
        @{ Name = "normal"; Value = $normalArguments },
        @{ Name = "verbose"; Value = $verboseArguments }
    )) {
        if ([string]::IsNullOrWhiteSpace($entry.Value) -or $entry.Value -match "[`r`n]") {
            throw "Shared $($entry.Name) live boot arguments must be a non-empty single line."
        }
    }

    $menuTemplatePath = Join-Path $PSScriptRoot "..\config\Libertix.LiveGrubMenu.cfg.in"
    if (-not (Test-Path -LiteralPath $menuTemplatePath -PathType Leaf)) {
        throw "Shared live GRUB menu template is missing: $menuTemplatePath"
    }
    $menuEntries = Get-Content -LiteralPath $menuTemplatePath -Raw -ErrorAction Stop
    $menuEntries = $menuEntries.Replace(
        "@LIBERTIX_NORMAL_KERNEL_ARGUMENTS@",
        $normalArguments)
    $menuEntries = $menuEntries.Replace(
        "@LIBERTIX_VERBOSE_KERNEL_ARGUMENTS@",
        $verboseArguments)
    if ($menuEntries -match "@LIBERTIX_[A-Z0-9_]+@") {
        throw "Shared live GRUB menu template contains an unresolved token."
    }

    return @"
set default=0
set timeout=0
set timeout_style=hidden
set hidden_timeout=0
set hidden_timeout_quiet=true

search --no-floppy --label $InstallerLabel --set=root

$($menuEntries.TrimEnd())
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
        [Parameter(Mandatory = $true)][ValidateRange(0, 100)][int]$Percent,
        [ValidateRange(0, 100)][Nullable[int]]$DetailPercent = $null
    )

    if (Test-LibertixTrackedExecution) {
        $progressArguments = @{
            Path = $ExecutionStatePath
            Stage = $Stage
            OverallPercent = $Percent
        }
        # PowerShell validates an explicitly bound null value before entering
        # the target function. Omit this optional argument when a stage has no
        # secondary percentage so the target's nullable default can apply.
        if ($null -ne $DetailPercent) {
            $progressArguments.DetailPercent = [int]$DetailPercent
        }
        $null = Set-LibertixExecutionProgress @progressArguments
    }
    Write-Log "Progress: stage=$Stage overall=$Percent detail=$DetailPercent"
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

function Complete-LibertixTrackedCompensation {
    param([Parameter(Mandatory = $true)][string]$Step)

    if (-not (Test-LibertixTrackedExecution)) {
        return
    }
    $state = Read-LibertixExecutionState -Path $ExecutionStatePath
    if ([string]$state.status -ne "rollback-running") {
        throw "Compensation proof requires a running rollback."
    }
    if ($Step -in @($state.completedSteps) -and $Step -notin @($state.compensatedSteps)) {
        $null = Complete-LibertixCompensation -Path $ExecutionStatePath -Step $Step
    }
}

function Complete-LibertixTrackedRollback {
    if (-not (Test-LibertixTrackedExecution)) {
        return
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
    # The plan and state are the only cross-environment contracts. A direct
    # Copy-Item can expose a truncated JSON document if power is lost while an
    # existing handoff is refreshed, so stage and verify each file before the
    # same-directory replacement.
    $contextFiles = @(
        [pscustomobject]@{
            Source = $InstallationPlanPath
            Destination = Join-Path $PartitionDrive "installation-plan.json"
        },
        [pscustomobject]@{
            Source = $ExecutionStatePath
            Destination = Join-Path $PartitionDrive "installation-state.json"
        }
    )
    foreach ($contextFile in $contextFiles) {
        $source = [IO.Path]::GetFullPath([string]$contextFile.Source)
        $destination = [IO.Path]::GetFullPath([string]$contextFile.Destination)
        $directory = [IO.Path]::GetDirectoryName($destination)
        $temporary = Join-Path `
            $directory `
            ".$([IO.Path]::GetFileName($destination)).$([Guid]::NewGuid().ToString('N')).tmp"
        $backup = Join-Path `
            $directory `
            ".$([IO.Path]::GetFileName($destination)).$([Guid]::NewGuid().ToString('N')).bak"
        try {
            $inputStream = New-Object IO.FileStream(
                $source,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::Read
            )
            try {
                $outputStream = New-Object IO.FileStream(
                    $temporary,
                    [IO.FileMode]::CreateNew,
                    [IO.FileAccess]::Write,
                    [IO.FileShare]::None,
                    4096,
                    [IO.FileOptions]::WriteThrough
                )
                try {
                    $inputStream.CopyTo($outputStream)
                    $outputStream.Flush($true)
                } finally {
                    $outputStream.Dispose()
                }
            } finally {
                $inputStream.Dispose()
            }

            $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
            $temporaryHash = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash
            if ($sourceHash -ne $temporaryHash) {
                throw "Installation context staging hash mismatch for $([IO.Path]::GetFileName($destination))."
            }
            Publish-LibertixFileAtomic `
                -TemporaryPath $temporary `
                -DestinationPath $destination `
                -BackupPath $backup
            $publishedHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
            if ($sourceHash -ne $publishedHash) {
                throw "Installation context publication hash mismatch for $([IO.Path]::GetFileName($destination))."
            }
        } finally {
            if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
            if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
        }
    }
}

function ConvertTo-LibertixDiagnosticText {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    $text = [string]$Value
    $secretAssignment = '(?i)(password(?:[-_]?hash)?|token|secret|api[-_]?key)(\s*[:=]\s*)("[^"]*"|''[^'']*''|[^\s,;]+)'
    return [regex]::Replace($text, $secretAssignment, '$1$2[REDACTED]')
}

function Write-LibertixDiagnosticField {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Value
    )

    $text = ConvertTo-LibertixDiagnosticText -Value $Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return
    }

    $lines = @($text -split "`r?`n")
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $fieldName = if ($index -eq 0) { $Name } else { "$Name+" }
        Write-Log "${fieldName}: $($lines[$index])" "Red"
    }
}

function Get-LibertixDiagnosticStage {
    try {
        if (Test-LibertixTrackedExecution) {
            $state = Read-LibertixExecutionState -Path $ExecutionStatePath
            if (-not [string]::IsNullOrWhiteSpace([string]$state.activeStep)) {
                return [string]$state.activeStep
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$state.phase)) {
                return [string]$state.phase
            }
        }
    } catch {
        return "diagnostic-stage-unavailable"
    }
    return "unknown"
}

function Write-ExceptionDiagnostics {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [ValidateSet("Primary", "Rollback", "Cancellation")]
        [string]$Kind = "Primary",
        [string]$CorrelationId = "",
        [string]$Stage = ""
    )

    $heading = $Kind.ToUpperInvariant()
    Write-Log "===== $heading ERROR BEGIN =====" "Red"
    Write-LibertixDiagnosticField -Name "ErrorKind" -Value $Kind
    Write-LibertixDiagnosticField -Name "CorrelationId" -Value $CorrelationId
    Write-LibertixDiagnosticField -Name "Stage" -Value $Stage
    Write-LibertixDiagnosticField -Name "Message" -Value $ErrorRecord.Exception.Message
    Write-LibertixDiagnosticField `
        -Name "ExceptionType" `
        -Value $ErrorRecord.Exception.GetType().FullName
    Write-LibertixDiagnosticField `
        -Name "FullyQualifiedErrorId" `
        -Value $ErrorRecord.FullyQualifiedErrorId

    if ($ErrorRecord.CategoryInfo) {
        Write-LibertixDiagnosticField -Name "Category" -Value $ErrorRecord.CategoryInfo.Category
        Write-LibertixDiagnosticField -Name "Reason" -Value $ErrorRecord.CategoryInfo.Reason
        Write-LibertixDiagnosticField -Name "Activity" -Value $ErrorRecord.CategoryInfo.Activity
        Write-LibertixDiagnosticField -Name "TargetName" -Value $ErrorRecord.CategoryInfo.TargetName
        Write-LibertixDiagnosticField -Name "TargetType" -Value $ErrorRecord.CategoryInfo.TargetType
    }

    if ($ErrorRecord.InvocationInfo) {
        $commandName = if ($ErrorRecord.InvocationInfo.MyCommand) {
            [string]$ErrorRecord.InvocationInfo.MyCommand.Name
        } else {
            ""
        }
        Write-LibertixDiagnosticField `
            -Name "Command" `
            -Value $commandName
        Write-LibertixDiagnosticField `
            -Name "InvocationName" `
            -Value $ErrorRecord.InvocationInfo.InvocationName
        Write-LibertixDiagnosticField `
            -Name "Script" `
            -Value $ErrorRecord.InvocationInfo.ScriptName
        Write-LibertixDiagnosticField `
            -Name "Line" `
            -Value $ErrorRecord.InvocationInfo.ScriptLineNumber
        Write-LibertixDiagnosticField `
            -Name "Offset" `
            -Value $ErrorRecord.InvocationInfo.OffsetInLine
        Write-LibertixDiagnosticField `
            -Name "SourceLine" `
            -Value ([string]$ErrorRecord.InvocationInfo.Line).Trim()
        Write-LibertixDiagnosticField `
            -Name "Position" `
            -Value ([string]$ErrorRecord.InvocationInfo.PositionMessage).Trim()
    }

    Write-LibertixDiagnosticField `
        -Name "PowerShellStack" `
        -Value $ErrorRecord.ScriptStackTrace

    $innerException = $ErrorRecord.Exception.InnerException
    $innerIndex = 0
    while ($null -ne $innerException -and $innerIndex -lt 8) {
        Write-LibertixDiagnosticField `
            -Name "InnerException[$innerIndex].Type" `
            -Value $innerException.GetType().FullName
        Write-LibertixDiagnosticField `
            -Name "InnerException[$innerIndex].Message" `
            -Value $innerException.Message
        $innerException = $innerException.InnerException
        $innerIndex++
    }

    Write-LibertixDiagnosticField `
        -Name "DotNetException" `
        -Value $ErrorRecord.Exception.ToString()
    Write-Log "===== $heading ERROR END =====" "Red"
}
