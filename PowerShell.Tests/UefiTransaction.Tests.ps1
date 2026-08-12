BeforeAll {
    $script:TransactionStatePath = "C:\LibertixTools\uefi-transaction.json"
    $script:RecoveryRunId = "0123456789abcdef0123456789abcdef"
    $script:ProgramData = "C:\ProgramData"
    $env:ProgramData = $script:ProgramData
    Import-Module `
        (Join-Path $PSScriptRoot "../Scripts/modules/Libertix.InstallationState.psm1") `
        -Force
    foreach ($component in @(
        "Libertix.Uefi.Execution.ps1",
        "Libertix.Uefi.Transaction.ps1",
        "Libertix.Uefi.Storage.ps1"
    )) {
        . (Join-Path $PSScriptRoot "../Scripts/uefi/$component")
    }
}

Describe "UEFI transaction partition resolution" {
    BeforeEach {
        $script:savedState = [pscustomobject]@{
            DiskNumber = 0
            DiskUniqueId = "disk-identity"
            PartitionNumber = 5
            PartitionOffset = 1048576
            PartitionSize = 8589934592
            RecoveryRunId = "0123456789abcdef0123456789abcdef"
            RecoveryRoot = "C:\ProgramData\Libertix\UefiRecovery\0123456789abcdef0123456789abcdef"
        }
        Mock Get-TransactionPartitionState { $script:savedState }
        Mock Get-Disk { [pscustomobject]@{ Number = 0; UniqueId = "disk-identity" } }
        Mock Write-Log {}
        Mock Save-LibertixTransactionStateAtomic {}
    }

    It "keeps a missing saved partition fatal during normal preparation" {
        Mock Get-Partition { @() }

        { Get-VerifiedTransactionPartition } |
            Should -Throw "*matches=0*"
    }

    It "accepts an already absent saved partition only during rollback" {
        Mock Get-Partition { @() }

        Get-VerifiedTransactionPartition -AllowMissing |
            Should -BeNullOrEmpty
        Should -Invoke Write-Log -Times 1
    }

    It "rejects ambiguous geometry even during rollback" {
        Mock Get-Partition {
            @(
                [pscustomobject]@{ PartitionNumber = 5; Offset = 1048576; Size = 8589934592 },
                [pscustomobject]@{ PartitionNumber = 6; Offset = 1048576; Size = 8589934592 }
            )
        }

        { Get-VerifiedTransactionPartition -AllowMissing } |
            Should -Throw "*matches=2*"
    }

    It "updates a renumbered partition while preserving geometry ownership" {
        Mock Get-Partition {
            @(
                [pscustomobject]@{
                    DiskNumber = 0
                    PartitionNumber = 7
                    Offset = 1048576
                    Size = 8589934592
                }
            )
        }

        $result = Get-VerifiedTransactionPartition

        $result.PartitionNumber | Should -Be 7
        $script:savedState.PartitionNumber | Should -Be 7
        Should -Invoke Save-LibertixTransactionStateAtomic -Times 1
    }
}

Describe "UEFI transaction recovery ownership" {
    BeforeEach {
        Mock Get-TransactionPartitionState {
            [pscustomobject]@{
                RecoveryRunId = "0123456789abcdef0123456789abcdef"
                RecoveryRoot = "C:\ProgramData\Libertix\UefiRecovery\0123456789abcdef0123456789abcdef"
            }
        }
    }

    It "accepts the recovery directory derived from the transaction owner" {
        $state = Get-ValidatedLibertixTransactionState

        $state.RecoveryRunId | Should -Be "0123456789abcdef0123456789abcdef"
    }

    It "rejects a recovery directory outside the owner's durable root" {
        Mock Get-TransactionPartitionState {
            [pscustomobject]@{
                RecoveryRunId = "0123456789abcdef0123456789abcdef"
                RecoveryRoot = "C:\unrelated"
            }
        }

        { Get-ValidatedLibertixTransactionState } |
            Should -Throw "*does not match its recovery identity*"
    }
}

Describe "UEFI rollback state requirements" {
    BeforeEach {
        $script:ExecutionStatePath = "C:\ProgramData\Libertix\UefiRecovery\0123456789abcdef0123456789abcdef\installation-state.json"
        Mock Write-Log {}
        Mock Get-TransactionPartitionState { $null }
        Mock Test-LibertixTrackedExecution { $true }
        Mock Mount-Esp { throw "Mount-Esp must not run without required transaction state." }
    }

    It "fails closed before firmware access when mutation proof has lost its owner state" {
        Mock Read-LibertixExecutionState {
            [pscustomobject]@{
                completedSteps = @(
                    "windows.preflight-verified",
                    "windows.artifacts-verified",
                    "windows.recovery-armed",
                    "windows.system-volume-shrunk"
                )
                compensatedSteps = @()
            }
        }

        { Invoke-Revert } | Should -Throw "*windows.system-volume-shrunk*"
        Should -Invoke Mount-Esp -Times 0
    }
}
