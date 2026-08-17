BeforeAll {
    $script:TransactionStatePath = "C:\LibertixTools\uefi-transaction.json"
    $script:RecoveryRunId = "0123456789abcdef0123456789abcdef"
    $script:ProgramData = "C:\ProgramData"
    $script:SystemDrive = "C:"
    $script:LowMemoryIsoPath = "C:\libertix-live.iso"
    $script:EspLetter = "Y"
    $script:InstallerEspDirectory = "EFI\LibertixInstaller"
    $script:installationPolicy = [pscustomobject]@{
        storage = [pscustomobject]@{ partitionAlignmentBytes = 1048576 }
    }
    $env:ProgramData = $script:ProgramData
    Import-Module `
        (Join-Path $PSScriptRoot "../Scripts/modules/Libertix.InstallationState.psm1") `
        -Force
    Import-Module `
        (Join-Path $PSScriptRoot "../Scripts/modules/Libertix.Rollback.psm1") `
        -Force
    Import-Module `
        (Join-Path $PSScriptRoot "../Scripts/modules/Libertix.TemporaryArtifacts.psm1") `
        -Force
    foreach ($component in @(
        "Libertix.Uefi.Execution.ps1",
        "Libertix.Uefi.Firmware.ps1",
        "Libertix.Uefi.Transaction.ps1",
        "Libertix.Uefi.Storage.ps1"
    )) {
        . (Join-Path $PSScriptRoot "../Scripts/uefi/$component")
    }
}

Describe "UEFI transaction partition resolution" {
    BeforeEach {
        $script:installationPlan = $null
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

    It "resolves the live-expanded partition from the matching durable plan" -ForEach @(
        @{ resizeMode = "windows-online" },
        @{ resizeMode = "live-offline" }
    ) {
        $script:installationPlan = [pscustomobject]@{
            planId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            runtime = [pscustomobject]@{
                recoveryRunId = "0123456789abcdef0123456789abcdef"
            }
            disk = [pscustomobject]@{
                number = 0
                installer = [pscustomobject]@{
                    resizeMode = $resizeMode
                    finalOffsetBytes = 172872433664
                    finalSizeBytes = 42949672960
                }
            }
        }
        Mock Get-Partition {
            @(
                [pscustomobject]@{
                    DiskNumber = 0
                    PartitionNumber = 5
                    Offset = 172872433664
                    Size = 42949672960
                }
            )
        }

        $result = Get-VerifiedTransactionPartition

        $result.Offset | Should -Be 172872433664
        $script:savedState.PartitionOffset | Should -Be 172872433664
        $script:savedState.PartitionSize | Should -Be 42949672960
        Should -Invoke Save-LibertixTransactionStateAtomic -Times 1
    }

    It "accepts and persists a final partition rounded down within alignment tolerance" {
        $script:installationPlan = [pscustomobject]@{
            planId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            runtime = [pscustomobject]@{
                recoveryRunId = "0123456789abcdef0123456789abcdef"
            }
            disk = [pscustomobject]@{
                number = 0
                installer = [pscustomobject]@{
                    resizeMode = "windows-online"
                    finalOffsetBytes = 172872433664
                    finalSizeBytes = 42949672960
                }
            }
        }
        $observedSize = 42949672960 - 1048576
        Mock Get-Partition {
            @([pscustomobject]@{
                DiskNumber = 0
                PartitionNumber = 5
                Offset = 172872433664
                Size = $observedSize
            })
        }

        $result = Get-VerifiedTransactionPartition

        $result.Size | Should -Be $observedSize
        $script:savedState.PartitionSize | Should -Be $observedSize
        Should -Invoke Save-LibertixTransactionStateAtomic -Times 1
    }

    It "does not trust a relocated partition from another recovery run" {
        $script:installationPlan = [pscustomobject]@{
            planId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            runtime = [pscustomobject]@{
                recoveryRunId = "ffffffffffffffffffffffffffffffff"
            }
            disk = [pscustomobject]@{
                number = 0
                installer = [pscustomobject]@{
                    resizeMode = "live-offline"
                    finalOffsetBytes = 172872433664
                    finalSizeBytes = 42949672960
                }
            }
        }
        Mock Get-Partition {
            @(
                [pscustomobject]@{
                    DiskNumber = 0
                    PartitionNumber = 5
                    Offset = 172872433664
                    Size = 42949672960
                }
            )
        }

        { Get-VerifiedTransactionPartition } | Should -Throw "*matches=0*"
        Should -Invoke Save-LibertixTransactionStateAtomic -Times 0
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

Describe "UEFI post-install rollback compensation" {
    BeforeEach {
        $script:RecoveryRunId = "0123456789abcdef0123456789abcdef"
        Mock Write-Log {}
        Mock Get-TransactionPartitionState {
            [pscustomobject]@{
                RecoveryRunId = $script:RecoveryRunId
                LowMemoryMode = $false
                OriginalHibernateEnabled = $null
            }
        }
        Mock Assert-LibertixTransactionRecoveryRunId {}
        Mock Mount-Esp { "Y:" }
        Mock Dismount-Letter {}
        Mock Remove-LibertixTemporaryEspFiles {}
        Mock Assert-LibertixInstalledEspOwnership { $false }
        Mock Remove-LibertixTemporaryFirmwareEntries {}
        Mock Restore-OriginalFirmwareBootOrder {}
        Mock Remove-LibertixInstallerPartitionIfPresent {}
        Mock Restore-LibertixSystemDriveInitialSize {}
        Mock Remove-LibertixRecoveryTasksForRunId {}
        Mock Remove-LibertixTransactionDownloads {}
        Mock Remove-LibertixUefiToolArtifacts {}
        Mock Save-LibertixRollbackTransactionArchive {}
        Mock Remove-Item {}
        Mock Complete-LibertixTrackedCompensation {}
        Mock Complete-LibertixTrackedRollback {}
    }

    It "records every live and target compensation after the owned partition is removed" {
        Invoke-Revert

        foreach ($step in @(
            "target.bootloader-installed",
            "target.system-configured",
            "live.distribution-extracted",
            "live.target-filesystem-created",
            "live.installer-partition-expanded"
        )) {
            Should -Invoke Complete-LibertixTrackedCompensation `
                -Times 1 `
                -ParameterFilter { $Step -eq $step }
        }
        Should -Invoke Restore-LibertixSystemDriveInitialSize -Times 1
        Should -Invoke Complete-LibertixTrackedRollback -Times 1
    }
}
