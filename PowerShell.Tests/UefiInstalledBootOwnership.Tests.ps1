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
}
