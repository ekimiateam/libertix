BeforeAll {
    Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.StorageTargets.psm1" -Force
    $path = Join-Path $PSScriptRoot '../Scripts/libertix-storage-preflight.ps1'
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
    if (@($errors).Count -ne 0) { throw 'Storage preflight does not parse.' }
    foreach ($name in @(
        'Get-PartitionTableIdentity', 'Assert-PartitionMatchesExpectedPlan',
        'Assert-StorageMatchesExpectedPlan'
    )) {
        $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $biosPath = Join-Path $PSScriptRoot '../Scripts/libertix-bios-storage.ps1'
    $biosAst = [Management.Automation.Language.Parser]::ParseFile($biosPath, [ref]$null, [ref]$errors)
    if (@($errors).Count -ne 0) { throw 'BIOS storage helper does not parse.' }
    $definition = $biosAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-ValidatedWindowsPartition'
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}

Describe 'BIOS storage identity immediately before partition actions' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $SystemDrive = 'C:'
        $DiskNumber = 3
        $DiskUniqueId = 'repeated-vendor-id'
        $DiskPartitionTableId = 'mbr:12345678'
        $WindowsPartitionOffsetBytes = 1MB
        $OriginalWindowsPartitionSizeBytes = 60GB
        $ExpectedDiskSizeBytes = 0
        $ExpectedLogicalSectorSizeBytes = 0
        $ExpectedSourceVolumeId = ''
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = 3; Offset = 1MB; PartitionNumber = 2; Size = 60GB } }
        Mock Get-Disk {
            [pscustomobject]@{
                Number = 3; UniqueId = 'repeated-vendor-id'; PartitionStyle = 'MBR'; Signature = 0x12345678
            }
        }
    }

    It 'retains the inspected Windows partition on its original disk' {
        (Get-ValidatedWindowsPartition).PartitionNumber | Should -Be 2
    }

    It 'rejects a disk with matching vendor ID but another MBR signature' {
        $DiskPartitionTableId = 'mbr:87654321'
        { Get-ValidatedWindowsPartition } | Should -Throw '*storage identity changed*'
    }

    It 'rejects a Windows drive letter moved to another physical disk' {
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = 0; Offset = 1MB; PartitionNumber = 2 } }
        { Get-ValidatedWindowsPartition } | Should -Throw '*storage identity changed*'
    }

    It 'rejects an extent larger than the original Windows volume' {
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = 3; Offset = 1MB; PartitionNumber = 2; Size = 61GB } }
        { Get-ValidatedWindowsPartition } | Should -Throw '*storage identity changed*'
    }
}

Describe 'BIOS staging remains inside the original Windows extent' {
    BeforeEach {
        $scriptPath = Join-Path $PSScriptRoot '../Scripts/libertix-bios-storage.ps1'
        $arguments = @{
            Action = 'CreateStaging'; SystemDrive = 'C:'; DiskNumber = 3
            DiskUniqueId = 'disk-id'; DiskPartitionTableId = 'mbr:12345678'
            WindowsPartitionOffsetBytes = 1MB; OriginalWindowsPartitionSizeBytes = 60GB
            RecoveryPartitionOffsetBytes = 90GB
        }
        Mock Get-Partition {
            [pscustomobject]@{ DiskNumber = 3; Offset = 1MB; Size = 55GB; PartitionNumber = 2 }
        }
        Mock Get-Disk {
            [pscustomobject]@{
                Number = 3; UniqueId = 'disk-id'; PartitionStyle = 'MBR'; Signature = 0x12345678
                Size = 128GB; LogicalSectorSize = 512
            }
        }
        Mock New-Partition { throw 'reached-verified-create' }
        Mock Format-Volume { throw 'Unexpected format in a no-write guard test.' }
        Mock Resize-Partition { throw 'Unexpected resize in a no-write guard test.' }
    }

    It 'refuses an allocation extending beyond original C even when Recovery is far away' {
        { & $scriptPath @arguments -SizeBytes 8GB } | Should -Throw '*original Windows extent*'
        Should -Invoke New-Partition -Times 0
        Should -Invoke Format-Volume -Times 0
        Should -Invoke Resize-Partition -Times 0
    }

    It 'allows a bounded staging request to reach the intercepted creation command' {
        { & $scriptPath @arguments -SizeBytes 4GB } | Should -Throw '*reached-verified-create*'
        Should -Invoke New-Partition -Times 1 -ParameterFilter {
            $DiskNumber -eq 3 -and $Offset -eq (55GB + 1MB) -and $Size -eq 4GB
        }
        Should -Invoke Format-Volume -Times 0
        Should -Invoke Resize-Partition -Times 0
    }
}

Describe 'Storage preflight identity before BitLocker mutation' {
    BeforeEach {
        $ExpectedFirmware = 'UEFI'
        $disk = [pscustomobject]@{
            Number = 0; UniqueId = 'repeated-vendor-id'; Size = 64GB
            PartitionStyle = 'GPT'; LogicalSectorSize = 512
            Guid = '12345678-1234-1234-1234-123456789abc'; Signature = 123
        }
        $windows = [pscustomobject]@{ PartitionNumber = 3; Offset = 256MB; Size = 50GB }
        $boot = [pscustomobject]@{ PartitionNumber = 1; Offset = 1MB; Size = 100MB }
        $recovery = [pscustomobject]@{ PartitionNumber = 4; Offset = 51GB; Size = 1GB }
        $plan = @{
            firmware = 'uefi'
            disk = @{
                number = 0; uniqueId = 'repeated-vendor-id'; sizeBytes = 64GB
                partitionStyle = 'GPT'; logicalSectorSizeBytes = 512
                partitionTableId = 'gpt:12345678-1234-1234-1234-123456789abc'
                windows = @{ number = 3; offsetBytes = 256MB; sizeBytes = 50GB }
                boot = @{ number = 1; offsetBytes = 1MB; sizeBytes = 100MB }
                recovery = @{ number = 4; offsetBytes = 51GB; sizeBytes = 1GB }
            }
        }
        $planPath = Join-Path $TestDrive 'plan.json'
        $plan | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $planPath -Encoding UTF8
        $arguments = @{
            PlanPath = $planPath; Disk = $disk; SystemPartition = $windows
            BootPartition = $boot; RecoveryPartition = $recovery
        }
        Mock Get-Disk { $disk }
    }

    It 'accepts the unchanged GPT disk and all original partitions' {
        { Assert-StorageMatchesExpectedPlan @arguments } | Should -Not -Throw
    }

    It 'rejects a replacement GPT disk even if its number vendor size and partitions match' {
        $disk.Guid = '87654321-1234-1234-1234-123456789abc'
        { Assert-StorageMatchesExpectedPlan @arguments } | Should -Throw '*disk no longer matches*'
    }

    It 'rejects a missing partition-table identity in the armed plan' {
        $plan.disk.Remove('partitionTableId')
        $plan | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $planPath -Encoding UTF8
        { Assert-StorageMatchesExpectedPlan @arguments } | Should -Throw
    }

    It 'rejects changed partition geometry on the original disk' {
        $windows.Size -= 1GB
        { Assert-StorageMatchesExpectedPlan @arguments } | Should -Throw '*system partition no longer matches*'
    }

    It 'checks the MBR disk signature independently of the vendor ID' {
        $ExpectedFirmware = 'BIOS'
        $disk.PartitionStyle = 'MBR'
        $plan.firmware = 'bios'
        $plan.disk.partitionStyle = 'MBR'
        $plan.disk.partitionTableId = 'mbr:0000007b'
        $plan | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $planPath -Encoding UTF8
        { Assert-StorageMatchesExpectedPlan @arguments } | Should -Not -Throw
        $disk.Signature = 124
        { Assert-StorageMatchesExpectedPlan @arguments } | Should -Throw '*disk no longer matches*'
    }

    It 'rejects a clone connected after the initial compatibility check' {
        $clone = $disk.PSObject.Copy()
        $clone.Number = 5
        Mock Get-Disk { @($disk, $clone) }
        { Assert-StorageMatchesExpectedPlan @arguments } | Should -Throw '*Multiple disks*'
    }
}
