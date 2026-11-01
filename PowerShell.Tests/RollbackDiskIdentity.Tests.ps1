BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../Scripts/modules/Libertix.Rollback.psm1') -Force
}

Describe 'Rollback capacity refresh retries' {
    InModuleScope Libertix.Rollback {
        BeforeEach {
            $script:capacityReads = 0
            Mock Update-HostStorageCache {}
            Mock Update-Disk {}
            Mock Start-Sleep {}
            Mock Get-Partition { [pscustomobject]@{ Size = 40GB } }
            Mock Get-PartitionSupportedSize {
                $script:capacityReads++
                if ($script:capacityReads -eq 1) { throw 'Storage cache is refreshing.' }
                [pscustomobject]@{ SizeMin = 30GB; SizeMax = 60GB }
            }
        }
        It 'retries a transient read and returns the refreshed capacity' {
            $result = Wait-LibertixSystemDriveResizeCapacity -DriveLetter J -DiskNumber 1 -RequiredSize 60GB
            $result.SizeMax | Should -Be 60GB
            Should -Invoke Get-PartitionSupportedSize -Times 2 -ParameterFilter { $DriveLetter -eq 'J' }
            Should -Invoke Start-Sleep -Times 1
        }
        It 'fails with the volume and deadline when capacity remains unreadable' {
            { Wait-LibertixSystemDriveResizeCapacity -DriveLetter J -DiskNumber 1 -RequiredSize 60GB `
                -TimeoutSeconds 0 } | Should -Throw '*J: did not become readable within 0s*'
            Should -Invoke Get-PartitionSupportedSize -Times 1
            Should -Invoke Start-Sleep -Times 0
        }
    }
}

Describe 'Rollback disk and Windows extent identity' {
    InModuleScope Libertix.Rollback {
        BeforeEach {
            $script:disk = [pscustomobject]@{
                Number = 3; UniqueId = 'repeated-vendor-id'; Size = 64GB
                PartitionStyle = 'GPT'; LogicalSectorSize = 512
                Guid = '12345678-1234-1234-1234-123456789abc'; Signature = 0x12345678
            }
            $script:partition = [pscustomobject]@{
                DiskNumber = 3; Offset = 256MB; Size = 40GB; PartitionNumber = 3
            }
            $planDisk = [pscustomobject]@{
                number = 3; uniqueId = 'repeated-vendor-id'; sizeBytes = 64GB
                partitionStyle = 'GPT'; logicalSectorSizeBytes = 512; systemDrive = 'C:'
                partitionTableId = 'gpt:12345678-1234-1234-1234-123456789abc'
                windows = [pscustomobject]@{ offsetBytes = 256MB; sizeBytes = 60GB }
                sourceNtfsUuid = '1234567890ABCDEF'
            }
            $state = [pscustomobject]@{
                DiskNumber = 3; DiskUniqueId = 'repeated-vendor-id'; SystemDrive = 'C:'
                OriginalCSize = 60GB
            }
            Mock Get-Disk { $script:disk }
            Mock Get-LibertixNtfsVolumeSerial { '1234567890ABCDEF' }
            Mock Get-Partition { $script:partition }
            Mock Wait-LibertixSystemDriveResizeCapacity {
                [pscustomobject]@{ SizeMin = 30GB; SizeMax = 60GB }
            }
            Mock Resize-Partition { $script:partition.Size = 60GB }
        }

        It 'restores the original extent on a nonzero Windows disk' {
            Restore-LibertixSystemDriveInitialSize -State $state -PlanDisk $planDisk
            Should -Invoke Resize-Partition -Times 1 -ParameterFilter { $DriveLetter -eq 'C' -and $Size -eq 60GB }
        }

        It 'does not resize an already restored Windows volume' {
            $script:partition.Size = 60GB
            Restore-LibertixSystemDriveInitialSize -State $state -PlanDisk $planDisk
            Should -Invoke Resize-Partition -Times 0
        }

        It 'replays safely when resize completed but its caller was interrupted' {
            Mock Resize-Partition {
                $script:partition.Size = 60GB
                throw 'Injected interruption after the physical resize.'
            }
            { Restore-LibertixSystemDriveInitialSize -State $state -PlanDisk $planDisk } |
                Should -Throw '*Injected interruption*'
            Restore-LibertixSystemDriveInitialSize -State $state -PlanDisk $planDisk
            Should -Invoke Resize-Partition -Times 1 -Exactly
        }

        It 'does not shrink a source volume expanded beyond the original allocation' {
            $script:partition.Size = 61GB
            { Restore-LibertixSystemDriveInitialSize -State $state -PlanDisk $planDisk } |
                Should -Throw '*refusing rollback shrink*'
            Should -Invoke Resize-Partition -Times 0
        }

        It 'rejects source growth beyond the original extent during the cache wait' {
            Mock Wait-LibertixSystemDriveResizeCapacity {
                $script:partition.Size = 61GB
                [pscustomobject]@{ SizeMin = 30GB; SizeMax = 64GB }
            }
            { Restore-LibertixSystemDriveInitialSize -State $state -PlanDisk $planDisk } |
                Should -Throw '*changed while waiting*'
            Should -Invoke Resize-Partition -Times 0
        }

        It 'does not report success if the source start changed during the resize' {
            Mock Resize-Partition {
                $script:partition.Size = 60GB
                $script:partition.Offset += 1MB
            }
            { Restore-LibertixSystemDriveInitialSize -State $state -PlanDisk $planDisk } |
                Should -Throw '*rollback size verification failed*'
        }

        It 'rejects changed disk <Field> before any resize' -ForEach @(
            @{ Field = 'Guid'; Value = '87654321-1234-1234-1234-123456789abc' },
            @{ Field = 'Number'; Value = 0 },
            @{ Field = 'LogicalSectorSize'; Value = 4096 },
            @{ Field = 'Size'; Value = 128GB }
        ) {
            $script:disk.$Field = $Value
            { Restore-LibertixSystemDriveInitialSize -State $state -PlanDisk $planDisk } |
                Should -Throw '*Disk identity*'
            Should -Invoke Resize-Partition -Times 0
        }

        It 'rejects a changed Windows start even on the original disk' {
            $script:partition.Offset += 1MB
            { Restore-LibertixSystemDriveInitialSize -State $state -PlanDisk $planDisk } |
                Should -Throw '*refusing rollback resize*'
            Should -Invoke Resize-Partition -Times 0
        }

        It 'rejects a saved size inconsistent with the installation plan' {
            $state.OriginalCSize = 61GB
            { Restore-LibertixSystemDriveInitialSize -State $state -PlanDisk $planDisk } |
                Should -Throw '*refusing rollback resize*'
            Should -Invoke Resize-Partition -Times 0
        }

        It 'rechecks disk identity after waiting for Windows storage cache refresh' {
            Mock Wait-LibertixSystemDriveResizeCapacity {
                $script:disk.Guid = '87654321-1234-1234-1234-123456789abc'
                [pscustomobject]@{ SizeMin = 30GB; SizeMax = 60GB }
            }
            { Restore-LibertixSystemDriveInitialSize -State $state -PlanDisk $planDisk } |
                Should -Throw '*Disk identity*'
            Should -Invoke Resize-Partition -Times 0
        }

        It 'checks MBR signature as well as the hardware identifier' {
            $script:disk.PartitionStyle = 'MBR'
            $planDisk.partitionStyle = 'MBR'
            $planDisk.partitionTableId = 'mbr:12345678'
            Assert-LibertixDiskMatchesPlan -Disk $script:disk -PlanDisk $planDisk
            $script:disk.Signature = 0x12345679
            { Assert-LibertixDiskMatchesPlan -Disk $script:disk -PlanDisk $planDisk } |
                Should -Throw '*Disk identity*'
        }

        It 'restores only the selected data volume and verifies its filesystem identity' {
            Mock Get-Volume { [pscustomobject]@{ UniqueId = 'volume-j'; FileSystem = 'NTFS' } }
            Restore-LibertixSourceVolumeInitialSize -SourceDrive 'J:' -PlanDisk $planDisk `
                -SourcePartition $planDisk.windows -ExpectedVolumeId 'volume-j'
            Should -Invoke Resize-Partition -Times 1 -Exactly -ParameterFilter {
                $DriveLetter -eq 'J' -and $Size -eq 60GB
            }
            Should -Invoke Get-Partition -Times 0 -Exactly -ParameterFilter { $DriveLetter -eq 'C' }
            Should -Invoke Get-Volume -Times 3 -Exactly -ParameterFilter { $DriveLetter -eq 'J' }
        }

        It 'refuses a reformatted secondary volume before resizing' {
            Mock Get-Volume { [pscustomobject]@{ UniqueId = 'replacement'; FileSystem = 'NTFS' } }
            { Restore-LibertixSourceVolumeInitialSize -SourceDrive 'J:' -PlanDisk $planDisk `
                -SourcePartition $planDisk.windows -ExpectedVolumeId 'volume-j' } |
                Should -Throw '*filesystem identity changed*'
            Should -Invoke Resize-Partition -Times 0 -Exactly
        }

        It 'refuses a replaced NTFS filesystem despite the unchanged Windows volume identifier' {
            Mock Get-Volume { [pscustomobject]@{ UniqueId = 'volume-j'; FileSystem = 'NTFS' } }
            Mock Get-LibertixNtfsVolumeSerial { '8765432190ABCDEF' }
            { Restore-LibertixSourceVolumeInitialSize -SourceDrive 'J:' -PlanDisk $planDisk `
                -SourcePartition $planDisk.windows -ExpectedVolumeId 'volume-j' } |
                Should -Throw '*source NTFS serial changed*'
            Should -Invoke Resize-Partition -Times 0 -Exactly
        }

        It 'rechecks the secondary volume identity after waiting for free space' {
            $script:volumeId = 'volume-j'
            Mock Get-Volume { [pscustomobject]@{ UniqueId = $script:volumeId; FileSystem = 'NTFS' } }
            Mock Wait-LibertixSystemDriveResizeCapacity {
                $script:volumeId = 'replacement'
                [pscustomobject]@{ SizeMin = 30GB; SizeMax = 60GB }
            }
            { Restore-LibertixSourceVolumeInitialSize -SourceDrive 'J:' -PlanDisk $planDisk `
                -SourcePartition $planDisk.windows -ExpectedVolumeId 'volume-j' } |
                Should -Throw '*filesystem identity changed*'
            Should -Invoke Resize-Partition -Times 0 -Exactly
        }

        It 'does not report success if the secondary volume identity changes during resize' {
            $script:volumeId = 'volume-j'
            Mock Get-Volume { [pscustomobject]@{ UniqueId = $script:volumeId; FileSystem = 'NTFS' } }
            Mock Resize-Partition {
                $script:partition.Size = 60GB
                $script:volumeId = 'replacement'
            }
            { Restore-LibertixSourceVolumeInitialSize -SourceDrive 'J:' -PlanDisk $planDisk `
                -SourcePartition $planDisk.windows -ExpectedVolumeId 'volume-j' } |
                Should -Throw '*filesystem identity changed*'
        }

        It 'refuses an initial source extent outside the recorded disk' {
            $planDisk.windows.sizeBytes = 64GB
            { Restore-LibertixSourceVolumeInitialSize -SourceDrive 'J:' -PlanDisk $planDisk `
                -SourcePartition $planDisk.windows -ExpectedVolumeId 'volume-j' } |
                Should -Throw '*Invalid source volume geometry*'
            Should -Invoke Resize-Partition -Times 0 -Exactly
        }
    }
}
