BeforeAll {
    $path = Join-Path $PSScriptRoot '../auto_tests/app/scripts/storage_fixture.ps1'
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
    if (@($errors).Count -ne 0) { throw 'Storage fixture does not parse.' }
    $function = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Assert-FixtureHardwareIdentity'
    }, $true)
    . ([scriptblock]::Create($function.Extent.Text))
    $allocationFunction = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Test-FixtureAllocationSource'
    }, $true)
    . ([scriptblock]::Create($allocationFunction.Extent.Text))
}

Describe 'Fixture preservation distinguishes the selected source from unrelated partitions' {
    BeforeEach {
        $script:fixtureAllocation = [pscustomobject]@{
            number = 1; partitionTableId = 'mbr:12345678'
            sourcePartition = [pscustomobject]@{ number = 1; offsetBytes = 1MB; sizeBytes = 60GB }
        }
        $script:fixtureLinuxSize = 20GB
        $disk = [pscustomobject]@{ Number = 1; PartitionStyle = 'MBR'; Signature = 0x12345678 }
        $partition = [pscustomobject]@{ PartitionNumber = 1; Offset = 1MB; Size = 40GB }
    }

    It 'permits only the planned source shrink' {
        Test-FixtureAllocationSource -Disk $disk -Partition $partition -OriginalSize 60GB | Should -BeTrue
        $partition.Size = 39GB
        { Test-FixtureAllocationSource -Disk $disk -Partition $partition -OriginalSize 60GB } |
            Should -Throw '*shrink does not match*'
    }

    It 'does not exempt another disk or another partition from preservation' {
        $disk.Number = 0
        Test-FixtureAllocationSource -Disk $disk -Partition $partition -OriginalSize 60GB | Should -BeFalse
        $disk.Number = 1
        $partition.Offset = 61GB
        Test-FixtureAllocationSource -Disk $disk -Partition $partition -OriginalSize 60GB | Should -BeFalse
    }

    It 'rejects a replaced partition table even if disk number and offset match' {
        $disk.Signature = 1
        { Test-FixtureAllocationSource -Disk $disk -Partition $partition -OriginalSize 60GB } |
            Should -Throw '*differs from its fixture baseline*'
    }
}

Describe 'Storage fixture hardware identity boundary' {
    It 'accepts repeated vendor IDs when disk paths and partition tables differ' {
        { Assert-FixtureHardwareIdentity @(
            [pscustomobject]@{ unique_id = 'ATAQEMU HARDDISK'; device_path = 'a'; style = 'GPT'; partition_table_id = 'guid-a' },
            [pscustomobject]@{ unique_id = 'ATAQEMU HARDDISK'; device_path = 'b'; style = 'GPT'; partition_table_id = 'guid-b' }
        ) } | Should -Not -Throw
    }

    It 'rejects cloned partition table identities despite distinct paths' {
        { Assert-FixtureHardwareIdentity @(
            [pscustomobject]@{ device_path = 'a'; style = 'GPT'; partition_table_id = 'guid-a' },
            [pscustomobject]@{ device_path = 'b'; style = 'GPT'; partition_table_id = ' {GUID-A} ' }
        ) } | Should -Throw '*duplicate or missing partition-table identifiers*'
    }

    It 'rejects an empty partition table identifier' {
        { Assert-FixtureHardwareIdentity @(
            [pscustomobject]@{ device_path = 'a'; style = 'GPT'; partition_table_id = ' ' }
        ) } | Should -Throw '*duplicate or missing partition-table identifiers*'
    }

    It 'allows an uninitialized RAW disk without a partition table identifier' {
        { Assert-FixtureHardwareIdentity @(
            [pscustomobject]@{ device_path = 'a'; style = 'RAW'; partition_table_id = '' }
        ) } | Should -Not -Throw
    }

    It 'rejects ambiguous device paths' {
        { Assert-FixtureHardwareIdentity @(
            [pscustomobject]@{ device_path = 'a'; style = 'RAW'; partition_table_id = '' },
            [pscustomobject]@{ device_path = ' A '; style = 'RAW'; partition_table_id = '' }
        ) } | Should -Throw '*duplicate or missing disk device paths*'
    }
}
