BeforeDiscovery {
    Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.StorageBaseline.psm1" -Force
}

BeforeAll {
    Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.StorageBaseline.psm1" -Force
}

Describe 'Product storage inventory and uninstall boundary' {
    InModuleScope Libertix.StorageBaseline {
        BeforeEach {
            $script:disks = @(0..2 | ForEach-Object {
                [pscustomobject]@{
                    Number = $_; UniqueId = "disk-$_"; Size = 80GB; PartitionStyle = 'GPT'
                    IsOffline = $false; IsReadOnly = $false
                    LogicalSectorSize = 512; PhysicalSectorSize = 4096
                    Guid = "12345678-1234-1234-1234-12345678900$_"; Signature = 0
                }
            })
            $script:partitions = @{}
            foreach ($disk in $script:disks) {
                $script:partitions[$disk.Number] = @(0..1 | ForEach-Object {
                    [pscustomobject]@{
                        PartitionNumber = $_ + 1
                        Offset = if ($_ -eq 0) { 1MB } else { 61GB }
                        Size = if ($_ -eq 0) { 60GB } else { 1GB }
                        Guid = "abcdef00-1234-1234-1234-12345678900$_"
                        GptType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'; MbrType = 0
                        IsActive = $false; IsHidden = ($_ -eq 1); IsReadOnly = $false
                        NoDefaultDriveLetter = ($_ -eq 1); AccessPaths = @()
                    }
                })
            }
            $plan = [pscustomobject]@{
                schemaVersion = 4; planId = 'baseline-test'
                disk = [pscustomobject]@{
                    number = 0; uniqueId = 'disk-0'; sizeBytes = 80GB; partitionStyle = 'GPT'
                    logicalSectorSizeBytes = 512; partitionTableId = 'gpt:12345678-1234-1234-1234-123456789000'
                    systemDrive = 'C:'; windows = [pscustomobject]@{ offsetBytes = 1MB; sizeBytes = 60GB }
                    installer = [pscustomobject]@{
                        finalOffsetBytes = 40GB + 1MB; finalSizeBytes = 20GB
                        offsetBytes = 40GB + 1MB; resizeMode = 'windows-online'
                    }
                }
            }
            Mock Get-Disk {
                if ($null -ne $Number -and @($Number).Count -gt 0) {
                    $found = @($script:disks | Where-Object Number -EQ $Number[0])
                    if ($found.Count -eq 0) { throw 'DISK_MISSING' }
                    return $found
                }
                $script:disks
            }
            Mock Get-Partition { $script:partitions[[int]$DiskNumber[0]] }
            Mock Get-Volume { [pscustomobject]@{ UniqueId = "volume-$DriveLetter"; FileSystem = 'NTFS' } }
            Mock Get-LibertixNtfsVolumeSerial { '0123456789ABCDEF' }
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $root
        }

        It 'captures all visible disks but does not query a removed unrelated disk during uninstall' {
            Save-LibertixStorageBaseline -Plan $plan -RecoveryRoot $root
            $baseline = Get-Content "$root/storage-before-installation.json" -Raw | ConvertFrom-Json
            $baseline.disks.Count | Should -Be 3
            $script:disks = @($script:disks[0])
            { Assert-LibertixStorageBaseline -Plan $plan -Baseline $baseline -Restored } | Should -Not -Throw
            Should -Invoke Get-Disk -ParameterFilter { $null -ne $Number -and @($Number).Count -gt 0 -and $Number[0] -ne 0 } -Times 0
        }

        It 'never overwrites the original inventory on retry' {
            Save-LibertixStorageBaseline -Plan $plan -RecoveryRoot $root
            $hash = (Get-FileHash "$root/storage-before-installation.json").Hash
            { Save-LibertixStorageBaseline -Plan $plan -RecoveryRoot $root } | Should -Throw '*already exists*'
            (Get-FileHash "$root/storage-before-installation.json").Hash | Should -Be $hash
        }

        It 'refuses an affected disk missing before uninstall' {
            Save-LibertixStorageBaseline -Plan $plan -RecoveryRoot $root
            $baseline = Get-Content "$root/storage-before-installation.json" -Raw | ConvertFrom-Json
            $script:disks = @($script:disks[1], $script:disks[2])
            { Assert-LibertixStorageBaseline -Plan $plan -Baseline $baseline } | Should -Throw '*DISK_MISSING*'
        }

        It 'refuses an affected disk that became read-only before uninstall' {
            Save-LibertixStorageBaseline -Plan $plan -RecoveryRoot $root
            $baseline = Get-Content "$root/storage-before-installation.json" -Raw | ConvertFrom-Json
            $script:disks[0].IsReadOnly = $true
            { Assert-LibertixStorageBaseline -Plan $plan -Baseline $baseline } | Should -Throw '*read-only*'
        }

        It 'records an unreadable unrelated medium without blocking the installation' {
            Mock Get-Partition { throw 'UNRELATED_MEDIA_UNREADABLE' } -ParameterFilter { $DiskNumber[0] -eq 2 }
            Save-LibertixStorageBaseline -Plan $plan -RecoveryRoot $root
            $baseline = Get-Content "$root/storage-before-installation.json" -Raw | ConvertFrom-Json
            $baseline.disks[2].inventoryError | Should -Match 'UNRELATED_MEDIA_UNREADABLE'
            { Assert-LibertixStorageBaseline -Plan $plan -Baseline $baseline -Restored } | Should -Not -Throw
        }

        It 'refuses a changed OEM partition field <Field>' -TestCases @(
            @{ Field = 'Offset'; Value = 62GB }, @{ Field = 'Size'; Value = 500MB },
            @{ Field = 'Guid'; Value = 'replacement' }, @{ Field = 'GptType'; Value = 'replacement' },
            @{ Field = 'IsHidden'; Value = $false }, @{ Field = 'IsReadOnly'; Value = $true },
            @{ Field = 'NoDefaultDriveLetter'; Value = $false }
        ) {
            param($Field, $Value)
            Save-LibertixStorageBaseline -Plan $plan -RecoveryRoot $root
            $baseline = Get-Content "$root/storage-before-installation.json" -Raw | ConvertFrom-Json
            $script:partitions[0][1].$Field = $Value
            { Assert-LibertixStorageBaseline -Plan $plan -Baseline $baseline } | Should -Throw
        }

        It 'accepts partition renumbering without accepting a moved partition' {
            Save-LibertixStorageBaseline -Plan $plan -RecoveryRoot $root
            $baseline = Get-Content "$root/storage-before-installation.json" -Raw | ConvertFrom-Json
            $script:partitions[0][1].PartitionNumber = 7
            { Assert-LibertixStorageBaseline -Plan $plan -Baseline $baseline -Restored } | Should -Not -Throw
        }

        It 'allows only the planned Linux extent before rollback and requires its absence afterwards' {
            Save-LibertixStorageBaseline -Plan $plan -RecoveryRoot $root
            $baseline = Get-Content "$root/storage-before-installation.json" -Raw | ConvertFrom-Json
            $linux = $script:partitions[0][0].PSObject.Copy()
            $linux.Offset = 40GB + 1MB; $linux.Size = 20GB
            $linux.Guid = 'owned-linux'; $linux.GptType = '{0fc63daf-8483-4772-8e79-3d69d8477de4}'
            $script:partitions[0][0].Size = 40GB
            $script:partitions[0] += $linux
            { Assert-LibertixStorageBaseline -Plan $plan -Baseline $baseline } | Should -Not -Throw
            { Assert-LibertixStorageBaseline -Plan $plan -Baseline $baseline -Restored } | Should -Throw
            $script:partitions[0][0].Size = 41GB
            { Assert-LibertixStorageBaseline -Plan $plan -Baseline $baseline } | Should -Throw '*overlaps*'
            $script:partitions[0][0].Size = 40GB
            $linux.GptType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
            { Assert-LibertixStorageBaseline -Plan $plan -Baseline $baseline } | Should -Throw '*unexpected partition*'
        }

        It 'verifies the secondary source independently of Windows' {
            $plan.schemaVersion = 5
            $allocation = [pscustomobject]@{
                number = 1; uniqueId = 'disk-1'; sizeBytes = 80GB; partitionStyle = 'GPT'
                logicalSectorSizeBytes = 512; partitionTableId = 'gpt:12345678-1234-1234-1234-123456789001'
                sourceDrive = 'D:'; sourcePartition = [pscustomobject]@{ offsetBytes = 1MB; sizeBytes = 60GB }
            }
            $plan | Add-Member -NotePropertyName allocation -NotePropertyValue $allocation
            Save-LibertixStorageBaseline -Plan $plan -RecoveryRoot $root
            $baseline = Get-Content "$root/storage-before-installation.json" -Raw | ConvertFrom-Json
            $script:partitions[1][0].Size = 40GB
            { Assert-LibertixStorageBaseline -Plan $plan -Baseline $baseline } | Should -Not -Throw
            { Assert-LibertixStorageBaseline -Plan $plan -Baseline $baseline -Restored } | Should -Throw '*size changed*'
            $script:partitions[1][0].Size = 60GB
            { Assert-LibertixStorageBaseline -Plan $plan -Baseline $baseline -Restored } | Should -Not -Throw
        }

        It 'refuses a source filesystem replaced without changing its partition geometry' {
            Save-LibertixStorageBaseline -Plan $plan -RecoveryRoot $root
            $baseline = Get-Content "$root/storage-before-installation.json" -Raw | ConvertFrom-Json
            Mock Get-LibertixNtfsVolumeSerial { 'FEDCBA9876543210' }
            { Assert-LibertixStorageBaseline -Plan $plan -Baseline $baseline } | Should -Throw '*NTFS volume*'
        }

        It 'accepts only the exact new MBR logical container and rejects it after restoration' {
            $plan.disk.partitionStyle = 'MBR'; $plan.disk.partitionTableId = 'mbr:12345678'
            $script:disks[0].PartitionStyle = 'MBR'; $script:disks[0].Guid = ''
            $script:disks[0].Signature = 0x12345678
            foreach ($partition in $script:partitions[0]) {
                $partition.Guid = ''; $partition.GptType = ''; $partition.MbrType = 7
            }
            Save-LibertixStorageBaseline -Plan $plan -RecoveryRoot $root
            $baseline = Get-Content "$root/storage-before-installation.json" -Raw | ConvertFrom-Json
            $script:partitions[0][0].Size = 40GB - 1MB
            $container = $script:partitions[0][0].PSObject.Copy()
            $container.Offset = 40GB; $container.Size = 20GB + 1MB; $container.MbrType = 15
            $linux = $container.PSObject.Copy()
            $linux.Offset = 40GB + 1MB; $linux.Size = 20GB; $linux.MbrType = 131
            $script:partitions[0] += @($container, $linux)
            { Assert-LibertixStorageBaseline -Plan $plan -Baseline $baseline } | Should -Not -Throw
            { Assert-LibertixStorageBaseline -Plan $plan -Baseline $baseline -Restored } | Should -Throw
            $container.Size += 1MB
            { Assert-LibertixStorageBaseline -Plan $plan -Baseline $baseline } | Should -Throw '*unexpected partition*'
        }

        It 'uses the observed MBR offset online and the final offset offline (<Mode>)' -TestCases @(
            @{ Mode = 'windows-online'; Offset = 40GB },
            @{ Mode = 'live-offline'; Offset = 40GB + 1MB }
        ) {
            param($Mode, $Offset)
            $plan.disk.partitionStyle = 'MBR'; $plan.disk.partitionTableId = 'mbr:12345678'
            $plan.disk.installer.resizeMode = $Mode
            $plan.disk.installer.offsetBytes = 40GB
            $script:disks[0].PartitionStyle = 'MBR'; $script:disks[0].Guid = ''
            $script:disks[0].Signature = 0x12345678
            foreach ($partition in $script:partitions[0]) {
                $partition.Guid = ''; $partition.GptType = ''; $partition.MbrType = 7
            }
            Save-LibertixStorageBaseline -Plan $plan -RecoveryRoot $root
            $baseline = Get-Content "$root/storage-before-installation.json" -Raw | ConvertFrom-Json
            $linux = $script:partitions[0][0].PSObject.Copy()
            $linux.Offset = $Offset; $linux.Size = 20GB; $linux.MbrType = 131
            $script:partitions[0][0].Size = $Offset - 1MB
            $script:partitions[0] += $linux
            { Assert-LibertixStorageBaseline -Plan $plan -Baseline $baseline } | Should -Not -Throw
            $linux.Offset += 512
            { Assert-LibertixStorageBaseline -Plan $plan -Baseline $baseline } | Should -Throw '*unexpected partition*'
        }
    }
}
