BeforeAll {
    $path = Join-Path $PSScriptRoot "../auto_tests/app/scripts/verify_installation_rollback.ps1"
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count) { throw $errors[0] }
    foreach ($name in @('Test-RollbackPartitionLayout', 'Test-RollbackStorageLayout')) {
    $function = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq $name
    }, $true)
    . ([scriptblock]::Create($function.Extent.Text))
    }
}

Describe 'Rollback verifies the secondary disk as well as Windows' {
    BeforeEach {
        $expectedDisks = @(0..1 | ForEach-Object {
            [pscustomobject]@{
                Number = $_; UniqueId = 'disk-' + $_; Guid = ''; Signature = $_ + 1
                Size = 64GB; PartitionStyle = 'MBR'; LogicalSectorSize = 512
                Partitions = @([pscustomobject]@{ Offset = 1MB; Size = 60GB; GptType = $null; MbrType = 7 })
            }
        })
        $script:rollbackObservedDisks = ConvertFrom-Json (ConvertTo-Json -InputObject $expectedDisks -Depth 6)
        Mock Get-Disk { $script:rollbackObservedDisks }
        Mock Get-Partition { $script:rollbackObservedDisks[[int]$DiskNumber[0]].Partitions }
    }
    It 'accepts both disks only after every extent was restored' {
        Test-RollbackStorageLayout -Expected $expectedDisks | Should -BeTrue
    }
    It 'round-trips the actual baseline collector for GPT disks without an MBR signature' {
        foreach ($disk in $script:rollbackObservedDisks) {
            $disk.PartitionStyle = 'GPT'
            $disk.Guid = [guid]::NewGuid().ToString('B')
            $disk.Signature = $null
        }
        $collector = [Management.Automation.Language.Parser]::ParseFile(
            "$PSScriptRoot/../auto_tests/app/scripts/inspect_installation_rollback_state.ps1",
            [ref]$null, [ref]$null)
        $assignment = $collector.Find({ param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq '$storageLayout'
        }, $true)
        . ([scriptblock]::Create($assignment.Extent.Text))
        $saved = ConvertFrom-Json (ConvertTo-Json -InputObject $storageLayout -Depth 6)
        Test-RollbackStorageLayout -Expected $saved | Should -BeTrue
        $script:rollbackObservedDisks[1].Guid = [guid]::NewGuid().ToString('B')
        Test-RollbackStorageLayout -Expected $saved | Should -BeFalse
    }
    It 'rejects a secondary source that remains shrunk' {
        $script:rollbackObservedDisks[1].Partitions[0].Size = 40GB
        Test-RollbackStorageLayout -Expected $expectedDisks | Should -BeFalse
    }
    It 'rejects an extra Linux partition on the secondary disk' {
        $script:rollbackObservedDisks[1].Partitions += [pscustomobject]@{ Offset = 40GB + 1MB; Size = 20GB; GptType = $null; MbrType = 131 }
        Test-RollbackStorageLayout -Expected $expectedDisks | Should -BeFalse
    }
    It 'rejects a replaced secondary disk with the same capacity' {
        $script:rollbackObservedDisks[1].Signature = 42
        Test-RollbackStorageLayout -Expected $expectedDisks | Should -BeFalse
    }
    It 'rejects a missing secondary disk' {
        $script:rollbackObservedDisks = @($script:rollbackObservedDisks[0])
        Test-RollbackStorageLayout -Expected $expectedDisks | Should -BeFalse
    }
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
