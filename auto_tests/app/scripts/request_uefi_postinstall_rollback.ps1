#requires -Version 5.1
param([Parameter(Mandatory = $true)][string]$ConfigPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($config.expected_firmware -cne 'uefi') { throw 'UEFI rollback fixture requires UEFI firmware.' }
$latestPlan = Join-Path $env:SystemDrive 'LibertixInstallLogs\Linux\latest\installation-plan.json'
$plan = Get-Content -LiteralPath $latestPlan -Raw -Encoding UTF8 | ConvertFrom-Json
$planId = [string]$plan.planId
if ($planId -cnotmatch '^[0-9a-f]{32}$' -or $plan.firmware -cne 'uefi') {
    throw 'The verified installation has no valid UEFI plan identity.'
}
$root = Join-Path $env:ProgramData "Libertix\UefiRecovery\$planId"
$statePath = Join-Path $root 'state.json'
$state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
$storedPlan = Join-Path $root 'installation-plan.json'
$execution = Get-Content -LiteralPath (Join-Path $root 'installation-state.json') -Raw | ConvertFrom-Json
$verification = Get-Content -LiteralPath (Join-Path $root 'post-install-verification.json') -Raw | ConvertFrom-Json
$linux = Get-Content -LiteralPath (Join-Path $root 'installed-linux-boot.json') -Raw | ConvertFrom-Json
if ($state.RunId -cne $planId -or $state.PlanId -cne $planId -or
    $execution.planId -cne $planId -or $execution.status -cne 'succeeded' -or
    $verification.planId -cne $planId -or $verification.status -cne 'succeeded' -or
    @($verification.checks).Count -eq 0 -or
    @($verification.checks | Where-Object passed -ne $true).Count -ne 0 -or
    $linux.planId -cne $planId -or $state.Phase -cne 'Verified' -or
    $state.RecoveryRoot -ine $root -or $state.PayloadRoot -ine (Join-Path $root 'payload') -or
    (Get-FileHash -LiteralPath $storedPlan -Algorithm SHA256).Hash -cne
        (Get-FileHash -LiteralPath $latestPlan -Algorithm SHA256).Hash) {
    throw 'Post-install rollback requires the matching completed and verified UEFI installation.'
}
foreach ($step in @('live.installer-partition-expanded', 'target.bootloader-installed')) {
    if ($step -cnotin @($execution.completedSteps)) { throw "Missing completed step: $step" }
}
$agent = Join-Path $state.PayloadRoot 'Scripts\libertix-uefi-recovery-agent.ps1'
$manifest = Get-Content -LiteralPath (Join-Path $root 'payload-manifest.json') -Raw | ConvertFrom-Json
$processModule = Join-Path $state.PayloadRoot 'Scripts\modules\Libertix.Process.psm1'
foreach ($payload in @(
    @{ Path = $agent; Relative = 'Scripts\libertix-uefi-recovery-agent.ps1' },
    @{ Path = $processModule; Relative = 'Scripts\modules\Libertix.Process.psm1' }
)) {
    $entry = @($manifest.Files | Where-Object RelativePath -EQ $payload.Relative)
    if ($entry.Count -ne 1 -or
        (Get-FileHash -LiteralPath $payload.Path -Algorithm SHA256).Hash -ine $entry[0].Sha256) {
        throw "The installed recovery payload does not match its archived hash: $($payload.Relative)"
    }
}
Import-Module $processModule -Force
$response = Invoke-LibertixNativeCommand -FilePath (Get-LibertixNativeSystemExecutable -FileName 'powershell.exe') `
    -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $agent,
        '-StatePath', $statePath, '-Action', 'Cancel') -TimeoutSeconds 900
if ($response.ExitCode -ne 0) {
    $diagnostic = ([string]$response.StandardOutput + "`n" + [string]$response.StandardError).Trim()
    if ($diagnostic.Length -gt 6000) { $diagnostic = $diagnostic.Substring($diagnostic.Length - 6000) }
    throw "UEFI post-install rollback failed: rc=$($response.ExitCode); $diagnostic"
}
Write-Output 'UEFI_POSTINSTALL_ROLLBACK_REQUESTED=True'
Write-Output 'RESULT=OK'
