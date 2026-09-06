BeforeAll {
    $sourceRoot = Split-Path -Parent $PSScriptRoot
    $path = Join-Path $sourceRoot "auto_tests/app/scripts/verify_installation_rollback.ps1"
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    $function = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Get-RollbackLedgerEvidence"
    }, $true)
    . ([scriptblock]::Create($function.Extent.Text))
}

Describe "Rollback proof uses the real durable ledger" {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($root) | Out-Null
        foreach ($name in @("Libertix.InstallationState.psm1", "Libertix.AtomicFile.psm1")) {
            Copy-Item -LiteralPath (Join-Path $sourceRoot "Scripts/modules/$name") -Destination (Join-Path $root $name)
        }
        Import-Module (Join-Path $root "Libertix.InstallationState.psm1") -Force
        $statePath = Join-Path $root "installation-state.json"
        $planId = [guid]::NewGuid().ToString('N')
        $null = New-LibertixExecutionState -Path $statePath -PlanId $planId
        $module = Get-Module Libertix.InstallationState | Where-Object {
            $_.Path -eq (Join-Path $root "Libertix.InstallationState.psm1")
        } | Select-Object -First 1
        $steps = & $module { $script:OrderedSteps }
        $compensations = & $module { $script:CompensatableSteps }
        foreach ($step in $steps) {
            $null = Start-LibertixExecutionStep -Path $statePath -Step $step
            $null = Complete-LibertixExecutionStep -Path $statePath -Step $step
        }
        $null = Complete-LibertixInstallation -Path $statePath
    }

    It "does not accept successful installation or unfinished rollback as restoration" {
        (Get-RollbackLedgerEvidence -Paths @($statePath) -ExcludedPlanIds @()).Verified | Should -BeFalse
        $null = Start-LibertixRollback -Path $statePath
        (Get-RollbackLedgerEvidence -Paths @($statePath) -ExcludedPlanIds @()).Verified | Should -BeFalse
    }

    It "accepts a fully compensated rollback and rejects missing live compensation" {
        $null = Start-LibertixRollback -Path $statePath
        foreach ($step in $compensations) {
            $null = Complete-LibertixCompensation -Path $statePath -Step $step
        }
        $null = Complete-LibertixRollback -Path $statePath
        $proof = Get-RollbackLedgerEvidence -Paths @($statePath) -ExcludedPlanIds @()
        $proof.Verified | Should -BeTrue
        $proof.PlanId | Should -Be $planId
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $state.compensatedSteps = @($state.compensatedSteps | Where-Object { $_ -ne "live.installer-partition-expanded" })
        $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding UTF8
        { Get-RollbackLedgerEvidence -Paths @($statePath) -ExcludedPlanIds @() } | Should -Throw "*every applicable compensation*"
    }

    It "cannot use a previous installation as evidence for this attempt" {
        { Get-RollbackLedgerEvidence -Paths @($statePath) -ExcludedPlanIds @($planId) } | Should -Throw "*one new installation ledger*"
        { Get-RollbackLedgerEvidence -Paths @() -ExcludedPlanIds @() } | Should -Throw "*one new installation ledger*"
    }
}
