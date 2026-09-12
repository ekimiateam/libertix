BeforeAll {
    $path = Join-Path $PSScriptRoot "../Scripts/libertix-recovery-guard.ps1"
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) { throw $errors[0] }
    foreach ($functionName in @('Restore-BiosMbrBootCode', 'Remove-OwnedBiosBcdEntry')) {
        $function = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
        }, $true)
        . ([scriptblock]::Create($function.Extent.Text))
    }
    function Write-RecoveryLog { param([string]$Message) }
    function Read-EnvValue { param([string]$Path, [string]$Name) }
    function Get-LibertixNativeSystemExecutable { param([string]$FileName) }
    function Invoke-LibertixNativeCommand {
        param([string]$FilePath, [string[]]$ArgumentList, [int]$TimeoutSeconds)
    }
}

Describe 'BIOS delayed uninstall preserves unrelated BCD entries' {
    BeforeEach {
        $script:Pending = 'C:\LibertixInstallRecovery\pending.env'
        $script:SystemDrive = 'C:'
        $script:enumerationCount = 0
        $script:deletedArguments = $null
        Mock Read-EnvValue { '0123456789abcdef0123456789abcdef' }
        Mock Get-LibertixNativeSystemExecutable { 'C:\Windows\System32\bcdedit.exe' }
        Mock Write-RecoveryLog {}
        Mock Invoke-LibertixNativeCommand {
            if ($ArgumentList[0] -eq '/delete') {
                $script:deletedArguments = @($ArgumentList)
                return [pscustomobject]@{
                    ExitCode = 0; StandardOutput = 'deleted'; StandardError = ''
                }
            }
            $script:enumerationCount++
            $owned = @'
Chargeur de secteur de demarrage
--------------------------------
identificateur          {11111111-2222-3333-4444-555555555555}
device                  partition=C:
path                    \grldr.mbr
description             Libertix BIOS Installer 0123456789abcdef0123456789abcdef
'@
            $foreign = @'
Chargeur de demarrage Windows
-----------------------------
identificateur          {aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}
device                  partition=C:
path                    \Windows\system32\winload.exe
description             Windows 11 maintenance entry
'@
            [pscustomobject]@{
                ExitCode = 0
                StandardOutput = if ($script:enumerationCount -eq 1) {
                    "$owned`r`n`r`n$foreign"
                } else {
                    $foreign
                }
                StandardError = ''
            }
        }
    }

    It 'deletes only the exact transaction-owned entry' {
        Remove-OwnedBiosBcdEntry

        $script:deletedArguments | Should -Be @(
            '/delete', '{11111111-2222-3333-4444-555555555555}', '/f'
        )
        Should -Invoke Invoke-LibertixNativeCommand -Times 0 -ParameterFilter {
            $ArgumentList[0] -eq '/import'
        }
        Should -Invoke Invoke-LibertixNativeCommand -Times 2 -ParameterFilter {
            $ArgumentList[0] -eq '/enum'
        }
    }

    It 'keeps whole-store import available for immediate installation rollback' {
        $guard = Get-Content "$PSScriptRoot/../Scripts/libertix-recovery-guard.ps1" -Raw
        $restoreCall = $guard.Substring($guard.IndexOf('$bcdRestored = Invoke-RecoveryOperation'))
        $restoreCall = $restoreCall.Substring(0, $restoreCall.IndexOf('$mbrRestored ='))

        $restoreCall | Should -Match '-PreserveUnrelatedChanges:\$VerifiedUninstall'
        $restoreCall | Should -Not -Match '-PreserveUnrelatedChanges:\$rollbackFromSucceeded'
    }
}

Describe "BIOS MBR recovery distinguishes Windows preparation from live GRUB installation" {
    BeforeEach {
        $MbrBackup = Join-Path $TestDrive "mbr-before-grub.bin"
        $MbrBackupHash = Join-Path $TestDrive "mbr-before-grub.sha256"
        Mock Write-RecoveryLog {}
        $state = [pscustomobject]@{
            status = "rollback-running"
            activeStep = $null
            completedSteps = @("windows.temporary-boot-prepared")
        }
    }

    It "does not require a live backup when reboot-ready was never acknowledged" {
        Restore-BiosMbrBootCode -DiskNumber -1 -ExecutionState $state
        Should -Invoke Write-RecoveryLog -Times 1 -Exactly -ParameterFilter {
            $Message -like '*boot-code restore skipped*'
        }
    }

    It "still requires the backup after the step preceding GRUB completed" {
        $state.completedSteps += "target.system-configured"
        { Restore-BiosMbrBootCode -DiskNumber -1 -ExecutionState $state } |
            Should -Throw '*Required pre-GRUB MBR backup*'
    }

    It "keeps the requirement when rollback has cleared the active GRUB step" {
        $state.completedSteps += @("target.system-configured", "target.bootloader-installed")
        { Restore-BiosMbrBootCode -DiskNumber -1 -ExecutionState $state } |
            Should -Throw '*Required pre-GRUB MBR backup*'
    }

    It "rejects an incomplete backup even before the live installation" {
        [IO.File]::WriteAllBytes($MbrBackup, (New-Object byte[] 512))
        { Restore-BiosMbrBootCode -DiskNumber -1 -ExecutionState $state } |
            Should -Throw '*missing or incomplete*'
    }

    It "rejects a corrupt backup without touching a physical disk" {
        [IO.File]::WriteAllBytes($MbrBackup, (New-Object byte[] 512))
        [IO.File]::WriteAllText($MbrBackupHash, ('f' * 64))
        { Restore-BiosMbrBootCode -DiskNumber -1 -ExecutionState $state } |
            Should -Throw '*checksum verification failed*'
    }
}
