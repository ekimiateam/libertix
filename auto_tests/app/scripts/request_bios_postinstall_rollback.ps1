param([Parameter(Mandatory = $true)][string]$ConfigPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
if ($config.expected_firmware -cne "bios") { throw "BIOS rollback fixture requires BIOS firmware." }
$root = Join-Path $env:SystemDrive "LibertixInstallRecovery"
Import-Module (Join-Path $root "Libertix.InstallationState.psm1") -Force
$state = Read-LibertixExecutionState -Path (Join-Path $root "installation-state.json")
$plan = Get-Content -LiteralPath (Join-Path $root "installation-plan.json") -Raw | ConvertFrom-Json
if ($state.status -cne "succeeded" -or $plan.firmware -cne "bios" -or $plan.planId -cne $state.planId) {
    throw "Post-install rollback requires the matching completed BIOS installation."
}
foreach ($step in @("live.installer-partition-expanded", "target.bootloader-installed")) {
    if ($step -cnotin @($state.completedSteps)) { throw "Post-install rollback lacks completed step $step." }
}
if (-not (Test-Path -LiteralPath (Join-Path $root "installed-linux-boot.json") -PathType Leaf)) {
    throw "Post-install rollback requires the installed Linux boot evidence."
}
Import-Module (Join-Path $root "Libertix.Process.psm1") -Force
$guard = Join-Path $root "recover.ps1"
if (-not (Test-Path -LiteralPath $guard -PathType Leaf)) { throw "The installed BIOS recovery guard is missing." }
$response = Invoke-LibertixNativeCommand -FilePath (Get-LibertixNativeSystemExecutable -FileName "powershell.exe") `
    -ArgumentList @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", $guard, "-Action", "Revert") `
    -TimeoutSeconds 900
if ($response.ExitCode -ne 0) {
    $diagnostic = ([string]$response.StandardOutput + "`n" + [string]$response.StandardError).Trim()
    if ($diagnostic.Length -gt 6000) { $diagnostic = $diagnostic.Substring($diagnostic.Length - 6000) }
    throw "BIOS post-install rollback failed: rc=$($response.ExitCode); $diagnostic"
}
Write-Output "BIOS_POSTINSTALL_ROLLBACK_REQUESTED=True"
Write-Output "RESULT=OK"
