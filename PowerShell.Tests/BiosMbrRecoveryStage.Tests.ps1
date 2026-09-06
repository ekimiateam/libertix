BeforeAll {
    $path = Join-Path $PSScriptRoot "../Scripts/libertix-recovery-guard.ps1"
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) { throw $errors[0] }
    $function = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Restore-BiosMbrBootCode"
    }, $true)
    . ([scriptblock]::Create($function.Extent.Text))
    function Write-RecoveryLog { param([string]$Message) }
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
