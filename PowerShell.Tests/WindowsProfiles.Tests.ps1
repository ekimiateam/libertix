BeforeAll {
    Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.WindowsProfiles.psm1" -Force
}

Describe 'Windows sharing profile locations' {
    InModuleScope Libertix.WindowsProfiles {
        BeforeEach {
            $script:profiles = @(
                [pscustomobject]@{ SID = 'S-1-5-21-1-2-3-1001'; LocalPath = 'C:\Users\Alice'; Special = $false; Loaded = $true },
                [pscustomobject]@{ SID = 'S-1-5-21-1-2-3-1002'; LocalPath = 'D:\Profiles\Bob'; Special = $false; Loaded = $false },
                [pscustomobject]@{ SID = 'S-1-5-21-1-2-3-1003'; LocalPath = 'C:\People\Carol'; Special = $false; Loaded = $false }
            )
            Mock Get-CimInstance { $script:profiles }
            Mock Test-Path { $true }
        }

        It 'uses the registered paths on both disks without assuming a Users directory' {
            $actual = @(Get-LibertixWindowsUserProfiles)
            $actual.Count | Should -Be 3
            $actual[0].LocalPath | Should -BeExactly 'C:\Users\Alice'
            $actual[1].LocalPath | Should -BeExactly 'D:\Profiles\Bob'
            $actual[2].LocalPath | Should -BeExactly 'C:\People\Carol'
            $actual[0].Loaded | Should -BeTrue
            $actual[1].Loaded | Should -BeFalse
        }

        It 'does not use a profile whose directory is unavailable' {
            Mock Test-Path { $LiteralPath -ne 'D:\Profiles\Bob' }
            @(Get-LibertixWindowsUserProfiles).Count | Should -Be 2
        }

        It 'reports an inaccessible data dependency for strict sharing inventory' {
            Mock Test-Path { $LiteralPath -ne 'D:\Profiles\Bob' }
            { Get-LibertixWindowsUserProfiles -RequireAccessible } | Should -Throw '*unavailable*'
        }

        It 'reports a nonlocal profile dependency for strict sharing inventory' {
            $script:profiles[1].LocalPath = '\\server\profiles\Bob'
            { Get-LibertixWindowsUserProfiles -RequireAccessible } | Should -Throw '*unsupported location*'
        }

        It 'excludes special profiles and service accounts' {
            $script:profiles[0].Special = $true
            $script:profiles[1].SID = 'S-1-5-18'
            $script:profiles[2].LocalPath = 'C:\Users\defaultuser0'
            @(Get-LibertixWindowsUserProfiles).Count | Should -Be 0
        }

        It 'excludes unsafe or nonlocal profile path <Path>' -ForEach @(
            @{ Path = '\\server\users\Alice' }, @{ Path = 'Users\Alice' },
            @{ Path = 'C:Users\Alice' }, @{ Path = 'C:\Users\..\Windows' },
            @{ Path = 'C:\Users\*' }, @{ Path = 'C:\Users\Alice:stream' }
        ) {
            $script:profiles = @($script:profiles[0])
            $script:profiles[0].LocalPath = $Path
            @(Get-LibertixWindowsUserProfiles).Count | Should -Be 0
        }

        It 'refuses duplicate user identities' {
            $script:profiles[1].SID = $script:profiles[0].SID
            { @(Get-LibertixWindowsUserProfiles) } | Should -Throw '*ambiguous*'
        }

        It 'refuses duplicate paths regardless of case or trailing separator' {
            $script:profiles[1].LocalPath = 'c:\USERS\Alice\'
            { @(Get-LibertixWindowsUserProfiles) } | Should -Throw '*ambiguous*'
        }

        It 'looks for shortcuts at the actual paths using literal filenames' {
            $script:profiles[1].LocalPath = 'D:\Profiles\Bob[1]'
            Mock Get-Item { [pscustomobject]@{ FullName = $LiteralPath } }
            $actual = @(Get-LibertixLinuxShortcutFiles -LinuxUsername 'test-linux')
            $actual.Count | Should -Be 3
            $actual[1].FullName | Should -BeExactly 'D:\Profiles\Bob[1]\Links\Linux_test-linux_read-only.lnk'
            Should -Invoke Get-Item -Times 1 -Exactly -ParameterFilter {
                $LiteralPath -eq 'D:\Profiles\Bob[1]\Links\Linux_test-linux_read-only.lnk'
            }
        }

        It 'does not return missing shortcuts' {
            Mock Test-Path { $PathType -ne 'Leaf' }
            @(Get-LibertixLinuxShortcutFiles -LinuxUsername 'test').Count | Should -Be 0
        }

        It 'rejects a shortcut name that escapes the Links directory' {
            { Get-LibertixLinuxShortcutFiles -LinuxUsername '..\test' } | Should -Throw '*invalid*'
            Should -Invoke Get-CimInstance -Times 0
        }
    }
}
