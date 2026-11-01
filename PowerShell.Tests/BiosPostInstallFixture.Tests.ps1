BeforeAll {
    $sourceRoot = Split-Path -Parent $PSScriptRoot
    $fixture = Join-Path $sourceRoot "auto_tests/app/scripts/request_bios_postinstall_rollback.ps1"
}

Describe "Post-install BIOS rollback fixture" {
    BeforeEach {
        $originalSystemDrive = $env:SystemDrive
        $env:SystemDrive = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $root = Join-Path $env:SystemDrive "LibertixInstallRecovery"
        [IO.Directory]::CreateDirectory($root) | Out-Null
        foreach ($name in @("Libertix.InstallationState.psm1", "Libertix.AtomicFile.psm1", "Libertix.Process.psm1")) {
            Copy-Item (Join-Path $sourceRoot "Scripts/modules/$name") (Join-Path $root $name)
        }
        Import-Module (Join-Path $root "Libertix.InstallationState.psm1") -Force
        $statePath = Join-Path $root "installation-state.json"
        $planId = [guid]::NewGuid().ToString('N')
        $null = New-LibertixExecutionState -Path $statePath -PlanId $planId
        $module = Get-Module Libertix.InstallationState | Where-Object {
            $_.Path -eq (Join-Path $root "Libertix.InstallationState.psm1")
        } | Select-Object -First 1
        foreach ($step in (& $module { $script:OrderedSteps })) {
            $null = Start-LibertixExecutionStep -Path $statePath -Step $step
            $null = Complete-LibertixExecutionStep -Path $statePath -Step $step
        }
        $null = Complete-LibertixInstallation -Path $statePath
        @{ planId = $planId; firmware = "bios" } | ConvertTo-Json |
            Set-Content (Join-Path $root "installation-plan.json")
        '{}' | Set-Content (Join-Path $root "installed-linux-boot.json")
        'param($Action); [IO.File]::WriteAllText((Join-Path $PSScriptRoot "requested.txt"), $Action)' |
            Set-Content (Join-Path $root "recover.ps1")
        $configPath = Join-Path $root "config.json"
        '{"expected_firmware":"bios"}' | Set-Content $configPath
    }
    AfterEach {
        $env:SystemDrive = $originalSystemDrive
        Get-Module -All | Where-Object { $_.Path -and $_.Path.StartsWith($root + "\", [StringComparison]::OrdinalIgnoreCase) } |
            Remove-Module -Force
    }

    It "invokes the installed recover.ps1 with Revert after a completed real ledger" {
        $output = & $fixture -ConfigPath $configPath
        $output | Should -Contain "RESULT=OK"
        Get-Content (Join-Path $root "requested.txt") | Should -BeExactly "Revert"
    }
    It "does not invoke recovery for an already running rollback" {
        $null = Start-LibertixRollback -Path $statePath
        { & $fixture -ConfigPath $configPath } | Should -Throw '*matching completed BIOS installation*'
        Test-Path (Join-Path $root "requested.txt") | Should -BeFalse
    }
    It "does not invoke recovery for another plan" {
        '{"firmware":"bios","planId":"other"}' | Set-Content (Join-Path $root "installation-plan.json")
        { & $fixture -ConfigPath $configPath } | Should -Throw '*matching completed BIOS installation*'
        Test-Path (Join-Path $root "requested.txt") | Should -BeFalse
    }
    It "preserves recovery diagnostics written to stdout on failure" {
        'param($Action); Write-Output "mbr.restore failed with Win32=87"; exit 1' |
            Set-Content (Join-Path $root "recover.ps1")
        { & $fixture -ConfigPath $configPath } |
            Should -Throw '*rc=1; mbr.restore failed with Win32=87*'
    }
}
