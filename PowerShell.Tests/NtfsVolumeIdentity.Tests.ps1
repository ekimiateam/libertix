BeforeAll {
    Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.StorageTargets.psm1" -Force
    # This is a read-only native integration check on the Windows test runner's system volume.
    $observedSerial = Get-LibertixNtfsVolumeSerial -Drive $env:SystemDrive
}

Describe 'NTFS source identity retains all 64 bits' {
    It 'queries the native NTFS volume without truncating its serial' {
        $observedSerial | Should -Match '^[0-9A-F]{16}$'
        $observedSerial | Should -Not -Be '0000000000000000'
    }

    It 'preserves the high bit and little-endian byte order' {
        $data = [byte[]]::new(96)
        [byte[]]$serial = 0x08,0x07,0x06,0x05,0x04,0x03,0x02,0xF1
        [Array]::Copy($serial, $data, 8)
        [Libertix.Native.NtfsVolumeIdentity]::ParseSerial($data, 96) | Should -Be 'F102030405060708'
    }

    It 'refuses a truncated native reply' {
        { [Libertix.Native.NtfsVolumeIdentity]::ParseSerial([byte[]]::new(96), 8) } |
            Should -Throw '*incomplete*'
    }

    It 'refuses a missing serial' {
        { [Libertix.Native.NtfsVolumeIdentity]::ParseSerial([byte[]]::new(96), 96) } |
            Should -Throw '*not usable*'
    }

    It 'refuses a device path instead of an explicit local drive' {
        { [Libertix.Native.NtfsVolumeIdentity]::ReadSerial('PhysicalDrive0') } |
            Should -Throw '*local volume drive*'
    }
}
