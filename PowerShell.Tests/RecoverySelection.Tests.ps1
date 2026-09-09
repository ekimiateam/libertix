Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.StorageGeometry.psm1" -Force

Describe 'Windows recovery selection with OEM partitions' {
    InModuleScope Libertix.StorageGeometry {
        BeforeAll {
            function New-RecoverySelectionPartition {
                param([int]$Number, [string]$Type = 'Recovery', [int]$Disk = 3)
                [pscustomobject]@{
                    DiskNumber = $Disk; PartitionNumber = $Number; Type = $Type
                    GptType = if ($Type -eq 'Recovery') { '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}' } else { '' }
                    MbrType = if ($Type -eq 'Recovery') { 39 } else { 7 }
                }
            }
        }
        BeforeEach {
            $windows = New-RecoverySelectionPartition 3 'Basic'
            $active = New-RecoverySelectionPartition 4
            $oem = New-RecoverySelectionPartition 5
            Mock Get-LibertixWindowsRecoveryLocation {
                [pscustomobject]@{ DiskNumber = 3; PartitionNumber = 4 }
            }
        }
        It 'preserves the single-Recovery behavior without requiring WinRE to be enabled' {
            Mock Get-LibertixWindowsRecoveryLocation { $null }
            $selected = Resolve-LibertixWindowsRecoveryPartition -Partitions @($windows, $active) `
                -WindowsPartition $windows -PartitionStyle GPT
            $selected.PartitionNumber | Should -Be 4
            Should -Invoke Get-LibertixWindowsRecoveryLocation -Times 1 -Exactly -ParameterFilter { $AllowMissing }
        }
        It 'selects active WinRE rather than the first OEM recovery candidate' {
            $parts = @($oem, $windows, $active)
            $selected = Resolve-LibertixWindowsRecoveryPartition -Partitions $parts `
                -WindowsPartition $windows -PartitionStyle GPT
            $selected.PartitionNumber | Should -Be 4
            $parts.Count | Should -Be 3
            $oem.PartitionNumber | Should -Be 5
            Should -Invoke Get-LibertixWindowsRecoveryLocation -Times 1 -Exactly
        }
        It 'refuses an unresolved active Recovery rather than guessing' {
            Mock Get-LibertixWindowsRecoveryLocation { throw 'Windows RE disabled or unavailable' }
            { Resolve-LibertixWindowsRecoveryPartition -Partitions @($windows, $oem, $active) `
                -WindowsPartition $windows -PartitionStyle GPT } | Should -Throw '*disabled or unavailable*'
        }
        It 'does not identify Recovery on another physical disk' {
            Mock Get-LibertixWindowsRecoveryLocation {
                [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 4 }
            }
            { Resolve-LibertixWindowsRecoveryPartition -Partitions @($windows, $oem, $active) `
                -WindowsPartition $windows -PartitionStyle GPT } | Should -Throw '*does not match*'
        }
        It 'refuses a lone OEM candidate when active WinRE is on another disk' {
            Mock Get-LibertixWindowsRecoveryLocation {
                [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 4 }
            }
            { Resolve-LibertixWindowsRecoveryPartition -Partitions @($windows, $oem) `
                -WindowsPartition $windows -PartitionStyle GPT } | Should -Throw '*does not match*'
        }
        It 'does not hide a failed Windows RE query with a lone candidate' {
            Mock Get-LibertixWindowsRecoveryLocation { throw 'REAGENT_QUERY_FAILED' }
            { Resolve-LibertixWindowsRecoveryPartition -Partitions @($windows, $active) `
                -WindowsPartition $windows -PartitionStyle GPT } | Should -Throw '*REAGENT_QUERY_FAILED*'
        }
        It 'selects the lone candidate when active WinRE matches it' {
            $selected = Resolve-LibertixWindowsRecoveryPartition -Partitions @($windows, $active) `
                -WindowsPartition $windows -PartitionStyle GPT
            $selected.PartitionNumber | Should -Be 4
        }
        It 'refuses a mixed-disk partition inventory' {
            $other = New-RecoverySelectionPartition 4 'Recovery' 0
            { Resolve-LibertixWindowsRecoveryPartition -Partitions @($windows, $other) `
                -WindowsPartition $windows -PartitionStyle GPT } | Should -Throw '*another physical disk*'
        }
        It 'does not silently broaden MBR container support' {
            { Resolve-LibertixWindowsRecoveryPartition -Partitions @($windows, $oem, $active) `
                -WindowsPartition $windows -PartitionStyle MBR } | Should -Throw '*no supported*'
        }
        It 'matches the native device path regardless of the translated heading' {
            $info = 'Emplacement Windows RE : \\?\GLOBALROOT\device\harddisk3\partition4\Recovery\WindowsRE'
            $location = ConvertFrom-LibertixWindowsRecoveryInfo $info
            $location.DiskNumber | Should -Be 3
            $location.PartitionNumber | Should -Be 4
        }
        It 'refuses multiple distinct device paths' {
            $info = '\\?\GLOBALROOT\device\harddisk3\partition4\Recovery\WindowsRE' + "`n" +
                '\\?\GLOBALROOT\device\harddisk3\partition5\Recovery\WindowsRE'
            { ConvertFrom-LibertixWindowsRecoveryInfo $info } | Should -Throw '*unambiguous*'
        }
        It 'refuses missing device paths' {
            { ConvertFrom-LibertixWindowsRecoveryInfo '' } | Should -Throw '*unambiguous*'
        }
        It 'allows an absent WinRE path only when explicitly requested' {
            ConvertFrom-LibertixWindowsRecoveryInfo '' -AllowMissing | Should -BeNullOrEmpty
        }
        It 'does not accept ambiguous paths when absence is allowed' {
            $info = '\\?\GLOBALROOT\device\harddisk3\partition4\Recovery\WindowsRE' + "`n" +
                '\\?\GLOBALROOT\device\harddisk3\partition5\Recovery\WindowsRE'
            { ConvertFrom-LibertixWindowsRecoveryInfo $info -AllowMissing } | Should -Throw '*unambiguous*'
        }
    }
}
