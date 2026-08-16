param(
    [Parameter(Mandatory = $true)][string]$StatePath,
    [ValidateSet("Check", "Prompt", "Cancel", "InstallPreferredPath")]
    [string]$Action = "Check",
    [ValidateRange(0, 2147483647)][int]$WaitForProcessId = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$SystemDrive = [string]$env:SystemDrive
if ($SystemDrive -notmatch "^[A-Za-z]:$") {
    throw "SystemDrive must be a valid Windows drive designator."
}
$WindowsShareRoot = Join-Path $SystemDrive "ProgramData\Libertix\WindowsShare"
$script:AtomicFileModulePath = ""

function Write-AgentLog {
    param([Parameter(Mandatory = $true)][string]$Message)

    $root = Split-Path -Parent $StatePath
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Add-Content -LiteralPath (Join-Path $root "recovery-agent.log") -Value (
        "[{0}] {1}" -f (Get-Date -Format o), $Message
    )
}

function Write-AgentErrorRecord {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $exception = $ErrorRecord.Exception
    Write-AgentLog "ERROR: $($exception.Message)"
    Write-AgentLog "ERROR ExceptionType: $($exception.GetType().FullName)"
    Write-AgentLog "ERROR FullyQualifiedErrorId: $($ErrorRecord.FullyQualifiedErrorId)"
    Write-AgentLog "ERROR CategoryInfo: $($ErrorRecord.CategoryInfo)"
    if ($ErrorRecord.InvocationInfo) {
        Write-AgentLog "ERROR Position: $($ErrorRecord.InvocationInfo.PositionMessage)"
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$ErrorRecord.ScriptStackTrace)) {
        Write-AgentLog "ERROR PowerShellStack: $($ErrorRecord.ScriptStackTrace)"
    }
    $innerException = $exception.InnerException
    $innerIndex = 0
    while ($null -ne $innerException) {
        $innerIndex++
        Write-AgentLog (
            "ERROR InnerException[$innerIndex]: " +
            "$($innerException.GetType().FullName): $($innerException.Message)"
        )
        $innerException = $innerException.InnerException
    }
    Write-AgentLog "ERROR DotNetException: $($exception.ToString())"
}

function Publish-RecoveryFileAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$TemporaryPath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][string]$BackupPath
    )

    if (-not (Test-Path -LiteralPath $script:AtomicFileModulePath -PathType Leaf)) {
        throw "Atomic file module is missing from the recovery payload."
    }
    # Other recovery modules import the same dependency in their private
    # session state. Invoke a fresh module instance explicitly so Windows
    # PowerShell 5.1 import order cannot hide the exported command.
    $atomicFileModule = Import-Module `
        -Name $script:AtomicFileModulePath `
        -Force `
        -PassThru `
        -ErrorAction Stop
    & $atomicFileModule {
        param(
            [string]$TemporaryPath,
            [string]$DestinationPath,
            [string]$BackupPath
        )
        Publish-LibertixFileAtomic `
            -TemporaryPath $TemporaryPath `
            -DestinationPath $DestinationPath `
            -BackupPath $BackupPath
    } $TemporaryPath $DestinationPath $BackupPath
}

function Read-EnvValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $line = Get-Content -LiteralPath $Path | Where-Object {
        $_ -match "^$([regex]::Escape($Name))="
    } | Select-Object -First 1
    if (-not $line) {
        return $null
    }
    return ($line -replace "^$([regex]::Escape($Name))=", "").Trim()
}

function Save-State {
    # This agent runs at startup and decides, from this document alone, which
    # recovery phase applies. A torn write would leave it unable to determine
    # that phase, so publish it with a same-directory atomic rename.
    param([Parameter(Mandatory = $true)]$State)

    $State.LastCheckedUtc = [DateTime]::UtcNow.ToString("o")
    $fullPath = [IO.Path]::GetFullPath($StatePath)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
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

        if ([IO.File]::Exists($fullPath)) {
            [IO.File]::Replace($temporaryPath, $fullPath, $backupPath)
        } else {
            [IO.File]::Move($temporaryPath, $fullPath)
        }
    } finally {
        if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
        if ([IO.File]::Exists($backupPath)) { [IO.File]::Delete($backupPath) }
    }
}

function Assert-RecoveryState {
    param([Parameter(Mandatory = $true)]$State)

    $expectedRoot = (Join-Path $env:ProgramData "Libertix\UefiRecovery") + "\"
    if (
        [string]$State.RunId -notmatch '^[0-9a-f]{32}$' -or
        [string]$State.PlanId -notmatch '^[0-9a-f]{32}$' -or
        [string]$State.PlanId -ne [string]$State.RunId
    ) {
        throw "Recovery state plan identity is invalid."
    }
    $fullRoot = [IO.Path]::GetFullPath([string]$State.RecoveryRoot)
    if (-not $fullRoot.StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Recovery state is outside the Libertix recovery root."
    }
    if ([IO.Path]::GetFullPath($StatePath) -ne (Join-Path $fullRoot "state.json")) {
        throw "Recovery state path does not match its declared recovery root."
    }
    foreach ($path in @($State.PayloadRoot, $State.ConfigPath)) {
        if (-not [IO.Path]::GetFullPath([string]$path).StartsWith($fullRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Recovery payload path is outside the declared recovery root."
        }
    }
    if (
        [int]$State.BootPartitionNumber -le 0 -or
        [int64]$State.BootPartitionOffset -le 0 -or
        [int64]$State.BootPartitionSize -le 0
    ) {
        throw "Recovery state boot partition geometry is invalid."
    }
}

function Read-ValidatedExecutionState {
    param([Parameter(Mandatory = $true)]$RecoveryState)

    $executionStatePath = Join-Path $RecoveryState.RecoveryRoot "installation-state.json"
    $modulePath = Join-Path `
        $RecoveryState.PayloadRoot `
        "Scripts\modules\Libertix.InstallationState.psm1"
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Installation state validation module is missing."
    }
    Import-Module -Name $modulePath -Force -ErrorAction Stop
    $executionState = Read-LibertixExecutionState -Path $executionStatePath
    if ([string]$executionState.planId -ne [string]$RecoveryState.PlanId) {
        throw "Installation state does not belong to the UEFI recovery transaction."
    }
    return $executionState
}

function Test-RecoveryPayload {
    param([Parameter(Mandatory = $true)]$State)

    $manifestPath = Join-Path $State.RecoveryRoot "payload-manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Recovery payload manifest is missing."
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    foreach ($item in @($manifest.Files)) {
        $path = Join-Path $State.PayloadRoot ([string]$item.RelativePath)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Recovery payload file is missing: $($item.RelativePath)"
        }
        $info = Get-Item -LiteralPath $path
        if ([int64]$info.Length -ne [int64]$item.Length) {
            throw "Recovery payload length mismatch: $($item.RelativePath)"
        }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne [string]$item.Sha256) {
            throw "Recovery payload hash mismatch: $($item.RelativePath)"
        }
    }
}

function Test-LinuxPartitionPresent {
    param([Parameter(Mandatory = $true)]$State)

    if (
        $null -eq $State.SystemDiskNumber -or
        [string]::IsNullOrWhiteSpace([string]$State.SystemDiskUniqueId) -or
        [string]::IsNullOrWhiteSpace([string]$State.SystemDiskPartitionTableId) -or
        $null -eq $State.SystemDiskSize -or
        $null -eq $State.ExpectedLinuxPartitionOffset -or
        $null -eq $State.ExpectedLinuxPartitionSize
    ) {
        return $false
    }
    $disk = Get-Disk -Number ([int]$State.SystemDiskNumber) -ErrorAction Stop
    if (
        ([string]$disk.UniqueId).Trim() -ne ([string]$State.SystemDiskUniqueId).Trim() -or
        [int64]$disk.Size -ne [int64]$State.SystemDiskSize -or
        [string]$disk.PartitionStyle -ne "GPT" -or
        -not $disk.Guid
    ) {
        return $false
    }
    $partitionTableId = "gpt:$(([Guid]$disk.Guid).ToString('D').ToLowerInvariant())"
    if ($partitionTableId -ne [string]$State.SystemDiskPartitionTableId) {
        return $false
    }
    $expectedSize = [int64]$State.ExpectedLinuxPartitionSize
    $expectedOffset = [int64]$State.ExpectedLinuxPartitionOffset
    $linuxGptType = "{0fc63daf-8483-4772-8e79-3d69d8477de4}"
    $installerPartitions = @(
        Get-Partition -DiskNumber ([int]$State.SystemDiskNumber) -ErrorAction Stop |
            Where-Object {
                [int64]$_.Offset -eq $expectedOffset -and
                [int64]$_.Size -eq $expectedSize -and
                ($_.GptType -eq $linuxGptType -or $_.Type -match "Linux")
            }
    )
    return $installerPartitions.Count -eq 1
}

function Get-VerifiedEspPartition {
    param([Parameter(Mandatory = $true)]$State)

    $disk = Get-Disk -Number ([int]$State.SystemDiskNumber) -ErrorAction Stop
    if (
        ([string]$disk.UniqueId).Trim() -ne ([string]$State.SystemDiskUniqueId).Trim() -or
        [int64]$disk.Size -ne [int64]$State.SystemDiskSize -or
        [string]$disk.PartitionStyle -ne "GPT" -or
        -not $disk.Guid
    ) {
        throw "System disk identity changed before firmware boot evidence collection."
    }
    $partitionTableId = "gpt:$(([Guid]$disk.Guid).ToString('D').ToLowerInvariant())"
    if ($partitionTableId -ne [string]$State.SystemDiskPartitionTableId) {
        throw "System partition table identity changed before firmware boot evidence collection."
    }

    $espGptType = "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}"
    $espMatches = @(
        Get-Partition -DiskNumber ([int]$State.SystemDiskNumber) -ErrorAction Stop |
            Where-Object {
                [int]$_.PartitionNumber -eq [int]$State.BootPartitionNumber -and
                [int64]$_.Offset -eq [int64]$State.BootPartitionOffset -and
                [int64]$_.Size -eq [int64]$State.BootPartitionSize -and
                [string]$_.GptType -eq $espGptType -and
                $_.Guid
            }
    )
    if ($espMatches.Count -ne 1) {
        throw "Recorded ESP geometry does not resolve to exactly one partition."
    }
    return $espMatches[0]
}

function Invoke-WithVerifiedEsp {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    $partition = Get-VerifiedEspPartition -State $State
    $assignedAccessPath = $null
    try {
        $driveLetter = ([string]$partition.DriveLetter).Trim().TrimEnd(":")
        if ($driveLetter -notmatch '^[A-Za-z]$') {
            $storageGeometryModule = Join-Path `
                $State.PayloadRoot `
                "Scripts\modules\Libertix.StorageGeometry.psm1"
            if (-not (Test-Path -LiteralPath $storageGeometryModule -PathType Leaf)) {
                throw "Storage geometry module is missing from the recovery payload."
            }
            Import-Module -Name $storageGeometryModule -Force -ErrorAction Stop
            $driveLetter = Get-LibertixFreeDriveLetter
            $assignedAccessPath = "${driveLetter}:\"
            Add-PartitionAccessPath `
                -DiskNumber ([int]$partition.DiskNumber) `
                -PartitionNumber ([int]$partition.PartitionNumber) `
                -AccessPath $assignedAccessPath `
                -ErrorAction Stop
        }
        $root = "${driveLetter}:\"
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            throw "The recorded ESP is not readable at $root"
        }
        return & $Action $partition $root
    } finally {
        if ($assignedAccessPath) {
            Remove-PartitionAccessPath `
                -DiskNumber ([int]$partition.DiskNumber) `
                -PartitionNumber ([int]$partition.PartitionNumber) `
                -AccessPath $assignedAccessPath `
                -ErrorAction Stop
        }
    }
}

function Test-EfiLoadOptionTargetsPartition {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)]$Partition,
        [Parameter(Mandatory = $true)]$Disk,
        [Parameter(Mandatory = $true)][string]$ExpectedLoaderPath
    )

    if (-not (Test-EfiLoadOptionLoaderPath -Bytes $Bytes -ExpectedPath $ExpectedLoaderPath)) {
        return $false
    }
    $nodes = @(Get-EfiLoadOptionHardDriveNodes -Bytes $Bytes)
    if ($nodes.Count -ne 1) {
        return $false
    }
    $sectorSize = [uint64]$Disk.LogicalSectorSize
    if ($sectorSize -eq 0) {
        return $false
    }
    if (
        ([uint64]$Partition.Offset % $sectorSize) -ne 0 -or
        ([uint64]$Partition.Size % $sectorSize) -ne 0
    ) {
        return $false
    }
    $node = $nodes[0]
    return (
        [uint32]$node.PartitionNumber -eq [uint32]$Partition.PartitionNumber -and
        [uint64]$node.PartitionStartLba -eq ([uint64]$Partition.Offset / $sectorSize) -and
        [uint64]$node.PartitionSizeLba -eq ([uint64]$Partition.Size / $sectorSize) -and
        [byte]$node.MbrType -eq 2 -and
        [byte]$node.SignatureType -eq 2 -and
        [string]$node.PartitionGuid -eq ([Guid]$Partition.Guid).ToString("D").ToLowerInvariant()
    )
}

function Save-FirmwareBootBypassEvidence {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Evidence
    )

    $path = Join-Path $State.RecoveryRoot "firmware-boot-bypass.json"
    $temporary = Join-Path `
        $State.RecoveryRoot `
        ".firmware-boot-bypass.$([Guid]::NewGuid().ToString('N')).tmp"
    $backup = Join-Path `
        $State.RecoveryRoot `
        ".firmware-boot-bypass.$([Guid]::NewGuid().ToString('N')).bak"
    try {
        $json = $Evidence | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText(
            $temporary,
            $json + "`n",
            (New-Object Text.UTF8Encoding($false))
        )
        Publish-RecoveryFileAtomic `
            -TemporaryPath $temporary `
            -DestinationPath $path `
            -BackupPath $backup
    } finally {
        if ([IO.File]::Exists($temporary)) {
            [IO.File]::Delete($temporary)
        }
        if ([IO.File]::Exists($backup)) {
            [IO.File]::Delete($backup)
        }
    }
}

function Get-FirmwareBootBypassEvidence {
    param([Parameter(Mandatory = $true)]$State)

    $firmwareModule = Join-Path $State.PayloadRoot "Scripts\modules\Libertix.Firmware.psm1"
    $firmwareReadModule = Join-Path `
        $State.PayloadRoot `
        "Scripts\modules\Libertix.FirmwareRead.psm1"
    foreach ($modulePath in @($firmwareModule, $firmwareReadModule)) {
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
            throw "Firmware evidence module is missing: $modulePath"
        }
        Import-Module -Name $modulePath -Force -ErrorAction Stop
    }

    return Invoke-WithVerifiedEsp -State $State -Action {
        param($espPartition, $espRoot)

        $ownerPath = Join-Path $espRoot "EFI\Libertix\.libertix-owner"
        if (-not (Test-Path -LiteralPath $ownerPath -PathType Leaf)) {
            throw "Installed Libertix ESP ownership marker is missing."
        }
        $ownerLines = @(Get-Content -LiteralPath $ownerPath -Encoding UTF8 -ErrorAction Stop)
        if ($ownerLines.Count -ne 5) {
            throw "Installed Libertix ESP ownership marker has an invalid field count."
        }
        $ownedBootText = ([string]$ownerLines[1]).Trim()
        $espGuid = ([Guid]$espPartition.Guid).ToString("D").ToLowerInvariant()
        if (
            ([string]$ownerLines[0]).Trim() -ne [string]$State.RunId -or
            $ownedBootText -notmatch '^[0-9a-fA-F]{4}$' -or
            ([string]$ownerLines[2]).Trim() -ne [string]$espPartition.PartitionNumber -or
            ([string]$ownerLines[3]).Trim().ToLowerInvariant() -ne $espGuid -or
            ([string]$ownerLines[4]).Trim() -ne "\EFI\Libertix\shimx64.efi"
        ) {
            throw "Installed Libertix ESP ownership marker does not match the recorded transaction."
        }

        [uint16]$ownedBootNumber = [Convert]::ToUInt16($ownedBootText, 16)
        $bootCurrent = @(
            ConvertFrom-BootOrderBytes `
                -Bytes (Get-LibertixFirmwareVariableBytes -Name "BootCurrent")
        )
        $bootOrder = @(
            ConvertFrom-BootOrderBytes `
                -Bytes (Get-LibertixFirmwareVariableBytes -Name "BootOrder")
        )
        if ($bootCurrent.Count -ne 1 -or $bootOrder.Count -eq 0) {
            throw "BootCurrent or BootOrder has an invalid cardinality."
        }
        [uint16]$currentBootNumber = $bootCurrent[0]
        [uint16]$firstBootNumber = $bootOrder[0]
        if ($currentBootNumber -ne $firstBootNumber) {
            Write-AgentLog (
                "Firmware bypass not proven: BootCurrent differs from the first BootOrder entry; " +
                "Windows may have been selected manually."
            )
            return $null
        }
        if ($firstBootNumber -eq $ownedBootNumber) {
            Write-AgentLog (
                "Firmware bypass not proven: the owned Libertix entry is still first in BootOrder."
            )
            return $null
        }

        $disk = Get-Disk -Number ([int]$State.SystemDiskNumber) -ErrorAction Stop
        $windowsBytes = Get-LibertixFirmwareVariableBytes -Name (
            "Boot{0:X4}" -f $currentBootNumber
        )
        $libertixBytes = Get-LibertixFirmwareVariableBytes -Name (
            "Boot{0:X4}" -f $ownedBootNumber
        )
        if (-not $windowsBytes -or -not $libertixBytes) {
            throw "A boot entry referenced by the installed ownership marker is missing."
        }
        if (-not (Test-EfiLoadOptionTargetsPartition `
            -Bytes $windowsBytes `
            -Partition $espPartition `
            -Disk $disk `
            -ExpectedLoaderPath "\EFI\Microsoft\Boot\bootmgfw.efi")) {
            Write-AgentLog (
                "Firmware bypass not proven: BootCurrent is not the exact Windows Boot Manager " +
                "entry on the recorded ESP."
            )
            return $null
        }
        if (-not (Test-EfiLoadOptionTargetsPartition `
            -Bytes $libertixBytes `
            -Partition $espPartition `
            -Disk $disk `
            -ExpectedLoaderPath "\EFI\Libertix\shimx64.efi")) {
            throw "Owned Libertix firmware entry does not target the recorded ESP loader."
        }
        if ($ownedBootNumber -notin @($bootOrder)) {
            Write-AgentLog "Firmware removed the owned Libertix entry from BootOrder."
        }

        return [pscustomobject]@{
            schemaVersion = 1
            runId = [string]$State.RunId
            capturedUtc = [DateTime]::UtcNow.ToString("o")
            bootCurrent = ("Boot{0:X4}" -f $currentBootNumber)
            bootOrder = @($bootOrder | ForEach-Object { "Boot{0:X4}" -f [uint16]$_ })
            windowsBootNumber = ("Boot{0:X4}" -f $currentBootNumber)
            windowsLoaderPath = "\EFI\Microsoft\Boot\bootmgfw.efi"
            libertixBootNumber = ("Boot{0:X4}" -f $ownedBootNumber)
            libertixLoaderPath = "\EFI\Libertix\shimx64.efi"
            esp = [ordered]@{
                diskNumber = [int]$espPartition.DiskNumber
                partitionNumber = [int]$espPartition.PartitionNumber
                offsetBytes = [int64]$espPartition.Offset
                sizeBytes = [int64]$espPartition.Size
                partitionGuid = $espGuid
            }
            reason = "firmware-retained-windows-first"
        }
    }
}

function Import-PreferredBootPathModule {
    param([Parameter(Mandatory = $true)]$State)

    $modulePath = Join-Path `
        $State.PayloadRoot `
        "Scripts\modules\Libertix.PreferredBootPath.psm1"
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Preferred boot path module is missing from the recovery payload."
    }
    Import-Module -Name $modulePath -Force -ErrorAction Stop
}

function Restore-PreferredBootPathIfPresent {
    param([Parameter(Mandatory = $true)]$State)

    $manifestPath = Join-Path $State.RecoveryRoot "preferred-boot-path\manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return $false
    }
    Import-PreferredBootPathModule -State $State
    $writeLog = { param($Message) Write-AgentLog -Message $Message }
    return Invoke-WithVerifiedEsp -State $State -Action {
        param($espPartition, $espRoot)
        $null = $espPartition
        return Restore-LibertixPreferredBootPath `
            -State $State `
            -EspRoot $espRoot `
            -WriteLog $writeLog
    }
}

function Remove-RecoveryTasks {
    param([Parameter(Mandatory = $true)]$State)

    $taskNames = @([string]$State.TaskName, [string]$State.PromptTaskName) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($taskName in $taskNames) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            throw "Recovery task still exists after removal: $taskName"
        }
    }
}

function Remove-StartupRecoveryTask {
    param([Parameter(Mandatory = $true)]$State)

    $taskName = [string]$State.TaskName
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        throw "Recovery startup task still exists after removal: $taskName"
    }
}

function Remove-TemporaryRecoveryArtifacts {
    param([Parameter(Mandatory = $true)]$State)

    $temporaryArtifactsModule = Join-Path `
        $State.PayloadRoot `
        "Scripts\modules\Libertix.TemporaryArtifacts.psm1"
    Import-Module -Name $temporaryArtifactsModule -Force -ErrorAction Stop
    Remove-LibertixTransactionDownloads `
        -SystemDrive $SystemDrive `
        -PlanId ([string]$State.PlanId)
    Remove-LibertixUefiToolArtifacts -SystemDrive $SystemDrive
}

function Save-UefiTransactionArchive {
    param([Parameter(Mandatory = $true)]$State)

    $source = Join-Path $SystemDrive "LibertixTools\uefi-transaction.json"
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "UEFI transaction state is missing before permanent archival."
    }
    $transaction = Get-Content -LiteralPath $source -Raw -Encoding UTF8 -ErrorAction Stop |
        ConvertFrom-Json -ErrorAction Stop
    if ([string]$transaction.RecoveryRunId -ne [string]$State.RunId) {
        throw "UEFI transaction state belongs to another recovery session."
    }
    $destination = Join-Path $State.RecoveryRoot "uefi-transaction.json"
    $temporary = Join-Path $State.RecoveryRoot ".uefi-transaction.$([Guid]::NewGuid().ToString('N')).tmp"
    $backup = Join-Path $State.RecoveryRoot ".uefi-transaction.$([Guid]::NewGuid().ToString('N')).bak"
    try {
        Copy-Item -LiteralPath $source -Destination $temporary -Force -ErrorAction Stop
        Publish-RecoveryFileAtomic `
            -TemporaryPath $temporary `
            -DestinationPath $destination `
            -BackupPath $backup
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
    }
    Write-AgentLog "UEFI transaction state archived permanently."
}

function Restore-UefiTransactionArchive {
    param([Parameter(Mandatory = $true)]$State)

    $destination = Join-Path $SystemDrive "LibertixTools\uefi-transaction.json"
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        $activeTransaction = Get-Content `
            -LiteralPath $destination `
            -Raw `
            -Encoding UTF8 `
            -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
        if ([string]$activeTransaction.RecoveryRunId -ne [string]$State.RunId) {
            throw "Active UEFI transaction state belongs to another recovery session."
        }
        return
    }
    $source = Join-Path $State.RecoveryRoot "uefi-transaction.json"
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Permanent UEFI transaction archive is missing."
    }
    $transaction = Get-Content -LiteralPath $source -Raw -Encoding UTF8 -ErrorAction Stop |
        ConvertFrom-Json -ErrorAction Stop
    if ([string]$transaction.RecoveryRunId -ne [string]$State.RunId) {
        throw "Permanent UEFI transaction archive belongs to another recovery session."
    }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
    $temporary = "$destination.$([Guid]::NewGuid().ToString('N')).tmp"
    $backup = "$destination.$([Guid]::NewGuid().ToString('N')).bak"
    try {
        Copy-Item -LiteralPath $source -Destination $temporary -Force -ErrorAction Stop
        Publish-RecoveryFileAtomic `
            -TemporaryPath $temporary `
            -DestinationPath $destination `
            -BackupPath $backup
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
    }
}

function Save-RecoveryLogs {
    param([Parameter(Mandatory = $true)]$State)

    $source = Join-Path $State.RecoveryRoot "recovery-agent.log"
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        return
    }
    $archiveRoot = Join-Path $SystemDrive "LibertixInstallLogs\Windows\$($State.RunId)"
    New-Item -ItemType Directory -Path $archiveRoot -Force | Out-Null
    Copy-Item `
        -LiteralPath $source `
        -Destination (Join-Path $archiveRoot "uefi-recovery-agent.log") `
        -Force `
        -ErrorAction Stop
}

function Invoke-WindowsShareFinalize {
    $config = Join-Path $WindowsShareRoot "config.json"
    $script = Join-Path $WindowsShareRoot "mount-linux-readonly.ps1"
    if (-not (Test-Path -LiteralPath $config -PathType Leaf)) { return }
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
        throw "Windows share configuration exists but its script is missing."
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -ConfigPath $config -Finalize
    if ($LASTEXITCODE -ne 0) {
        throw "Windows read-only Linux sharing setup failed with rc=$LASTEXITCODE."
    }
    Write-AgentLog "Windows read-only Linux sharing finalized."
}

function Restore-HibernationAfterInstallation {
    param([Parameter(Mandatory = $true)]$State)

    $planPath = Join-Path $State.RecoveryRoot "installation-plan.json"
    $transactionPath = Join-Path $State.RecoveryRoot "uefi-transaction.json"
    if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
        throw "Installation plan is missing before hibernation finalization."
    }
    if (-not (Test-Path -LiteralPath $transactionPath -PathType Leaf)) {
        throw "UEFI transaction archive is missing before hibernation finalization."
    }
    $plan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 -ErrorAction Stop |
        ConvertFrom-Json -ErrorAction Stop
    if (
        [string]$plan.planId -ne [string]$State.PlanId -or
        [string]$plan.runtime.recoveryRunId -ne [string]$State.RunId
    ) {
        throw "Installation plan identity does not match the UEFI recovery transaction."
    }
    if ([bool]$plan.features.shareWindowsFilesInLinux) {
        Write-AgentLog (
            "Hibernation remains disabled because " +
            "Windows file sharing in Linux is enabled."
        )
        return
    }

    $transaction = Get-Content `
        -LiteralPath $transactionPath `
        -Raw `
        -Encoding UTF8 `
        -ErrorAction Stop |
        ConvertFrom-Json -ErrorAction Stop
    if ([string]$transaction.RecoveryRunId -ne [string]$State.RunId) {
        throw "UEFI transaction archive identity is invalid during hibernation finalization."
    }
    if (
        -not ($transaction.PSObject.Properties.Name -contains "OriginalHibernateEnabled") -or
        $null -eq $transaction.OriginalHibernateEnabled
    ) {
        Write-AgentLog "Original hibernation state is unknown; it remains disabled."
        return
    }

    $expected = [bool]$transaction.OriginalHibernateEnabled
    $argument = if ($expected) { "on" } else { "off" }
    $output = & "$env:SystemRoot\System32\powercfg.exe" /hibernate $argument 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Hibernation finalization failed with rc=$LASTEXITCODE output=$($output -join ' ')"
    }
    $observed = [int](Get-ItemProperty `
        -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power" `
        -Name "HibernateEnabled" `
        -ErrorAction Stop).HibernateEnabled
    if (($observed -ne 0) -ne $expected) {
        throw "Hibernation finalization did not apply the recorded original state."
    }
    Write-AgentLog "Original hibernation state restored after verified installation."
}

function Remove-PendingWindowsSharePayload {
    if (Test-Path -LiteralPath (Join-Path $WindowsShareRoot "pending.marker") -PathType Leaf) {
        Remove-Item -LiteralPath $WindowsShareRoot -Recurse -Force -ErrorAction SilentlyContinue
        Write-AgentLog "Removed pending Windows sharing payload."
    }
}

function Remove-WindowsShareAfterRollback {
    param([Parameter(Mandatory = $true)]$State)

    if (-not (Test-Path -LiteralPath $WindowsShareRoot -PathType Container)) { return }
    $shareLog = Join-Path $WindowsShareRoot "windows-share.log"
    if (Test-Path -LiteralPath $shareLog -PathType Leaf) {
        Copy-Item `
            -LiteralPath $shareLog `
            -Destination (Join-Path $State.RecoveryRoot "windows-share.log") `
            -Force `
            -ErrorAction Stop
    }
    Unregister-ScheduledTask `
        -TaskName "LibertixLinuxReadOnly" `
        -Confirm:$false `
        -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $WindowsShareRoot -Recurse -Force -ErrorAction Stop
    Write-AgentLog "Removed Windows read-only Linux sharing after rollback."
}

function Start-FallbackUi {
    param(
        [Parameter(Mandatory = $true)]$State,
        [ValidateSet("BootNext", "PreferredPath")][string]$Mode = "BootNext"
    )

    $exe = Join-Path $State.PayloadRoot "Libertix.exe"
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "Cached Libertix.exe is missing."
    }
    $State.Phase = if ($Mode -eq "PreferredPath") {
        "PreferredPathPrompted"
    } else {
        "FallbackPrompted"
    }
    Save-State -State $State
    if ($Mode -eq "PreferredPath") {
        Write-AgentLog (
            "Installed Linux boot was bypassed by firmware; opening the verified preferred-path prompt."
        )
    } else {
        Write-AgentLog (
            "BootNext returned to Windows without a live marker; opening the firmware fallback prompt."
        )
    }
    Start-Process -FilePath $exe -ArgumentList @(
        "--uefi-bootnext-failed",
        "--uefi-recovery-state",
        $StatePath
    )
}

function Start-PostInstallResultUi {
    param([Parameter(Mandatory = $true)]$State)

    $resultScript = Join-Path $State.PayloadRoot "Scripts\libertix-post-install-result.ps1"
    $agentPath = Join-Path $State.PayloadRoot "Scripts\libertix-uefi-recovery-agent.ps1"
    if (-not (Test-Path -LiteralPath $resultScript -PathType Leaf)) {
        throw "Post-install result UI is missing from the recovery payload."
    }
    & $resultScript `
        -StatePath (Join-Path $State.RecoveryRoot "post-install-verification.json") `
        -RecoveryScriptPath $agentPath `
        -Firmware uefi `
        -PromptTaskName ([string]$State.PromptTaskName)
}

function Start-PostInstallPromptTask {
    param([Parameter(Mandatory = $true)]$State)

    try {
        Start-ScheduledTask -TaskName ([string]$State.PromptTaskName) -ErrorAction Stop
        Write-AgentLog "Post-install result task was started for the interactive user."
    } catch {
        # InteractiveToken tasks cannot run before their user has logged on.
        # The persistent logon trigger will start it when a session exists.
        Write-AgentLog (
            "Post-install result task remains armed for the next user logon: " +
            $_.Exception.Message
        )
    }
}

function Invoke-VerifiedInstallationSuccess {
    param([Parameter(Mandatory = $true)]$State)

    if (-not (Test-LinuxPartitionPresent -State $State)) {
        throw "Live success marker exists but the expected Linux partition is absent."
    }
    $modulePath = Join-Path `
        $State.PayloadRoot `
        "Scripts\modules\Libertix.PostInstallVerification.psm1"
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Post-install verification module is missing from the recovery payload."
    }
    Import-Module -Name $modulePath -Force -ErrorAction Stop
    $writeLog = { param($Message) Write-AgentLog -Message $Message }
    try {
        $filesystemRepair = Invoke-LibertixWindowsFilesystemRepairIfRequired `
            -RecoveryRoot ([string]$State.RecoveryRoot) `
            -LogPath (Join-Path $State.RecoveryRoot "recovery-agent.log") `
            -WriteLog $writeLog
        if ([bool]$filesystemRepair.RestartRequired) {
            $State.Phase = "WaitingWindowsFilesystemRepair"
            Save-State -State $State
            Write-AgentLog (
                "A verified Windows boot-volume repair is scheduled; " +
                "requesting restart before final verification."
            )
            & shutdown.exe /r /t 5 /d p:4:1 /c "Libertix Windows filesystem verification"
            if ($LASTEXITCODE -ne 0) {
                throw "Windows restart request failed with rc=$LASTEXITCODE."
            }
            return
        }
        Save-UefiTransactionArchive -State $State
        Invoke-WindowsShareFinalize
        Remove-TemporaryRecoveryArtifacts -State $State
        Restore-HibernationAfterInstallation -State $State
        $null = Invoke-LibertixPostInstallVerification `
            -RecoveryRoot ([string]$State.RecoveryRoot) `
            -LogPath (Join-Path $State.RecoveryRoot "recovery-agent.log") `
            -WriteLog $writeLog
        $State.Phase = "Verified"
        Save-State -State $State
    } catch {
        $verificationFailure = $_
        $State.Phase = "VerificationFailed"
        Save-State -State $State
        try {
            $null = Set-LibertixPostInstallFailure `
                -RecoveryRoot ([string]$State.RecoveryRoot) `
                -LogPath (Join-Path $State.RecoveryRoot "recovery-agent.log") `
                -CheckName "post-install-controller" `
                -ErrorMessage $verificationFailure.Exception.Message
        } catch {
            Write-AgentLog (
                "Could not persist the post-install controller failure: " +
                $_.Exception.Message
            )
        }
        throw $verificationFailure
    } finally {
        $verificationResultPath = Join-Path $State.RecoveryRoot "post-install-verification.json"
        $verificationStatus = if (Test-Path -LiteralPath $verificationResultPath -PathType Leaf) {
            try {
                [string](Get-Content `
                    -LiteralPath $verificationResultPath `
                    -Raw `
                    -Encoding UTF8 `
                    -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop).status
            } catch { "unreadable" }
        } else { "missing" }
        if ($verificationStatus -in @("succeeded", "failed")) {
            Start-PostInstallPromptTask -State $State
            # Start the interactive task before retiring the startup task. This
            # avoids losing the result if shutdown begins between both actions.
            Remove-StartupRecoveryTask -State $State
        } else {
            Write-AgentLog (
                "Post-install verification was interrupted with status=" +
                "$verificationStatus; startup recovery remains armed."
            )
        }
        Save-RecoveryLogs -State $State
    }
}

try {
    $state = Get-Content -LiteralPath $StatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    Assert-RecoveryState -State $state
    Test-RecoveryPayload -State $state
    $script:AtomicFileModulePath = Join-Path `
        $state.PayloadRoot `
        "Scripts\modules\Libertix.AtomicFile.psm1"
    if (-not (Test-Path -LiteralPath $script:AtomicFileModulePath -PathType Leaf)) {
        throw "Atomic file module is missing from the recovery payload."
    }
    $postInstallModulePath = Join-Path `
        $state.PayloadRoot `
        "Scripts\modules\Libertix.PostInstallVerification.psm1"
    if (-not (Test-Path -LiteralPath $postInstallModulePath -PathType Leaf)) {
        throw "Post-install verification module is missing from the recovery payload."
    }
    Import-Module -Name $postInstallModulePath -Force -ErrorAction Stop
    Set-LibertixShutdownVerificationPriority
    $executionState = Read-ValidatedExecutionState -RecoveryState $state
    Write-AgentLog "Recovery agent started. action=$Action phase=$($state.Phase)"

    $liveStarted = Join-Path $state.RecoveryRoot "live-started.env"
    $installSuccess = Join-Path $state.RecoveryRoot "install-success.env"
    $liveFailed = Join-Path $state.RecoveryRoot "live-failed.env"

    if ($Action -eq "Prompt") {
        $postInstallResult = Join-Path $state.RecoveryRoot "post-install-verification.json"
        $linuxBootEvidence = Join-Path $state.RecoveryRoot "installed-linux-boot.json"
        $successRunIdForPrompt = Read-EnvValue `
            -Path $installSuccess `
            -Name "LIBERTIX_UEFI_RECOVERY_RUN_ID"
        if ($successRunIdForPrompt -eq [string]$state.RunId) {
            $linuxBootEvidencePresent = Test-Path `
                -LiteralPath $linuxBootEvidence `
                -PathType Leaf
            if (-not $linuxBootEvidencePresent) {
                $preferredPathRequired = [string]$state.Phase -in @(
                    "InstalledBootBypassed",
                    "PreferredPathPrompted",
                    "PreferredPathPreparationFailed"
                )
                if (-not $preferredPathRequired) {
                    try {
                        $firmwareBypassEvidence = Get-FirmwareBootBypassEvidence -State $state
                        if ($firmwareBypassEvidence) {
                            Save-FirmwareBootBypassEvidence `
                                -State $state `
                                -Evidence $firmwareBypassEvidence
                            $state.Phase = "InstalledBootBypassed"
                            Save-State -State $state
                            $preferredPathRequired = $true
                            Write-AgentLog (
                                "Interactive prompt independently proved that firmware retained " +
                                "Windows first in BootOrder."
                            )
                        }
                    } catch {
                        Write-AgentLog (
                            "Interactive prompt could not determine whether firmware bypassed " +
                            "the installed Linux entry: $($_.Exception.Message)"
                        )
                        # Do not display the generic first-Linux-boot advice when
                        # firmware ownership could not be evaluated. The startup
                        # agent remains armed and can retry, while the failure is
                        # preserved for automation and diagnostics.
                        throw
                    }
                }
                if ($preferredPathRequired) {
                    Start-FallbackUi -State $state -Mode PreferredPath
                    exit 0
                }
            }
            if (
                $linuxBootEvidencePresent -or
                (Test-Path -LiteralPath $postInstallResult -PathType Leaf)
            ) {
                Start-PostInstallResultUi -State $state
                exit 0
            }
            Write-AgentLog (
                "The live installation succeeded, but installed Linux has not published " +
                "its first-boot evidence yet; no result window is shown."
            )
            exit 0
        }
        if (Test-Path -LiteralPath $postInstallResult -PathType Leaf) {
            Start-PostInstallResultUi -State $state
            exit 0
        }
        $startedRunIdForPrompt = Read-EnvValue `
            -Path $liveStarted `
            -Name "LIBERTIX_UEFI_RECOVERY_RUN_ID"
        if ($startedRunIdForPrompt -eq [string]$state.RunId) {
            Write-AgentLog "The live installer ran; no firmware fallback prompt is applicable."
            exit 0
        }
        Start-FallbackUi -State $state
        exit 0
    }

    if ($Action -eq "Cancel") {
        $rollbackFromSucceeded = [string]$executionState.status -eq "succeeded"
        if ([string]$executionState.status -ne "rolled-back") {
            $null = Restore-PreferredBootPathIfPresent -State $state
            Restore-UefiTransactionArchive -State $state
            $installerScript = Join-Path $state.PayloadRoot "Scripts\libertix-uefi-install.ps1"
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installerScript `
                -Revert `
                -ExpectedRecoveryRunId ([string]$state.RunId)
            if ($LASTEXITCODE -ne 0) {
                throw "UEFI revert failed with rc=$LASTEXITCODE."
            }
            Write-AgentLog "Fallback was declined; UEFI transaction reverted."
        } else {
            Write-AgentLog "UEFI transaction was already rolled back; cleanup is continuing."
        }
        if ($rollbackFromSucceeded) {
            Remove-WindowsShareAfterRollback -State $state
        } else {
            Remove-PendingWindowsSharePayload
        }
        Save-RecoveryLogs -State $state
        Remove-TemporaryRecoveryArtifacts -State $state
        Remove-RecoveryTasks -State $state
        exit 0
    }

    if ($Action -eq "InstallPreferredPath") {
        $successRunIdForFallback = Read-EnvValue `
            -Path $installSuccess `
            -Name "LIBERTIX_UEFI_RECOVERY_RUN_ID"
        $successStateForFallback = Read-EnvValue `
            -Path $installSuccess `
            -Name "LIBERTIX_UEFI_RECOVERY_STATE"
        $linuxBootEvidence = Join-Path $state.RecoveryRoot "installed-linux-boot.json"
        if (
            $successRunIdForFallback -ne [string]$state.RunId -or
            $successStateForFallback -ne "install-success" -or
            [string]$executionState.status -ne "succeeded" -or
            (Test-Path -LiteralPath $linuxBootEvidence -PathType Leaf)
        ) {
            throw "Preferred boot fallback is not valid in the current installation state."
        }
        $firmwareBypassEvidence = Get-FirmwareBootBypassEvidence -State $state
        if (-not $firmwareBypassEvidence) {
            throw "Firmware boot bypass could not be reproven immediately before mutation."
        }
        Save-FirmwareBootBypassEvidence `
            -State $state `
            -Evidence $firmwareBypassEvidence
        Import-PreferredBootPathModule -State $state
        $writeLog = { param($Message) Write-AgentLog -Message $Message }
        $null = Invoke-WithVerifiedEsp -State $state -Action {
            param($espPartition, $espRoot)
            Install-LibertixPreferredBootPath `
                -State $state `
                -EspPartition $espPartition `
                -EspRoot $espRoot `
                -WriteLog $writeLog
        }
        $state.Phase = "AwaitingPreferredPathReboot"
        Save-State -State $state
        Write-AgentLog "Preferred Windows boot path fallback is installed and ready for reboot."
        Save-RecoveryLogs -State $state
        exit 0
    }

    $successRunId = Read-EnvValue -Path $installSuccess -Name "LIBERTIX_UEFI_RECOVERY_RUN_ID"
    $successState = Read-EnvValue -Path $installSuccess -Name "LIBERTIX_UEFI_RECOVERY_STATE"

    if (
        $successRunId -eq [string]$state.RunId -and
        $successState -eq "install-success" -and
        [string]$executionState.status -eq "succeeded"
    ) {
        $linuxBootEvidence = Join-Path $state.RecoveryRoot "installed-linux-boot.json"
        if (-not (Test-Path -LiteralPath $linuxBootEvidence -PathType Leaf)) {
            $firmwareBypassEvidence = $null
            $preferredManifest = Join-Path `
                $state.RecoveryRoot `
                "preferred-boot-path\manifest.json"
            $preferredPathAlreadyInstalled = (
                [string]$state.Phase -eq "AwaitingPreferredPathReboot" -and
                (Test-Path -LiteralPath $preferredManifest -PathType Leaf)
            )
            if (-not $preferredPathAlreadyInstalled) {
                try {
                    $firmwareBypassEvidence = Get-FirmwareBootBypassEvidence -State $state
                } catch {
                    Write-AgentLog (
                        "Firmware bypass evidence could not be proven; continuing to wait for " +
                        "installed Linux: $($_.Exception.Message)"
                    )
                }
            }
            if ($firmwareBypassEvidence) {
                Save-FirmwareBootBypassEvidence `
                    -State $state `
                    -Evidence $firmwareBypassEvidence
                $state.Phase = "InstalledBootBypassed"
                Save-State -State $state
                Write-AgentLog (
                    "Firmware bypass proven: Windows Boot Manager is BootCurrent and remains " +
                    "first in BootOrder while the exact owned Libertix entry targets the same ESP."
                )
            }
            $null = Set-LibertixPostInstallWaitingForLinux `
                -RecoveryRoot ([string]$state.RecoveryRoot) `
                -LogPath (Join-Path $state.RecoveryRoot "recovery-agent.log")
            if (-not $firmwareBypassEvidence -and -not $preferredPathAlreadyInstalled) {
                $state.Phase = "AwaitingInstalledLinuxBoot"
                Save-State -State $state
            }
            Write-AgentLog (
                "The live installation succeeded. Waiting for the installed Linux system " +
                "to boot and publish installed-linux-boot.json."
            )
            Start-PostInstallPromptTask -State $state
            exit 0
        }
        Write-AgentLog "Live success found; starting cross-runtime post-install verification."
        Invoke-VerifiedInstallationSuccess -State $state
        exit 0
    }

    $failedRunId = Read-EnvValue -Path $liveFailed -Name "LIBERTIX_UEFI_RECOVERY_RUN_ID"
    if (
        $failedRunId -eq [string]$state.RunId -and
        [string]$executionState.status -in @("failed", "rollback-running", "rolled-back")
    ) {
        $installerScript = Join-Path $state.PayloadRoot "Scripts\libertix-uefi-install.ps1"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installerScript `
            -RestoreWindowsSettings `
            -ExpectedRecoveryRunId ([string]$state.RunId)
        if ($LASTEXITCODE -ne 0) {
            throw "Windows setting restoration failed after live rollback with rc=$LASTEXITCODE."
        }
        Remove-PendingWindowsSharePayload
        $state.Phase = "LiveFailed"
        Save-State -State $state
        Write-AgentLog "The live installer failed; Windows settings were restored and logs were archived."
        Save-RecoveryLogs -State $state
        Remove-TemporaryRecoveryArtifacts -State $state
        Remove-RecoveryTasks -State $state
        exit 2
    }

    $startedRunId = Read-EnvValue -Path $liveStarted -Name "LIBERTIX_UEFI_RECOVERY_RUN_ID"
    if ($startedRunId -eq [string]$state.RunId) {
        $state.Phase = "LiveStartedWithoutResult"
        Save-State -State $state
        Write-AgentLog "Live marker exists without a final result; preserving recovery files and logs."
        exit 3
    }

    if ([string]$state.Phase -eq "FallbackPrompted" -or [string]$state.Phase -eq "FallbackRunning" -or [string]$state.Phase -eq "AwaitingFallbackReboot") {
        Write-AgentLog "Fallback was already offered or is running; no duplicate prompt is started."
        exit 0
    }

    $state.Phase = "FallbackNeeded"
    Save-State -State $state
    Write-AgentLog "BootNext returned to Windows without a live marker; waiting for the interactive fallback prompt."
    exit 0
} catch {
    $fatalError = $_
    try {
        Write-AgentErrorRecord -ErrorRecord $fatalError
    } catch {
        Write-Verbose "Unable to persist the recovery failure: $($_.Exception.Message)"
    }
    try {
        if ($null -ne (Get-Variable -Name state -ValueOnly -ErrorAction SilentlyContinue)) {
            Save-RecoveryLogs -State $state
        }
    } catch {
        Write-Verbose "Unable to archive the recovery failure log: $($_.Exception.Message)"
    }
    Write-Error $fatalError.Exception.Message
    exit 1
}
