BeforeAll {
    Import-Module (Join-Path $PSScriptRoot "../Scripts/modules/Libertix.BiosMbr.psm1") -Force
    Initialize-LibertixBiosMbrIo
}

Describe "Aligned BIOS MBR restoration" {
    It "restores only boot code and is idempotent with <Size>-byte sectors" -TestCases @(
        @{ Size = 512 }, @{ Size = 4096 }
    ) {
        param($Size)
        $path = Join-Path $TestDrive "sector-$Size.bin"
        [byte[]]$current = New-Object byte[] $Size
        for ($i = 0; $i -lt $Size; $i++) { $current[$i] = [byte]($i % 251) }
        $current[510] = 0x55; $current[511] = 0xaa
        [byte[]]$backup = New-Object byte[] 512
        for ($i = 0; $i -lt 440; $i++) { $backup[$i] = [byte](255 - ($i % 251)) }
        $backup[510] = 0x55; $backup[511] = 0xaa
        [IO.File]::WriteAllBytes($path, $current)
        [byte[]]$expected = $current.Clone()
        [Array]::Copy($backup, 0, $expected, 0, 440)
        foreach ($attempt in @(1, 2)) {
            [Libertix.BiosMbrIo]::Restore($path, $Size, $backup)
            [Libertix.BiosMbrIo]::VerifyBootCode($path, $Size, $backup)
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) |
                Should -BeExactly ([Convert]::ToBase64String($expected))
        }
    }

    It 'detects changed boot code without repairing or writing the sector' {
        $path = Join-Path $TestDrive 'changed-boot-code.bin'
        [byte[]]$backup = New-Object byte[] 512
        $backup[510] = 0x55; $backup[511] = 0xaa
        [byte[]]$current = $backup.Clone()
        $current[20] = 42
        [IO.File]::WriteAllBytes($path, $current)
        { [Libertix.BiosMbrIo]::VerifyBootCode($path, 512, $backup) } |
            Should -Throw '*differs from its backup*'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) |
            Should -BeExactly ([Convert]::ToBase64String($current))
    }

    It "rejects unsupported geometry without opening a destination" {
        { [Libertix.BiosMbrIo]::Restore("not-a-device", 1024, (New-Object byte[] 512)) } |
            Should -Throw '*Unsupported BIOS disk sector size*'
    }

    It "rejects an invalid backup without opening a destination" {
        { [Libertix.BiosMbrIo]::Restore("not-a-device", 512, (New-Object byte[] 512)) } |
            Should -Throw '*Invalid pre-GRUB MBR backup signature*'
    }

    It "does not modify a current sector with no MBR signature" {
        $path = Join-Path $TestDrive "invalid-sector.bin"
        [byte[]]$current = New-Object byte[] 4096
        [byte[]]$backup = New-Object byte[] 512
        $backup[510] = 0x55; $backup[511] = 0xaa
        [IO.File]::WriteAllBytes($path, $current)
        { [Libertix.BiosMbrIo]::Restore($path, 4096, $backup) } |
            Should -Throw '*Current BIOS MBR signature is invalid*'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) |
            Should -BeExactly ([Convert]::ToBase64String($current))
    }
}
