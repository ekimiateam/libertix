Set-StrictMode -Version Latest

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
    param([Parameter(Mandatory = $true)][string]$SystemDrive)

    if ($SystemDrive -notmatch '^[A-Za-z]:$') {
        throw "SystemDrive must be a valid Windows drive designator."
    }

    $toolRoot = Join-Path $SystemDrive "LibertixTools"
    foreach ($ownedPath in @(
        (Join-Path $toolRoot "aria2"),
        (Join-Path $toolRoot "downloads"),
        (Join-Path $toolRoot "uefi-transaction.json")
    )) {
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
    Get-LibertixTransactionDownloadRoot, `
    Remove-LibertixTransactionDownloads, `
    Remove-LibertixUefiToolArtifacts
