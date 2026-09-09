BeforeAll {
    $fixtureScript = Join-Path $PSScriptRoot '../auto_tests/app/scripts/prepare_storage_fixture_volume.ps1'
    $configPath = Join-Path $TestDrive 'decryption.json'
    function Get-Disk {
        param([Parameter(ValueFromPipeline = $true)]$InputObject)
        process { throw 'The test must mock disk inventory.' }
    }
    function Write-TestConfig {
        param([bool]$Begin = $true, [string]$DiskPath = 'test-system-device')
        @{ drive = $env:SystemDrive; disk_device_path = $DiskPath; begin = $Begin; require_system = $true } |
            ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
    }
}

Describe 'Test fixture BitLocker decryption boundary' {
    BeforeEach {
        Write-TestConfig
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = 3; PartitionNumber = 2 } }
        Mock Get-Disk {
            [pscustomobject]@{ Path = 'test-system-device'; IsOffline = $false; IsReadOnly = $false }
        }
        Mock Get-Volume { [pscustomobject]@{ FileSystemType = 'NTFS'; HealthStatus = 'Healthy' } }
        Mock Get-Process { @() }
        Mock Get-BitLockerVolume {
            [pscustomobject]@{ VolumeStatus = 'DecryptionInProgress'; EncryptionPercentage = 40 }
        }
        Mock Disable-BitLocker { }
    }

    It 'decrypts only the inspected system volume once' {
        $output = & $fixtureScript -ConfigPath $configPath
        $state = ($output -replace '^STORAGE_ENCRYPTION_JSON=', '') | ConvertFrom-Json
        $state.drive | Should -BeExactly $env:SystemDrive
        $state.percentage | Should -Be 40
        $state.fully_decrypted | Should -BeFalse
        Should -Invoke Disable-BitLocker -Times 1 -Exactly -ParameterFilter {
            $MountPoint -eq $env:SystemDrive -and -not $WhatIf
        }
    }

    It 'only observes when polling' {
        Write-TestConfig -Begin $false
        & $fixtureScript -ConfigPath $configPath | Out-Null
        Should -Invoke Disable-BitLocker -Times 0 -Exactly
    }

    It 'does not decrypt an already clear volume again' {
        Mock Get-BitLockerVolume {
            [pscustomobject]@{ VolumeStatus = 'FullyDecrypted'; EncryptionPercentage = 0 }
        }
        $output = & $fixtureScript -ConfigPath $configPath
        $state = ($output -replace '^STORAGE_ENCRYPTION_JSON=', '') | ConvertFrom-Json
        $state.fully_decrypted | Should -BeTrue
        Should -Invoke Disable-BitLocker -Times 0 -Exactly
    }

    It 'refuses a different physical disk before modifying BitLocker' {
        Write-TestConfig -DiskPath 'other-disk'
        { & $fixtureScript -ConfigPath $configPath } | Should -Throw '*identity changed*'
        Should -Invoke Disable-BitLocker -Times 0 -Exactly
    }

    It 'refuses to race an active product installation' {
        Mock Get-Process { [pscustomobject]@{ Name = 'Libertix' } }
        { & $fixtureScript -ConfigPath $configPath } | Should -Throw '*already running*'
        Should -Invoke Disable-BitLocker -Times 0 -Exactly
    }

    It 'does not hide a failed decryption command or try a different command' {
        Mock Disable-BitLocker { throw 'Test BitLocker refusal' }
        { & $fixtureScript -ConfigPath $configPath } | Should -Throw '*Test BitLocker refusal*'
        Should -Invoke Disable-BitLocker -Times 1 -Exactly
    }

    Context 'Explicit secondary-volume fixture' {
        BeforeEach {
            @{ drive = 'J:'; disk_device_path = 'test-secondary-device'; begin = $true;
                require_system = $false; partition_offset = 1048576; volume_id = 'test-volume' } |
                ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
            Mock Get-Partition { [pscustomobject]@{ DiskNumber = 1; PartitionNumber = 1; Offset = 1048576 } }
            Mock Get-Disk { [pscustomobject]@{ Path = 'test-secondary-device'; IsOffline = $false;
                IsReadOnly = $false; IsBoot = $false; IsSystem = $false } }
            Mock Get-Volume { [pscustomobject]@{ FileSystemType = 'NTFS'; HealthStatus = 'Healthy'; UniqueId = 'test-volume' } }
        }

        It 'decrypts the exact secondary volume' {
            & $fixtureScript -ConfigPath $configPath | Out-Null
            Should -Invoke Disable-BitLocker -Times 1 -Exactly -ParameterFilter { $MountPoint -eq 'J:' }
        }

        It 'refuses a reformatted volume even at the same offset' {
            Mock Get-Volume { [pscustomobject]@{ FileSystemType = 'NTFS'; HealthStatus = 'Healthy'; UniqueId = 'replacement' } }
            { & $fixtureScript -ConfigPath $configPath } | Should -Throw '*identity changed*'
            Should -Invoke Disable-BitLocker -Times 0 -Exactly
        }

        It 'refuses a secondary drive that now contains boot files' {
            Mock Get-Disk { [pscustomobject]@{ Path = 'test-secondary-device'; IsOffline = $false;
                IsReadOnly = $false; IsBoot = $false; IsSystem = $true } }
            { & $fixtureScript -ConfigPath $configPath } | Should -Throw '*identity changed*'
            Should -Invoke Disable-BitLocker -Times 0 -Exactly
        }
    }
}
