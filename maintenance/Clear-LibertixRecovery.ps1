#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param([switch]$Apply)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-PlainPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing a symbolic link, junction or mounted folder: $current"
        }
        $current = [IO.Path]::GetDirectoryName($current.TrimEnd('\'))
    }
}

function Get-CleanupInventory {
    param([Parameter(Mandatory = $true)][string[]]$Roots)

    $pending = [Collections.Generic.Stack[string]]::new()
    foreach ($root in $Roots) { $pending.Push($root) }
    while ($pending.Count -gt 0) {
        $path = $pending.Pop()
        Assert-PlainPath -Path $path
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        $item
        if ($item.PSIsContainer) {
            foreach ($child in @(Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop)) {
                $pending.Push($child.FullName)
            }
        }
    }
}

function Read-RecoveryJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    Assert-PlainPath -Path $Path
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop |
        ConvertFrom-Json -ErrorAction Stop
}

function Assert-FileHash {
    param([string]$Path, [string]$Expected)
    if ($Expected -notmatch '^[0-9a-fA-F]{64}$' -or
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash -ine $Expected) {
        throw "A restored boot file does not match its saved hash: $Path"
    }
}

function Assert-RestoredBoot {
    param([string]$Root, [object]$Plan)

    if ([string]$Plan.firmware -eq 'bios') {
        $backup = Join-Path $Root 'mbr-backup\mbr-before-grub.bin'
        $hash = ((Get-Content -LiteralPath (Join-Path $Root 'mbr-backup\mbr-before-grub.sha256') -Raw).Trim() -split '\s+')[0]
        Assert-FileHash -Path $backup -Expected $hash
        $disk = Get-Disk -Number $Plan.disk.number -ErrorAction Stop
        Initialize-LibertixBiosMbrIo
        [Libertix.BiosMbrIo]::VerifyBootCode("\\.\PhysicalDrive$($disk.Number)",
            [Math]::Max([int]$disk.LogicalSectorSize, [int]$disk.PhysicalSectorSize),
            [IO.File]::ReadAllBytes($backup))
        return
    }

    $transaction = Read-RecoveryJson -Path (Join-Path $Root 'uefi-transaction.json')
    if ([string]$transaction.RecoveryRunId -cne [string]$Plan.planId) {
        throw "The UEFI transaction belongs to another installation: $Root"
    }
    [byte[]]$order = Get-LibertixFirmwareVariableBytes -Name 'BootOrder'
    $original = @($transaction.OriginalBootOrder)
    if ($original.Count -eq 0 -or $order.Length -ne 2 * $original.Count) {
        throw 'The original UEFI boot order is missing or has changed.'
    }
    for ($index = 0; $index -lt $original.Count; $index++) {
        if ([BitConverter]::ToUInt16($order, 2 * $index) -ne [uint16]$original[$index]) {
            throw 'The UEFI boot order does not match its pre-installation value.'
        }
    }
    if ($null -ne (Get-LibertixFirmwareVariableBytes -Name 'BootNext')) {
        throw 'A one-time firmware boot is pending; restart and diagnose before cleanup.'
    }
    $esp = @(Get-Partition -DiskNumber $Plan.disk.number -ErrorAction Stop | Where-Object {
        [long]$_.Offset -eq [long]$Plan.disk.boot.offsetBytes -and
        [long]$_.Size -eq [long]$Plan.disk.boot.sizeBytes -and
        [string]$_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    })
    if ($esp.Count -ne 1) { throw 'The original EFI system partition cannot be identified.' }
    $volume = $esp[0] | Get-Volume -ErrorAction Stop
    $espRoot = [string]$volume.Path
    if (-not $espRoot -or -not [IO.Directory]::Exists($espRoot)) {
        throw 'The EFI system partition is not readable; cleanup will not mount or alter it.'
    }
    foreach ($name in @('EFI\Libertix', 'EFI\LibertixInstaller')) {
        if (Test-Path -LiteralPath (Join-Path $espRoot $name) -ErrorAction Stop) {
            throw "A Libertix boot directory still exists: $name"
        }
    }
    $loader = Join-Path $espRoot 'EFI\Microsoft\Boot\bootmgfw.efi'
    if (-not (Test-Path -LiteralPath $loader -PathType Leaf)) { throw 'Windows Boot Manager is missing.' }

    $manifestPath = Join-Path $Root 'preferred-boot-path\manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { return }
    $manifest = Read-RecoveryJson -Path $manifestPath
    if ([string]$manifest.runId -cne [string]$Plan.planId -or [string]$manifest.status -cne 'restored') {
        throw 'The preferred Windows boot path has not been restored.'
    }
    Assert-FileHash -Path $loader -Expected ([string]$manifest.windowsLoader.sha256)
    $expectedPaths = @(
        '\EFI\Microsoft\Boot\bootmgfw.libertix-windows.efi',
        '\EFI\Microsoft\Boot\grubx64.efi', '\EFI\Microsoft\Boot\mmx64.efi',
        '\EFI\Microsoft\Boot\grub.cfg'
    )
    if (@($manifest.originalFiles).Count -ne $expectedPaths.Count) { throw 'Original EFI file evidence is incomplete.' }
    foreach ($name in $expectedPaths) {
        $records = @($manifest.originalFiles | Where-Object path -CEQ $name)
        if ($records.Count -ne 1 -or $records[0].existed -isnot [bool]) {
            throw "Original EFI file evidence is ambiguous: $name"
        }
        $path = Join-Path $espRoot $name.TrimStart('\')
        if ($records[0].existed) {
            Assert-FileHash -Path $path -Expected ([string]$records[0].sha256)
        } elseif (Test-Path -LiteralPath $path) {
            throw "An added preferred-boot file remains: $path"
        }
    }
    $entry = $manifest.windowsBootEntry
    if ([string]$entry.name -notmatch '^Boot[0-9A-F]{4}$') { throw 'Original Windows boot entry evidence is invalid.' }
    [byte[]]$bytes = Get-LibertixFirmwareVariableBytes -Name ([string]$entry.name)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '') }
    finally { $sha.Dispose() }
    if ([string]$entry.originalSha256 -notmatch '^[0-9a-f]{64}$' -or $hash -ine [string]$entry.originalSha256) {
        throw 'The original Windows firmware entry has not been restored.'
    }
}

function Assert-CompletedRecovery {
    param([Parameter(Mandatory = $true)][string]$Root)

    [Libertix.Security.RecoveryCleanupAccess]::VerifyEvidence($Root)
    $plan = Read-LibertixInstallationPlan -Path (Join-Path $Root 'installation-plan.json')
    $state = Read-LibertixExecutionState -Path (Join-Path $Root 'installation-state.json')
    if ([string]$plan.disk.systemDrive -ine $env:SystemDrive -or
        [string]$state.planId -cne [string]$plan.planId -or [string]$state.status -cne 'rolled-back') {
        throw "A matching completed rollback is required: $Root"
    }
    # Failed installations do not produce the post-uninstall report. Observe the
    # machine directly instead of requiring evidence from a different workflow.
    Assert-LibertixUninstallStorageBaseline -RecoveryRoot $Root -Restored
    Assert-RestoredBoot -Root $Root -Plan $plan
    Write-Host "Verified rollback: $($plan.planId) ($Root)"
}

function Assert-NoLibertixActivity {
    param([string[]]$Roots)

    foreach ($task in @(Get-ScheduledTask -ErrorAction Stop)) {
        $actions = @($task.Actions | Where-Object {
            $_.PSObject.Properties.Name -contains 'Execute'
        } | ForEach-Object { [string]$_.Execute + ' ' + [string]$_.Arguments }) -join '\n'
        if ([string]$task.TaskName -like 'Libertix*' -or @($Roots | Where-Object {
            $actions.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0
        }).Count -gt 0) {
            throw "A Libertix task remains: $($task.TaskName). Complete rollback before cleanup."
        }
    }
    foreach ($service in @(Get-CimInstance Win32_Service -ErrorAction Stop)) {
        if ($null -ne $script:residualGuardian -and $service.Name -eq 'LibertixBootGuardian') { continue }
        if ([string]$service.Name -like 'Libertix*' -or @($Roots | Where-Object {
            ([string]$service.PathName).IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0
        }).Count -gt 0) {
            throw "A Libertix service remains: $($service.Name). Complete rollback before cleanup."
        }
    }
    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
        if ([int]$process.ProcessId -eq $PID) { continue }
        if ($null -ne $script:residualGuardian -and
            [int]$process.ProcessId -eq [int]$script:residualGuardian.ProcessId) { continue }
        if ([string]$process.Name -like 'Libertix*.exe') { throw 'Close Libertix before cleanup.' }
        foreach ($root in $Roots) {
            if (([string]$process.CommandLine).IndexOf($root, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                throw "A process still references cleanup data: PID $($process.ProcessId)."
            }
        }
    }
    $bcd = Invoke-LibertixNativeCommand -FilePath (Join-Path $env:SystemRoot 'System32\bcdedit.exe') `
        -ArgumentList @('/enum', 'all', '/v') -TimeoutSeconds 60
    if ($bcd.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($bcd.StandardOutput) -or
        $bcd.StandardOutput -match '(?i)libertix|grldr') {
        throw 'BCD is unreadable or still references Libertix/GRUB4DOS; cleanup is refused.'
    }
}

function Get-ResidualBootGuardian {
    param([string[]]$RecoveryRoots)
    $service = Get-CimInstance Win32_Service -Filter "Name='LibertixBootGuardian'" -ErrorAction Stop
    if ($null -eq $service) { return $null }
    $root = Join-Path $env:ProgramData 'Libertix\BootGuardian'
    $expected = Join-Path $root 'Libertix.BootGuardian.exe'
    if ([string]$service.StartName -ne 'LocalSystem' -or
        ([string]$service.PathName).Trim('"') -ine $expected) {
        throw 'BootGuardian service ownership cannot be established; refusing to remove it.'
    }
    [Libertix.Security.RecoveryCleanupAccess]::VerifyEvidence($root)
    $config = Read-RecoveryJson -Path (Join-Path $root 'config.json')
    $planIds = @($RecoveryRoots | ForEach-Object {
        (Read-RecoveryJson -Path (Join-Path $_ 'installation-plan.json')).planId
    })
    if ([int]$config.version -ne 1 -or [string]$config.runId -cnotin $planIds) {
        throw 'BootGuardian does not belong to a verified recovery session.'
    }
    return $service
}

function Remove-ResidualBootGuardian {
    if ($null -eq $script:residualGuardian) { return }
    $sc = Join-Path $env:SystemRoot 'System32\sc.exe'
    $result = Invoke-LibertixNativeCommand -FilePath $sc `
        -ArgumentList @('stop', 'LibertixBootGuardian') -TimeoutSeconds 30
    if ($result.ExitCode -notin @(0, 1062)) { throw 'BootGuardian could not be stopped.' }
    $service = Get-Service -Name LibertixBootGuardian -ErrorAction Stop
    $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(30))
    $result = Invoke-LibertixNativeCommand -FilePath $sc `
        -ArgumentList @('delete', 'LibertixBootGuardian') -TimeoutSeconds 30
    if ($result.ExitCode -ne 0) { throw 'BootGuardian service registration could not be removed.' }
    $service.Dispose()
    if (Get-Service -Name LibertixBootGuardian -ErrorAction SilentlyContinue) {
        throw 'BootGuardian is still registered; close other service-management tools and retry.'
    }
    $script:residualGuardian = $null
}

if ($PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess) {
    throw 'Use 64-bit Windows PowerShell 5.1 as administrator.'
}
if ($env:SystemDrive -notmatch '^[A-Za-z]:$') { throw 'The Windows system drive is invalid.' }
$repository = Split-Path -Parent $PSScriptRoot
if (-not ('Libertix.Security.RecoveryCleanupAccess' -as [type])) {
    # Reuse the product's permission rules instead of approximating Windows ACLs here.
    $accessSource = Get-Content -LiteralPath (Join-Path $repository 'Helpers\ProtectedFiles.cs') -Raw
    Add-Type -TypeDefinition ($accessSource + @'

namespace Libertix.Security
{
    public static class RecoveryCleanupAccess
    {
        public static void Verify(string path)
        {
            ProtectedFiles.RequireRemovalPath(path);
        }
        public static void VerifyEvidence(string path)
        {
            ProtectedFiles.RequireRecoveryTree(path);
        }
    }
}
'@) -ErrorAction Stop
}
foreach ($name in @('InstallationPlan', 'InstallationState', 'StorageBaseline', 'BiosMbr', 'FirmwareVariables', 'Process')) {
    Import-Module (Join-Path $repository "Scripts\modules\Libertix.$name.psm1") -ErrorAction Stop
}

$productRoot = Join-Path $env:ProgramData 'Libertix'
$biosRoot = Join-Path $env:SystemDrive 'LibertixInstallRecovery'
$roots = @(@(
    (Join-Path $env:SystemDrive 'LibertixTools'),
    (Join-Path $env:SystemDrive 'LibertixInstallLogs'),
    (Join-Path $env:SystemDrive 'libertix-live.iso'), $biosRoot, $productRoot
) | Where-Object { Test-Path -LiteralPath $_ -ErrorAction Stop })
foreach ($userProfile in @(Get-CimInstance Win32_UserProfile -ErrorAction Stop)) {
    if ([string]$userProfile.LocalPath -notmatch '^[A-Za-z]:\\') { continue }
    $userLogs = Join-Path ([string]$userProfile.LocalPath) 'AppData\Local\Libertix\Logs'
    if (Test-Path -LiteralPath $userLogs -ErrorAction Stop) { $roots += $userLogs }
}
$roots = @($roots | Sort-Object -Unique)
if ($roots.Count -eq 0) { Write-Host 'No managed installation files found.'; return }
if ([IO.Path]::GetFullPath($env:ProgramData) -ine (Join-Path $env:SystemDrive 'ProgramData')) {
    throw 'Relocated ProgramData is not supported by this cleanup tool.'
}
foreach ($root in $roots) {
    if (($repository + '\').StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Run this tool from a source checkout outside the directories being cleaned.'
    }
}
$inventory = @(Get-CleanupInventory -Roots $roots)
foreach ($item in $inventory) { [Libertix.Security.RecoveryCleanupAccess]::Verify($item.FullName) }
if (Test-Path -LiteralPath $productRoot) {
    $knownDirectories = @('Runtime', 'Downloads', 'UefiRecovery', 'RecoveryHistory', 'WindowsShare', 'BootGuardian', 'Automation')
    foreach ($child in @(Get-ChildItem -LiteralPath $productRoot -Force)) {
        if (-not $child.PSIsContainer -or $child.Name -notin $knownDirectories) {
            throw "Unexpected data in the product directory; refusing global cleanup: $($child.FullName)"
        }
    }
}
$recoveryRoots = @()
if (Test-Path -LiteralPath $biosRoot) { $recoveryRoots += $biosRoot }
foreach ($relative in @('UefiRecovery', 'RecoveryHistory\bios')) {
    $parent = Join-Path $productRoot $relative
    if (Test-Path -LiteralPath $parent) {
        foreach ($child in @(Get-ChildItem -LiteralPath $parent -Force)) {
            if (-not $child.PSIsContainer) { throw "Unexpected recovery entry: $($child.FullName)" }
            $recoveryRoots += $child.FullName
        }
    }
}
$history = Join-Path $productRoot 'RecoveryHistory'
if (Test-Path -LiteralPath $history) {
    foreach ($child in @(Get-ChildItem -LiteralPath $history -Force)) {
        if (-not $child.PSIsContainer -or $child.Name -cne 'bios') {
            throw "Unknown recovery history must be investigated before cleanup: $($child.FullName)"
        }
    }
}
if ($recoveryRoots.Count -eq 0) { throw 'No recovery evidence remains. Refusing to guess whether cleanup is safe.' }
foreach ($root in $recoveryRoots) { Assert-CompletedRecovery -Root $root }
$script:residualGuardian = Get-ResidualBootGuardian -RecoveryRoots $recoveryRoots
Assert-NoLibertixActivity -Roots $roots

Write-Warning 'This permanently deletes managed installation logs, runtime files and rollback archives. Save diagnostics elsewhere first.'
if ($null -ne $script:residualGuardian) { Write-Warning 'The verified residual LibertixBootGuardian service will also be stopped and removed.' }
foreach ($item in $inventory) { Write-Host $item.FullName }
if (-not $Apply) { Write-Host 'Preview only. Nothing deleted. Use -Apply only after reviewing the complete list.'; return }
if (-not $PSCmdlet.ShouldProcess(($roots -join ', '), 'Permanently remove verified Libertix recovery data')) { return }

# Revalidate after the confirmation prompt, before losing any recovery evidence.
Assert-NoLibertixActivity -Roots $roots
foreach ($root in $recoveryRoots) { Assert-CompletedRecovery -Root $root }
$script:residualGuardian = Get-ResidualBootGuardian -RecoveryRoots $recoveryRoots
Remove-ResidualBootGuardian
Assert-NoLibertixActivity -Roots $roots
foreach ($root in $recoveryRoots) { Assert-CompletedRecovery -Root $root }
$current = @(Get-CleanupInventory -Roots $roots)
foreach ($item in $current) { [Libertix.Security.RecoveryCleanupAccess]::Verify($item.FullName) }
if (Compare-Object @($inventory.FullName | Sort-Object) @($current.FullName | Sort-Object)) {
    throw 'The cleanup inventory changed during confirmation; run the preview again.'
}
$deletionOrder = @($current | Sort-Object @{
    Expression = {
        $path = $_.FullName.TrimEnd('\') + '\'
        # Leave recovery evidence until the other managed files have been removed.
        [int](@($recoveryRoots | Where-Object {
            $recovery = $_.TrimEnd('\') + '\'
            $path.StartsWith($recovery, [StringComparison]::OrdinalIgnoreCase) -or
                $recovery.StartsWith($path, [StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0)
    }
}, @{ Expression = { $_.FullName.Length }; Descending = $true })
foreach ($item in $deletionOrder) {
    Assert-PlainPath -Path $item.FullName
    [Libertix.Security.RecoveryCleanupAccess]::Verify($item.FullName)
    # Delete only enumerated leaves; never recursively traverse a newly added directory.
    if ($item.PSIsContainer) {
        [IO.Directory]::Delete($item.FullName, $false)
    } else {
        Remove-Item -LiteralPath $item.FullName -Force -Confirm:$false -ErrorAction Stop
    }
}
Write-Host 'Managed installation data removed. No partitions or boot entries were modified.'
