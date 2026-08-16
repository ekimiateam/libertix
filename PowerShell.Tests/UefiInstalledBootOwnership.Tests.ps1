BeforeAll {
    Import-Module `
        "$PSScriptRoot/../Scripts/modules/Libertix.Firmware.psm1" `
        -Force
    . "$PSScriptRoot/../Scripts/uefi/Libertix.Uefi.Firmware.ps1"
}

Describe "Installed UEFI boot ownership" {
    BeforeEach {
        $script:RecoveryRunId = "0123456789abcdef0123456789abcdef"
        $script:InstalledEspDirectory = "EFI\Libertix"
        $script:InstallerEspOwnershipFile = ".libertix-owner"
        $script:InstalledBootDescription = "Libertix"
        $script:InstalledBootLoaderPath = "\EFI\Libertix\shimx64.efi"
        $directory = Join-Path $TestDrive $script:InstalledEspDirectory
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        @(
            $script:RecoveryRunId
            "0007"
            "1"
            "11111111-2222-3333-4444-555555555555"
            "\EFI\Libertix\shimx64.efi"
        ) | Set-Content `
            -LiteralPath (Join-Path $directory $script:InstallerEspOwnershipFile) `
            -Encoding UTF8

        Mock Get-FirmwareVariableBytes { return [byte[]](1, 2, 3) }
        Mock Get-EfiLoadOptionDescription { return "Libertix" }
        Mock Test-EfiLoadOptionLoaderPath { return $true }
        Mock Remove-FirmwareBootNumberFromOrder {}
        Mock Remove-FirmwareVariable {}
        Mock Test-FirmwareVariableExists { return $false }
    }

    It "removes only the Boot number recorded by the owned ESP marker" {
        Remove-LibertixInstalledFirmwareEntries -EspDrive $TestDrive

        Should -Invoke Remove-FirmwareBootNumberFromOrder `
            -Times 1 `
            -ParameterFilter { $BootNumber -eq 7 }
        Should -Invoke Remove-FirmwareVariable `
            -Times 1 `
            -ParameterFilter { $Name -eq "Boot0007" }
    }

    It "refuses a reused Boot number whose description is no longer Libertix" {
        Mock Get-EfiLoadOptionDescription { return "Windows Boot Manager" }

        { Remove-LibertixInstalledFirmwareEntries -EspDrive $TestDrive } |
            Should -Throw "*not the installed Libertix entry*"
        Should -Invoke Remove-FirmwareVariable -Times 0
    }

    It "refuses a reused Boot number whose loader path is no longer Libertix" {
        Mock Test-EfiLoadOptionLoaderPath { return $false }

        { Remove-LibertixInstalledFirmwareEntries -EspDrive $TestDrive } |
            Should -Throw "*loader path does not match*"
        Should -Invoke Remove-FirmwareVariable -Times 0
    }
}

Describe "BCD firmware entry discovery cardinality" {
    It "returns an empty array without triggering the PowerShell 5.1 generic-list binder" {
        Mock Invoke-BcdeditCommand { return "Windows Boot Manager" }

        $entries = @(Get-BcdFirmwareEntriesByDescription -Descriptions @("Libertix"))

        $entries.Count | Should -Be 0
    }

    It "returns one discovered entry as one array element" {
        Mock Invoke-BcdeditCommand {
            return @"
identifier              {11111111-2222-3333-4444-555555555555}
description             Libertix UEFI Installer test
"@
        }

        $entries = @(
            Get-BcdFirmwareEntriesByDescription `
                -Descriptions @("Libertix UEFI Installer test")
        )

        $entries.Count | Should -Be 1
        $entries[0].Identifier | Should -Be "{11111111-2222-3333-4444-555555555555}"
    }
}

Describe "UEFI load option path ownership" {
    BeforeEach {
        Mock Get-Disk {
            [pscustomobject]@{
                LogicalSectorSize = 512
            }
        }
    }

    It "matches only the exact file path node" {
        $partition = [pscustomobject]@{
            DiskNumber = 0
            PartitionNumber = 1
            Offset = 1048576
            Size = 209715200
            Guid = "11111111-2222-3333-4444-555555555555"
        }
        $bytes = New-EfiLoadOption `
            -Description "Libertix" `
            -Partition $partition `
            -LoaderPath "\EFI\Libertix\shimx64.efi"

        Test-EfiLoadOptionLoaderPath `
            -Bytes $bytes `
            -ExpectedPath "\efi\libertix\SHIMX64.EFI" |
            Should -BeTrue
        Test-EfiLoadOptionLoaderPath `
            -Bytes $bytes `
            -ExpectedPath "\EFI\Microsoft\Boot\bootmgfw.efi" |
            Should -BeFalse
    }

    It "decodes the exact GPT hard-drive node used by a load option" {
        $partition = [pscustomobject]@{
            DiskNumber = 0
            PartitionNumber = 3
            Offset = 1048576
            Size = 209715200
            Guid = "11111111-2222-3333-4444-555555555555"
        }
        $bytes = New-EfiLoadOption `
            -Description "Libertix" `
            -Partition $partition `
            -LoaderPath "\EFI\Libertix\shimx64.efi"

        $nodes = @(Get-EfiLoadOptionHardDriveNodes -Bytes $bytes)

        $nodes.Count | Should -Be 1
        $nodes[0].PartitionNumber | Should -Be 3
        $nodes[0].PartitionStartLba | Should -Be 2048
        $nodes[0].PartitionSizeLba | Should -Be 409600
        $nodes[0].PartitionGuid | Should -Be "11111111-2222-3333-4444-555555555555"
        $nodes[0].MbrType | Should -Be 2
        $nodes[0].SignatureType | Should -Be 2
    }
}
