BeforeAll {
    Import-Module `
        "$PSScriptRoot/../Scripts/modules/Libertix.BootGuardian.psm1" `
        -Force
}

Describe "Boot guardian rollback" {
    It "rejects a writable service executable before launching it" {
        $payload = Join-Path $TestDrive "payload"
        $guardian = Join-Path $TestDrive "unsafe-guardian"
        $recovery = Join-Path $TestDrive "unsafe-recovery"
        New-Item -ItemType Directory -Path $payload, $guardian, "$recovery\boot-guardian" -Force | Out-Null
        Add-Type -Path "$PSScriptRoot/../Helpers/ProtectedFiles.cs" `
            -OutputAssembly "$payload\ProtectedFiles.dll" -OutputType Library
        Copy-Item "$payload\ProtectedFiles.dll" "$payload\Libertix.BootGuardian.exe"
        Set-Content "$guardian\Libertix.BootGuardian.exe" 'must not execute'
        $acl = Get-Acl $guardian
        $users = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $users, 'Modify', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
        Set-Acl $guardian $acl
        @{ version = 1; runId = 'test'; mode = 'firmware-boot-order' } |
            ConvertTo-Json | Set-Content "$recovery\boot-guardian\config.json"
        $state = [pscustomobject]@{ RunId = 'test'; RecoveryRoot = $recovery; PayloadRoot = $payload }
        InModuleScope Libertix.BootGuardian -Parameters @{ Root = $guardian } {
            $script:GuardianRoot = $Root
        }
        Mock Start-Process { throw 'Untrusted executable was launched' } -ModuleName Libertix.BootGuardian

        { Remove-LibertixBootGuardian -State $state -EspRoot $TestDrive -WriteLog {} } |
            Should -Throw '*untrusted account*'
        Should -Invoke Start-Process -Times 0 -ModuleName Libertix.BootGuardian
        Get-Content "$guardian\Libertix.BootGuardian.exe" | Should -Be 'must not execute'
        # Recovery must be able to remove its own payload after loading the protection code.
        [IO.File]::Delete("$payload\Libertix.BootGuardian.exe")
        Test-Path "$payload\Libertix.BootGuardian.exe" | Should -BeFalse
    }

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
