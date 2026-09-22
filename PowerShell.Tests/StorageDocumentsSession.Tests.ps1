BeforeAll {
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        "$PSScriptRoot/../auto_tests/app/scripts/storage_documents_fixture.ps1", [ref]$null, [ref]$null)
    $apply = $ast.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.IfStatementAst] -and
        $_.Clauses[0].Item1.Extent.Text -eq "`$config.phase -eq 'apply'"
    }
    $guard = $apply.Clauses[0].Item2.Statements | Select-Object -First 2
    $check = [scriptblock]::Create(($guard.Extent.Text -join "`n"))
    $identity = [pscustomobject]@{ Name = 'TEST\admin' }
}

Describe 'Documents fixture session boundary' {
    It 'requires the interactive account before creating a redirection' {
        Mock Get-CimInstance { [pscustomobject]@{ UserName = '' } }
        { . $check } | Should -Throw '*logged-in test account*'
        Mock Get-CimInstance { [pscustomobject]@{ UserName = 'TEST\other' } }
        { . $check } | Should -Throw '*logged-in test account*'
        Mock Get-CimInstance { [pscustomobject]@{ UserName = 'TEST\admin' } }
        { . $check } | Should -Not -Throw
    }
    It 'does not require an interactive session for read-only verification' {
        $queries = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Get-CimInstance'
        }, $true))
        $queries.Count | Should -Be 1
        $queries[0].Extent.StartOffset | Should -BeGreaterThan $apply.Extent.StartOffset
        $queries[0].Extent.EndOffset | Should -BeLessThan $apply.Extent.EndOffset
        $ast.Extent.Text | Should -Match '\$identity.User.Value -cne \[string\]\$receipt.user_sid'
    }
}
