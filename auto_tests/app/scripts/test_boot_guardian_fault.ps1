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

function Get-ByteHash {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
    }
}

function Format-BootOrder {
    param([Parameter(Mandatory = $true)]$Order)

    return (@($Order | ForEach-Object { "Boot{0:X4}" -f [uint16]$_ }) -join ",")
}

function Get-WindowsBootNumber {
    param(
        [Parameter(Mandatory = $true)][uint16[]]$Order,
        [Parameter(Mandatory = $true)][uint16]$OwnedBootNumber
    )

    $windowsMatches = @()
    foreach ($bootNumber in $Order) {
        if ([uint16]$bootNumber -eq $OwnedBootNumber) {
            continue
        }
        $name = "Boot{0:X4}" -f [uint16]$bootNumber
        $bytes = Get-FirmwareVariableBytes -Name $name
        if (
            $bytes -and
            (Get-EfiLoadOptionDescription -Bytes $bytes) -eq "Windows Boot Manager" -and
            (Test-EfiLoadOptionLoaderPath `
                -Bytes $bytes `
                -ExpectedPath "\EFI\Microsoft\Boot\bootmgfw.efi")
        ) {
            $windowsMatches += [uint16]$bootNumber
        }
    }
    Assert-Condition ($windowsMatches.Count -eq 1) `
        "The fault fixture did not resolve exactly one Windows Boot Manager entry."
    return [uint16]$windowsMatches[0]
}

$request = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
    ConvertFrom-Json -ErrorAction Stop
$action = [string]$request.action
Assert-Condition ($action -in @(
        "plan-boot-order",
        "inject-boot-order",
        "verify-boot-order",
        "inspect-boot-order",
        "suspend-guardian",
        "resume-guardian",
        "plan-preferred-bypass",
        "inject-preferred-bypass"
    )) `
    "The boot guardian fault action is unsupported."

$guardianRoot = Join-Path $env:ProgramData "Libertix\BootGuardian"
$guardianConfigPath = Join-Path $guardianRoot "config.json"
Assert-Condition (Test-Path -LiteralPath $guardianConfigPath -PathType Leaf) `
    "The active boot guardian configuration is missing."
$guardian = Get-Content -LiteralPath $guardianConfigPath -Raw -Encoding UTF8 |
    ConvertFrom-Json -ErrorAction Stop
Assert-Condition ([int]$guardian.version -eq 1) `
    "The active boot guardian configuration version is invalid."
Assert-Condition ([string]$guardian.runId -match '^[0-9a-f]{32}$') `
    "The active boot guardian run identifier is invalid."
Assert-Condition ([string]$guardian.mode -eq "firmware-boot-order") `
    "The active boot guardian is not protecting firmware BootOrder."
Assert-Condition (
    $guardian.PSObject.Properties.Name -contains "bootOrder" -and
    $guardian.PSObject.Properties.Name -notcontains "preferredPath"
) `
    "The BootOrder guardian contract is incomplete."

$archiveDirectory = [IO.Path]::GetFullPath([string]$guardian.archiveDirectory)
$expectedArchiveSuffix = "\boot-guardian"
Assert-Condition ($archiveDirectory.EndsWith($expectedArchiveSuffix, [StringComparison]::OrdinalIgnoreCase)) `
    "The guardian archive directory is not owned by a recovery session."
$recoveryRoot = Split-Path -Parent $archiveDirectory
$archiveConfigPath = Join-Path $archiveDirectory "config.json"
Assert-Condition (Test-Path -LiteralPath $archiveConfigPath -PathType Leaf) `
    "The permanent guardian configuration is missing."
Assert-Condition (
    (Get-FileHash -LiteralPath $archiveConfigPath -Algorithm SHA256).Hash -eq
    (Get-FileHash -LiteralPath $guardianConfigPath -Algorithm SHA256).Hash
) "The active guardian configuration differs from its permanent archive."

$firmwareModule = Join-Path $recoveryRoot "payload\Scripts\modules\Libertix.Firmware.psm1"
$firmwareScript = Join-Path $recoveryRoot "payload\Scripts\uefi\Libertix.Uefi.Firmware.ps1"
Assert-Condition (Test-Path -LiteralPath $firmwareModule -PathType Leaf) `
    "The recovery payload firmware parser is missing."
Assert-Condition (Test-Path -LiteralPath $firmwareScript -PathType Leaf) `
    "The recovery payload firmware writer is missing."
Import-Module -Name $firmwareModule -Force -ErrorAction Stop
. $firmwareScript

$service = Get-CimInstance -ClassName Win32_Service -Filter "Name='LibertixBootGuardian'"
Assert-Condition ($null -ne $service) "The boot guardian service is missing."
Assert-Condition ([string]$service.StartMode -eq "Auto") `
    "The boot guardian service is not configured for automatic startup."
Assert-Condition ([string]$service.State -eq "Running") `
    "The boot guardian service is not running."

$ownedBootNumber = [uint16][int]$guardian.bootOrder.bootNumber
$ownedName = "Boot{0:X4}" -f $ownedBootNumber
$ownedBytes = Get-FirmwareVariableBytes -Name $ownedName
Assert-Condition ($null -ne $ownedBytes) "The owned Libertix UEFI entry is missing."
Assert-Condition (
    (Get-ByteHash -Bytes ([byte[]]$ownedBytes)) -eq [string]$guardian.bootOrder.entrySha256
) "The owned Libertix UEFI entry does not match its guardian contract."

[uint16[]]$currentOrder = @(
    ConvertFrom-BootOrderBytes -Bytes (Get-FirmwareVariableBytes -Name "BootOrder")
)
Assert-Condition ($currentOrder.Count -gt 0) "UEFI BootOrder is empty."
$windowsBootNumber = Get-WindowsBootNumber `
    -Order $currentOrder `
    -OwnedBootNumber $ownedBootNumber
[uint16[]]$faultOrder = @($windowsBootNumber) + @(
    $currentOrder | Where-Object { [uint16]$_ -ne $windowsBootNumber }
)

Write-Output "ACTION=$action"
Write-Output "RUN_ID=$($guardian.runId)"
Write-Output "MODE=$($guardian.mode)"
Write-Output "OWNED_BOOT=$ownedName"
Write-Output ("WINDOWS_BOOT=Boot{0:X4}" -f $windowsBootNumber)
Write-Output "CURRENT_ORDER=$(Format-BootOrder -Order $currentOrder)"
Write-Output "FAULT_ORDER=$(Format-BootOrder -Order $faultOrder)"

if ($action -eq "inspect-boot-order") {
    Write-Output "OWNED_FIRST=$(([uint16]$currentOrder[0] -eq $ownedBootNumber).ToString().ToLowerInvariant())"
    Write-Output "SERVICE_STATE=$([string]$service.State)"
    Write-Output "RESULT=OK"
    exit 0
}

if ($action -in @("suspend-guardian", "resume-guardian")) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class LibertixFaultProcessControl
{
    [DllImport("ntdll.dll")]
    public static extern int NtSuspendProcess(IntPtr processHandle);

    [DllImport("ntdll.dll")]
    public static extern int NtResumeProcess(IntPtr processHandle);
}
"@
    $serviceProcess = Get-Process -Id ([int]$service.ProcessId) -ErrorAction Stop
    if ($action -eq "suspend-guardian") {
        $processStatus = [LibertixFaultProcessControl]::NtSuspendProcess($serviceProcess.Handle)
        $failureMessage = "The fault fixture could not suspend the boot guardian process."
        $resultName = "SUSPENDED_PROCESS_ID"
    } else {
        $processStatus = [LibertixFaultProcessControl]::NtResumeProcess($serviceProcess.Handle)
        $failureMessage = "The fault fixture could not resume the boot guardian process."
        $resultName = "RESUMED_PROCESS_ID"
    }
    Assert-Condition ($processStatus -eq 0) $failureMessage
    Write-Output "$resultName=$([int]$service.ProcessId)"
    Write-Output "RESULT=OK"
    exit 0
}

if ($action -in @("plan-boot-order", "plan-preferred-bypass")) {
    Assert-Condition ($currentOrder[0] -eq $ownedBootNumber) `
        "The nominal BootOrder does not currently place Libertix first."
    if ($action -eq "plan-preferred-bypass") {
        $statePath = Join-Path $recoveryRoot "state.json"
        $linuxEvidence = Join-Path $recoveryRoot "installed-linux-boot.json"
        $installSuccess = Join-Path $recoveryRoot "install-success.env"
        Assert-Condition (Test-Path -LiteralPath $statePath -PathType Leaf) `
            "The recovery state is missing before the preferred-path bypass test."
        Assert-Condition (Test-Path -LiteralPath $installSuccess -PathType Leaf) `
            "The installation success marker is missing before the preferred-path bypass test."
        Assert-Condition (-not (Test-Path -LiteralPath $linuxEvidence -PathType Leaf)) `
            "The preferred-path bypass test must run before the first installed Linux boot."
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 |
            ConvertFrom-Json -ErrorAction Stop
        Assert-Condition ([string]$state.RunId -eq [string]$guardian.runId) `
            "The recovery state and guardian run identifiers differ."
        Assert-Condition (
            (Get-Content -LiteralPath $installSuccess -Raw -Encoding UTF8) -match
                "(?m)^LIBERTIX_UEFI_RECOVERY_RUN_ID=$([regex]::Escape([string]$guardian.runId))$"
        ) "The installation success marker belongs to another recovery run."
    }
    Write-Output "WOULD_WRITE_BOOT_ORDER=true"
    if ($action -eq "plan-preferred-bypass") {
        Write-Output "WOULD_STOP_GUARDIAN=true"
    }
    Write-Output "RESULT=OK"
    exit 0
}

if ($action -in @("inject-boot-order", "inject-preferred-bypass")) {
    Assert-Condition ($currentOrder[0] -eq $ownedBootNumber) `
        "The fault fixture refuses to alter a non-nominal BootOrder."
    Assert-Condition ($faultOrder[0] -eq $windowsBootNumber) `
        "The fault fixture did not place Windows first."
    $guardianStopped = $false
    $injectionSucceeded = $false
    try {
        if ($action -eq "inject-preferred-bypass") {
            Stop-Service -Name "LibertixBootGuardian" -ErrorAction Stop
            $guardianStopped = $true
            $serviceStopDeadline = [DateTime]::UtcNow.AddSeconds(15)
            do {
                $service = Get-CimInstance `
                    -ClassName Win32_Service `
                    -Filter "Name='LibertixBootGuardian'"
                if ([string]$service.State -eq "Stopped") {
                    break
                }
                Start-Sleep -Milliseconds 250
            } while ([DateTime]::UtcNow -lt $serviceStopDeadline)
            Assert-Condition ([string]$service.State -eq "Stopped") `
                "The boot guardian service did not stop within 15 seconds."
        }
        Set-FirmwareVariable `
            -Name "BootOrder" `
            -Value (ConvertTo-BootOrderBytes -Order $faultOrder)
        [uint16[]]$verifiedFaultOrder = @(
            ConvertFrom-BootOrderBytes -Bytes (Get-FirmwareVariableBytes -Name "BootOrder")
        )
        Assert-Condition (
            (Format-BootOrder -Order $verifiedFaultOrder) -eq (Format-BootOrder -Order $faultOrder)
        ) "Firmware did not retain the injected BootOrder fault."
        $injectedUtc = [DateTime]::UtcNow.ToString("o")
        Write-Output "INJECTED_UTC=$injectedUtc"
        Write-Output "VERIFIED_FAULT_ORDER=$(Format-BootOrder -Order $verifiedFaultOrder)"
        if ($action -eq "inject-preferred-bypass") {
            Assert-Condition (
                [string](Get-Service -Name "LibertixBootGuardian" -ErrorAction Stop).Status -eq "Stopped"
            ) "The boot guardian restarted before the controlled firmware-bypass reboot."
            Write-Output "GUARDIAN_STOPPED=true"
        }
        $injectionSucceeded = $true
        Write-Output "RESULT=OK"
        exit 0
    } finally {
        if ($guardianStopped -and -not $injectionSucceeded) {
            Start-Service -Name "LibertixBootGuardian" -ErrorAction SilentlyContinue
        }
    }
}

$injectedAfterUtc = [DateTime]::Parse(
    [string]$request.injected_after_utc,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::RoundtripKind
).ToUniversalTime()
Assert-Condition ($currentOrder[0] -eq $ownedBootNumber) `
    "The guardian did not restore Libertix to the front of BootOrder."
$repairLogs = @(
    Get-ChildItem -LiteralPath ([string]$guardian.logDirectory) -Filter "*-repair-*.log" -File |
        Where-Object { $_.LastWriteTimeUtc -ge $injectedAfterUtc.AddSeconds(-2) } |
        Sort-Object LastWriteTimeUtc
)
Assert-Condition ($repairLogs.Count -ge 1) `
    "The guardian repaired BootOrder without producing its required repair journal."
$matchingLogs = @(
    $repairLogs | Where-Object {
        (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8) -match
            'REPAIR: BootOrder changed from .+ to .+'
    }
)
Assert-Condition ($matchingLogs.Count -ge 1) `
    "No repair journal records the BootOrder correction."
Write-Output "REPAIR_LOG=$($matchingLogs[-1].FullName)"
Write-Output "REPAIRED_ORDER=$(Format-BootOrder -Order $currentOrder)"
Write-Output "RESULT=OK"
