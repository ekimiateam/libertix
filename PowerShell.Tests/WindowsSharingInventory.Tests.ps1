BeforeDiscovery {
    Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.WindowsSharingInventory.psm1" -Force
}

Describe 'User-specific Windows sharing paths' {
    InModuleScope Libertix.WindowsSharingInventory {
        It 'expands variables from the owning profile rather than the installer account' {
            Expand-LibertixProfileFolderPath -Value '%USERPROFILE%\Documents' `
                -ProfilePath 'D:\Profiles\Bob' -EnvironmentValues @{} |
                Should -BeExactly 'D:\Profiles\Bob\Documents'
            Expand-LibertixProfileFolderPath -Value '%OneDrive%\Pictures' `
                -ProfilePath 'D:\Profiles\Bob' -EnvironmentValues @{ OneDrive = '%USERPROFILE%\Cloud' } |
                Should -BeExactly 'D:\Profiles\Bob\Cloud\Pictures'
        }

        It 'rejects unsupported or unresolved path <Value>' -ForEach @(
            @{ Value = '%UNKNOWN%\Documents' }, @{ Value = '%LOOP%\Documents' },
            @{ Value = '\\server\documents' }, @{ Value = 'D:Documents' },
            @{ Value = 'D:\Data\..\Windows' }, @{ Value = 'D:\Data:stream' }
        ) {
            { Expand-LibertixProfileFolderPath -Value $Value -ProfilePath 'C:\Users\Alice' `
                -EnvironmentValues @{ LOOP = '%LOOP%' } } | Should -Throw
        }

        BeforeEach {
            $script:profile = [pscustomobject]@{
                SID = 'S-1-5-21-1-2-3-1001'; LocalPath = 'C:\Users\Alice'; Loaded = $true
            }
            Mock Get-LibertixWindowsUserProfiles { $script:profile }
            Mock Get-LibertixProfileFolderValues {
                [pscustomobject]@{ Folders = @{ Personal = 'D:\Data\Alice\Documents' }; Environment = @{} }
            }
            Mock Resolve-LibertixSharingDirectory {
                if ($Path.StartsWith('C:')) { return '\\?\Volume{11111111-1111-1111-1111-111111111111}\Users\Alice' }
                return '\\?\Volume{22222222-2222-2222-2222-222222222222}\Data\Alice\Documents'
            }
            Mock Get-LibertixSharingVolumeIdentity {
                [pscustomobject]@{ ntfsUuid = if ($VolumePath.Contains('11111111')) {
                    '1111111111111111'
                } else { '2222222222222222' } }
            }
        }

        It 'records the profile and redirected Documents on distinct volumes' {
            $inventory = Get-LibertixWindowsSharingInventory -InstallationDrives @('C:')
            $inventory.version | Should -Be 1
            $inventory.volumes.Count | Should -Be 2
            $inventory.folders.Count | Should -Be 2
            $inventory.folders[1].shortcut | Should -BeExactly 'User_Alice_Documents'
            $inventory.folders[1].ntfsUuid | Should -BeExactly '2222222222222222'
            $inventory.folders[1].relativePath | Should -BeExactly 'Data/Alice/Documents'
        }

        It 'follows a directory junction rather than retaining its original drive letter' {
            Mock Get-LibertixProfileFolderValues { [pscustomobject]@{ Folders = @{}; Environment = @{} } }
            Mock Resolve-LibertixSharingDirectory { '\\?\Volume{22222222-2222-2222-2222-222222222222}\Profiles\Alice' }
            $inventory = Get-LibertixWindowsSharingInventory -InstallationDrives @('C:')
            $inventory.folders[0].relativePath | Should -BeExactly 'Profiles/Alice'
            $inventory.folders[0].ntfsUuid | Should -BeExactly '2222222222222222'
        }

        It 'refuses an unavailable redirected directory instead of pretending it is shared' {
            Mock Resolve-LibertixSharingDirectory { throw 'Directory unavailable.' } -ParameterFilter { $Path.StartsWith('D:') }
            { Get-LibertixWindowsSharingInventory -InstallationDrives @('C:') } | Should -Throw '*unavailable*'
        }

        It 'rejects cloned NTFS serial numbers on different volumes' {
            Mock Get-LibertixSharingVolumeIdentity { [pscustomobject]@{ ntfsUuid = '1111111111111111' } }
            { Get-LibertixWindowsSharingInventory -InstallationDrives @('C:') } | Should -Throw '*duplicated*'
        }

        It 'does not inspect unrelated USB or other volumes' {
            Get-LibertixWindowsSharingInventory -InstallationDrives @('C:') | Out-Null
            Should -Invoke Get-LibertixSharingVolumeIdentity -Times 2 -Exactly
            Should -Invoke Get-LibertixSharingVolumeIdentity -Times 0 -ParameterFilter {
                $VolumePath -notin @('\\?\Volume{11111111-1111-1111-1111-111111111111}\',
                    '\\?\Volume{22222222-2222-2222-2222-222222222222}\')
            }
        }
    }
}

Describe 'Native directory and profile lookup' {
    InModuleScope Libertix.WindowsSharingInventory {
        It 'loads the native helper and resolves an actual existing directory' {
            Initialize-LibertixSharingPathReader
            $resolved = Resolve-LibertixSharingDirectory -Path $TestDrive
            $resolved | Should -Match '^\\\\\?\\Volume\{[a-fA-F0-9-]{36}\}\\'
        }

        It 'does not create a missing offline registry hive' {
            Initialize-LibertixSharingPathReader
            $profilePath = Join-Path $TestDrive 'OfflineProfile'
            New-Item -Path $profilePath -ItemType Directory -Force | Out-Null
            { [Libertix.Native.WindowsSharingPaths]::ReadProfile('S-1-5-21-1-2-3-9999', $profilePath) } | Should -Throw
            Test-Path -LiteralPath (Join-Path $profilePath 'NTUSER.DAT') | Should -BeFalse
        }

        It 'reads an existing offline profile hive without changing its bytes' {
            Initialize-LibertixSharingPathReader
            $profilePath = Join-Path $TestDrive 'ExistingOfflineProfile'
            New-Item -Path $profilePath -ItemType Directory | Out-Null
            $hive = Join-Path $profilePath 'NTUSER.DAT'
            Copy-Item -LiteralPath (Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT') -Destination $hive
            $before = (Get-FileHash -LiteralPath $hive -Algorithm SHA256).Hash
            $values = [Libertix.Native.WindowsSharingPaths]::ReadProfile('S-1-5-21-1-2-3-9999', $profilePath)
            $values.Count | Should -Be 2
            $values[0].ContainsKey('Personal') | Should -BeTrue
            (Get-FileHash -LiteralPath $hive -Algorithm SHA256).Hash | Should -BeExactly $before
        }
    }
}
