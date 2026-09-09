BeforeAll {
    $path = Join-Path $PSScriptRoot '../Scripts/libertix-configure-windows-share.ps1'
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
    if (@($errors).Count) { throw 'Windows sharing script does not parse.' }
    $definition = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-LinuxPartition'
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}

Describe 'Read-only sharing physical disk ownership' {
    BeforeEach {
        $disk = [pscustomobject]@{
            Number = 3; UniqueId = 'repeated-vendor'; PartitionStyle = 'GPT'
            Guid = '12345678-1234-1234-1234-123456789abc'; Signature = 0x12345678
        }
        $config = [pscustomobject]@{
            SystemDiskNumber = 3; SystemDiskUniqueId = 'repeated-vendor'
            SystemDiskPartitionTableId = 'gpt:12345678-1234-1234-1234-123456789abc'
            ExpectedLinuxPartitionOffset = 41GB; ExpectedLinuxPartitionSize = 20GB
            PartitionSizeToleranceBytes = 1MB
        }
        $partition = [pscustomobject]@{
            DiskNumber = 3; Offset = 41GB; Size = 20GB; PartitionNumber = 2
            GptType = '{0fc63daf-8483-4772-8e79-3d69d8477de4}'; MbrType = 131; Type = 'Linux'
        }
        Mock Get-Disk { $disk }
        Mock Get-Partition { $partition }
    }

    It 'resolves the recorded nonzero physical disk' {
        (Get-LinuxPartition -Config $config).PartitionNumber | Should -Be 2
        Should -Invoke Get-Disk -Times 1 -Exactly -ParameterFilter { $Number[0] -eq 3 }
        Should -Invoke Get-Partition -Times 1 -Exactly -ParameterFilter { $DiskNumber[0] -eq 3 }
    }

    It 'rejects identical vendor IDs with a different GPT identity before partition lookup' {
        $disk.Guid = '87654321-1234-1234-1234-123456789abc'
        { Get-LinuxPartition -Config $config } | Should -Throw '*partition-table identity*'
        Should -Invoke Get-Partition -Times 0
    }

    It 'checks MBR signatures as well as GPT identifiers' {
        $disk.PartitionStyle = 'MBR'
        $config.SystemDiskPartitionTableId = 'mbr:12345678'
        (Get-LinuxPartition -Config $config).PartitionNumber | Should -Be 2
        $disk.Signature = 0x12345679
        { Get-LinuxPartition -Config $config } | Should -Throw '*partition-table identity*'
    }

    It 'rejects missing table identity rather than using the vendor ID alone' {
        $config.SystemDiskPartitionTableId = ''
        { Get-LinuxPartition -Config $config } | Should -Throw '*partition-table identity*'
        Should -Invoke Get-Partition -Times 0
    }
}
