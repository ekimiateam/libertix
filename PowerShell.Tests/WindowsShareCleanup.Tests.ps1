BeforeAll {
    Import-Module (Join-Path $PSScriptRoot "../Scripts/modules/Libertix.TemporaryArtifacts.psm1") -Force
    $tokens = $null; $errors = $null
    $path = Join-Path $PSScriptRoot "../Scripts/libertix-uefi-recovery-agent.ps1"
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    $function = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Remove-RecoveryTasks"
    }, $true)
    . ([scriptblock]::Create($function.Extent.Text))
    $assignment = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$rollbackFromSucceeded'
    }, $true)
    $script:SelectCleanup = [scriptblock]::Create($assignment.Extent.Text + '; $rollbackFromSucceeded')
}

Describe "Recovery cleanup continuation" {
    It "still selects installed-share cleanup after the ledger has rolled back" {
        foreach ($status in @('succeeded', 'rollback-running', 'rolled-back')) {
            $executionState = [pscustomobject]@{
                status = $status; completedSteps = @('target.bootloader-installed')
            }
            & $script:SelectCleanup | Should -BeTrue
        }
        $executionState = [pscustomobject]@{ status = 'rolled-back'; completedSteps = @() }
        & $script:SelectCleanup | Should -BeFalse
    }

    It "keeps startup recovery armed if prompt removal fails" {
        $state = [pscustomobject]@{ TaskName = 'Startup'; PromptTaskName = 'Prompt' }
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'Prompt' } }
        Mock Unregister-ScheduledTask { throw 'PROMPT_REMOVE_FAILED' }
        { Remove-RecoveryTasks -State $state } | Should -Throw '*PROMPT_REMOVE_FAILED*'
        Should -Invoke Unregister-ScheduledTask -Times 0 -ParameterFilter { $TaskName -eq 'Startup' }
    }

    It "does not claim missing recovery tasks when the scheduler cannot be queried" {
        $state = [pscustomobject]@{ TaskName = 'Startup'; PromptTaskName = 'Prompt' }
        Mock Get-ScheduledTask { throw 'SCHEDULER_UNAVAILABLE' }
        Mock Unregister-ScheduledTask {}
        { Remove-RecoveryTasks -State $state } | Should -Throw '*SCHEDULER_UNAVAILABLE*'
        Should -Invoke Unregister-ScheduledTask -Times 0
    }
}

Describe "Resumable Windows sharing task cleanup" {
    BeforeEach {
        InModuleScope Libertix.TemporaryArtifacts {
            $script:tasks = @()
            $script:removed = @()
            foreach ($name in @("LibertixLinuxReadOnly", "LibertixLinuxReadOnlyPin_S_1_5_21_123_456_789_1001")) {
                $script:tasks += [pscustomobject]@{
                    TaskPath = '\'; TaskName = $name; State = 'Ready'
                    Actions = @([pscustomobject]@{
                        Execute = 'C:\Share\Libertix.BootGuardian.exe'
                        Arguments = '--run-hidden-powershell -File "C:\Share\mount-linux-readonly.ps1" -ConfigPath "C:\Share\config.json" -Pin'
                    })
                }
            }
            Mock Get-ScheduledTask { $script:tasks }
            Mock Stop-ScheduledTask {}
            Mock Unregister-ScheduledTask {
                param($TaskName)
                $script:removed += $TaskName
                $script:tasks = @($script:tasks | Where-Object TaskName -ne $TaskName)
            }
        }
    }

    It "removes the mount and per-user tasks even when the payload is already absent" {
        InModuleScope Libertix.TemporaryArtifacts {
            Remove-LibertixWindowsShareTasks -ShareRoot 'C:\Share'
            $script:removed.Count | Should -Be 2
            Remove-LibertixWindowsShareTasks -ShareRoot 'C:\Share'
            $script:removed.Count | Should -Be 2
        }
    }

    It "checks every task before removing any task" {
        InModuleScope Libertix.TemporaryArtifacts {
            $script:tasks[1].Actions[0].Execute = 'C:\Foreign\program.exe'
            { Remove-LibertixWindowsShareTasks -ShareRoot 'C:\Share' } | Should -Throw '*ownership*'
            $script:removed.Count | Should -Be 0
        }
    }

    It "does not mistake a scheduler query failure for successful cleanup" {
        InModuleScope Libertix.TemporaryArtifacts {
            Mock Get-ScheduledTask { throw 'QUERY_FAILED' }
            { Remove-LibertixWindowsShareTasks -ShareRoot 'C:\Share' } | Should -Throw '*QUERY_FAILED*'
            $script:removed.Count | Should -Be 0
        }
    }

    It "resumes after one task was removed and another removal failed" {
        InModuleScope Libertix.TemporaryArtifacts {
            Mock Unregister-ScheduledTask {
                param($TaskName)
                if ($TaskName -like '*Pin*') { throw 'REMOVE_FAILED' }
                $script:tasks = @($script:tasks | Where-Object TaskName -ne $TaskName)
            }
            { Remove-LibertixWindowsShareTasks -ShareRoot 'C:\Share' } | Should -Throw '*REMOVE_FAILED*'
            $script:tasks.Count | Should -Be 1
            Mock Unregister-ScheduledTask { $script:tasks = @() }
            Remove-LibertixWindowsShareTasks -ShareRoot 'C:\Share'
            $script:tasks.Count | Should -Be 0
        }
    }
}
