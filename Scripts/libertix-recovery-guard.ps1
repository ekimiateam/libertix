param()

$ErrorActionPreference = "Stop"

$Root = "C:\LibertixInstallRecovery"
$TaskName = "LibertixInstallRecovery"
$Log = Join-Path $Root "recovery.log"
$Pending = Join-Path $Root "pending.env"
$Result = "C:\LibertixInstallLogs\latest\result.env"
$ArchiveRoot = "C:\LibertixInstallLogs"
$ArchiveLog = Join-Path $ArchiveRoot "windows-recovery.log"

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

try {
    Write-RecoveryLog "Recovery guard started."

    # A successful live install writes this marker before rebooting. In that case
    # the Windows guard only cleans up its scheduled task and leaves disks alone.
    $success = Read-EnvValue -Path $Result -Name "LIBERTIX_INSTALL_SUCCESS"
    if ($success -eq "true") {
        Write-RecoveryLog "Successful install marker found; no rollback needed."
        Remove-RecoveryTask
        Save-RecoveryLog
        Remove-Item -Path $Root -Recurse -Force -ErrorAction SilentlyContinue
        exit 0
    }

    $expectedMbText = Read-EnvValue -Path $Pending -Name "LINUX_SIZE_MB"
    if (-not $expectedMbText) {
        Write-RecoveryLog "No pending metadata found; leaving system unchanged."
        Remove-RecoveryTask
        exit 0
    }

    $expectedMb = [int][double]::Parse($expectedMbText, [Globalization.CultureInfo]::InvariantCulture)
    $minBytes = [int64]([Math]::Max(1024, $expectedMb - 1024)) * 1MB
    $maxBytes = [int64]($expectedMb + 1024) * 1MB

    # Find the partition created by the Windows phase. The size window avoids
    # touching the recovery partition or unrelated user volumes.
    $systemPartition = Get-Partition -DriveLetter C -ErrorAction Stop
    $partitions = Get-Partition -DiskNumber $systemPartition.DiskNumber | Sort-Object Offset
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

        if ($letter -and $letter -ne "Z") {
            continue
        }
        if ($label -and $label -ne "LIBERTIX") {
            continue
        }

        $candidates += [pscustomobject]@{
            Partition = $partition
            Label = $label
            FileSystem = $fs
            DriveLetter = $letter
        }
    }

    if ($candidates.Count -eq 0) {
        Write-RecoveryLog "No temporary Linux partition candidate found."
        Remove-RecoveryTask
        exit 0
    }

    $candidate = $candidates | Sort-Object { $_.Partition.Offset } | Select-Object -First 1
    $number = $candidate.Partition.PartitionNumber
    $sizeMb = [Math]::Round($candidate.Partition.Size / 1MB, 0)
    Write-RecoveryLog "Removing temporary partition number=$number sizeMB=$sizeMb label=$($candidate.Label) fs=$($candidate.FileSystem)."

    Remove-Partition -DiskNumber $systemPartition.DiskNumber -PartitionNumber $number -Confirm:$false -ErrorAction Stop
    Start-Sleep -Seconds 2

    # Once the temporary partition is gone, Windows can safely reclaim all free
    # space before the recovery partition.
    $supported = Get-PartitionSupportedSize -DriveLetter C -ErrorAction Stop
    Write-RecoveryLog "Extending C: to $($supported.SizeMax) bytes."
    Resize-Partition -DriveLetter C -Size $supported.SizeMax -ErrorAction Stop

    Write-RecoveryLog "Recovery completed."
    Remove-RecoveryTask
    Save-RecoveryLog
    Remove-Item -Path $Root -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
} catch {
    Write-RecoveryLog "Recovery failed: $($_.Exception.Message)"
    exit 1
}
