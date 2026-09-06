BeforeAll {
    $path = Join-Path $PSScriptRoot "../auto_tests/app/scripts/verify_installation_rollback.ps1"
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count) { throw $errors[0] }
    $function = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Test-RollbackPartitionLayout"
    }, $true)
    . ([scriptblock]::Create($function.Extent.Text))
}

Describe "Rollback partition identity ignores only volatile Windows numbering" {
    BeforeEach {
        $expected = @(
            [pscustomobject]@{ PartitionNumber = 1; Offset = 1MB; Size = 50MB; GptType = $null; MbrType = 7 },
            [pscustomobject]@{ PartitionNumber = 2; Offset = 51MB; Size = 60GB; GptType = $null; MbrType = 7 },
            [pscustomobject]@{ PartitionNumber = 3; Offset = 60GB + 51MB; Size = 500MB; GptType = $null; MbrType = 39 }
        )
        $actual = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $expected)
    }
    It "accepts unchanged Recovery with its previous Windows number" {
        $actual[2].PartitionNumber = 4
        Test-RollbackPartitionLayout -Actual $actual -Expected $expected | Should -BeTrue
    }
    It "compares physical layout independently of enumeration order" {
        Test-RollbackPartitionLayout -Actual @($actual[2], $actual[0], $actual[1]) -Expected $expected |
            Should -BeTrue
    }
    It "rejects a changed <Field>" -TestCases @(
        @{ Field = 'Offset'; Value = 61GB },
        @{ Field = 'Size'; Value = 499MB },
        @{ Field = 'MbrType'; Value = 7 },
        @{ Field = 'GptType'; Value = 'de94bba4-06d1-4d40-a16a-bfd50179d6ac' }
    ) {
        param($Field, $Value)
        $actual[2].$Field = $Value
        Test-RollbackPartitionLayout -Actual $actual -Expected $expected | Should -BeFalse
    }
    It "rejects missing or additional partitions" {
        Test-RollbackPartitionLayout -Actual @($actual[0], $actual[1]) -Expected $expected | Should -BeFalse
        Test-RollbackPartitionLayout -Actual @($actual + $actual[2]) -Expected $expected | Should -BeFalse
    }
    It "does not accept two empty inventories" {
        Test-RollbackPartitionLayout -Actual @() -Expected @() | Should -BeFalse
    }
}
