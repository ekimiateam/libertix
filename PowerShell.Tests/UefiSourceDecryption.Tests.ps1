BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../Scripts/modules/Libertix.Rollback.psm1') -Force
    . (Join-Path $PSScriptRoot '../Scripts/uefi/Libertix.Uefi.Execution.ps1')
    . (Join-Path $PSScriptRoot '../Scripts/uefi/Libertix.Uefi.Firmware.ps1')
    . (Join-Path $PSScriptRoot '../Scripts/uefi/Libertix.Uefi.Storage.ps1')
    function Get-NativeSystemExecutable { param($FileName) $FileName }
    function Write-LibertixInstallationPlanAtomic { param($Path, $Plan) }
}

Describe 'UEFI allocation decryption transaction ordering' {
    BeforeEach {
        $script:InstallationPlanPath = 'C:\recovery\installation-plan.json'
        $script:installationPlan = [pscustomobject]@{
            allocation = [pscustomobject]@{ sourceDrive = 'J:'; sourceBitLockerState = 'EncryptedOrProtected' }
        }
        $script:events = [Collections.Generic.List[string]]::new()
        Mock Assert-LibertixPlanMatchesCurrentStorage { $script:events.Add('windows') }
        Mock Assert-LibertixAllocationMatchesCurrentStorage { $script:events.Add('source') }
        Mock Set-WindowsVolumeReadableFromLinux { $script:events.Add('decrypt:' + $MountPoint) }
        Mock Write-LibertixInstallationPlanAtomic { $script:events.Add('save') }
    }

    It 'verifies both disks before and after decrypting only the selected source' {
        Set-LibertixAllocationVolumeReadableFromLinux
        ($script:events -join ',') | Should -Be 'windows,source,decrypt:J:,windows,source,save'
        Should -Invoke Write-LibertixInstallationPlanAtomic -Times 1 -Exactly -ParameterFilter {
            $Path -eq $script:InstallationPlanPath -and $Plan.allocation.sourceBitLockerState -eq 'FullyDecrypted'
        }
        Should -Invoke Set-WindowsVolumeReadableFromLinux -Times 0 -ParameterFilter { $MountPoint -ne 'J:' }
    }

    It 'does not add decryption or disk queries to the historical single-disk plan' {
        $script:installationPlan = [pscustomobject]@{ disk = [pscustomobject]@{ systemDrive = 'C:' } }
        Set-LibertixAllocationVolumeReadableFromLinux
        $script:events.Count | Should -Be 0
    }

    It 'stops before decryption if the <Kind> proof changed' -ForEach @(
        @{ Kind = 'Windows'; Command = 'Assert-LibertixPlanMatchesCurrentStorage' },
        @{ Kind = 'source'; Command = 'Assert-LibertixAllocationMatchesCurrentStorage' }
    ) {
        Mock $Command { throw 'identity-changed' }
        { Set-LibertixAllocationVolumeReadableFromLinux } | Should -Throw '*identity-changed*'
        Should -Invoke Set-WindowsVolumeReadableFromLinux -Times 0
        Should -Invoke Write-LibertixInstallationPlanAtomic -Times 0
    }

    It 'does not publish decryption success if the source changed during decryption' {
        $script:sourceChecks = 0
        Mock Assert-LibertixAllocationMatchesCurrentStorage {
            $script:sourceChecks++
            if ($script:sourceChecks -eq 2) { throw 'source-replaced' }
        }
        { Set-LibertixAllocationVolumeReadableFromLinux } | Should -Throw '*source-replaced*'
        Should -Invoke Set-WindowsVolumeReadableFromLinux -Times 1
        Should -Invoke Write-LibertixInstallationPlanAtomic -Times 0
        $script:installationPlan.allocation.sourceBitLockerState | Should -Be 'EncryptedOrProtected'
    }

    It 'does not publish decryption success after a decryption failure' {
        Mock Set-WindowsVolumeReadableFromLinux { throw 'decryption-failed' }
        { Set-LibertixAllocationVolumeReadableFromLinux } | Should -Throw '*decryption-failed*'
        Should -Invoke Write-LibertixInstallationPlanAtomic -Times 0
        $script:installationPlan.allocation.sourceBitLockerState | Should -Be 'EncryptedOrProtected'
    }
}

Describe 'UEFI decryption follows the selected volume' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $script:SystemDrive = 'C:'
        $script:reads = 0
        Mock Get-NativeSystemExecutable { 'manage-bde.exe' }
        Mock Request-BitLockerDecryption {}
        Mock Write-Log {}
        Mock Write-LibertixProgress {}
        Mock Start-Sleep {}
        Mock Get-BitLockerVolume {
            $script:reads++
            if ($script:reads -lt 3) {
                [pscustomobject]@{
                    VolumeStatus = 'FullyEncrypted'; EncryptionPercentage = 100; ProtectionStatus = 'Off'
                }
            } else {
                [pscustomobject]@{
                    VolumeStatus = 'FullyDecrypted'; EncryptionPercentage = 0; ProtectionStatus = 'Off'
                }
            }
        }
    }

    It 'preserves the historical default C volume' {
        Set-WindowsVolumeReadableFromLinux
        Should -Invoke Get-BitLockerVolume -Times 3 -ParameterFilter { $MountPoint -eq 'C:' }
        Should -Invoke Request-BitLockerDecryption -Times 1 -ParameterFilter { $MountPoint -eq 'C:' }
    }

    It 'decrypts only J and does not confuse suspended protection with decryption' {
        Set-WindowsVolumeReadableFromLinux -MountPoint 'J:'
        Should -Invoke Get-BitLockerVolume -Times 3 -ParameterFilter { $MountPoint -eq 'J:' }
        Should -Invoke Get-BitLockerVolume -Times 0 -ParameterFilter { $MountPoint -ne 'J:' }
        Should -Invoke Request-BitLockerDecryption -Times 1 -ParameterFilter { $MountPoint -eq 'J:' }
        Should -Invoke Request-BitLockerDecryption -Times 0 -ParameterFilter { $MountPoint -ne 'J:' }
        $script:SystemDrive | Should -Be 'C:'
    }

    It 'does not modify an already decrypted source' {
        Mock Get-BitLockerVolume {
            [pscustomobject]@{ VolumeStatus = 'FullyDecrypted'; EncryptionPercentage = 0; ProtectionStatus = 'Off' }
        }
        Set-WindowsVolumeReadableFromLinux -MountPoint 'J:'
        Should -Invoke Request-BitLockerDecryption -Times 0
        Should -Invoke Start-Sleep -Times 0
    }

    It 'waits for terminal conversion on <Drive> even when progress rounds to zero' -ForEach @(
        @{ Drive = 'C:' }, @{ Drive = 'J:' }
    ) {
        Mock Get-BitLockerVolume {
            $script:reads++
            [pscustomobject]@{
                VolumeStatus = if ($script:reads -lt 3) { 'DecryptionInProgress' } else { 'FullyDecrypted' }
                EncryptionPercentage = 0
                ProtectionStatus = 'Off'
            }
        }
        Set-WindowsVolumeReadableFromLinux -MountPoint $Drive
        Should -Invoke Get-BitLockerVolume -Times 3 -Exactly -ParameterFilter { $MountPoint -eq $Drive }
        Should -Invoke Start-Sleep -Times 2 -Exactly
        Should -Invoke Write-LibertixProgress -Times 1 -Exactly -ParameterFilter {
            $Stage -eq 'windows-decryption-complete'
        }
    }

    It 'refuses an unknown source without requesting decryption anywhere' {
        Mock Get-BitLockerVolume { $null }
        { Set-WindowsVolumeReadableFromLinux -MountPoint 'J:' } | Should -Throw '*returned no J: volume*'
        Should -Invoke Request-BitLockerDecryption -Times 0
    }

    It 'checks identity immediately before every decryption request and while waiting' {
        $script:sequence = [Collections.Generic.List[string]]::new()
        Mock Get-BitLockerVolume {
            $script:sequence.Add('read')
            $script:reads++
            if ($script:reads -le 13) {
                [pscustomobject]@{
                    VolumeStatus = 'FullyEncrypted'; EncryptionPercentage = 100; ProtectionStatus = 'Off'
                }
            } else {
                [pscustomobject]@{
                    VolumeStatus = 'FullyDecrypted'; EncryptionPercentage = 0; ProtectionStatus = 'Off'
                }
            }
        }
        Mock Request-BitLockerDecryption { $script:sequence.Add('decrypt') }
        Set-WindowsVolumeReadableFromLinux -MountPoint 'J:' -VerifyStorageIdentity {
            $script:sequence.Add('identity')
        }
        for ($index = 0; $index -lt $script:sequence.Count; $index++) {
            if ($script:sequence[$index] -in @('read', 'decrypt')) {
                $index | Should -BeGreaterThan 0
                $script:sequence[$index - 1] | Should -Be 'identity'
            }
        }
        Should -Invoke Request-BitLockerDecryption -Times 2 -Exactly
    }

    It 'stops before a repeated request when the selected disk changes during the wait' {
        $script:identityChecks = 0
        Mock Get-BitLockerVolume {
            [pscustomobject]@{
                VolumeStatus = 'FullyEncrypted'; EncryptionPercentage = 100; ProtectionStatus = 'Off'
            }
        }
        {
            Set-WindowsVolumeReadableFromLinux -MountPoint 'J:' -VerifyStorageIdentity {
                $script:identityChecks++
                if ($script:identityChecks -eq 15) { throw 'selected-disk-replaced' }
            }
        } | Should -Throw '*selected-disk-replaced*'
        Should -Invoke Request-BitLockerDecryption -Times 1 -Exactly
    }
}
