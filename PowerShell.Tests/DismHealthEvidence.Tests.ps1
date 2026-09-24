Describe 'Auto-test DISM health evidence' {
    BeforeAll {
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            "$PSScriptRoot/../auto_tests/app/scripts/post_install_windows_check.ps1",
            [ref]$null, [ref]$errors)
        if ($errors.Count) { throw ($errors | Out-String) }
        $assert = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Assert-Condition'
        }, $true)
        . ([scriptblock]::Create($assert.Extent.Text))
        $switch = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.SwitchStatementAst]
        }, $true)
        $clauses = @($switch.Clauses | Where-Object { $_.Item1.Value -eq 'dism_check_health' })
        if ($clauses.Count -ne 1) { throw 'The DISM health check is missing or ambiguous.' }
        $text = $clauses[0].Item2.Extent.Text.Trim()
        $check = [scriptblock]::Create($text.Substring(1, $text.Length - 2))
        function Repair-WindowsImage {
            [CmdletBinding()]
            param([switch]$Online, [switch]$CheckHealth, [switch]$NoRestart)
            throw 'The real DISM command must never run in this unit test.'
        }
    }

    It 'accepts and records a healthy image without requesting repair' {
        Mock Repair-WindowsImage { [pscustomobject]@{ ImageHealthState = 'Healthy' } }
        & $check | Should -Contain 'DISM_CHECK_HEALTH_STATE=Healthy'
        Should -Invoke Repair-WindowsImage -Times 1 -Exactly -ParameterFilter {
            $Online -and $CheckHealth -and $NoRestart -and $ErrorAction -eq 'Stop'
        }
    }

    It 'rejects image health state <State>' -ForEach @(
        @{ State = 'Repairable' }, @{ State = 'NonRepairable' },
        @{ State = 'Unknown' }, @{ State = '' }
    ) {
        Mock Repair-WindowsImage { [pscustomobject]@{ ImageHealthState = $State } }
        { & $check } | Should -Throw '*did not report Healthy*'
    }

    It 'rejects an absent result' {
        Mock Repair-WindowsImage {}
        { & $check } | Should -Throw '*unique image health result*'
    }

    It 'rejects duplicate results' {
        Mock Repair-WindowsImage {
            [pscustomobject]@{ ImageHealthState = 'Healthy' }
            [pscustomobject]@{ ImageHealthState = 'Healthy' }
        }
        { & $check } | Should -Throw '*unique image health result*'
    }

    It 'rejects a result without a health state' {
        Mock Repair-WindowsImage { [pscustomobject]@{ Online = $true } }
        { & $check } | Should -Throw '*did not report Healthy*'
    }

    It 'preserves a DISM execution failure' {
        Mock Repair-WindowsImage { throw 'DISM probe failed' }
        { & $check } | Should -Throw '*DISM probe failed*'
    }
}
