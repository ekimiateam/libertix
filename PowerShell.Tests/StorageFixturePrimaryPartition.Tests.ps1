BeforeAll {
    $path = Join-Path $PSScriptRoot '../auto_tests/app/scripts/storage_fixture.ps1'
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
    if (@($errors).Count) { throw 'The storage fixture does not parse.' }
    foreach ($name in @('Resolve-FixtureDisk', 'Invoke-FixtureDiskPart', 'New-FixtureSystemPartition')) {
        $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
}

Describe 'Storage fixture primary partition creation before formatting' {
    BeforeEach {
        $disk = [pscustomobject]@{
            Number = 3; Path = 'verified-system-disk'; PartitionStyle = 'MBR'; Size = 64GB
            Guid = [guid]::Empty; Signature = 123; IsOffline = $false; IsReadOnly = $false
        }
        $before = @(
            [pscustomobject]@{ PartitionNumber = 1; Offset = 1MB; Size = 100MB; GptType = ''; MbrType = 7 },
            [pscustomobject]@{ PartitionNumber = 2; Offset = 1GB; Size = 40GB; GptType = ''; MbrType = 7 },
            [pscustomobject]@{ PartitionNumber = 3; Offset = 61GB; Size = 1GB; GptType = ''; MbrType = 39 }
        )
        $created = [pscustomobject]@{ PartitionNumber = 4; Offset = 41GB; Size = 1GB; GptType = ''; MbrType = 7 }
        $after = $before + @($created)
        $script:created = $false
        Mock Resolve-FixtureDisk { $disk.PSObject.Copy() }
        Mock Get-Partition { if ($script:created) { $after } else { $before } }
        Mock Invoke-FixtureDiskPart { $script:created = $true }
        Mock New-Partition { $script:created = $true }
    }

    It 'explicitly creates the fourth primary with MB sizes and KB offsets' {
        $result = New-FixtureSystemPartition -Disk $disk -Offset 41GB -Size 1GB
        $result.PartitionNumber | Should -Be 4
        Should -Invoke Invoke-FixtureDiskPart -Times 1 -Exactly -ParameterFilter {
            $Commands -ceq "select disk 3`r`ncreate partition primary size=1024 offset=42991616`r`nexit"
        }
        Should -Invoke New-Partition -Times 0
    }

    It 'keeps GPT creation through the Storage cmdlet' {
        $disk.PartitionStyle = 'GPT'
        $disk.Guid = [guid]'12345678-1234-1234-1234-123456789abc'
        (New-FixtureSystemPartition -Disk $disk -Offset 41GB -Size 1GB).PartitionNumber | Should -Be 4
        Should -Invoke Invoke-FixtureDiskPart -Times 0
        Should -Invoke New-Partition -Times 1 -Exactly -ParameterFilter {
            $DiskNumber -eq 3 -and $Offset -eq 41GB -and $Size -eq 1GB
        }
    }

    It 'refuses overlap without invoking either creator' {
        { New-FixtureSystemPartition -Disk $disk -Offset 40GB -Size 1GB } | Should -Throw '*overlaps*'
        Should -Invoke Invoke-FixtureDiskPart -Times 0
        Should -Invoke New-Partition -Times 0
    }

    It 'creates GPT Recovery with its final type before formatting' {
        $disk.PartitionStyle = 'GPT'
        $created.GptType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
        (New-FixtureSystemPartition -Disk $disk -Offset 41GB -Size 1GB -Recovery).PartitionNumber | Should -Be 4
        Should -Invoke New-Partition -Times 1 -Exactly -ParameterFilter {
            $DiskNumber -eq 3 -and $Offset -eq 41GB -and $Size -eq 1GB -and
                $GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
        }
    }

    It 'creates MBR Recovery as primary type 27 without a later type conversion' {
        $created.MbrType = 39
        (New-FixtureSystemPartition -Disk $disk -Offset 41GB -Size 1GB -Recovery).PartitionNumber | Should -Be 4
        Should -Invoke Invoke-FixtureDiskPart -Times 1 -Exactly -ParameterFilter {
            $Commands -ceq "select disk 3`r`ncreate partition primary size=1024 offset=42991616 id=27`r`nexit"
        }
    }

    It 'refuses formatting when GPT Recovery creation returned a basic data partition' {
        $disk.PartitionStyle = 'GPT'
        $created.GptType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
        { New-FixtureSystemPartition -Disk $disk -Offset 41GB -Size 1GB -Recovery } |
            Should -Throw '*Recovery type was not verified*'
    }

    It 'refuses formatting when MBR Recovery creation returned type 7' {
        { New-FixtureSystemPartition -Disk $disk -Offset 41GB -Size 1GB -Recovery } |
            Should -Throw '*Recovery type was not verified*'
    }

    It 'refuses changed disk identity before creation' {
        Mock Resolve-FixtureDisk { $changed = $disk.PSObject.Copy(); $changed.Signature++; $changed }
        { New-FixtureSystemPartition -Disk $disk -Offset 41GB -Size 1GB } | Should -Throw '*disk changed*'
        Should -Invoke Invoke-FixtureDiskPart -Times 0
    }

    It 'refuses a created extent with a different size even when DiskPart reports success' {
        $created.Size = 2GB
        { New-FixtureSystemPartition -Disk $disk -Offset 41GB -Size 1GB } | Should -Throw '*formatting is refused*'
    }

    It 'refuses an extended container instead of accepting a logical partition' {
        $created.MbrType = 15
        { New-FixtureSystemPartition -Disk $disk -Offset 41GB -Size 1GB } | Should -Throw '*formatting is refused*'
    }

    It 'refuses a changed pre-existing Recovery partition' {
        $replacement = $before[2].PSObject.Copy()
        $replacement.MbrType = 7
        $after = @($before[0], $before[1], $replacement, $created)
        { New-FixtureSystemPartition -Disk $disk -Offset 41GB -Size 1GB } | Should -Throw '*existing fixture partition changed*'
    }

    It 'refuses to create a fifth primary' {
        $before += [pscustomobject]@{ PartitionNumber = 4; Offset = 42GB; Size = 1GB; GptType = ''; MbrType = 7 }
        { New-FixtureSystemPartition -Disk $disk -Offset 41GB -Size 1GB } | Should -Throw '*no free primary*'
        Should -Invoke Invoke-FixtureDiskPart -Times 0
    }
}
