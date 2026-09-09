BeforeAll {
    Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.StorageTargets.psm1" -Force
}

Describe 'Selected volume BitLocker state uses the full conversion proof' {
    BeforeEach {
        $volume = [Microsoft.Management.Infrastructure.CimInstance]::new('Win32_EncryptableVolume')
        $conversion = [pscustomobject]@{ ReturnValue = 0; ConversionStatus = 0; EncryptionPercentage = 0 }
        $protection = [pscustomobject]@{ ReturnValue = 0; ProtectionStatus = 0 }
        Mock Get-CimInstance -ModuleName Libertix.StorageTargets { $volume }
        Mock Invoke-CimMethod -ModuleName Libertix.StorageTargets {
            if ($MethodName -eq 'GetConversionStatus') { $conversion } else { $protection }
        }
    }

    It 'returns fully decrypted only after all three indicators agree' {
        Get-LibertixTargetVolumeEncryptionState -Drive 'J:' | Should -Be 'FullyDecrypted'
        Should -Invoke Get-CimInstance -ModuleName Libertix.StorageTargets -Times 1 -Exactly -ParameterFilter {
            $Filter -eq "DriveLetter='J:'" -and $ClassName -eq 'Win32_EncryptableVolume'
        }
    }

    It 'does not mistake <State> for a fully decrypted volume' -ForEach @(
        @{ State = 'suspended protection'; ConversionCode = 1; EncryptedPercent = 100; ProtectionCode = 0 },
        @{ State = 'decryption still finishing'; ConversionCode = 3; EncryptedPercent = 0; ProtectionCode = 0 },
        @{ State = 'remaining encrypted sectors'; ConversionCode = 0; EncryptedPercent = 1; ProtectionCode = 0 },
        @{ State = 'active protection'; ConversionCode = 0; EncryptedPercent = 0; ProtectionCode = 1 }
    ) {
        $conversion.ConversionStatus = $ConversionCode
        $conversion.EncryptionPercentage = $EncryptedPercent
        $protection.ProtectionStatus = $ProtectionCode
        Get-LibertixTargetVolumeEncryptionState -Drive 'J:' | Should -Be 'EncryptedOrProtected'
    }

    It 'refuses missing proof instead of converting null into zero' {
        $conversion.EncryptionPercentage = $null
        { Get-LibertixTargetVolumeEncryptionState -Drive 'J:' } | Should -Throw '*incomplete*'
    }

    It 'refuses a failed encryption query' {
        $conversion.ReturnValue = 5
        { Get-LibertixTargetVolumeEncryptionState -Drive 'J:' } | Should -Throw '*unavailable*'
    }

    It 'retains the exact initial conversion and protection values for rollback' {
        $conversion.ConversionStatus = 1
        $conversion.EncryptionPercentage = 100
        $snapshot = Get-LibertixTargetVolumeEncryptionSnapshot -Drive 'J:'
        $snapshot.state | Should -Be 'EncryptedOrProtected'
        $snapshot.conversionStatus | Should -Be 1
        $snapshot.encryptionPercentage | Should -Be 100
        $snapshot.protectionStatus | Should -Be 0
    }

    It 'refuses invalid native status <Field>' -ForEach @(
        @{ Field = 'ConversionStatus'; Value = 9 },
        @{ Field = 'EncryptionPercentage'; Value = 101 },
        @{ Field = 'EncryptionPercentage'; Value = -1 }
    ) {
        $conversion.$Field = $Value
        { Get-LibertixTargetVolumeEncryptionSnapshot -Drive 'J:' } | Should -Throw '*invalid*'
    }

    It 'refuses an inaccessible encryption provider' {
        Mock Get-CimInstance -ModuleName Libertix.StorageTargets { throw 'provider-unavailable' }
        { Get-LibertixTargetVolumeEncryptionState -Drive 'J:' } | Should -Throw '*provider-unavailable*'
    }

    It 'supports volumes not managed by BitLocker without issuing conversion commands' {
        Mock Get-CimInstance -ModuleName Libertix.StorageTargets { @() }
        Get-LibertixTargetVolumeEncryptionState -Drive 'J:' | Should -Be 'NotEncryptable'
        Should -Invoke Invoke-CimMethod -ModuleName Libertix.StorageTargets -Times 0
    }
}
