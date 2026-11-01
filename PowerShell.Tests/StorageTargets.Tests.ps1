BeforeAll {
    Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.StorageTargets.psm1" -Force
}

Describe 'Installation target physical disk selection' {
    BeforeEach {
        $windows = [pscustomobject]@{ DiskNumber = 3; PartitionNumber = 2 }
        $disk = [pscustomobject]@{
            Number = 3; BusType = 'SATA'; PartitionStyle = 'GPT'; HealthStatus = 'Healthy'
            IsOffline = $false; IsReadOnly = $false; IsBoot = $true; IsSystem = $true
            Guid = '{12345678-1234-1234-1234-123456789abc}'
        }
        $partition = [pscustomobject]@{
            DiskNumber = 3; PartitionNumber = 2; DriveLetter = 'C'
            IsReadOnly = $false; IsHidden = $false; IsOffline = $false
            GptType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'; MbrType = 7
        }
    }

    It 'retains the actual Windows partition as the default candidate' {
        Test-LibertixTargetPartitionCandidate -Disk $disk -Partition $partition `
            -SystemPartition $windows | Should -BeTrue
    }

    It 'does not offer a second drive letter on the Windows physical disk' {
        $partition.PartitionNumber = 4
        $partition.DriveLetter = 'D'
        Test-LibertixTargetPartitionCandidate -Disk $disk -Partition $partition `
            -SystemPartition $windows | Should -BeFalse
    }

    It 'offers a data partition on a distinct basic disk regardless of its letter' {
        $disk.Number = 0
        $disk.IsBoot = $false
        $disk.IsSystem = $false
        $partition.DiskNumber = 0
        $partition.DriveLetter = 'J'
        Test-LibertixTargetPartitionCandidate -Disk $disk -Partition $partition `
            -SystemPartition $windows | Should -BeTrue
    }

    It 'ignores unsupported storage bus <Bus>' -ForEach @(
        @{ Bus = 'USB' }, @{ Bus = 'SD' }, @{ Bus = 'iSCSI' },
        @{ Bus = 'RAID' }, @{ Bus = 'Spaces' }, @{ Bus = 'File Backed Virtual' }
    ) {
        $disk.BusType = $Bus
        Test-LibertixTargetPartitionCandidate -Disk $disk -Partition $partition `
            -SystemPartition $windows | Should -BeFalse
    }

    It 'does not offer an OEM recovery partition even if it has a drive letter' {
        $partition.GptType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
        Test-LibertixTargetPartitionCandidate -Disk $disk -Partition $partition `
            -SystemPartition $windows | Should -BeFalse
    }

    It 'refuses an offline or read-only disk' {
        $disk.IsOffline = $true
        Test-LibertixTargetPartitionCandidate -Disk $disk -Partition $partition `
            -SystemPartition $windows | Should -BeFalse
        $disk.IsOffline = $false
        $disk.IsReadOnly = $true
        Test-LibertixTargetPartitionCandidate -Disk $disk -Partition $partition `
            -SystemPartition $windows | Should -BeFalse
    }

    It 'uses the actual GPT identifier independently of a repeated vendor ID' {
        Get-LibertixTargetDiskIdentity -Disk $disk | Should -Be 'gpt:12345678-1234-1234-1234-123456789abc'
        $disk.Guid = [guid]::Empty
        { Get-LibertixTargetDiskIdentity -Disk $disk } | Should -Throw '*GPT identity*'
    }

    It 'does not offer an existing MBR logical partition' {
        $disk.PartitionStyle = 'MBR'
        $disk.Number = 0
        $disk.IsBoot = $false
        $disk.IsSystem = $false
        $partition.DiskNumber = 0
        $partition.PartitionNumber = 5
        Test-LibertixTargetPartitionCandidate -Disk $disk -Partition $partition `
            -SystemPartition $windows | Should -BeFalse
    }
}

Describe 'Installation target verification before use' {
    BeforeEach {
        Mock Get-LibertixStorageControllerNames -ModuleName Libertix.StorageTargets { @('Standard SATA AHCI Controller') }
        $windows = [pscustomobject]@{ DiskNumber = 3; PartitionNumber = 2 }
        $selectedDisk = [pscustomobject]@{
            Number = 0; UniqueId = 'vendor-id'; Guid = '87654321-1234-1234-1234-123456789abc'
            Size = 64GB; LogicalSectorSize = 512; PartitionStyle = 'GPT'; BusType = 'SATA'
            HealthStatus = 'Healthy'; IsOffline = $false; IsReadOnly = $false
            IsBoot = $false; IsSystem = $false
        }
        $selectedPartition = [pscustomobject]@{
            DiskNumber = 0; PartitionNumber = 2; DriveLetter = 'J'; Offset = 1MB; Size = 60GB
            GptType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'; MbrType = 7
            IsReadOnly = $false; IsHidden = $false; IsOffline = $false
        }
        $selectedVolume = [pscustomobject]@{
            UniqueId = 'volume-data'; FileSystemType = 'NTFS'; HealthStatus = 'Healthy'
        }
        $expected = [pscustomobject]@{
            drive = 'J:'; diskNumber = 0; diskUniqueId = 'vendor-id'; diskSizeBytes = 64GB
            logicalSectorSizeBytes = 512; partitionStyle = 'GPT'
            partitionTableId = 'gpt:87654321-1234-1234-1234-123456789abc'
            partitionNumber = 2; offsetBytes = 1MB; sizeBytes = 60GB; volumeId = 'volume-data'
        }
        Mock Get-Disk -ModuleName Libertix.StorageTargets { $selectedDisk }
        Mock Get-Partition -ModuleName Libertix.StorageTargets { $selectedPartition }
        Mock Get-Volume -ModuleName Libertix.StorageTargets { $selectedVolume }
        Mock Get-PartitionSupportedSize -ModuleName Libertix.StorageTargets {
            [pscustomobject]@{ SizeMin = 24GB; SizeMax = 60GB }
        }
    }

    It 'rechecks the selected volume and returns current shrink limits' {
        $verified = Get-LibertixVerifiedInstallationTarget -ExpectedTarget $expected -SystemPartition $windows
        $verified.Disk.Number | Should -Be 0
        $verified.Partition.DriveLetter | Should -Be 'J'
        $verified.Limits.SizeMin | Should -Be 24GB
        Should -Invoke Get-LibertixStorageControllerNames -ModuleName Libertix.StorageTargets `
            -Times 1 -Exactly -ParameterFilter { $DiskNumber -eq 0 -and $RequireSupported }
    }

    It 'rejects a selected target with unproven controller support before shrink queries' {
        Mock Get-LibertixStorageControllerNames -ModuleName Libertix.StorageTargets { throw 'CONTROLLER_UNPROVEN' }
        { Get-LibertixVerifiedInstallationTarget -ExpectedTarget $expected -SystemPartition $windows } |
            Should -Throw '*CONTROLLER_UNPROVEN*'
        Should -Invoke Get-PartitionSupportedSize -ModuleName Libertix.StorageTargets -Times 0
    }

    It 'rejects a selected disk whose <Field> changed' -ForEach @(
        @{ Field = 'Guid'; Value = '12345678-1234-1234-1234-123456789abc' },
        @{ Field = 'Size'; Value = 128GB },
        @{ Field = 'LogicalSectorSize'; Value = 4096 },
        @{ Field = 'UniqueId'; Value = 'replacement-vendor-id' }
    ) {
        $selectedDisk.$Field = $Value
        { Get-LibertixVerifiedInstallationTarget -ExpectedTarget $expected -SystemPartition $windows } |
            Should -Throw '*changed since compatibility*'
        Should -Invoke Get-PartitionSupportedSize -ModuleName Libertix.StorageTargets -Times 0
    }

    It 'rejects a volume reformatted in the same partition' {
        $selectedVolume.UniqueId = 'replacement-volume'
        { Get-LibertixVerifiedInstallationTarget -ExpectedTarget $expected -SystemPartition $windows } |
            Should -Throw '*NTFS volume no longer matches*'
    }

    It 'rejects changed source geometry before checking shrink limits' {
        $selectedPartition.Offset += 1MB
        { Get-LibertixVerifiedInstallationTarget -ExpectedTarget $expected -SystemPartition $windows } |
            Should -Throw '*changed since compatibility*'
        Should -Invoke Get-PartitionSupportedSize -ModuleName Libertix.StorageTargets -Times 0
    }

    It 'does not silently accept a USB clone with the same partition-table identity' {
        Mock Get-Disk -ModuleName Libertix.StorageTargets {
            $selectedDisk
            [pscustomobject]@{ Number = 4; PartitionStyle = 'GPT'; Guid = $selectedDisk.Guid; BusType = 'USB' }
        }
        { Get-LibertixVerifiedInstallationTarget -ExpectedTarget $expected -SystemPartition $windows } |
            Should -Throw '*Multiple disks*'
    }

    It 'rejects a target that became read-only' {
        $selectedDisk.IsReadOnly = $true
        { Get-LibertixVerifiedInstallationTarget -ExpectedTarget $expected -SystemPartition $windows } |
            Should -Throw '*not a supported local data volume*'
    }

    It 'rejects invalid shrink limits rather than guessing an available size' {
        Mock Get-PartitionSupportedSize -ModuleName Libertix.StorageTargets {
            [pscustomobject]@{ SizeMin = 0 }
        }
        { Get-LibertixVerifiedInstallationTarget -ExpectedTarget $expected -SystemPartition $windows } |
            Should -Throw '*no verified shrink limit*'
    }
}

Describe 'Installation target inventory failures' {
    BeforeEach {
        Mock Get-LibertixStorageControllerNames -ModuleName Libertix.StorageTargets { @('Standard SATA AHCI Controller') }
        $windows = [pscustomobject]@{ DiskNumber = 3; PartitionNumber = 2 }
        $disks = @(0, 3 | ForEach-Object {
            [pscustomobject]@{
                Number = $_; BusType = 'SATA'; PartitionStyle = 'GPT'; HealthStatus = 'Healthy'
                IsOffline = $false; IsReadOnly = $false; IsBoot = ($_ -eq 3); IsSystem = ($_ -eq 3)
                Guid = ('12345678-1234-1234-1234-123456789ab' + $_)
                UniqueId = 'vendor-id'; Path = ('disk-' + $_); SerialNumber = ('serial-' + $_)
                Size = 64GB; LogicalSectorSize = 512; FriendlyName = 'Test disk'
            }
        })
        Mock Get-Partition -ModuleName Libertix.StorageTargets {
            [pscustomobject]@{
                DiskNumber = [int]$DiskNumber[0]; PartitionNumber = 2
                DriveLetter = $(if ($DiskNumber -eq 3) { 'C' } else { 'J' })
                IsReadOnly = $false; IsHidden = $false; IsOffline = $false
                GptType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'; MbrType = 7
                Offset = 1MB; Size = 60GB
            }
        }
        Mock Get-Volume -ModuleName Libertix.StorageTargets {
            [pscustomobject]@{
                FileSystemType = 'NTFS'; HealthStatus = 'Healthy'; SizeRemaining = 40GB
                UniqueId = 'test-volume'
            }
        }
        Mock Get-PartitionSupportedSize -ModuleName Libertix.StorageTargets {
            [pscustomobject]@{ SizeMin = 24GB }
        }
    }

    It 'returns the Windows volume and the separate data volume' {
        $targets = @(Get-LibertixInstallationTargetInventory -SystemPartition $windows -Disks $disks)
        $targets.Count | Should -Be 2
        @($targets | Where-Object isWindows).drive | Should -BeExactly 'C:'
        @($targets | Where-Object { -not $_.isWindows }).drive | Should -BeExactly 'J:'
    }

    It 'keeps the Windows download inventory when its four MBR slots are occupied' {
        foreach ($disk in $disks) {
            $disk.PartitionStyle = 'MBR'
            $disk | Add-Member Signature ([uint32](305419896 + $disk.Number))
        }
        Mock Get-Partition -ModuleName Libertix.StorageTargets {
            $number = [int]$DiskNumber[0]
            [pscustomobject]@{
                DiskNumber = $number; PartitionNumber = 2
                DriveLetter = $(if ($number -eq 3) { 'C' } else { 'J' })
                IsReadOnly = $false; IsHidden = $false; IsOffline = $false
                MbrType = 7; Offset = 1MB; Size = 60GB
            }
            if ($number -eq 3) {
                foreach ($part in @(1, 3, 4)) {
                    [pscustomobject]@{ DiskNumber = 3; PartitionNumber = $part; MbrType = 39 }
                }
            }
        }
        $targets = @(Get-LibertixInstallationTargetInventory -SystemPartition $windows -Disks $disks)
        $targets.Count | Should -Be 2
        @($targets | Where-Object isWindows).drive | Should -BeExactly 'C:'
    }

    It 'ignores an optional volume whose resize limits cannot be established' {
        Mock Get-PartitionSupportedSize -ModuleName Libertix.StorageTargets {
            throw 'Optional volume is locked.'
        } -ParameterFilter { $DiskNumber[0] -eq 0 }
        $targets = @(Get-LibertixInstallationTargetInventory -SystemPartition $windows -Disks $disks)
        $targets.Count | Should -Be 1
        $targets[0].drive | Should -BeExactly 'C:'
    }

    It 'does not offer an optional disk whose controller support is unproven' {
        Mock Get-LibertixStorageControllerNames -ModuleName Libertix.StorageTargets {
            throw 'CONTROLLER_UNPROVEN'
        }
        $targets = @(Get-LibertixInstallationTargetInventory -SystemPartition $windows -Disks $disks)
        $targets.Count | Should -Be 1
        $targets[0].drive | Should -BeExactly 'C:'
        Should -Invoke Get-Partition -ModuleName Libertix.StorageTargets -Times 0 `
            -ParameterFilter { $DiskNumber[0] -eq 0 }
    }

    It 'does not hide a failure to inspect the actual Windows volume' {
        Mock Get-PartitionSupportedSize -ModuleName Libertix.StorageTargets {
            throw 'System volume is unavailable.'
        } -ParameterFilter { $DiskNumber[0] -eq 3 }
        { Get-LibertixInstallationTargetInventory -SystemPartition $windows -Disks $disks } |
            Should -Throw '*System volume is unavailable*'
    }

    It 'never enumerates the partitions of an unrelated USB disk' {
        $disks[0].BusType = 'USB'
        $targets = @(Get-LibertixInstallationTargetInventory -SystemPartition $windows -Disks $disks)
        $targets.Count | Should -Be 1
        Should -Invoke Get-Partition -ModuleName Libertix.StorageTargets -Exactly -Times 0 `
            -ParameterFilter { $DiskNumber[0] -eq 0 }
    }

    It 'does not offer a data disk when an attached USB clone makes its identity ambiguous' {
        $clone = $disks[0].PSObject.Copy()
        $clone.Number = 4
        $clone.BusType = 'USB'
        $clone.IsOffline = $true
        $clone.Size = 128GB
        $targets = @(Get-LibertixInstallationTargetInventory -SystemPartition $windows -Disks ($disks + $clone))
        $targets.Count | Should -Be 1
        $targets[0].drive | Should -BeExactly 'C:'
        Should -Invoke Get-Partition -ModuleName Libertix.StorageTargets -Times 0 `
            -ParameterFilter { $DiskNumber[0] -ne 3 }
    }

    It 'never hides an ambiguous Windows disk identity from the inventory caller' {
        $disks[0].Guid = $disks[1].Guid
        { Get-LibertixInstallationTargetInventory -SystemPartition $windows -Disks $disks } |
            Should -Throw '*Multiple disks*'
        Should -Invoke Get-Partition -ModuleName Libertix.StorageTargets -Times 0
    }

    It 'does not offer an optional MBR disk with an existing extended container' {
        $disks[0].PartitionStyle = 'MBR'
        $disks[0] | Add-Member -NotePropertyName Signature -NotePropertyValue 123
        Mock Get-Partition -ModuleName Libertix.StorageTargets {
            @(
                [pscustomobject]@{ MbrType = 15 },
                [pscustomobject]@{ MbrType = 7 }
            )
        } -ParameterFilter { $DiskNumber[0] -eq 0 }
        $targets = @(Get-LibertixInstallationTargetInventory -SystemPartition $windows -Disks $disks)
        $targets.Count | Should -Be 1
        $targets[0].drive | Should -BeExactly 'C:'
    }
}
