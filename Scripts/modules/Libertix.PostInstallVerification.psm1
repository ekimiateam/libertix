Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot "Libertix.AtomicFile.psm1") -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot "Libertix.InstallationState.psm1") -Force -ErrorAction Stop

function Set-LibertixShutdownVerificationPriority {
    if (-not ("LibertixShutdownControl" -as [type])) {
        Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
public static class LibertixShutdownControl
{
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetProcessShutdownParameters(uint level, uint flags);
}
"@
    }
    # Run late during shutdown and suppress the visible retry dialog. Every
    # completed check is already durable, so Windows can safely resume the
    # scheduled task at the next startup if shutdown reaches this process.
    if (-not [LibertixShutdownControl]::SetProcessShutdownParameters(0x100, 0x1)) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Cannot configure shutdown-safe verification priority: Win32 error $code."
    }
}

function Test-LibertixProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return $null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name
}

function Write-LibertixPostInstallErrorDiagnostic {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [Parameter(Mandatory = $true)][scriptblock]$WriteLog,
        [Parameter(Mandatory = $true)][string]$Context
    )

    & $WriteLog "$Context exceptionType=$($ErrorRecord.Exception.GetType().FullName)"
    & $WriteLog "$Context fullyQualifiedErrorId=$($ErrorRecord.FullyQualifiedErrorId)"
    & $WriteLog "$Context category=$($ErrorRecord.CategoryInfo.Category) reason=$($ErrorRecord.CategoryInfo.Reason)"
    if (-not [string]::IsNullOrWhiteSpace([string]$ErrorRecord.InvocationInfo.PositionMessage)) {
        & $WriteLog "$Context position=$([string]$ErrorRecord.InvocationInfo.PositionMessage)"
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$ErrorRecord.ScriptStackTrace)) {
        & $WriteLog "$Context powershellStack=$([string]$ErrorRecord.ScriptStackTrace)"
    }
    $inner = $ErrorRecord.Exception.InnerException
    $depth = 0
    while ($null -ne $inner -and $depth -lt 8) {
        & $WriteLog "$Context innerException[$depth]=$($inner.GetType().FullName): $($inner.Message)"
        $inner = $inner.InnerException
        $depth++
    }
}

function Read-LibertixJsonObject {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description is missing: $Path"
    }
    try {
        $value = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Cannot read ${Description}: $($_.Exception.Message)"
    }
    if ($null -eq $value -or $value -is [Array]) {
        throw "$Description does not contain a JSON object."
    }
    return $value
}

function Get-LibertixScheduledTaskPrincipalSid {
    param([Parameter(Mandatory = $true)][string]$TaskName)

    [xml]$taskDefinition = Export-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    $principalId = [string]$taskDefinition.Task.Principals.Principal.UserId
    if ([string]::IsNullOrWhiteSpace($principalId)) {
        throw "Scheduled task principal is missing: $TaskName"
    }
    if ($principalId -match '^S-\d-(?:\d+-)+\d+$') {
        return $principalId
    }
    try {
        return ([Security.Principal.NTAccount]::new($principalId)).Translate(
            [Security.Principal.SecurityIdentifier]
        ).Value
    } catch {
        throw "Cannot resolve scheduled task principal '$principalId' to a SID: $TaskName"
    }
}

function Get-LibertixPartitionAlignmentBytes {
    param([Parameter(Mandatory = $true)][string]$RecoveryRoot)

    $candidates = @(
        (Join-Path $RecoveryRoot "Libertix.InstallationPolicy.json")
        (Join-Path $RecoveryRoot "payload\Scripts\config\Libertix.InstallationPolicy.json")
    )
    $policyPaths = @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($policyPaths.Count -ne 1) {
        throw "The recovery session does not contain exactly one installation policy."
    }
    $policy = Read-LibertixJsonObject -Path $policyPaths[0] -Description "installation policy"
    [int64]$alignmentBytes = [int64]$policy.storage.partitionAlignmentBytes
    if ($alignmentBytes -le 0) {
        throw "Installation policy partition alignment is invalid."
    }
    return $alignmentBytes
}

function Write-LibertixPostInstallResult {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Result
    )

    $Result.updatedAtUtc = [DateTime]::UtcNow.ToString("o")
    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ".$(Split-Path -Leaf $fullPath).$([Guid]::NewGuid().ToString('N')).tmp"
    $backup = Join-Path $directory ".$(Split-Path -Leaf $fullPath).$([Guid]::NewGuid().ToString('N')).bak"
    try {
        $encoding = New-Object Text.UTF8Encoding($false)
        $stream = New-Object IO.FileStream(
            $temporary,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough
        )
        try {
            $writer = New-Object IO.StreamWriter($stream, $encoding)
            try {
                $writer.Write(($Result | ConvertTo-Json -Depth 8))
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
            -TemporaryPath $temporary `
            -DestinationPath $fullPath `
            -BackupPath $backup
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
    }
}

function New-LibertixPostInstallResult {
    param(
        [Parameter(Mandatory = $true)][string]$PlanId,
        [Parameter(Mandatory = $true)][string]$Firmware,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        planId = $PlanId
        firmware = $Firmware
        status = "in-progress"
        startedAtUtc = [DateTime]::UtcNow.ToString("o")
        updatedAtUtc = [DateTime]::UtcNow.ToString("o")
        checks = @()
        attempts = @()
        activeAttemptId = $null
        interruptionCount = 0
        error = $null
        logPath = $LogPath
        rollbackAvailable = $true
    }
}

function Start-LibertixPostInstallAttempt {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$ResultPath,
        [Parameter(Mandatory = $true)][scriptblock]$WriteLog
    )

    $now = [DateTime]::UtcNow.ToString("o")
    if (-not (Test-LibertixProperty -Object $Result -Name "attempts")) {
        $Result | Add-Member -NotePropertyName attempts -NotePropertyValue @()
    }
    if (-not (Test-LibertixProperty -Object $Result -Name "interruptionCount")) {
        $Result | Add-Member -NotePropertyName interruptionCount -NotePropertyValue 0
    }
    $interruptedAttempts = 0
    foreach ($attempt in @($Result.attempts)) {
        if ([string]$attempt.outcome -eq "running") {
            $attempt.outcome = "interrupted"
            $attempt.completedAtUtc = $now
            $attempt | Add-Member `
                -NotePropertyName interruptionDetectedAtUtc `
                -NotePropertyValue $now `
                -Force
            $interruptedAttempts++
        }
    }
    if ($interruptedAttempts -gt 0) {
        $Result.interruptionCount = [int]$Result.interruptionCount + $interruptedAttempts
        & $WriteLog (
            "Resuming post-install verification after $interruptedAttempts " +
            "interrupted attempt(s); durable successful checks will not be repeated."
        )
    }

    $attemptId = [Guid]::NewGuid().ToString("N")
    $Result.attempts = @($Result.attempts) + @(
        [pscustomobject][ordered]@{
            attemptId = $attemptId
            processId = $PID
            startedAtUtc = $now
            completedAtUtc = $null
            outcome = "running"
        }
    )
    $Result | Add-Member `
        -NotePropertyName activeAttemptId `
        -NotePropertyValue $attemptId `
        -Force
    Write-LibertixPostInstallResult -Path $ResultPath -Result $Result
    return $attemptId
}

function Complete-LibertixPostInstallAttempt {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$AttemptId,
        [Parameter(Mandatory = $true)]
        [ValidateSet("succeeded", "failed")]
        [string]$Outcome
    )

    $attemptMatches = @(
        $Result.attempts | Where-Object { [string]$_.attemptId -eq $AttemptId }
    )
    if ($attemptMatches.Count -ne 1) {
        throw "Post-install verification attempt identity is missing or ambiguous."
    }
    if ([string]$attemptMatches[0].outcome -ne "running") {
        throw "Post-install verification attempt is not running."
    }
    $attemptMatches[0].outcome = $Outcome
    $attemptMatches[0].completedAtUtc = [DateTime]::UtcNow.ToString("o")
    $Result.activeAttemptId = $null
}

function Set-LibertixPostInstallWaitingForLinux {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RecoveryRoot,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    $plan = Read-LibertixJsonObject `
        -Path (Join-Path $RecoveryRoot "installation-plan.json") `
        -Description "installation plan"
    if ([string]$plan.planId -notmatch '^[0-9a-f]{32}$') {
        throw "Installation plan identifier is invalid."
    }
    $resultPath = Join-Path $RecoveryRoot "post-install-verification.json"
    $result = if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
        $saved = Read-LibertixJsonObject `
            -Path $resultPath `
            -Description "post-install verification result"
        if (
            [int]$saved.schemaVersion -ne 1 -or
            [string]$saved.planId -ne [string]$plan.planId -or
            [string]$saved.firmware -ne [string]$plan.firmware
        ) {
            throw "Post-install verification result belongs to another contract."
        }
        if ([string]$saved.status -in @("succeeded", "failed", "rolled-back")) {
            return $saved
        }
        $saved
    } else {
        New-LibertixPostInstallResult `
            -PlanId ([string]$plan.planId) `
            -Firmware ([string]$plan.firmware) `
            -LogPath $LogPath
    }
    $result.status = "waiting-linux-boot"
    $result.error = $null
    $result.logPath = $LogPath
    $result.rollbackAvailable = $true
    $result | Add-Member `
        -NotePropertyName waitingFor `
        -NotePropertyValue "installed-linux-boot.json" `
        -Force
    Write-LibertixPostInstallResult -Path $resultPath -Result $result
    return $result
}

function Set-LibertixPostInstallFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RecoveryRoot,
        [Parameter(Mandatory = $true)][string]$LogPath,
        [Parameter(Mandatory = $true)][string]$CheckName,
        [Parameter(Mandatory = $true)][string]$ErrorMessage
    )

    $plan = Read-LibertixJsonObject `
        -Path (Join-Path $RecoveryRoot "installation-plan.json") `
        -Description "installation plan"
    $resultPath = Join-Path $RecoveryRoot "post-install-verification.json"
    $result = if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
        $saved = Read-LibertixJsonObject `
            -Path $resultPath `
            -Description "post-install verification result"
        if (
            [int]$saved.schemaVersion -ne 1 -or
            [string]$saved.planId -ne [string]$plan.planId -or
            [string]$saved.firmware -ne [string]$plan.firmware
        ) {
            throw "Post-install verification result belongs to another contract."
        }
        $saved
    } else {
        New-LibertixPostInstallResult `
            -PlanId ([string]$plan.planId) `
            -Firmware ([string]$plan.firmware) `
            -LogPath $LogPath
    }
    $result.checks = @($result.checks | Where-Object { [string]$_.name -ne $CheckName }) + @(
        [pscustomobject][ordered]@{
            name = $CheckName
            passed = $false
            detail = $ErrorMessage
            checkedAtUtc = [DateTime]::UtcNow.ToString("o")
        }
    )
    $result.status = "failed"
    $result.error = $ErrorMessage
    $result.logPath = $LogPath
    $result.rollbackAvailable = $true
    Write-LibertixPostInstallResult -Path $resultPath -Result $result
    return $result
}

function Add-LibertixPostInstallCheck {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$ResultPath,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Test,
        [Parameter(Mandatory = $true)][scriptblock]$WriteLog
    )

    $existingChecks = @($Result.checks | Where-Object { [string]$_.name -eq $Name })
    if ($existingChecks.Count -gt 1) {
        throw "Post-install result contains duplicate check '$Name'."
    }
    if ($existingChecks.Count -eq 1 -and [bool]$existingChecks[0].passed) {
        & $WriteLog (
            "Post-install check resumed from durable result: $Name - " +
            [string]$existingChecks[0].detail
        )
        return
    }
    $Result.checks = @($Result.checks | Where-Object { [string]$_.name -ne $Name })
    & $WriteLog "Post-install check started: $Name"
    try {
        $detail = & $Test
        $Result.checks = @($Result.checks) + @(
            [pscustomobject][ordered]@{
                name = $Name
                passed = $true
                detail = if ($null -eq $detail) { "OK" } else { [string]$detail }
                checkedAtUtc = [DateTime]::UtcNow.ToString("o")
            }
        )
        Write-LibertixPostInstallResult -Path $ResultPath -Result $Result
        & $WriteLog "Post-install check passed: $Name - $($Result.checks[-1].detail)"
    } catch {
        $Result.checks = @($Result.checks) + @(
            [pscustomobject][ordered]@{
                name = $Name
                passed = $false
                detail = $_.Exception.Message
                checkedAtUtc = [DateTime]::UtcNow.ToString("o")
            }
        )
        Write-LibertixPostInstallResult -Path $ResultPath -Result $Result
        & $WriteLog "Post-install check failed: $Name - $($_.Exception.Message)"
        Write-LibertixPostInstallErrorDiagnostic `
            -ErrorRecord $_ `
            -WriteLog $WriteLog `
            -Context "Post-install check diagnostic: $Name"
        throw
    }
}

function Assert-LibertixLinuxBootEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Evidence,
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][int64]$AlignmentBytes
    )

    foreach ($property in @(
        "schemaVersion", "planId", "recoveryRunId", "observedAtUtc", "bootId",
        "firmware", "distribution", "root", "system", "grub"
    )) {
        if (-not (Test-LibertixProperty -Object $Evidence -Name $property)) {
            throw "Linux boot evidence is missing field '$property'."
        }
    }
    if ([int]$Evidence.schemaVersion -ne 1) {
        throw "Linux boot evidence schema is unsupported."
    }
    if (
        [string]$Evidence.planId -ne [string]$Plan.planId -or
        [string]$Evidence.recoveryRunId -ne [string]$Plan.runtime.recoveryRunId
    ) {
        throw "Linux boot evidence belongs to another installation plan."
    }
    if ([string]$Evidence.firmware -ne [string]$Plan.firmware) {
        throw "Linux boot evidence firmware differs from the installation plan."
    }
    if (
        [string]$Evidence.distribution.id -ne [string]$Plan.distribution.id -or
        [string]$Evidence.distribution.osReleaseId -ne [string]$Plan.distribution.osReleaseId
    ) {
        throw "Linux boot evidence distribution differs from the installation plan."
    }
    [int64]$plannedLinuxSize = [int64]$Plan.disk.installer.finalSizeBytes
    [int64]$observedLinuxSize = [int64]$Evidence.root.sizeBytes
    if (
        [string]$Evidence.root.filesystem -ne "ext4" -or
        [int64]$Evidence.root.offsetBytes -ne [int64]$Plan.disk.installer.offsetBytes -or
        $observedLinuxSize -gt $plannedLinuxSize -or
        $observedLinuxSize -lt ($plannedLinuxSize - $AlignmentBytes) -or
        [int64]$Evidence.root.plannedSizeBytes -ne $plannedLinuxSize -or
        [int64]$Evidence.root.alignmentToleranceBytes -ne $AlignmentBytes
    ) {
        throw "Linux root evidence differs from the planned ext4 partition."
    }
    if (
        -not [bool]$Evidence.system.rootReadWrite -or
        [string]$Evidence.system.fstabRootUuid -ne [string]$Evidence.root.uuid -or
        [string]$Evidence.system.machineIdSha256 -notmatch '^[0-9a-f]{64}$' -or
        [string]$Evidence.system.username -ne [string]$Plan.account.username -or
        -not [bool]$Evidence.system.sudoMember -or
        -not [bool]$Evidence.system.passwordActive -or
        -not [bool]$Evidence.system.dpkgAuditClean -or
        [int]$Evidence.system.failedSystemdUnits -ne 0
    ) {
        throw "Linux boot evidence does not prove a healthy installed system."
    }
    if (
        -not [bool]$Evidence.grub.syntaxValid -or
        -not [bool]$Evidence.grub.requiredEntriesPresent -or
        [string]$Evidence.grub.configSha256 -notmatch '^[0-9a-f]{64}$' -or
        [string]::IsNullOrWhiteSpace([string]$Evidence.grub.runningKernel)
    ) {
        throw "Linux boot evidence does not prove a valid GRUB and running kernel."
    }
    if (-not [bool]$Evidence.grub.bootChain.verified) {
        throw "Linux boot evidence does not prove the installed boot chain."
    }
    if ([string]$Plan.firmware -eq "uefi") {
        foreach ($property in @("type", "bootNumber", "entry")) {
            if (-not (Test-LibertixProperty -Object $Evidence.grub.bootChain -Name $property)) {
                throw "UEFI boot evidence is missing boot-chain field '$property'."
            }
        }
        $uefiEntry = $Evidence.grub.bootChain.entry
        foreach ($property in @("description", "loaderPath", "partitionNumber", "partitionGuid")) {
            if (-not (Test-LibertixProperty -Object $uefiEntry -Name $property)) {
                throw "UEFI boot evidence is missing boot-entry field '$property'."
            }
        }
        if (
            [string]$Evidence.grub.bootChain.type -ne "uefi-boot-current" -or
            [string]$Evidence.grub.bootChain.bootNumber -notmatch '^[0-9a-f]{4}$' -or
            [string]$uefiEntry.description -ne "Libertix" -or
            [string]$uefiEntry.loaderPath -ne "\EFI\Libertix\shimx64.efi" -or
            [int]$uefiEntry.partitionNumber -le 0 -or
            [string]$uefiEntry.partitionGuid -notmatch (
                '^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
            )
        ) {
            throw "UEFI boot evidence does not prove that firmware selected Libertix."
        }
    } elseif (
        [string]$Evidence.grub.bootChain.type -ne "bios-mbr" -or
        -not [bool]$Evidence.grub.bootChain.bootCodeChangedFromBackup -or
        [string]$Evidence.grub.bootChain.currentMbrSha256 -notmatch '^[0-9a-f]{64}$' -or
        [string]$Evidence.grub.bootChain.backupMbrSha256 -notmatch '^[0-9a-f]{64}$'
    ) {
        throw "BIOS boot evidence does not prove that GRUB replaced the saved boot code."
    }
    [DateTimeOffset]$observed = [DateTimeOffset]::MinValue
    if (
        -not [DateTimeOffset]::TryParse([string]$Evidence.observedAtUtc, [ref]$observed) -or
        $observed.Offset -ne [TimeSpan]::Zero -or
        $observed -lt [DateTimeOffset]$Plan.createdAtUtc
    ) {
        throw "Linux boot evidence timestamp is invalid or predates the plan."
    }
    return "plan=$($Evidence.planId) boot=$($Evidence.bootId) kernel=$($Evidence.grub.runningKernel)"
}

function Test-LibertixDiskGeometry {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][int64]$AlignmentBytes
    )

    $disk = Get-Disk -Number ([int]$Plan.disk.number) -ErrorAction Stop
    if (([string]$disk.UniqueId).Trim() -ne ([string]$Plan.disk.uniqueId).Trim()) {
        throw "System disk identity differs from the installation plan."
    }
    if ([int64]$disk.Size -ne [int64]$Plan.disk.sizeBytes) {
        throw "System disk size differs from the installation plan."
    }
    if ([string]$disk.PartitionStyle -ne [string]$Plan.disk.partitionStyle) {
        throw "System disk partition style differs from the installation plan."
    }
    $partitions = @(Get-Partition -DiskNumber ([int]$disk.Number) -ErrorAction Stop)
    [int64]$plannedLinuxSize = [int64]$Plan.disk.installer.finalSizeBytes
    $linux = @($partitions | Where-Object {
        [int64]$_.Offset -eq [int64]$Plan.disk.installer.offsetBytes -and
        [int64]$_.Size -le $plannedLinuxSize -and
        [int64]$_.Size -ge ($plannedLinuxSize - $AlignmentBytes)
    })
    if ($linux.Count -ne 1) {
        throw "Expected Linux partition geometry is absent or ambiguous."
    }
    $windows = @($partitions | Where-Object {
        [int64]$_.Offset -eq [int64]$Plan.disk.windows.offsetBytes
    })
    if ($windows.Count -ne 1) {
        throw "Expected Windows partition geometry is absent or ambiguous."
    }
    $gap = [int64]$Plan.disk.installer.offsetBytes -
        ([int64]$windows[0].Offset + [int64]$windows[0].Size)
    if ($gap -lt 0 -or $gap -gt 1MB) {
        throw "Windows and Linux partitions have an unexpected gap."
    }
    if ([int64]$Plan.disk.recovery.sizeBytes -gt 0) {
        $recovery = @($partitions | Where-Object {
            [int64]$_.Offset -eq [int64]$Plan.disk.recovery.offsetBytes -and
            [int64]$_.Size -eq [int64]$Plan.disk.recovery.sizeBytes
        })
        if ($recovery.Count -ne 1) {
            throw "Windows Recovery partition geometry changed."
        }
    }
    return "disk=$($disk.Number) linuxPartition=$($linux[0].PartitionNumber)"
}

function Test-LibertixWindowsHealth {
    param([Parameter(Mandatory = $true)][object]$Plan)

    $systemDrive = ([string]$Plan.disk.systemDrive).TrimEnd(":")
    $volume = Get-Volume -DriveLetter $systemDrive -ErrorAction Stop
    if ([string]$volume.FileSystem -ne "NTFS") {
        throw "Windows system volume is not NTFS."
    }
    if ([string]$volume.HealthStatus -ne "Healthy") {
        throw "Windows system volume is not healthy."
    }
    # REAgentC localizes every /info status value. /enable is idempotent and its
    # exit code is the stable contract already used during BIOS preparation.
    $reagent = @(& reagentc.exe /enable 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "reagentc.exe could not enable Windows Recovery Environment with rc=$LASTEXITCODE output=$($reagent -join ' ')"
    }
    return "filesystem=$($volume.FileSystem) health=$($volume.HealthStatus) winre=enabled"
}

function Test-LibertixWindowsBootConfiguration {
    param([Parameter(Mandatory = $true)][object]$Plan)

    $entries = @(& bcdedit.exe /enum all 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "bcdedit.exe failed with rc=$LASTEXITCODE."
    }
    $text = $entries -join "`n"
    if ($text -notmatch '(?i)winload[.]e(?:xe|fi)') {
        throw "Windows loader is absent from BCD."
    }
    if ($text -match '(?i)Libertix Installer|grldr|libertix-live[.]iso') {
        throw "A temporary Libertix boot entry remains in BCD."
    }
    $partitions = @(Get-Partition -DiskNumber ([int]$Plan.disk.number) -ErrorAction Stop)
    if ([string]$Plan.firmware -eq "uefi") {
        $esp = @($partitions | Where-Object {
            [string]$_.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}"
        })
        if ($esp.Count -ne 1) {
            throw "The system disk does not contain exactly one EFI System Partition."
        }
    } else {
        $bootPartitions = @($partitions | Where-Object { $_.IsSystem })
        if ($bootPartitions.Count -eq 0) {
            $bootPartitions = @($partitions | Where-Object { $_.IsActive })
        }
        if ($bootPartitions.Count -ne 1) {
            throw "The BIOS system disk does not contain exactly one Windows boot partition."
        }
    }
    return "firmware=$($Plan.firmware) windowsLoader=present"
}

function Test-LibertixTemporaryBootFilesAbsent {
    param([Parameter(Mandatory = $true)][object]$Plan)

    $systemDrive = [string]$Plan.disk.systemDrive
    foreach ($name in @("grldr", "grldr.mbr", "menu.lst", "libertix-live.iso")) {
        $path = Join-Path $systemDrive $name
        if (Test-Path -LiteralPath $path) {
            throw "Temporary boot file remains: $path"
        }
    }
    return "temporary boot files absent"
}

function Test-LibertixRecoveryArchive {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$RecoveryRoot
    )

    foreach ($relativePath in @(
        "installation-plan.json",
        "installation-state.json",
        "installed-linux-boot.json"
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $RecoveryRoot $relativePath) -PathType Leaf)) {
            throw "Permanent recovery file is missing: $relativePath"
        }
    }
    $runtimeFiles = if ([string]$Plan.firmware -eq "uefi") {
        @(
            "payload\Scripts\modules\Libertix.InstallationState.psm1",
            "payload\Scripts\modules\Libertix.PostInstallVerification.psm1",
            "payload\Scripts\libertix-uefi-recovery-agent.ps1",
            "payload\Scripts\libertix-post-install-result.ps1",
            "payload\Resources\Images\icon.ico"
        )
    } else {
        @(
            "Libertix.InstallationState.psm1",
            "Libertix.PostInstallVerification.psm1",
            "recover.ps1",
            "libertix-post-install-result.ps1",
            "Images\icon.ico"
        )
    }
    foreach ($relativePath in $runtimeFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $RecoveryRoot $relativePath) -PathType Leaf)) {
            throw "Permanent recovery runtime is missing: $relativePath"
        }
    }
    $firmwareEvidence = if ([string]$Plan.firmware -eq "uefi") {
        @("uefi-transaction.json")
    } else {
        @("bcd-backup", "mbr-backup\mbr-before-grub.bin", "mbr-backup\mbr-before-grub.sha256")
    }
    foreach ($relativePath in $firmwareEvidence) {
        $path = Join-Path $RecoveryRoot $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Firmware rollback evidence is missing: $path"
        }
    }
    return "rollback archive retained"
}

function Test-LibertixWindowsReadOnlyShare {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][int64]$AlignmentBytes
    )

    if (-not [bool]$Plan.features.shareLinuxFilesInWindows) {
        return "Linux-to-Windows sharing was not requested"
    }
    $shareRoot = Join-Path $env:ProgramData "Libertix\WindowsShare"
    $config = Read-LibertixJsonObject `
        -Path (Join-Path $shareRoot "config.json") `
        -Description "Windows read-only Linux sharing configuration"
    if (-not [bool]$config.Enabled) {
        throw "Windows read-only Linux sharing is disabled despite the installation plan."
    }
    if (
        [int]$config.SystemDiskNumber -ne [int]$Plan.disk.number -or
        ([string]$config.SystemDiskUniqueId).Trim() -ne ([string]$Plan.disk.uniqueId).Trim() -or
        [int64]$config.ExpectedLinuxPartitionOffset -ne [int64]$Plan.disk.installer.offsetBytes -or
        [int64]$config.ExpectedLinuxPartitionSize -ne [int64]$Plan.disk.installer.finalSizeBytes -or
        [int64]$config.PartitionSizeToleranceBytes -ne $AlignmentBytes
    ) {
        throw "Windows sharing configuration does not match the installation plan partition."
    }
    $disk = Get-Disk -Number ([int]$config.SystemDiskNumber) -ErrorAction Stop
    if (([string]$disk.UniqueId).Trim() -ne ([string]$config.SystemDiskUniqueId).Trim()) {
        throw "Windows sharing disk identity does not match the current disk."
    }
    $partitions = @(
        Get-Partition -DiskNumber ([int]$config.SystemDiskNumber) -ErrorAction Stop |
            Where-Object {
                [int64]$_.Offset -eq [int64]$config.ExpectedLinuxPartitionOffset -and
                [int64]$_.Size -le [int64]$config.ExpectedLinuxPartitionSize -and
                [int64]$_.Size -ge (
                    [int64]$config.ExpectedLinuxPartitionSize - $AlignmentBytes
                )
            }
    )
    if ($partitions.Count -ne 1) {
        throw "Windows sharing partition identity does not resolve to exactly one partition."
    }

    $winFspKey = "HKLM:\SOFTWARE\WOW6432Node\WinFsp"
    $launcherKey = Join-Path $winFspKey "Services\ext4-mount"
    $commandLine = [string](
        Get-ItemPropertyValue -LiteralPath $launcherKey -Name CommandLine -ErrorAction Stop
    )
    $runAs = [string](
        Get-ItemPropertyValue -LiteralPath $launcherKey -Name RunAs -ErrorAction Stop
    )
    [int]$recovery = [int](
        Get-ItemPropertyValue -LiteralPath $launcherKey -Name Recovery -ErrorAction Stop
    )
    [int]$broadcast = [int](
        Get-ItemPropertyValue `
            -LiteralPath $winFspKey `
            -Name MountBroadcastDriveChange `
            -ErrorAction Stop
    )
    if (
        $commandLine -notmatch '(?i)(?:^|\s)--ro(?:\s|$)' -or
        $runAs -ne "LocalSystem" -or
        $recovery -ne 1 -or
        $broadcast -ne 1
    ) {
        throw "WinFsp is not configured as a recoverable global read-only mount."
    }

    $mountTasks = @(Get-ScheduledTask -TaskName "LibertixLinuxReadOnly" -ErrorAction Stop)
    $mountTaskPrincipalSid = if ($mountTasks.Count -eq 1) {
        Get-LibertixScheduledTaskPrincipalSid -TaskName "LibertixLinuxReadOnly"
    } else {
        $null
    }
    if (
        $mountTasks.Count -ne 1 -or
        $mountTaskPrincipalSid -ne "S-1-5-18" -or
        [string]$mountTasks[0].State -eq "Disabled"
    ) {
        throw "Windows read-only Linux mount task is missing, disabled or not owned by SYSTEM."
    }

    $mountStatus = Read-LibertixJsonObject `
        -Path (Join-Path $shareRoot "mount-status.json") `
        -Description "Windows read-only Linux mount status"
    if (
        [int]$mountStatus.schemaVersion -ne 1 -or
        [int]$mountStatus.diskNumber -ne [int]$config.SystemDiskNumber -or
        ([string]$mountStatus.diskUniqueId).Trim() -ne ([string]$config.SystemDiskUniqueId).Trim() -or
        [int]$mountStatus.partitionNumber -ne [int]$partitions[0].PartitionNumber -or
        [int64]$mountStatus.partitionOffset -ne [int64]$partitions[0].Offset -or
        [int64]$mountStatus.partitionSize -ne [int64]$partitions[0].Size -or
        -not [bool]$mountStatus.readOnly -or
        [string]$mountStatus.drive -notmatch '^[L-Z]:$'
    ) {
        throw "Windows read-only Linux mount status does not match the proven partition."
    }
    $drive = [string]$mountStatus.drive
    $linuxHome = "$drive\home\$($config.LinuxUsername)"
    if (-not (Test-Path -LiteralPath $linuxHome -PathType Container)) {
        throw "Linux home is not readable from the verified Windows drive."
    }

    $ext4Exe = Join-Path $env:ProgramFiles "ext4-win-driver\ext4.exe"
    $devicePattern = [regex]::Escape("\\.\PhysicalDrive$($config.SystemDiskNumber)")
    $drivePattern = [regex]::Escape($drive)
    $partitionPattern = [regex]::Escape([string]$partitions[0].PartitionNumber)
    $processes = @(
        Get-CimInstance Win32_Process -Filter "Name='ext4.exe'" -ErrorAction Stop |
            Where-Object {
                $processCommandLine = [string]$_.CommandLine
                [string]$_.ExecutablePath -ieq $ext4Exe -and
                $processCommandLine -match '(?i)(?:^|\s)mount(?:\s|$)' -and
                $processCommandLine -match ('(?i)(?:^|\s)"?{0}"?(?:\s|$)' -f $devicePattern) -and
                $processCommandLine -match ('(?i)(?:^|\s)--drive\s+"?{0}"?(?:\s|$)' -f $drivePattern) -and
                $processCommandLine -match ('(?i)(?:^|\s)--part\s+"?{0}"?(?:\s|$)' -f $partitionPattern) -and
                $processCommandLine -match '(?i)(?:^|\s)--ro(?:\s|$)'
            }
    )
    if ($processes.Count -ne 1) {
        throw "Exactly one ext4 process must own the verified read-only Linux drive."
    }

    $writeProbe = Join-Path $drive ".libertix-postinstall-write-probe-$([Guid]::NewGuid().ToString('N'))"
    $writeAccepted = $false
    try {
        Set-Content -LiteralPath $writeProbe -Value "write must be refused" -ErrorAction Stop
        $writeAccepted = $true
    } catch {
        # A denied probe is the expected proof for this security boundary.
        $writeAccepted = $false
    } finally {
        if ($writeAccepted) {
            Remove-Item -LiteralPath $writeProbe -Force -ErrorAction SilentlyContinue
        }
    }
    if ($writeAccepted) {
        throw "SECURITY ERROR: the Windows ext4 mount accepted a write."
    }

    $shortcutPaths = @(
        Get-ChildItem `
            -Path "$env:SystemDrive\Users\*\Links\Linux_$($config.LinuxUsername)_read-only.lnk" `
            -File `
            -ErrorAction SilentlyContinue
    )
    if ($shortcutPaths.Count -eq 0) {
        throw "No Windows user profile contains the Linux read-only shortcut."
    }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($shortcutPath in $shortcutPaths) {
        $shortcut = $shell.CreateShortcut([string]$shortcutPath.FullName)
        if ([string]$shortcut.TargetPath -ne $linuxHome) {
            throw "Windows Linux shortcut target does not match the verified Linux home."
        }
    }
    return "drive=$drive partition=$($partitions[0].PartitionNumber) readOnly=true shortcuts=$($shortcutPaths.Count)"
}

function Invoke-LibertixPostInstallVerification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RecoveryRoot,
        [Parameter(Mandatory = $true)][string]$LogPath,
        [Parameter(Mandatory = $true)][scriptblock]$WriteLog
    )

    $planPath = Join-Path $RecoveryRoot "installation-plan.json"
    $executionStatePath = Join-Path $RecoveryRoot "installation-state.json"
    $evidencePath = Join-Path $RecoveryRoot "installed-linux-boot.json"
    $resultPath = Join-Path $RecoveryRoot "post-install-verification.json"
    $plan = Read-LibertixJsonObject -Path $planPath -Description "installation plan"
    if ([string]$plan.planId -notmatch '^[0-9a-f]{32}$') {
        throw "Installation plan identifier is invalid."
    }
    [int64]$alignmentBytes = Get-LibertixPartitionAlignmentBytes -RecoveryRoot $RecoveryRoot
    $result = if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
        $saved = Read-LibertixJsonObject `
            -Path $resultPath `
            -Description "post-install verification result"
        if (
            [int]$saved.schemaVersion -ne 1 -or
            [string]$saved.planId -ne [string]$plan.planId -or
            [string]$saved.firmware -ne [string]$plan.firmware
        ) {
            throw "Post-install verification result belongs to another contract."
        }
        if ([string]$saved.status -eq "rolled-back") {
            throw "Post-install verification cannot resume after rollback."
        }
        if ([string]$saved.status -eq "succeeded") {
            return $saved
        }
        $saved.status = "in-progress"
        $saved.error = $null
        $saved.logPath = $LogPath
        $saved.rollbackAvailable = $true
        $saved
    } else {
        New-LibertixPostInstallResult `
            -PlanId ([string]$plan.planId) `
            -Firmware ([string]$plan.firmware) `
            -LogPath $LogPath
    }
    $attemptId = Start-LibertixPostInstallAttempt `
        -Result $result `
        -ResultPath $resultPath `
        -WriteLog $WriteLog
    & $WriteLog (
        "Post-install verification started: attempt=$attemptId plan=$($plan.planId) " +
        "firmware=$($plan.firmware) host=$env:COMPUTERNAME " +
        "powershell=$($PSVersionTable.PSVersion) os=$([Environment]::OSVersion.VersionString)"
    )

    try {
        Set-LibertixShutdownVerificationPriority
        Add-LibertixPostInstallCheck -Result $result -ResultPath $resultPath `
            -Name "execution-ledger" -WriteLog $WriteLog -Test {
                $state = Read-LibertixExecutionState -Path $executionStatePath
                if ([string]$state.planId -ne [string]$plan.planId -or [string]$state.status -ne "succeeded") {
                    throw "Installation execution ledger is not a successful state for this plan."
                }
                "revision=$($state.revision) status=$($state.status)"
            }
        Add-LibertixPostInstallCheck -Result $result -ResultPath $resultPath `
            -Name "installed-linux-boot" -WriteLog $WriteLog -Test {
                $evidence = Read-LibertixJsonObject `
                    -Path $evidencePath `
                    -Description "installed Linux boot evidence"
                Assert-LibertixLinuxBootEvidence `
                    -Evidence $evidence `
                    -Plan $plan `
                    -AlignmentBytes $alignmentBytes
            }
        Add-LibertixPostInstallCheck -Result $result -ResultPath $resultPath `
            -Name "disk-geometry" -WriteLog $WriteLog -Test {
                Test-LibertixDiskGeometry -Plan $plan -AlignmentBytes $alignmentBytes
            }
        Add-LibertixPostInstallCheck -Result $result -ResultPath $resultPath `
            -Name "windows-read-only-linux-share" -WriteLog $WriteLog -Test {
                Test-LibertixWindowsReadOnlyShare `
                    -Plan $plan `
                    -AlignmentBytes $alignmentBytes
            }
        Add-LibertixPostInstallCheck -Result $result -ResultPath $resultPath `
            -Name "windows-health" -WriteLog $WriteLog -Test {
                Test-LibertixWindowsHealth -Plan $plan
            }
        Add-LibertixPostInstallCheck -Result $result -ResultPath $resultPath `
            -Name "boot-configuration" -WriteLog $WriteLog -Test {
                Test-LibertixWindowsBootConfiguration -Plan $plan
            }
        Add-LibertixPostInstallCheck -Result $result -ResultPath $resultPath `
            -Name "temporary-boot-cleanup" -WriteLog $WriteLog -Test {
                Test-LibertixTemporaryBootFilesAbsent -Plan $plan
            }
        Add-LibertixPostInstallCheck -Result $result -ResultPath $resultPath `
            -Name "permanent-recovery-archive" -WriteLog $WriteLog -Test {
                Test-LibertixRecoveryArchive -Plan $plan -RecoveryRoot $RecoveryRoot
            }
    } catch {
        $primaryError = $_
        $result.status = "failed"
        $result.error = $primaryError.Exception.Message
        $result.rollbackAvailable = $true
        try {
            Complete-LibertixPostInstallAttempt `
                -Result $result `
                -AttemptId $attemptId `
                -Outcome "failed"
            Write-LibertixPostInstallResult -Path $resultPath -Result $result
        } catch {
            & $WriteLog (
                "Could not persist the failed post-install attempt; " +
                "the startup task will retry: $($_.Exception.Message)"
            )
        }
        & $WriteLog "Post-install verification failed: $($primaryError.Exception.Message)"
        try {
            Write-LibertixPostInstallErrorDiagnostic `
                -ErrorRecord $primaryError `
                -WriteLog $WriteLog `
                -Context "Post-install verification diagnostic"
        } catch {
            & $WriteLog "Could not write the extended error diagnostic: $($_.Exception.Message)"
        }
        throw $primaryError
    }

    $result.status = "succeeded"
    $result.rollbackAvailable = $true
    Complete-LibertixPostInstallAttempt `
        -Result $result `
        -AttemptId $attemptId `
        -Outcome "succeeded"
    Write-LibertixPostInstallResult -Path $resultPath -Result $result
    & $WriteLog "Post-install verification completed successfully."
    return $result
}

Export-ModuleMember -Function `
    Assert-LibertixLinuxBootEvidence, `
    Invoke-LibertixPostInstallVerification, `
    Set-LibertixPostInstallFailure, `
    Set-LibertixPostInstallWaitingForLinux, `
    Set-LibertixShutdownVerificationPriority, `
    Test-LibertixDiskGeometry, `
    Test-LibertixRecoveryArchive, `
    Test-LibertixTemporaryBootFilesAbsent, `
    Test-LibertixWindowsReadOnlyShare
