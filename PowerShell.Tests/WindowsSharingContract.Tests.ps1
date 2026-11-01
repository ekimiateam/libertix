BeforeDiscovery {
    Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.InstallationPlan.psm1" -Force
}

Describe 'Windows sharing cross-runtime contract' {
    InModuleScope Libertix.InstallationPlan {
        BeforeEach {
            $script:sharing = [pscustomobject]@{
                version = 1
                volumes = @([pscustomobject]@{
                    ntfsUuid = '0123456789ABCDEF'; windowsDrive = 'D:'
                    windowsVolumeId = '\\?\Volume{11111111-1111-1111-1111-111111111111}\'
                    offsetBytes = 1MB; sizeBytes = 64GB
                    disk = [pscustomobject]@{ partitionStyle = 'MBR'; partitionTableId = 'mbr:12345678'
                        sizeBytes = 128GB; logicalSectorSizeBytes = 512 }
                })
                folders = @([pscustomobject]@{
                    shortcut = 'User_Alice_Documents'; profileSid = 'S-1-5-21-1-2-3-1001'
                    ntfsUuid = '0123456789ABCDEF'; relativePath = 'Data/Alice/Documents'
                })
            }
        }
        It 'accepts a related data volume with its actual folder path' {
            Assert-LibertixWindowsSharingPlan -Sharing $script:sharing
        }
        It 'retains an empty inventory for no interactive profiles' {
            $script:sharing.volumes = @(); $script:sharing.folders = @()
            Assert-LibertixWindowsSharingPlan -Sharing $script:sharing
        }
        It 'rejects unsafe relative path <Path>' -ForEach @(
            @{ Path = '../Windows' }, @{ Path = '/Documents' }, @{ Path = 'Data//Documents' },
            @{ Path = 'D:\Documents' }, @{ Path = "Data`nDocuments" }
        ) {
            $script:sharing.folders[0].relativePath = $Path
            { Assert-LibertixWindowsSharingPlan -Sharing $script:sharing } | Should -Throw
        }
        It 'rejects invalid identities: <Change>' -ForEach @(
            @{ Change = 'duplicate-volume' }, @{ Change = 'duplicate-shortcut' }, @{ Change = 'unknown-volume' },
            @{ Change = 'unrelated-volume' }, @{ Change = 'wrong-table' }, @{ Change = 'overflow' }, @{ Change = 'zero-serial' }
        ) {
            switch ($Change) {
                'duplicate-volume' { $script:sharing.volumes += $script:sharing.volumes[0] }
                'duplicate-shortcut' { $script:sharing.folders += $script:sharing.folders[0] }
                'unknown-volume' { $script:sharing.folders[0].ntfsUuid = 'FFFFFFFFFFFFFFFF' }
                'unrelated-volume' { $script:sharing.folders = @() }
                'wrong-table' { $script:sharing.volumes[0].disk.partitionTableId = 'gpt:12345678' }
                'overflow' { $script:sharing.volumes[0].sizeBytes = [long]::MaxValue }
                'zero-serial' { $script:sharing.volumes[0].ntfsUuid = '0000000000000000' }
            }
            { Assert-LibertixWindowsSharingPlan -Sharing $script:sharing } | Should -Throw
        }
    }
}
