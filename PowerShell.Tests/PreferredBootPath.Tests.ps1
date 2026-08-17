BeforeAll {
    Import-Module `
        "$PSScriptRoot/../Scripts/modules/Libertix.Firmware.psm1" `
        -Force
    Import-Module `
        "$PSScriptRoot/../Scripts/modules/Libertix.PreferredBootPath.psm1" `
        -Force
}

Describe "Preferred Windows boot path transaction" {
    BeforeEach {
        $testDrivePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
            $TestDrive
        )
        $caseRoot = Join-Path $testDrivePath ([Guid]::NewGuid().ToString("N"))
        $script:EspRoot = Join-Path $caseRoot "esp"
        $script:RecoveryRoot = Join-Path $caseRoot "recovery"
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
        [ordered]@{
            schemaVersion = 1
            runId = $script:State.RunId
            windowsBootNumber = "Boot0001"
            windowsLoaderPath = "\EFI\Microsoft\Boot\bootmgfw.efi"
        } | ConvertTo-Json -Depth 4 | Set-Content `
            -LiteralPath (Join-Path $script:RecoveryRoot "firmware-boot-bypass.json") `
            -Encoding UTF8

        $devicePath = [System.Collections.Generic.List[byte]]::new()
        foreach ($value in (New-EfiFilePathNode -Path "\EFI\Microsoft\Boot\bootmgfw.efi")) {
            $devicePath.Add($value)
        }
        foreach ($value in (New-EfiEndNode)) {
            $devicePath.Add($value)
        }
        $description = [Text.Encoding]::Unicode.GetBytes("Windows Boot Manager" + [char]0)
        $entry = [System.Collections.Generic.List[byte]]::new()
        foreach ($value in [BitConverter]::GetBytes([uint32]1)) { $entry.Add($value) }
        foreach ($value in [BitConverter]::GetBytes([uint16]$devicePath.Count)) {
            $entry.Add($value)
        }
        foreach ($value in $description) { $entry.Add($value) }
        foreach ($value in $devicePath) { $entry.Add($value) }
        foreach ($value in [Text.Encoding]::ASCII.GetBytes("WINDOWS")) { $entry.Add($value) }
        $env:LIBERTIX_TEST_PREFERRED_BOOT_ENTRY = [Convert]::ToBase64String(
            [byte[]]$entry.ToArray()
        )
        $script:OriginalWindowsBootEntry = [byte[]]$entry.ToArray()

        Mock Import-LibertixPreferredPathFirmwareModules {} `
            -ModuleName Libertix.PreferredBootPath
        Mock Get-LibertixPreferredPathFirmwareVariableBytes {
            return ,([Convert]::FromBase64String($env:LIBERTIX_TEST_PREFERRED_BOOT_ENTRY))
        } -ModuleName Libertix.PreferredBootPath
        Mock Set-LibertixPreferredPathFirmwareVariableBytes {
            param($Name, $Bytes)
            $null = $Name
            $env:LIBERTIX_TEST_PREFERRED_BOOT_ENTRY = [Convert]::ToBase64String([byte[]]$Bytes)
        } -ModuleName Libertix.PreferredBootPath
        $script:EspPartition = [pscustomobject]@{
            DiskNumber = 0
            PartitionNumber = 1
            Offset = 1048576
            Size = 209715200
            Guid = "11111111-2222-3333-4444-555555555555"
        }
        $script:Log = { param($Message) $null = $Message }
    }

    AfterEach {
        Remove-Item Env:\LIBERTIX_TEST_PREFERRED_BOOT_ENTRY -ErrorAction SilentlyContinue
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
        (Get-EfiLoadOptionOptionalDataLength `
            -Bytes ([Convert]::FromBase64String(
                $env:LIBERTIX_TEST_PREFERRED_BOOT_ENTRY
            ))) | Should -Be 0
        Test-Path `
            -LiteralPath (Join-Path `
                $script:RecoveryRoot `
                "preferred-boot-path\windows-boot-entry.original.bin") |
            Should -BeTrue

        Restore-LibertixPreferredBootPath `
            -State $script:State `
            -EspRoot $script:EspRoot `
            -WriteLog $script:Log | Should -BeTrue

        (Get-FileHash `
            -LiteralPath (Join-Path $script:MicrosoftDirectory "bootmgfw.efi") `
            -Algorithm SHA256).Hash | Should -Be $originalHash
        $env:LIBERTIX_TEST_PREFERRED_BOOT_ENTRY |
            Should -Be ([Convert]::ToBase64String($script:OriginalWindowsBootEntry))
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

    It "archives and restores every pre-existing preferred-path destination" {
        $originalFiles = [ordered]@{
            "bootmgfw.libertix-windows.efi" = "pre-existing-backup-slot"
            "grubx64.efi" = "pre-existing-grub"
            "mmx64.efi" = "pre-existing-mm"
            "grub.cfg" = "pre-existing-config"
        }
        foreach ($entry in $originalFiles.GetEnumerator()) {
            Set-Content `
                -LiteralPath (Join-Path $script:MicrosoftDirectory $entry.Key) `
                -Value $entry.Value `
                -Encoding ASCII `
                -NoNewline
        }

        $manifest = Install-LibertixPreferredBootPath `
            -State $script:State `
            -EspPartition $script:EspPartition `
            -EspRoot $script:EspRoot `
            -WriteLog $script:Log

        @($manifest.originalFiles).Count | Should -Be 4
        foreach ($entry in $originalFiles.GetEnumerator()) {
            $archiveName = switch ($entry.Key) {
                "bootmgfw.libertix-windows.efi" {
                    "preexisting-bootmgfw.libertix-windows.efi"
                }
                "grubx64.efi" { "preexisting-grubx64.efi" }
                "mmx64.efi" { "preexisting-mmx64.efi" }
                "grub.cfg" { "preexisting-grub.cfg" }
            }
            (Get-Content `
                -LiteralPath (Join-Path `
                    $script:RecoveryRoot `
                    "preferred-boot-path\original-files\$archiveName") `
                -Raw) | Should -Be $entry.Value
        }

        # Reproduce a power loss after the manifests exist but before the Windows
        # backup slot and first-stage loader have both been published.
        Set-Content `
            -LiteralPath (Join-Path $script:MicrosoftDirectory "bootmgfw.efi") `
            -Value "original-windows-loader" `
            -Encoding ASCII `
            -NoNewline
        Set-Content `
            -LiteralPath (Join-Path `
                $script:MicrosoftDirectory `
                "bootmgfw.libertix-windows.efi") `
            -Value "pre-existing-backup-slot" `
            -Encoding ASCII `
            -NoNewline

        Restore-LibertixPreferredBootPath `
            -State $script:State `
            -EspRoot $script:EspRoot `
            -WriteLog $script:Log | Should -BeTrue

        foreach ($entry in $originalFiles.GetEnumerator()) {
            (Get-Content `
                -LiteralPath (Join-Path $script:MicrosoftDirectory $entry.Key) `
                -Raw) | Should -Be $entry.Value
        }
        Test-Path `
            -LiteralPath (Join-Path `
                $script:RecoveryRoot `
                "preferred-boot-path\original-files\preexisting-grubx64.efi") |
            Should -BeTrue
    }
}
