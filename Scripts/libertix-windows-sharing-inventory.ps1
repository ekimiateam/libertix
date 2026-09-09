param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Z]:$')][string]$SystemDrive,
    [ValidatePattern('^([A-Z]:)?$')][string]$AllocationDrive = ''
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
try {
    Import-Module (Join-Path $PSScriptRoot 'modules/Libertix.WindowsSharingInventory.psm1') -Force -ErrorAction Stop
    $drives = @($SystemDrive)
    if ($AllocationDrive) { $drives += $AllocationDrive }
    $inventory = Get-LibertixWindowsSharingInventory -InstallationDrives $drives
    [ordered]@{ ok = $true; inventory = $inventory } | ConvertTo-Json -Depth 8 -Compress
} catch {
    [ordered]@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
    exit 1
}
