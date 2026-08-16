BeforeAll {
    Import-Module `
        "$PSScriptRoot/../Scripts/modules/Libertix.PreferredBootPath.psm1" `
        -Force
}

Describe "Preferred Windows boot path transaction" {
    BeforeEach {
        $testDrivePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
            $TestDrive
        )
        $script:EspRoot = Join-Path $testDrivePath "esp"
        $script:RecoveryRoot = Join-Path $testDrivePath "recovery"
        $script:LibertixDirectory = Join-Path $script:EspRoot "EFI\Libertix"
        $script:MicrosoftDirectory = Join-Path $script:EspRoot "EFI\Microsoft\Boot"
        New-Item -ItemType Directory -Path $script:LibertixDirectory -Force | Out-Null
        New-Item -ItemType Directory -Path $script:MicrosoftDirectory -Force | Out-Null
        New-Item -ItemType Directory -Path $script:RecoveryRoot -Force | Out-Null

        Set-Content `
            -LiteralPath (Join-Path $script:LibertixDirectory "shimx64.efi") `
            -Value "verified-shim" `
            -Encoding ASCII `
            -NoNewline
        Set-Content `
            -LiteralPath (Join-Path $script:LibertixDirectory "grubx64.efi") `
            -Value "verified-grub" `
            -Encoding ASCII `
            -NoNewline
        Set-Content `
            -LiteralPath (Join-Path $script:LibertixDirectory "mmx64.efi") `
            -Value "verified-mm" `
            -Encoding ASCII `
            -NoNewline
        Set-Content `
            -LiteralPath (Join-Path $script:LibertixDirectory "grub.cfg") `
            -Value "configfile /boot/grub/grub.cfg" `
            -Encoding ASCII
        Set-Content `
            -LiteralPath (Join-Path $script:MicrosoftDirectory "bootmgfw.efi") `
            -Value "original-windows-loader" `
            -Encoding ASCII `
            -NoNewline

        $hash = {
            param($Name)
            (Get-FileHash `
                -LiteralPath (Join-Path $script:LibertixDirectory $Name) `
                -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        [ordered]@{
            version = 1
            status = "not-required"
            secureBootEnabled = $false
            selectedAuthority = "2011"
            images = [ordered]@{
                shim = [ordered]@{ sha256 = & $hash "shimx64.efi" }
                grub = [ordered]@{ sha256 = & $hash "grubx64.efi" }
                mokManager = [ordered]@{ sha256 = & $hash "mmx64.efi" }
            }
        } | ConvertTo-Json -Depth 8 | Set-Content `
            -LiteralPath (Join-Path $script:LibertixDirectory "secure-boot-chain.json") `
            -Encoding UTF8

        $script:State = [pscustomobject]@{
            RunId = "0123456789abcdef0123456789abcdef"
            RecoveryRoot = $script:RecoveryRoot
            SecureBootEnabled = $false
        }
        $script:EspPartition = [pscustomobject]@{
            DiskNumber = 0
            PartitionNumber = 1
            Offset = 1048576
            Size = 209715200
            Guid = "11111111-2222-3333-4444-555555555555"
        }
        $script:Log = { param($Message) $null = $Message }
    }

    It "backs up Windows, publishes shim last, and restores the exact original" {
        $originalHash = (Get-FileHash `
            -LiteralPath (Join-Path $script:MicrosoftDirectory "bootmgfw.efi") `
            -Algorithm SHA256).Hash

        $null = Install-LibertixPreferredBootPath `
            -State $script:State `
            -EspPartition $script:EspPartition `
            -EspRoot $script:EspRoot `
            -WriteLog $script:Log

        (Get-Content `
            -LiteralPath (Join-Path $script:MicrosoftDirectory "bootmgfw.efi") `
            -Raw) | Should -Be "verified-shim"
        (Get-Content `
            -LiteralPath (Join-Path $script:MicrosoftDirectory "bootmgfw.libertix-windows.efi") `
            -Raw) | Should -Be "original-windows-loader"
        (Get-Content `
            -LiteralPath (Join-Path $script:MicrosoftDirectory "grub.cfg") `
            -Raw) | Should -Match "bootmgfw\.libertix-windows\.efi"

        Restore-LibertixPreferredBootPath `
            -State $script:State `
            -EspRoot $script:EspRoot `
            -WriteLog $script:Log | Should -BeTrue

        (Get-FileHash `
            -LiteralPath (Join-Path $script:MicrosoftDirectory "bootmgfw.efi") `
            -Algorithm SHA256).Hash | Should -Be $originalHash
        Test-Path `
            -LiteralPath (Join-Path $script:MicrosoftDirectory "grubx64.efi") |
            Should -BeFalse
        Test-Path `
            -LiteralPath (Join-Path $script:RecoveryRoot "preferred-boot-path\bootmgfw.efi") |
            Should -BeTrue
    }

    It "refuses a changed installed chain before replacing Windows Boot Manager" {
        Set-Content `
            -LiteralPath (Join-Path $script:LibertixDirectory "shimx64.efi") `
            -Value "tampered-shim" `
            -Encoding ASCII `
            -NoNewline

        {
            Install-LibertixPreferredBootPath `
                -State $script:State `
                -EspPartition $script:EspPartition `
                -EspRoot $script:EspRoot `
                -WriteLog $script:Log
        } | Should -Throw "*differs from its Secure Boot evidence*"
        (Get-Content `
            -LiteralPath (Join-Path $script:MicrosoftDirectory "bootmgfw.efi") `
            -Raw) | Should -Be "original-windows-loader"
    }
}
