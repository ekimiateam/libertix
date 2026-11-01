BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../Scripts/modules/Libertix.SecondaryBootPreflight.psm1') -Force
}

Describe 'Secondary disk boot preflight' {
    InModuleScope Libertix.SecondaryBootPreflight {
        BeforeEach {
            $script:disk = [pscustomobject]@{ Number = 0; LogicalSectorSize = 512 }
            $script:partition = [pscustomobject]@{
                DiskNumber = 0; PartitionNumber = 1; Offset = 1MB; Size = 200MB
                Guid = '11111111-2222-3333-4444-555555555555'; IsActive = $true
            }
            $script:allocation = [pscustomobject]@{ number = 1 }
            Mock Get-Disk -ModuleName Libertix.Firmware {
                [pscustomobject]@{ LogicalSectorSize = 512 }
            }
            $script:variables = @{
                BootOrder = [byte[]](7, 0)
                Boot0007 = New-EfiLoadOption -Description 'Windows Boot Manager' `
                    -Partition $script:partition -LoaderPath '\EFI\Microsoft\Boot\bootmgfw.efi'
            }
            Mock Get-LibertixNativeSystemExecutable { 'C:\Windows\System32\bcdedit.exe' }
            Mock Invoke-LibertixNativeCommand {
                [pscustomobject]@{ ExitCode = 0; StandardOutput = 'Readable BCD entry'; StandardError = '' }
            }
            Mock Get-LibertixFirmwareVariableBytes { $script:variables[$Name] }
            Mock Set-LibertixFirmwareVariableBytes { throw 'Firmware writes are forbidden in preflight.' }
        }

        AfterEach {
            Should -Invoke Set-LibertixFirmwareVariableBytes -Times 0 -Exactly
            Should -Invoke Invoke-LibertixNativeCommand -Times 0 -Exactly -ParameterFilter {
                $ArgumentList[0] -ne '/enum' -or $ArgumentList[1] -notin @('{bootmgr}', '{current}') -or
                $TimeoutSeconds -ne 15
            }
        }

        It 'checks BIOS BCD and the active system partition without requiring UEFI' {
            $result = Assert-LibertixSecondaryBootPreflight BIOS $disk $partition $allocation
            $result.status | Should -Be 'verified'
            $result.secondaryFirmwareAccess | Should -Be 'unverified'
            Should -Invoke Invoke-LibertixNativeCommand -Times 2 -Exactly
            Should -Invoke Get-LibertixFirmwareVariableBytes -Times 0 -Exactly
        }

        It 'accepts a data disk with no boot entry without claiming it is firmware-accessible' {
            $result = Assert-LibertixSecondaryBootPreflight UEFI $disk $partition $allocation
            $result.windowsBoot | Should -Be @('Boot0007')
            $result.secondaryFirmwareAccess | Should -Be 'unverified'
        }

        It 'preserves other boot options and does not require Windows first' {
            $script:variables.BootOrder = [byte[]](9, 0, 7, 0)
            $script:variables.Boot0009 = New-EfiLoadOption -Description 'Other OS' `
                -Partition $partition -LoaderPath '\EFI\other\shimx64.efi'
            $script:variables.BootCurrent = [byte[]](9, 0)
            $script:variables.BootNext = [byte[]](7, 0)
            (Assert-LibertixSecondaryBootPreflight UEFI $disk $partition $allocation).status | Should -Be 'verified'
            $script:variables.BootOrder | Should -Be ([byte[]](9, 0, 7, 0))
        }

        It 'rejects an inactive BIOS boot partition' {
            $partition.IsActive = $false
            { Assert-LibertixSecondaryBootPreflight BIOS $disk $partition $allocation } | Should -Throw '*not active*'
        }

        It 'rejects unreadable BCD before querying firmware' {
            Mock Invoke-LibertixNativeCommand { [pscustomobject]@{ ExitCode = 1; StandardOutput = '' } }
            { Assert-LibertixSecondaryBootPreflight UEFI $disk $partition $allocation } | Should -Throw '*BCD*cannot be read*'
            Should -Invoke Get-LibertixFirmwareVariableBytes -Times 0 -Exactly
        }

        It 'rejects empty BCD output even with a successful exit code' {
            Mock Invoke-LibertixNativeCommand { [pscustomobject]@{ ExitCode = 0; StandardOutput = ' ' } }
            { Assert-LibertixSecondaryBootPreflight BIOS $disk $partition $allocation } | Should -Throw '*BCD*cannot be read*'
        }

        It 'rejects malformed BootOrder: <Case>' -TestCases @(
            @{ Case = 'missing'; Value = $null },
            @{ Case = 'odd length'; Value = [byte[]](7) },
            @{ Case = 'duplicate'; Value = [byte[]](7, 0, 7, 0) },
            @{ Case = 'oversized'; Value = [byte[]]::new(1026) }
        ) {
            param($Case, $Value)
            $script:variables.BootOrder = $Value
            { Assert-LibertixSecondaryBootPreflight UEFI $disk $partition $allocation } | Should -Throw '*BootOrder*'
        }

        It 'rejects malformed <Name>' -TestCases @(@{ Name = 'BootCurrent' }, @{ Name = 'BootNext' }) {
            param($Name)
            $script:variables[$Name] = [byte[]](7)
            { Assert-LibertixSecondaryBootPreflight UEFI $disk $partition $allocation } | Should -Throw '*malformed*'
        }

        It 'rejects a pending boot entry that cannot be read' {
            $script:variables.BootNext = [byte[]](8, 0)
            { Assert-LibertixSecondaryBootPreflight UEFI $disk $partition $allocation } | Should -Throw '*missing or truncated*'
        }

        It 'rejects a Windows loader whose ESP identity or geometry differs: <Field>' -TestCases @(
            @{ Field = 'Guid'; Value = 'aaaaaaaa-2222-3333-4444-555555555555' },
            @{ Field = 'Offset'; Value = 2MB }, @{ Field = 'Size'; Value = 100MB },
            @{ Field = 'PartitionNumber'; Value = 2 }
        ) {
            param($Field, $Value)
            $partition.$Field = $Value
            { Assert-LibertixSecondaryBootPreflight UEFI $disk $partition $allocation } | Should -Throw '*no active Windows loader*'
        }

        It 'does not accept an inactive Windows EFI option' {
            $script:variables.Boot0007[0] = 0
            { Assert-LibertixSecondaryBootPreflight UEFI $disk $partition $allocation } | Should -Throw '*no active Windows loader*'
        }

        It 'rejects allocation on the Windows disk before executing BCD' {
            $allocation.number = 0
            { Assert-LibertixSecondaryBootPreflight BIOS $disk $partition $allocation } | Should -Throw '*inconsistent disk identities*'
            Should -Invoke Invoke-LibertixNativeCommand -Times 0 -Exactly
        }

        It 'rejects a boot partition on another disk before executing BCD' {
            $partition.DiskNumber = 2
            { Assert-LibertixSecondaryBootPreflight UEFI $disk $partition $allocation } | Should -Throw '*inconsistent disk identities*'
            Should -Invoke Invoke-LibertixNativeCommand -Times 0 -Exactly
        }
    }
}
