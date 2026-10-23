BeforeAll {
    . "$PSScriptRoot/../Scripts/uefi/Libertix.Uefi.Storage.ps1"
    . "$PSScriptRoot/../Scripts/uefi/Libertix.Uefi.Transaction.ps1"
    function Write-Log { param($Message, $Color) }
    function Dismount-Letter { param($Letter) }
}

Describe 'Temporary EFI ownership and write intent' {
    BeforeEach {
        $script:RecoveryRunId = '0123456789abcdef0123456789abcdef'
        $script:InstallerEspDirectory = 'EFI/LibertixInstaller'
        $script:InstalledEspDirectory = 'EFI/Libertix'
        $script:InstallerEspOwnershipFile = '.libertix-owner'
        $script:EspLetter = 'Y'
        $script:esp = Join-Path $TestDrive 'esp'
        $script:destination = Join-Path $script:esp $script:InstallerEspDirectory
        New-Item -ItemType Directory -Path $script:destination -Force | Out-Null
        $script:ownerPath = Join-Path $script:destination '.libertix-owner'
        Set-Content -LiteralPath $script:ownerPath -Value $script:RecoveryRunId -NoNewline
        $script:transaction = [pscustomobject]@{
            RecoveryRunId = $script:RecoveryRunId
            TemporaryBootPreparationStarted = $false
        }
        Mock Get-TransactionPartitionState { $script:transaction }
        Mock Save-LibertixTransactionStateAtomic {}
        Mock Mount-Esp { $script:esp }
        Mock Dismount-Letter {}
    }

    It 'removes the owned directory and accepts an already completed cleanup' {
        Remove-LibertixTemporaryEspFiles -EspDrive $script:esp
        Test-Path -LiteralPath $script:destination | Should -BeFalse
        { Remove-LibertixTemporaryEspFiles -EspDrive $script:esp } | Should -Not -Throw
    }

    It 'refuses a foreign owner before writes and releases the ESP mount' {
        Set-Content -LiteralPath $script:ownerPath -Value ('f' * 32) -NoNewline
        { Assert-LibertixEspPreparationOwnership } | Should -Throw '*another recovery run*'
        (Get-Content -LiteralPath $script:ownerPath -Raw) | Should -Be ('f' * 32)
        Should -Invoke Dismount-Letter -Times 1
        Should -Invoke Save-LibertixTransactionStateAtomic -Times 0
    }

    It 'does not arm write intent or replace a foreign temporary directory' {
        Set-Content -LiteralPath $script:ownerPath -Value ('f' * 32) -NoNewline
        { Install-LibertixTemporaryBootloaderOnEsp -EspDrive $script:esp -InstallerDrive $TestDrive } |
            Should -Throw '*another recovery run*'
        (Get-Content -LiteralPath $script:ownerPath -Raw) | Should -Be ('f' * 32)
        Should -Invoke Save-LibertixTransactionStateAtomic -Times 0
    }

    It 'persists write intent before deleting or copying any owned EFI file' {
        Mock Save-LibertixTransactionStateAtomic {
            $State.TemporaryBootPreparationStarted | Should -BeTrue
            Test-Path -LiteralPath $script:ownerPath | Should -BeTrue
            throw 'SIMULATED_STATE_WRITE_FAILURE'
        }
        { Install-LibertixTemporaryBootloaderOnEsp -EspDrive $script:esp -InstallerDrive $TestDrive } |
            Should -Throw '*SIMULATED_STATE_WRITE_FAILURE*'
        (Get-Content -LiteralPath $script:ownerPath -Raw) | Should -Be $script:RecoveryRunId
    }

    It 'keeps ownership verification ahead of downloads and partition changes' {
        $source = Get-Content "$PSScriptRoot/../Scripts/libertix-uefi-install.ps1" -Raw
        $preflight = $source.IndexOf('    Assert-LibertixEspPreparationOwnership')
        $preflight | Should -BeGreaterThan 0
        $preflight | Should -BeLessThan $source.IndexOf('    Set-WindowsVolumeReadableFromLinux')
        $preflight | Should -BeLessThan $source.IndexOf('    Set-DistributionIsoOnWindows')
        $preflight | Should -BeLessThan $source.IndexOf('    $info = New-OrReuseInstallerPartition')
    }
}
