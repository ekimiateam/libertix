BeforeAll {
    Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.Rollback.psm1" -Force
    Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.StorageTargets.psm1" -Force
    . "$PSScriptRoot/../Scripts/uefi/Libertix.Uefi.Firmware.ps1"
}

Describe 'UEFI allocation source is checked against the persisted plan' {
    BeforeEach {
        $script:installationPlan = [pscustomobject]@{
            disk = [pscustomobject]@{ systemDrive = $env:SystemDrive; number = 0 }
            allocation = [pscustomobject]@{
                number = 1; uniqueId = 'data-disk'; sizeBytes = 64GB; logicalSectorSizeBytes = 512
                partitionStyle = 'GPT'; partitionTableId = 'gpt:87654321-1234-1234-1234-123456789abc'
                sourceDrive = 'J:'; sourceVolumeId = 'data-volume'
                sourceNtfsUuid = '1234567890ABCDEF'
                sourcePartition = [pscustomobject]@{ number = 2; offsetBytes = 16MB; sizeBytes = 60GB }
            }
        }
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 3 } }
        Mock Get-LibertixVerifiedInstallationTarget {}
        Mock Get-LibertixNtfsVolumeSerial { '1234567890ABCDEF' }
    }

    It 'passes the exact selected disk and NTFS volume identity to the shared verifier' {
        Assert-LibertixAllocationMatchesCurrentStorage
        Should -Invoke Get-LibertixVerifiedInstallationTarget -Times 1 -Exactly -ParameterFilter {
            $SystemPartition.DiskNumber -eq 0 -and $SystemPartition.PartitionNumber -eq 3 -and
            $ExpectedTarget.drive -eq 'J:' -and $ExpectedTarget.diskNumber -eq 1 -and
            $ExpectedTarget.diskUniqueId -eq 'data-disk' -and
            $ExpectedTarget.partitionTableId -eq 'gpt:87654321-1234-1234-1234-123456789abc' -and
            $ExpectedTarget.diskSizeBytes -eq 64GB -and $ExpectedTarget.logicalSectorSizeBytes -eq 512 -and
            $ExpectedTarget.partitionStyle -eq 'GPT' -and $ExpectedTarget.partitionNumber -eq 2 -and
            $ExpectedTarget.offsetBytes -eq 16MB -and $ExpectedTarget.sizeBytes -eq 60GB -and
            $ExpectedTarget.volumeId -eq 'data-volume'
        }
    }

    It 'does nothing for the historical plan without a separate allocation' {
        $script:installationPlan.PSObject.Properties.Remove('allocation')
        Assert-LibertixAllocationMatchesCurrentStorage
        Should -Invoke Get-Partition -Times 0
        Should -Invoke Get-LibertixVerifiedInstallationTarget -Times 0
    }

    It 'refuses <Kind> before probing the volume' -ForEach @(
        @{ Kind = 'a same-disk allocation'; Field = 'number'; Value = 0 },
        @{ Kind = 'an unsupported partition style'; Field = 'partitionStyle'; Value = 'MBR' }
    ) {
        $script:installationPlan.allocation.$Field = $Value
        { Assert-LibertixAllocationMatchesCurrentStorage } | Should -Throw '*separate GPT disk*'
        Should -Invoke Get-Partition -Times 0
    }

    It 'propagates failed storage proof without accepting a fallback volume' {
        Mock Get-LibertixVerifiedInstallationTarget { throw 'volume-changed' }
        { Assert-LibertixAllocationMatchesCurrentStorage } | Should -Throw '*volume-changed*'
        Should -Invoke Get-LibertixVerifiedInstallationTarget -Times 1
    }

    It 'refuses a changed NTFS filesystem on the same disk and partition' {
        Mock Get-LibertixNtfsVolumeSerial { '8765432190ABCDEF' }
        { Assert-LibertixAllocationMatchesCurrentStorage } | Should -Throw '*NTFS filesystem identity changed*'
        Should -Invoke Get-LibertixNtfsVolumeSerial -Times 1 -Exactly -ParameterFilter { $Drive -eq 'J:' }
    }
}

Describe 'UEFI disk proof before decryption and partition preparation' {
    BeforeEach {
        $script:installationPlan = [pscustomobject]@{
            disk = [pscustomobject]@{
                systemDrive = $env:SystemDrive; number = 0; uniqueId = 'vendor-id'
                partitionTableId = 'gpt:12345678-1234-1234-1234-123456789abc'
                partitionStyle = 'GPT'; sizeBytes = 64GB; logicalSectorSizeBytes = 512
                windows = [pscustomobject]@{ number = 3; offsetBytes = 256MB; sizeBytes = 50GB }
                boot = [pscustomobject]@{ number = 1; offsetBytes = 1MB; sizeBytes = 100MB }
                recovery = [pscustomobject]@{ number = 4; offsetBytes = 51GB; sizeBytes = 1GB }
            }
        }
        $disk = [pscustomobject]@{
            Number = 0; UniqueId = 'vendor-id'; Size = 64GB; LogicalSectorSize = 512
            PartitionStyle = 'GPT'; Guid = '12345678-1234-1234-1234-123456789abc'
        }
        $windows = [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 3; Offset = 256MB; Size = 50GB }
        $boot = [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 1; Offset = 1MB; Size = 100MB }
        $recovery = [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 4; Offset = 51GB; Size = 1GB }
        Mock Get-Disk { $disk }
        Mock Get-Partition { @($windows, $boot, $recovery) }
        Mock Get-Partition { $windows } -ParameterFilter { $null -ne $DriveLetter }
    }

    It 'accepts the unchanged disk and partition geometry' {
        { Assert-LibertixPlanMatchesCurrentStorage } | Should -Not -Throw
    }

    It 'rejects a replacement with the same vendor ID and geometry but a different GPT ID' {
        $disk.Guid = '87654321-1234-1234-1234-123456789abc'
        { Assert-LibertixPlanMatchesCurrentStorage } | Should -Throw '*Disk identity*'
        Should -Invoke Get-Partition -Times 1
    }

    It 'rejects a clone connected after the initial compatibility check' {
        $clone = $disk.PSObject.Copy()
        $clone.Number = 2
        Mock Get-Disk { @($disk, $clone) }
        Mock Get-Disk { $disk } -ParameterFilter { $null -ne $Number }
        { Assert-LibertixPlanMatchesCurrentStorage } | Should -Throw '*Multiple disks*'
        Should -Invoke Get-Partition -Times 1
    }

    It 'rejects changed Windows geometry' {
        $windows.Size -= 1GB
        { Assert-LibertixPlanMatchesCurrentStorage } | Should -Throw '*system partition*'
    }

    It 'rejects changed Recovery geometry' {
        $recovery.Offset += 1MB
        { Assert-LibertixPlanMatchesCurrentStorage } | Should -Throw '*recovery partition*'
    }
}
