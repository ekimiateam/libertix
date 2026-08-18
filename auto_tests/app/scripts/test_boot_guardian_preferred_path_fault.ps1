param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-Condition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

$request = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
    ConvertFrom-Json -ErrorAction Stop
$action = [string]$request.action
Assert-Condition ($action -in @("plan-loader", "inject-loader", "verify-loader")) `
    "The preferred-path fault action is unsupported."

$guardianRoot = Join-Path $env:ProgramData "Libertix\BootGuardian"
$guardianConfigPath = Join-Path $guardianRoot "config.json"
Assert-Condition (Test-Path -LiteralPath $guardianConfigPath -PathType Leaf) `
    "The active boot guardian configuration is missing."
$guardian = Get-Content -LiteralPath $guardianConfigPath -Raw -Encoding UTF8 |
    ConvertFrom-Json -ErrorAction Stop
Assert-Condition (
    [int]$guardian.version -eq 1 -and
    [string]$guardian.runId -match '^[0-9a-f]{32}$' -and
    [string]$guardian.mode -eq "preferred-windows-path"
) "The active guardian is not protecting the preferred Windows EFI path."
Assert-Condition (
    $guardian.PSObject.Properties.Name -contains "preferredPath" -and
    $guardian.PSObject.Properties.Name -notcontains "bootOrder"
) "The preferred-path guardian contract is incomplete."

$archiveDirectory = [IO.Path]::GetFullPath([string]$guardian.archiveDirectory)
Assert-Condition (
    $archiveDirectory.EndsWith("\boot-guardian", [StringComparison]::OrdinalIgnoreCase)
) "The guardian archive directory is not owned by a recovery session."
$recoveryRoot = Split-Path -Parent $archiveDirectory
$archiveConfigPath = Join-Path $archiveDirectory "config.json"
Assert-Condition (Test-Path -LiteralPath $archiveConfigPath -PathType Leaf) `
    "The permanent guardian configuration is missing."
Assert-Condition (
    (Get-Sha256 -Path $archiveConfigPath) -eq (Get-Sha256 -Path $guardianConfigPath)
) "The active guardian configuration differs from its permanent archive."

$manifestPath = Join-Path $recoveryRoot "preferred-boot-path\manifest.json"
$originalLoaderPath = Join-Path $recoveryRoot "preferred-boot-path\bootmgfw.efi"
Assert-Condition (Test-Path -LiteralPath $manifestPath -PathType Leaf) `
    "The preferred-path manifest archive is missing."
Assert-Condition (Test-Path -LiteralPath $originalLoaderPath -PathType Leaf) `
    "The permanent original Windows Boot Manager archive is missing."
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 |
    ConvertFrom-Json -ErrorAction Stop
Assert-Condition (
    [int]$manifest.version -eq 1 -and
    [string]$manifest.runId -eq [string]$guardian.runId -and
    [string]$manifest.status -eq "installed"
) "The preferred-path manifest identity or state is invalid."
$originalHash = [string]$manifest.windowsLoader.sha256
$preferredHash = [string]$manifest.preferred.shimSha256
Assert-Condition ($originalHash -match '^[0-9a-f]{64}$') `
    "The archived Windows Boot Manager hash is invalid."
Assert-Condition ($preferredHash -match '^[0-9a-f]{64}$') `
    "The preferred shim hash is invalid."
Assert-Condition ((Get-Sha256 -Path $originalLoaderPath) -eq $originalHash) `
    "The original Windows Boot Manager archive hash is invalid."

$service = Get-Service -Name "LibertixBootGuardian" -ErrorAction Stop
Assert-Condition ([string]$service.Status -eq "Running") `
    "The preferred-path guardian service is not running."
$repairLogsBefore = @(
    Get-ChildItem -LiteralPath ([string]$guardian.logDirectory) -Filter "*-repair-*.log" -File
)
$matchingRepairLogsBefore = @(
    $repairLogsBefore | Where-Object {
        (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8) -match
            'EFI\\Microsoft\\Boot\\bootmgfw\.efi differs from the verified reference'
    }
)
$repairLogBaselineNames = @(
    $repairLogsBefore | ForEach-Object { $_.Name }
) -join "|"

$volumePath = [string]$guardian.esp.volumePath
Assert-Condition (
    $volumePath -match '^\\\\\?\\Volume\{[0-9a-fA-F-]{36}\}\\$'
) "The guardian ESP volume path is invalid."
$mountRoot = Join-Path $guardianRoot "FaultTestEspMount"
[IO.Directory]::CreateDirectory($mountRoot) | Out-Null
$mountPoint = $mountRoot.TrimEnd('\') + "\"
$mounted = $false
try {
    & mountvol.exe $mountPoint $volumePath | Out-Null
    Assert-Condition ($LASTEXITCODE -eq 0) "The recorded ESP could not be mounted for the fault test."
    $mounted = $true

    $ownerPath = Join-Path $mountRoot "EFI\Libertix\.libertix-owner"
    Assert-Condition (Test-Path -LiteralPath $ownerPath -PathType Leaf) `
        "The installed Libertix ESP ownership marker is missing."
    Assert-Condition (
        [IO.File]::ReadAllText($ownerPath, [Text.Encoding]::UTF8) -eq [string]$guardian.esp.ownerMarker
    ) "The mounted ESP ownership marker differs from the guardian contract."

    $activeLoaderPath = Join-Path $mountRoot "EFI\Microsoft\Boot\bootmgfw.efi"
    Assert-Condition (Test-Path -LiteralPath $activeLoaderPath -PathType Leaf) `
        "The active preferred Windows EFI path is missing."
    $activeHash = Get-Sha256 -Path $activeLoaderPath

    Write-Output "ACTION=$action"
    Write-Output "RUN_ID=$($guardian.runId)"
    Write-Output "MODE=$($guardian.mode)"
    Write-Output "ACTIVE_HASH=$activeHash"
    Write-Output "ORIGINAL_HASH=$originalHash"
    Write-Output "PREFERRED_HASH=$preferredHash"

    if ($action -eq "plan-loader") {
        Assert-Condition ($activeHash -eq $preferredHash) `
            "The preferred shim is not active before the fault test."
        Write-Output "WOULD_RESTORE_WINDOWS_LOADER=true"
        Write-Output "RESULT=OK"
        exit 0
    }

    if ($action -eq "inject-loader") {
        Assert-Condition ($activeHash -eq $preferredHash) `
            "The fault fixture refuses to replace a non-nominal preferred loader."
        $modulePath = Join-Path `
            $recoveryRoot `
            "payload\Scripts\modules\Libertix.PreferredBootPath.psm1"
        Assert-Condition (Test-Path -LiteralPath $modulePath -PathType Leaf) `
            "The recovery payload preferred-path module is missing."
        Import-Module -Name $modulePath -Force -ErrorAction Stop
        Copy-LibertixPreferredPathFileAtomic `
            -Source $originalLoaderPath `
            -Destination $activeLoaderPath `
            -ExpectedSha256 $originalHash
        Assert-Condition ((Get-Sha256 -Path $activeLoaderPath) -eq $originalHash) `
            "The controlled Windows Boot Manager restoration was not retained."
        Write-Output "INJECTED_UTC=$([DateTime]::UtcNow.ToString('o'))"
        Write-Output "INJECTED_HASH=$originalHash"
        Write-Output "REPAIR_LOG_BASELINE_COUNT=$($repairLogsBefore.Count)"
        Write-Output "MATCHING_REPAIR_LOG_BASELINE_COUNT=$($matchingRepairLogsBefore.Count)"
        Write-Output "REPAIR_LOG_BASELINE_NAMES=$repairLogBaselineNames"
        Write-Output "RESULT=OK"
        exit 0
    }

    $repairLogBaselineCount = [int]$request.repair_log_baseline_count
    $matchingRepairLogBaselineCount = [int]$request.matching_repair_log_baseline_count
    $repairLogBaselineNames = @(
        if ([string]$request.repair_log_baseline_names) {
            [string]$request.repair_log_baseline_names -split '\|'
        }
    )
    Assert-Condition ($activeHash -eq $preferredHash) `
        "The guardian did not restore the preferred shim at the Windows EFI path."
    $repairLogs = @(
        Get-ChildItem -LiteralPath ([string]$guardian.logDirectory) -Filter "*-repair-*.log" -File |
            Sort-Object LastWriteTimeUtc
    )
    Assert-Condition ($repairLogs.Count -gt $repairLogBaselineCount) `
        "The guardian restored the preferred shim without creating a new repair journal."
    Assert-Condition ($matchingRepairLogsBefore.Count -gt $matchingRepairLogBaselineCount) `
        "The preferred-path repair journal count did not increase."
    $newRepairLogs = @(
        $repairLogs | Where-Object { $_.Name -notin $repairLogBaselineNames }
    )
    Assert-Condition ($newRepairLogs.Count -ge 1) `
        "The preferred-path repair journal set changed without a new unique file."
    $matchingLogs = @(
        $newRepairLogs | Where-Object {
            (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8) -match
                'EFI\\Microsoft\\Boot\\bootmgfw\.efi differs from the verified reference'
        }
    )
    Assert-Condition ($matchingLogs.Count -ge 1) `
        "No repair journal records the preferred Windows EFI path correction."
    $unexpectedArchive = Join-Path `
        $archiveDirectory `
        "unexpected-efi\shimx64.efi-$originalHash.bin"
    Assert-Condition (Test-Path -LiteralPath $unexpectedArchive -PathType Leaf) `
        "The displaced Windows Boot Manager was not archived by the guardian."
    Assert-Condition ((Get-Sha256 -Path $unexpectedArchive) -eq $originalHash) `
        "The displaced Windows Boot Manager archive hash is invalid."
    Write-Output "REPAIR_LOG=$($matchingLogs[-1].FullName)"
    Write-Output "REPAIRED_HASH=$activeHash"
    Write-Output "UNEXPECTED_ARCHIVE=$unexpectedArchive"
    Write-Output "RESULT=OK"
} finally {
    if ($mounted) {
        & mountvol.exe $mountPoint /D | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Error "The fault-test ESP mount point could not be removed."
        }
    }
}
