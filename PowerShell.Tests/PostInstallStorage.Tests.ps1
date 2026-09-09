BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../Scripts/modules/Libertix.PostInstallVerification.psm1') -Force
}

Describe 'Auto-test Linux mount disk selection' {
    BeforeAll {
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            "$PSScriptRoot/../auto_tests/app/scripts/post_install_windows_check.ps1", [ref]$null, [ref]$errors)
        if ($errors.Count) { throw ($errors | Out-String) }
        foreach ($name in @('Assert-Condition', 'Get-PlannedLinuxDisk')) {
            $definition = $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
    }
    BeforeEach {
        $definition = [pscustomobject]@{
            number = 1; uniqueId = 'vendor'; partitionStyle = 'MBR'; partitionTableId = 'mbr:12345678'
            sizeBytes = 64GB; logicalSectorSizeBytes = 512
        }
        $plan = [pscustomobject]@{ schemaVersion = 5; disk = [pscustomobject]@{ number = 0 }; allocation = $definition }
        Mock Get-Disk {
            [pscustomobject]@{
                Number = 1; UniqueId = 'vendor'; PartitionStyle = 'MBR'; Signature = 0x12345678
                Size = 64GB; LogicalSectorSize = 512
            }
        }
    }
    It 'uses the allocation disk rather than the Windows disk' {
        (Get-PlannedLinuxDisk -Plan $plan).Number | Should -Be 1
        Should -Invoke Get-Disk -Times 1 -ParameterFilter { $Number[0] -eq 1 }
    }
    It 'rejects an allocation aliasing Windows' {
        $plan.allocation.number = 0
        { Get-PlannedLinuxDisk -Plan $plan } | Should -Throw '*distinct from Windows*'
        Should -Invoke Get-Disk -Times 0
    }
    It 'rejects a clone with the same vendor identifier' {
        $plan.allocation.partitionTableId = 'mbr:11111111'
        { Get-PlannedLinuxDisk -Plan $plan } | Should -Throw '*no longer matches*'
    }
    It 'retains the original schema four selection' {
        $plan.schemaVersion = 4
        $plan.disk = $definition
        (Get-PlannedLinuxDisk -Plan $plan).Number | Should -Be 1
    }
}

Describe 'Post-installation disk allocation proof' {
    InModuleScope Libertix.PostInstallVerification {
        BeforeEach {
            $script:windowsDisk = [pscustomobject]@{
                Number = 0; UniqueId = 'vendor'; PartitionStyle = 'GPT'
                Guid = '12345678-1234-1234-1234-123456789abc'
                LogicalSectorSize = 512; Size = 128GB
            }
            $script:linuxDisk = [pscustomobject]@{
                Number = 1; UniqueId = 'vendor'; PartitionStyle = 'MBR'
                Signature = 0x12345678; LogicalSectorSize = 512; Size = 64GB
            }
            $script:windows = [pscustomobject]@{ Offset = 1GB; Size = 100GB; PartitionNumber = 3 }
            $script:recovery = [pscustomobject]@{ Offset = 102GB; Size = 1GB; PartitionNumber = 4 }
            $script:source = [pscustomobject]@{ DiskNumber = 1; DriveLetter = 'J'; Offset = 1GB; Size = 40GB; PartitionNumber = 1 }
            $script:linux = [pscustomobject]@{ Offset = 41GB; Size = 20GB; PartitionNumber = 2 }
            $script:plan = [pscustomobject]@{
                schemaVersion = 5
                disk = [pscustomobject]@{
                    number = 0; uniqueId = 'vendor'; partitionStyle = 'GPT'; systemDrive = 'C:'
                    partitionTableId = 'gpt:12345678-1234-1234-1234-123456789abc'
                    logicalSectorSizeBytes = 512; sizeBytes = 128GB
                    windows = [pscustomobject]@{ offsetBytes = 1GB; sizeBytes = 100GB }
                    recovery = [pscustomobject]@{ offsetBytes = 102GB; sizeBytes = 1GB }
                    installer = [pscustomobject]@{
                        resizeMode = 'windows-online'; offsetBytes = 41GB; finalSizeBytes = 20GB
                    }
                }
                allocation = [pscustomobject]@{
                    number = 1; uniqueId = 'vendor'; partitionStyle = 'MBR'
                    partitionTableId = 'mbr:12345678'; logicalSectorSizeBytes = 512; sizeBytes = 64GB
                    sourceDrive = 'J:'; sourceVolumeId = 'volume-data'; sourceNtfsUuid = '1234567890ABCDEF'
                    sourcePartition = [pscustomobject]@{ offsetBytes = 1GB; sizeBytes = 60GB }
                }
            }
            Mock Get-Disk {
                if (@($Number).Count -ne 1) { throw 'Expected exactly one disk number.' }
                if ($Number[0] -eq 0) { return $script:windowsDisk }
                if ($Number[0] -eq 1) { return $script:linuxDisk }
                throw 'Unexpected disk lookup.'
            }
            Mock Get-Partition {
                if (@($DiskNumber).Count -ne 1) { throw 'Expected exactly one disk number.' }
                if ($DiskNumber[0] -eq 0) {
                    if ($script:plan.schemaVersion -eq 4) {
                        return @($script:windows, $script:linux, $script:recovery)
                    }
                    return @($script:windows, $script:recovery)
                }
                if ($DiskNumber[0] -eq 1) { return @($script:source, $script:linux) }
                throw 'Unexpected partition lookup.'
            }
        }

        It 'verifies Linux on the other disk and Recovery on the Windows disk' {
            Test-LibertixDiskGeometry -Plan $script:plan -AlignmentBytes 1MB |
                Should -BeExactly 'windowsDisk=0 linuxDisk=1 linuxPartition=2'
        }

        It 'resolves the original data volume for an offline NTFS consistency check' {
            Mock Get-Partition { $script:source } -ParameterFilter { $DriveLetter[0] -eq 'J' }
            Mock Get-Volume { [pscustomobject]@{ UniqueId = 'volume-data'; FileSystem = 'NTFS' } }
            Mock Get-LibertixNtfsVolumeSerial { '1234567890ABCDEF' }
            Get-LibertixAllocationSourceDrive -Plan $script:plan | Should -BeExactly 'J:'
        }

        It 'refuses the same volume GUID when its NTFS filesystem was replaced' {
            Mock Get-Partition { $script:source } -ParameterFilter { $DriveLetter[0] -eq 'J' }
            Mock Get-Volume { [pscustomobject]@{ UniqueId = 'volume-data'; FileSystem = 'NTFS' } }
            Mock Get-LibertixNtfsVolumeSerial { 'FEDCBA0987654321' }
            { Get-LibertixAllocationSourceDrive -Plan $script:plan } | Should -Throw '*volume identity changed*'
        }

        It 'refuses a non-NTFS filesystem even when its volume GUID is unchanged' {
            Mock Get-Partition { $script:source } -ParameterFilter { $DriveLetter[0] -eq 'J' }
            Mock Get-Volume { [pscustomobject]@{ UniqueId = 'volume-data'; FileSystem = 'exFAT' } }
            Mock Get-LibertixNtfsVolumeSerial { throw 'Must not query NTFS data on exFAT.' }
            { Get-LibertixAllocationSourceDrive -Plan $script:plan } | Should -Throw '*volume identity changed*'
            Should -Invoke Get-LibertixNtfsVolumeSerial -Times 0
        }

        It 'refuses repair of a reformatted data volume at the same offset' {
            Mock Get-Partition { $script:source } -ParameterFilter { $DriveLetter[0] -eq 'J' }
            Mock Get-Volume { [pscustomobject]@{ UniqueId = 'replacement-data' } }
            { Get-LibertixAllocationSourceDrive -Plan $script:plan } | Should -Throw '*volume identity changed*'
        }

        It 'keeps the schema four single-disk path' {
            $script:plan.schemaVersion = 4
            $script:plan.PSObject.Properties.Remove('allocation')
            $script:windows.Size = 80GB
            $script:linux.Offset = 81GB
            $script:plan.disk.installer.offsetBytes = 81GB
            Test-LibertixDiskGeometry -Plan $script:plan -AlignmentBytes 1MB |
                Should -BeExactly 'windowsDisk=0 linuxDisk=0 linuxPartition=2'
            Should -Invoke Get-Disk -Times 0 -ParameterFilter { $Number[0] -eq 1 }
        }

        It 'rejects resized Windows on a separate-disk installation' {
            $script:windows.Size = 99GB
            { Test-LibertixDiskGeometry -Plan $script:plan -AlignmentBytes 1MB } |
                Should -Throw '*Windows size changed*'
        }

        It 'rejects a modified source extent' {
            $script:source.Size = 39GB
            { Test-LibertixDiskGeometry -Plan $script:plan -AlignmentBytes 1MB } |
                Should -Throw '*unexpected gap*'
        }

        It 'rejects Recovery moved on the original Windows disk' {
            $script:recovery.Offset += 1MB
            { Test-LibertixDiskGeometry -Plan $script:plan -AlignmentBytes 1MB } |
                Should -Throw '*Recovery partition geometry changed*'
        }

        It 'rejects matching vendor IDs with a changed Linux disk signature' {
            $script:linuxDisk.Signature = [uint32]::Parse('87654321', [Globalization.NumberStyles]::HexNumber)
            { Test-LibertixDiskGeometry -Plan $script:plan -AlignmentBytes 1MB } |
                Should -Throw '*Disk identity*'
        }

        It 'rejects matching vendor IDs with a changed Windows disk GUID' {
            $script:windowsDisk.Guid = '87654321-1234-1234-1234-123456789abc'
            { Test-LibertixDiskGeometry -Plan $script:plan -AlignmentBytes 1MB } |
                Should -Throw '*Disk identity*'
        }

        It 'rejects missing Linux even if the same extent exists on Windows' {
            Mock Get-Partition {
                if ($DiskNumber[0] -eq 0) { return @($script:windows, $script:recovery, $script:linux) }
                return @($script:source)
            }
            { Test-LibertixDiskGeometry -Plan $script:plan -AlignmentBytes 1MB } |
                Should -Throw '*Linux partition geometry is absent*'
        }

        It 'rejects a missing allocation without falling back to Windows' {
            $script:plan.PSObject.Properties.Remove('allocation')
            { Test-LibertixDiskGeometry -Plan $script:plan -AlignmentBytes 1MB } |
                Should -Throw '*allocation is invalid*'
            Should -Invoke Get-Disk -Times 0
        }

        It 'rejects an allocation on Windows itself' {
            $script:plan.allocation.number = 0
            { Test-LibertixDiskGeometry -Plan $script:plan -AlignmentBytes 1MB } |
                Should -Throw '*allocation is invalid*'
            Should -Invoke Get-Disk -Times 0
        }
    }
}
