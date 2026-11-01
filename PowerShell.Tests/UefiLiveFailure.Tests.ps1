BeforeAll {
    $path = Join-Path $PSScriptRoot "..\Scripts\libertix-uefi-recovery-agent.ps1"
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    $function = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Restore-FailedLiveInstallation"
    }, $true)
    . ([scriptblock]::Create($function.Extent.Text))
    function Read-ValidatedExecutionState { param($RecoveryState) }
    function Restore-UefiTransactionArchive { param($State) }
    function Invoke-LibertixNativeCommand {
        param($FilePath, $ArgumentList, $TimeoutSeconds, $OnStandardOutputLine, $OnStandardErrorLine)
    }
}

Describe "UEFI recovery after live failure" {
    BeforeEach {
        $script:status = "failed"
        $script:resultCode = 0
        $script:completeRollback = $true
        $script:operations = [Collections.Generic.List[string]]::new()
        $script:state = @{ PayloadRoot = $TestDrive; RunId = "0123456789abcdef0123456789abcdef" }
        Mock Import-Module {}
        Mock Restore-UefiTransactionArchive {}
        Mock Read-ValidatedExecutionState { @{ status = $script:status } }
        Mock Invoke-LibertixNativeCommand {
            $script:operations.Add(($ArgumentList -join " "))
            if ($script:completeRollback -and $script:resultCode -eq 0) {
                $script:status = "rolled-back"
            }
            @{ ExitCode = $script:resultCode }
        }
    }

    It "resumes a <Status> rollback before permitting cleanup" -TestCases @(
        @{ Status = "failed" }
        @{ Status = "rollback-running" }
    ) {
        param($Status)
        $script:status = $Status
        Restore-FailedLiveInstallation -State $script:state
        $script:operations.Count | Should -Be 1
        $script:operations[0] | Should -Match "-Revert -ExpectedRecoveryRunId 0123456789abcdef0123456789abcdef"
        $script:operations[0] | Should -Not -Match "-RestoreWindowsSettings"
        Should -Invoke Read-ValidatedExecutionState -Times 2 -Exactly
    }

    It "only restores settings when the live already proved rollback" {
        $script:status = "rolled-back"
        Restore-FailedLiveInstallation -State $script:state
        $script:operations[0] | Should -Match "-RestoreWindowsSettings"
        $script:operations[0] | Should -Not -Match "-Revert "
    }

    It "rejects a zero exit code without a terminal rollback ledger" {
        $script:completeRollback = $false
        { Restore-FailedLiveInstallation -State $script:state } |
            Should -Throw "*did not prove a completed rollback*"
    }

    It "does not authorize cleanup after a child failure" {
        $script:resultCode = 1
        { Restore-FailedLiveInstallation -State $script:state } |
            Should -Throw "*failed with rc=1*"
        $script:status | Should -Be "failed"
    }

    It "refuses a success state even if a stale failure marker exists" {
        $script:status = "succeeded"
        { Restore-FailedLiveInstallation -State $script:state } |
            Should -Throw "*cannot restore an execution*"
        Should -Invoke Restore-UefiTransactionArchive -Times 0 -Exactly
        Should -Invoke Invoke-LibertixNativeCommand -Times 0 -Exactly
    }
}
