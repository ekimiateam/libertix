Set-StrictMode -Version Latest

function Remove-LibertixWindowsShareTasks {
    param([Parameter(Mandatory = $true)][string]$ShareRoot)

    $hostPath = Join-Path $ShareRoot "Libertix.BootGuardian.exe"
    $scriptPath = Join-Path $ShareRoot "mount-linux-readonly.ps1"
    $configPath = Join-Path $ShareRoot "config.json"
    $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
        $_.TaskPath -eq '\' -and (
            $_.TaskName -eq "LibertixLinuxReadOnly" -or
            $_.TaskName -match '^LibertixLinuxReadOnlyPin_S_1_\d+(?:_\d+)+$'
        )
    })
    foreach ($task in $tasks) {
        $actions = @($task.Actions)
        if ($actions.Count -ne 1 -or [string]$actions[0].Execute -ine $hostPath -or
            -not ([string]$actions[0].Arguments).Contains('-File "' + $scriptPath + '"') -or
            -not ([string]$actions[0].Arguments).Contains('-ConfigPath "' + $configPath + '"')) {
            throw "Windows sharing task ownership could not be verified: $($task.TaskName)"
        }
    }
    foreach ($task in $tasks) {
        if ([string]$task.State -eq "Running") {
            Stop-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop
        }
        Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction Stop
    }
    $taskNames = @($tasks | ForEach-Object { [string]$_.TaskName })
    $remaining = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
        $_.TaskPath -eq '\' -and $_.TaskName -in $taskNames
    })
    if ($remaining.Count -ne 0) { throw "Windows sharing scheduled-task cleanup is incomplete." }
}

function Remove-LibertixBiosBootPayload {
    param(
        [Parameter(Mandatory = $true)][string]$SystemRoot,
        [Parameter(Mandatory = $true)][string]$RecoveryRoot,
        [Parameter(Mandatory = $true)][string]$PlanId
    )

    $manifestPath = Join-Path $RecoveryRoot "bios-boot-payload.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) { return }
    $manifestItem = Get-Item -LiteralPath $manifestPath -Force -ErrorAction Stop
    if ($manifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "BIOS boot ownership manifest cannot be a reparse point."
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $names = @("grldr", "grldr.mbr", "menu.lst")
    if ($PlanId -notmatch '^[0-9a-f]{32}$' -or [int]$manifest.version -ne 1 -or
        [string]$manifest.planId -cne $PlanId -or
        @(Compare-Object @($manifest.files.PSObject.Properties.Name) $names).Count -ne 0) {
        throw "BIOS boot ownership manifest is invalid or belongs to another installation."
    }
    $ownedFiles = @()
    foreach ($name in $names) {
        $hash = [string]$manifest.files.$name
        if ($hash -cnotmatch '^[0-9a-f]{64}$') { throw "Invalid BIOS boot payload hash." }
        $path = Join-Path $SystemRoot $name
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $hash) {
            throw "Refusing to delete an unverified BIOS boot file: $path"
        }
        $ownedFiles += $path
    }
    # Validate the complete set before removing any file, including on a retry.
    foreach ($path in $ownedFiles) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
    foreach ($path in $ownedFiles) {
        if (Test-Path -LiteralPath $path) { throw "Temporary boot payload remains: $path" }
    }
}

function Get-LibertixTransactionDownloadRoot {
    param(
        [Parameter(Mandatory = $true)][string]$SystemDrive,
        [Parameter(Mandatory = $true)][string]$PlanId
    )

    if ($SystemDrive -notmatch '^[A-Za-z]:$') {
        throw "SystemDrive must be a valid Windows drive designator."
    }
    if ($PlanId -notmatch '^[0-9a-f]{32}$') {
        throw "PlanId must contain exactly 32 lowercase hexadecimal characters."
    }

    return [IO.Path]::GetFullPath(
        (Join-Path $SystemDrive "ProgramData\Libertix\Downloads\$PlanId")
    )
}

function Remove-LibertixTransactionDownloads {
    param(
        [Parameter(Mandatory = $true)][string]$SystemDrive,
        [Parameter(Mandatory = $true)][string]$PlanId
    )

    $transactionRoot = Get-LibertixTransactionDownloadRoot `
        -SystemDrive $SystemDrive `
        -PlanId $PlanId
    if (Test-Path -LiteralPath $transactionRoot) {
        Remove-Item -LiteralPath $transactionRoot -Recurse -Force -ErrorAction Stop
    }
    if (Test-Path -LiteralPath $transactionRoot) {
        throw "Transaction download root still exists after cleanup: $transactionRoot"
    }

    $downloadsRoot = Split-Path -Parent $transactionRoot
    if (
        (Test-Path -LiteralPath $downloadsRoot -PathType Container) -and
        @((Get-ChildItem -LiteralPath $downloadsRoot -Force -ErrorAction Stop)).Count -eq 0
    ) {
        Remove-Item -LiteralPath $downloadsRoot -Force -ErrorAction Stop
    }

    $productRoot = Split-Path -Parent $downloadsRoot
    if (
        (Test-Path -LiteralPath $productRoot -PathType Container) -and
        @((Get-ChildItem -LiteralPath $productRoot -Force -ErrorAction Stop)).Count -eq 0
    ) {
        Remove-Item -LiteralPath $productRoot -Force -ErrorAction Stop
    }
}

function Remove-LibertixUefiToolArtifacts {
    param(
        [Parameter(Mandatory = $true)][string]$SystemDrive,
        [switch]$PreserveTransactionState
    )

    if ($SystemDrive -notmatch '^[A-Za-z]:$') {
        throw "SystemDrive must be a valid Windows drive designator."
    }

    $toolRoot = Join-Path $SystemDrive "LibertixTools"
    $ownedPaths = @(
        (Join-Path $toolRoot "aria2"),
        (Join-Path $toolRoot "downloads")
    )
    if (-not $PreserveTransactionState) {
        $ownedPaths += (Join-Path $toolRoot "uefi-transaction.json")
    }
    foreach ($ownedPath in $ownedPaths) {
        if (Test-Path -LiteralPath $ownedPath) {
            Remove-Item -LiteralPath $ownedPath -Recurse -Force -ErrorAction Stop
        }
    }

    if (
        (Test-Path -LiteralPath $toolRoot -PathType Container) -and
        @((Get-ChildItem -LiteralPath $toolRoot -Force -ErrorAction Stop)).Count -eq 0
    ) {
        Remove-Item -LiteralPath $toolRoot -Force -ErrorAction Stop
    }

    $lowMemoryIso = Join-Path $SystemDrive "libertix-live.iso"
    if (Test-Path -LiteralPath $lowMemoryIso -PathType Leaf) {
        Remove-Item -LiteralPath $lowMemoryIso -Force -ErrorAction Stop
    }
}

Export-ModuleMember -Function `
    Remove-LibertixWindowsShareTasks, `
    Remove-LibertixBiosBootPayload, `
    Get-LibertixTransactionDownloadRoot, `
    Remove-LibertixTransactionDownloads, `
    Remove-LibertixUefiToolArtifacts
