BeforeAll {
    Import-Module (Join-Path $PSScriptRoot "../Scripts/modules/Libertix.TemporaryArtifacts.psm1") -Force
}

Describe "Transaction-owned BIOS boot payload cleanup" {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        $recovery = Join-Path $root "LibertixInstallRecovery"
        New-Item -ItemType Directory -Path $recovery -Force | Out-Null
        $files = @{}
        foreach ($name in @("grldr", "grldr.mbr", "menu.lst")) {
            $path = Join-Path $root $name
            Set-Content -LiteralPath $path -Value $name -Encoding UTF8
            $files[$name] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $manifest = @{ version = 1; planId = ('a' * 32); files = $files }
        $manifestPath = Join-Path $recovery "bios-boot-payload.json"
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    }

    It "removes owned files and safely repeats cleanup" {
        Remove-LibertixBiosBootPayload -SystemRoot $root -RecoveryRoot $recovery -PlanId ('a' * 32)
        Remove-LibertixBiosBootPayload -SystemRoot $root -RecoveryRoot $recovery -PlanId ('a' * 32)
        @(Get-ChildItem -LiteralPath $root -File).Count | Should -Be 0
    }

    It "preserves preexisting files when there is no ownership manifest" {
        Remove-Item -LiteralPath $manifestPath
        Remove-LibertixBiosBootPayload -SystemRoot $root -RecoveryRoot $recovery -PlanId ('a' * 32)
        @(Get-ChildItem -LiteralPath $root -File).Count | Should -Be 3
    }

    It "rejects another installation before any deletion" {
        { Remove-LibertixBiosBootPayload -SystemRoot $root -RecoveryRoot $recovery -PlanId ('b' * 32) } | Should -Throw
        @(Get-ChildItem -LiteralPath $root -File).Count | Should -Be 3
    }

    It "rejects altered files before any deletion" {
        Set-Content -LiteralPath (Join-Path $root "menu.lst") -Value "foreign boot menu"
        { Remove-LibertixBiosBootPayload -SystemRoot $root -RecoveryRoot $recovery -PlanId ('a' * 32) } | Should -Throw
        @(Get-ChildItem -LiteralPath $root -File).Count | Should -Be 3
    }

    It "rejects unexpected destination names" {
        $manifest.files['unexpected'] = 'a' * 64
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        { Remove-LibertixBiosBootPayload -SystemRoot $root -RecoveryRoot $recovery -PlanId ('a' * 32) } | Should -Throw
        @(Get-ChildItem -LiteralPath $root -File).Count | Should -Be 3
    }
}
