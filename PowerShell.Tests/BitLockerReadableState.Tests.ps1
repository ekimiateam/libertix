BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../Scripts/modules/Libertix.Rollback.psm1') -Force
}

Describe 'BitLocker readiness requires terminal conversion evidence' {
    It 'refuses zero percent while conversion is <Status>' -ForEach @(
        @{ Status = 'FullyEncrypted' }, @{ Status = 'EncryptionInProgress' },
        @{ Status = 'DecryptionInProgress' }, @{ Status = 'EncryptionPaused' },
        @{ Status = 'DecryptionPaused' }, @{ Status = 'Unknown' }
    ) {
        Test-BitLockerVolumeReadable -Volume ([pscustomobject]@{
            VolumeStatus = $Status; EncryptionPercentage = 0; ProtectionStatus = 'Off'
        }) | Should -BeFalse
    }

    It 'accepts a fully decrypted unprotected volume' {
        Test-BitLockerVolumeReadable -Volume ([pscustomobject]@{
            VolumeStatus = 'FullyDecrypted'; EncryptionPercentage = 0; ProtectionStatus = 'Off'
        }) | Should -BeTrue
    }

    It 'refuses incomplete field <Field>' -ForEach @(
        @{ Field = 'VolumeStatus' }, @{ Field = 'EncryptionPercentage' }, @{ Field = 'ProtectionStatus' }
    ) {
        $properties = @{ VolumeStatus = 'FullyDecrypted'; EncryptionPercentage = 0; ProtectionStatus = 'Off' }
        $properties.Remove($Field)
        Test-BitLockerVolumeReadable -Volume ([pscustomobject]$properties) | Should -BeFalse
        $properties[$Field] = $null
        Test-BitLockerVolumeReadable -Volume ([pscustomobject]$properties) | Should -BeFalse
    }

    It 'refuses inconsistent terminal evidence: <Percent>, <Protection>' -ForEach @(
        @{ Percent = -1; Protection = 'Off' }, @{ Percent = 1; Protection = 'Off' },
        @{ Percent = 0; Protection = 'On' }, @{ Percent = 0; Protection = 'Unknown' }
    ) {
        Test-BitLockerVolumeReadable -Volume ([pscustomobject]@{
            VolumeStatus = 'FullyDecrypted'; EncryptionPercentage = $Percent; ProtectionStatus = $Protection
        }) | Should -BeFalse
    }
}
