BeforeAll {
    . "$PSScriptRoot/../Scripts/uefi/Libertix.Uefi.Execution.ps1"
    . "$PSScriptRoot/../Scripts/uefi/Libertix.Uefi.Firmware.ps1"
}

Describe "Installed-system Secure Boot compatibility" {
    BeforeEach {
        Mock Confirm-SecureBootUEFI { $true }
        Mock Write-LibertixProgress {}
        Mock Write-Log {}
    }

    It "accepts a 2011 distribution when firmware trusts Microsoft UEFI CA 2011" {
        Mock Get-SecureBootDbCertificates {
            [pscustomobject]@{ Subject = "CN=Microsoft Corporation UEFI CA 2011, O=Microsoft" }
        }
        $plan = [pscustomobject]@{
            distribution = [pscustomobject]@{
                secureBootMicrosoftAuthorities = @("2011")
            }
        }

        { Test-LibertixSecureBootCompatibility -InstallationPlan $plan } |
            Should -Not -Throw
    }

    It "accepts a future 2023 distribution when firmware trusts Microsoft UEFI CA 2023" {
        Mock Get-SecureBootDbCertificates {
            [pscustomobject]@{ Subject = "CN=Microsoft UEFI CA 2023, O=Microsoft" }
        }
        $plan = [pscustomobject]@{
            distribution = [pscustomobject]@{
                secureBootMicrosoftAuthorities = @("2023")
            }
        }

        { Test-LibertixSecureBootCompatibility -InstallationPlan $plan } |
            Should -Not -Throw
    }

    It "rejects a 2011-only distribution on a 2023-only firmware before storage mutation" {
        Mock Get-SecureBootDbCertificates {
            [pscustomobject]@{ Subject = "CN=Microsoft UEFI CA 2023, O=Microsoft" }
        }
        $plan = [pscustomobject]@{
            distribution = [pscustomobject]@{
                secureBootMicrosoftAuthorities = @("2011")
            }
        }

        { Test-LibertixSecureBootCompatibility -InstallationPlan $plan } |
            Should -Throw "*installed system would not*"
    }

    It "does not require a signed chain while Secure Boot is disabled" {
        Mock Confirm-SecureBootUEFI { $false }
        Mock Get-SecureBootDbCertificates { throw "must not be inspected" }
        $plan = [pscustomobject]@{
            distribution = [pscustomobject]@{
                secureBootMicrosoftAuthorities = @("2011")
            }
        }

        { Test-LibertixSecureBootCompatibility -InstallationPlan $plan } |
            Should -Not -Throw
        Should -Invoke Get-SecureBootDbCertificates -Times 0
    }
}
