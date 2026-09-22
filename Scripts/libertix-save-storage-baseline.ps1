param([Parameter(Mandatory = $true)][string]$InstallationPlanPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'modules/Libertix.InstallationPlan.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'modules/Libertix.StorageBaseline.psm1') -ErrorAction Stop
$plan = Read-LibertixInstallationPlan -Path $InstallationPlanPath
Save-LibertixStorageBaseline -Plan $plan -RecoveryRoot (Split-Path -Parent $InstallationPlanPath)
