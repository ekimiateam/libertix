BeforeAll {
    Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.StorageTargets.psm1" -Force
}

Describe 'Selected allocation records freshly verified source identity' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $windows = [pscustomobject]@{ DiskNumber = 3; PartitionNumber = 2 }
        $expected = [pscustomobject]@{ drive = 'J:' }
        $disk = [pscustomobject]@{
            Number = 0; UniqueId = 'vendor-id'; Size = 64GB; LogicalSectorSize = 512
            PartitionStyle = 'GPT'; Guid = '12345678-1234-1234-1234-123456789abc'
        }
        $partition = [pscustomobject]@{
            DiskNumber = 0; PartitionNumber = 2; DriveLetter = 'J'; Offset = 1MB; Size = 60GB
        }
        Mock Get-LibertixVerifiedInstallationTarget -ModuleName Libertix.StorageTargets {
            [pscustomobject]@{
                Disk = $disk; Partition = $partition
                Volume = [pscustomobject]@{ UniqueId = 'verified-volume-id' }
            }
        }
        Mock Get-LibertixTargetVolumeEncryptionState -ModuleName Libertix.StorageTargets {
            'EncryptedOrProtected'
        }
        Mock Get-LibertixNtfsVolumeSerial -ModuleName Libertix.StorageTargets { '1234567890ABCDEF' }
    }

    It 'records the donor without changing the Windows disk or assuming encryption is off' {
        $result = Get-LibertixInstallationAllocation -ExpectedTarget $expected `
            -SystemPartition $windows -RequiredPartitionStyle GPT
        $result.number | Should -Be 0
        $result.sourceDrive | Should -Be 'J:'
        $result.sourceVolumeId | Should -Be 'verified-volume-id'
        $result.sourceNtfsUuid | Should -Be '1234567890ABCDEF'
        $result.partitionTableId | Should -Be 'gpt:12345678-1234-1234-1234-123456789abc'
        $result.sourcePartition.number | Should -Be 2
        $result.sourcePartition.offsetBytes | Should -Be 1MB
        $result.sourcePartition.sizeBytes | Should -Be 60GB
        $result.sizeBytes | Should -Be 64GB
        $result.logicalSectorSizeBytes | Should -Be 512
        $result.sourceBitLockerState | Should -Be 'EncryptedOrProtected'
        $windows.DiskNumber | Should -Be 3
        Should -Invoke Get-LibertixVerifiedInstallationTarget -ModuleName Libertix.StorageTargets `
            -Times 1 -Exactly -ParameterFilter {
                $ExpectedTarget -eq $expected -and $SystemPartition -eq $windows
            }
        Should -Invoke Get-LibertixTargetVolumeEncryptionState -ModuleName Libertix.StorageTargets `
            -Times 1 -Exactly -ParameterFilter { $Drive -eq 'J:' }
        Should -Invoke Get-LibertixNtfsVolumeSerial -ModuleName Libertix.StorageTargets `
            -Times 1 -Exactly -ParameterFilter { $Drive -eq 'J:' }
    }

    It 'retains the schema-four default without treating Windows as a donor' {
        $disk.Number = 3
        $partition.DiskNumber = 3
        $partition.DriveLetter = 'C'
        Get-LibertixInstallationAllocation -ExpectedTarget $expected `
            -SystemPartition $windows -RequiredPartitionStyle GPT | Should -BeNullOrEmpty
        Should -Invoke Get-LibertixTargetVolumeEncryptionState -ModuleName Libertix.StorageTargets -Times 0
    }

    It 'refuses another partition on the Windows disk even if the lower verifier returns it' {
        $disk.Number = 3
        $partition.PartitionNumber = 4
        { Get-LibertixInstallationAllocation -ExpectedTarget $expected `
            -SystemPartition $windows -RequiredPartitionStyle GPT } | Should -Throw '*not a separate*'
    }

    It 'refuses an unsupported mixed partition style before querying encryption' {
        { Get-LibertixInstallationAllocation -ExpectedTarget $expected `
            -SystemPartition $windows -RequiredPartitionStyle MBR } | Should -Throw '*not supported*'
        Should -Invoke Get-LibertixTargetVolumeEncryptionState -ModuleName Libertix.StorageTargets -Times 0
    }

    It 'does not create allocation metadata after an identity failure' {
        Mock Get-LibertixVerifiedInstallationTarget -ModuleName Libertix.StorageTargets {
            throw 'selected-source-changed'
        }
        { Get-LibertixInstallationAllocation -ExpectedTarget $expected `
            -SystemPartition $windows -RequiredPartitionStyle GPT } | Should -Throw '*selected-source-changed*'
        Should -Invoke Get-LibertixTargetVolumeEncryptionState -ModuleName Libertix.StorageTargets -Times 0
    }

    It 'does not create allocation metadata when the NTFS serial cannot be read' {
        Mock Get-LibertixNtfsVolumeSerial -ModuleName Libertix.StorageTargets { throw 'ntfs-query-failed' }
        { Get-LibertixInstallationAllocation -ExpectedTarget $expected `
            -SystemPartition $windows -RequiredPartitionStyle GPT } | Should -Throw '*ntfs-query-failed*'
    }
}
