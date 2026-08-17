BeforeAll {
    Import-Module `
        "$PSScriptRoot/../Scripts/modules/Libertix.BootGuardian.psm1" `
        -Force
}

Describe "Boot guardian rollback" {
    It "accepts an exact preferred-path reference directory and removes it" {
        $testDrivePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
            $TestDrive
        )
        $runId = "0123456789abcdef0123456789abcdef"
        $guardianRoot = Join-Path $testDrivePath "guardian"
        $recoveryRoot = Join-Path $testDrivePath "recovery"
        $espRoot = Join-Path $testDrivePath "esp"
        $referenceRoot = Join-Path $espRoot "EFI\Libertix\BootGuardianReference"
        New-Item -ItemType Directory -Path $guardianRoot -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $recoveryRoot "boot-guardian") -Force |
            Out-Null
        New-Item -ItemType Directory -Path $referenceRoot -Force | Out-Null
        foreach ($name in @(
            ".libertix-owner",
            "shimx64.efi",
            "grubx64.efi",
            "mmx64.efi",
            "grub.cfg"
        )) {
            $value = if ($name -eq ".libertix-owner") { $runId } else { $name }
            [IO.File]::WriteAllText(
                (Join-Path $referenceRoot $name),
                $value,
                [Text.UTF8Encoding]::new($false)
            )
        }
        [ordered]@{
            version = 1
            runId = $runId
            mode = "preferred-windows-path"
        } | ConvertTo-Json | Set-Content `
            -LiteralPath (Join-Path $recoveryRoot "boot-guardian\config.json") `
            -Encoding UTF8
        $state = [pscustomobject]@{
            RunId = $runId
            RecoveryRoot = $recoveryRoot
        }
        InModuleScope Libertix.BootGuardian -Parameters @{ Root = $guardianRoot } {
            $script:GuardianRoot = $Root
        }
        Mock Get-Service { return $null } -ModuleName Libertix.BootGuardian

        Remove-LibertixBootGuardian `
            -State $state `
            -EspRoot $espRoot `
            -WriteLog { param($Message) $null = $Message } | Should -BeTrue

        Test-Path -LiteralPath $referenceRoot | Should -BeFalse
        Test-Path -LiteralPath $guardianRoot | Should -BeFalse
    }
}
