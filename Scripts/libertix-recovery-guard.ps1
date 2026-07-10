param()

$ErrorActionPreference = "Stop"

$Root = "C:\LibertixInstallRecovery"
$TaskName = "LibertixInstallRecovery"
$Log = Join-Path $Root "recovery.log"
$Pending = Join-Path $Root "pending.env"
$Result = "C:\LibertixInstallLogs\latest\result.env"
$ArchiveRoot = "C:\LibertixInstallLogs"
$ArchiveLog = Join-Path $ArchiveRoot "windows-recovery.log"
$BcdBackup = Join-Path $Root "bcd-backup"

function Write-RecoveryLog {
    param([string]$Message)
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    Add-Content -Path $Log -Value ("[{0}] {1}" -f (Get-Date -Format o), $Message)
}

function Read-EnvValue {
    param(
        [string]$Path,
        [string]$Name
    )

    if (-not (Test-Path $Path)) {
        return $null
    }

    $line = Get-Content $Path | Where-Object { $_ -match "^$([regex]::Escape($Name))=" } | Select-Object -First 1
    if (-not $line) {
        return $null
    }

    return ($line -replace "^$([regex]::Escape($Name))=", "").Trim()
}

function Remove-RecoveryTask {
    try {
        schtasks.exe /Delete /TN $TaskName /F | Out-Null
    } catch {
        Write-RecoveryLog "Task cleanup failed: $($_.Exception.Message)"
    }
}

function Save-RecoveryLog {
    New-Item -ItemType Directory -Force -Path $ArchiveRoot | Out-Null
    if (Test-Path $Log) {
        Add-Content -Path $ArchiveLog -Value ("===== Libertix recovery guard {0} =====" -f (Get-Date -Format o))
        Get-Content $Log | Add-Content -Path $ArchiveLog
    }
}

function Restore-BcdState {
    if (-not (Test-Path -LiteralPath $BcdBackup -PathType Leaf)) {
        Write-RecoveryLog "No BCD backup present; BCD restore skipped."
        return
    }

    $output = & bcdedit.exe /import $BcdBackup /clean 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "BCD restore failed with rc=$LASTEXITCODE output=$($output -join ' ')"
    }
    Write-RecoveryLog "BCD state restored from the pre-install backup."
}

try {
    Write-RecoveryLog "Recovery guard started."

    # A successful live install writes this marker before rebooting. In that case
    # the Windows guard only cleans up its scheduled task and leaves disks alone.
    $success = Read-EnvValue -Path $Result -Name "LIBERTIX_INSTALL_SUCCESS"
    $resultIsFresh = (
        (Test-Path -LiteralPath $Result -PathType Leaf) -and
        (Test-Path -LiteralPath $Pending -PathType Leaf) -and
        ((Get-Item -LiteralPath $Result).LastWriteTimeUtc -gt (Get-Item -LiteralPath $Pending).LastWriteTimeUtc)
    )
    if ($success -eq "true" -and $resultIsFresh) {
        Write-RecoveryLog "Successful install marker found; no disk rollback needed."
        Remove-RecoveryTask
        Save-RecoveryLog
        Remove-Item -Path $Root -Recurse -Force -ErrorAction SilentlyContinue
        exit 0
    }

    $expectedMbText = Read-EnvValue -Path $Pending -Name "LINUX_SIZE_MB"
    $diskNumberText = Read-EnvValue -Path $Pending -Name "SYSTEM_DISK_NUMBER"
    $systemPartitionNumberText = Read-EnvValue -Path $Pending -Name "SYSTEM_PARTITION_NUMBER"
    $initialSystemSizeText = Read-EnvValue -Path $Pending -Name "SYSTEM_PARTITION_SIZE_BYTES"
    $expectedDiskId = Read-EnvValue -Path $Pending -Name "SYSTEM_DISK_UNIQUE_ID"
    if (-not $expectedMbText -or -not $diskNumberText -or -not $systemPartitionNumberText -or -not $initialSystemSizeText) {
        throw "Pending metadata is incomplete; refusing heuristic rollback."
    }

    $expectedMb = [int][double]::Parse($expectedMbText, [Globalization.CultureInfo]::InvariantCulture)
    $diskNumber = [int]$diskNumberText
    $systemPartitionNumber = [int]$systemPartitionNumberText
    $initialSystemSize = [int64]$initialSystemSizeText
    $minBytes = [int64]([Math]::Max(1024, $expectedMb - 1024)) * 1MB
    $maxBytes = [int64]($expectedMb + 1024) * 1MB

    $systemPartition = Get-Partition -DriveLetter C -ErrorAction Stop
    if ($systemPartition.DiskNumber -ne $diskNumber -or $systemPartition.PartitionNumber -ne $systemPartitionNumber) {
        throw "Windows system partition identity changed; refusing rollback."
    }
    $disk = Get-Disk -Number $diskNumber -ErrorAction Stop
    if ($expectedDiskId -and ([string]$disk.UniqueId).Trim() -ne $expectedDiskId.Trim()) {
        throw "Windows system disk identity changed; refusing rollback."
    }

    # A candidate must be unique, on the exact Windows disk, after C:, within
    # the requested size window, and either carry the temporary label/letter or
    # already be the ext4 partition produced by the live installer.
    $partitions = Get-Partition -DiskNumber $diskNumber | Sort-Object Offset
    $candidates = @()

    foreach ($partition in $partitions) {
        if ($partition.PartitionNumber -eq $systemPartition.PartitionNumber) {
            continue
        }
        if ($partition.Size -lt $minBytes -or $partition.Size -gt $maxBytes) {
            continue
        }
        if ($partition.Offset -lt $systemPartition.Offset) {
            continue
        }

        $volume = $null
        try {
            $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
        } catch {
            $volume = $null
        }

        $label = if ($volume) { [string]$volume.FileSystemLabel } else { "" }
        $fs = if ($volume) { [string]$volume.FileSystem } else { "" }
        $letter = if ($volume) { [string]$volume.DriveLetter } else { "" }

        $isTemporaryFat = ($label -eq "LIBERTIX" -or $letter -eq "Z")
        $isLinux = ($fs -match "^(ext2|ext3|ext4)$")
        if (-not $isTemporaryFat -and -not $isLinux) {
            continue
        }

        $candidates += [pscustomobject]@{
            Partition = $partition
            Label = $label
            FileSystem = $fs
            DriveLetter = $letter
        }
    }

    if (@($candidates).Count -gt 1) {
        throw "Multiple temporary Linux partition candidates found; refusing ambiguous rollback."
    }

    if (@($candidates).Count -eq 1) {
        $candidate = $candidates[0]
        $number = $candidate.Partition.PartitionNumber
        $sizeMb = [Math]::Round($candidate.Partition.Size / 1MB, 0)
        Write-RecoveryLog "Removing transaction partition number=$number sizeMB=$sizeMb label=$($candidate.Label) fs=$($candidate.FileSystem)."
        Remove-Partition -DiskNumber $diskNumber -PartitionNumber $number -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds 2
    } else {
        Write-RecoveryLog "No transaction partition exists; checking whether only C: needs extension."
    }

    $supported = Get-PartitionSupportedSize -DriveLetter C -ErrorAction Stop
    $currentSystemPartition = Get-Partition -DriveLetter C -ErrorAction Stop
    if ($currentSystemPartition.Size -lt $initialSystemSize) {
        if ($supported.SizeMax -lt $initialSystemSize) {
            throw "C: cannot be restored to its initial size ($initialSystemSize); SizeMax=$($supported.SizeMax)."
        }
        Write-RecoveryLog "Restoring C: to its exact initial size: $initialSystemSize bytes."
        Resize-Partition -DriveLetter C -Size $initialSystemSize -ErrorAction Stop
    } else {
        Write-RecoveryLog "C: is already at or above its initial size; resize skipped."
    }

    Restore-BcdState

    foreach ($temporaryBootFile in @("C:\grldr", "C:\grldr.mbr", "C:\menu.lst")) {
        if (Test-Path -LiteralPath $temporaryBootFile -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryBootFile -Force -ErrorAction Stop
            Write-RecoveryLog "Removed temporary boot file: $temporaryBootFile"
        }
    }

    $finalSystemPartition = Get-Partition -DriveLetter C -ErrorAction Stop
    if ($finalSystemPartition.Size -lt $initialSystemSize) {
        throw "C: rollback verification failed: size=$($finalSystemPartition.Size), expected=$initialSystemSize."
    }

    Write-RecoveryLog "Recovery completed and verified."
    Remove-RecoveryTask
    Save-RecoveryLog
    Remove-Item -Path $Root -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
} catch {
    Write-RecoveryLog "Recovery failed: $($_.Exception.Message)"
    exit 1
}
