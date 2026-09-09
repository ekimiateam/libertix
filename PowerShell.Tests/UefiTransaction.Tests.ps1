BeforeAll {
    function New-UefiTransactionTestPlan {
        [pscustomobject]@{
            planId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            runtime = [pscustomobject]@{ recoveryRunId = '0123456789abcdef0123456789abcdef' }
            disk = [pscustomobject]@{
                number = 0; uniqueId = 'disk-identity'; sizeBytes = 256GB
                partitionStyle = 'GPT'; logicalSectorSizeBytes = 512
                partitionTableId = 'gpt:12345678-1234-1234-1234-123456789abc'
                systemDrive = 'C:'
                windows = [pscustomobject]@{ offsetBytes = 256MB; sizeBytes = 200GB }
                installer = [pscustomobject]@{ resizeMode = '' }
            }
        }
    }
    function New-UefiTransactionTestDisk {
        [pscustomobject]@{
            Number = 0; UniqueId = 'disk-identity'; Size = 256GB
            PartitionStyle = 'GPT'; LogicalSectorSize = 512
            Guid = '12345678-1234-1234-1234-123456789abc'
        }
    }
    function New-UefiAllocationTestPlan {
        $plan = New-UefiTransactionTestPlan
        $plan | Add-Member -NotePropertyName schemaVersion -NotePropertyValue 5
        $plan | Add-Member -NotePropertyName allocation -NotePropertyValue ([pscustomobject]@{
            number = 1; uniqueId = 'data-disk'; sizeBytes = 64GB
            partitionStyle = 'GPT'; logicalSectorSizeBytes = 512
            partitionTableId = 'gpt:87654321-1234-1234-1234-123456789abc'
            sourceDrive = 'J:'; sourceVolumeId = '\\?\Volume{data}\'
            sourceNtfsUuid = '1234567890ABCDEF'
            sourcePartition = [pscustomobject]@{ number = 2; offsetBytes = 16MB; sizeBytes = 60GB }
        })
        $plan
    }
    function New-UefiAllocationTestDisk {
        [pscustomobject]@{
            Number = 1; UniqueId = 'data-disk'; Size = 64GB
            PartitionStyle = 'GPT'; LogicalSectorSize = 512
            Guid = '87654321-1234-1234-1234-123456789abc'
        }
    }
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
    Import-Module (Join-Path $PSScriptRoot "../Scripts/modules/Libertix.AtomicFile.psm1") -Force
    Import-Module (Join-Path $PSScriptRoot "../Scripts/modules/Libertix.StorageTargets.psm1") -Force
    foreach ($component in @(
        "Libertix.Uefi.Execution.ps1",
        "Libertix.Uefi.Firmware.ps1",
        "Libertix.Uefi.Transaction.ps1",
        "Libertix.Uefi.Storage.ps1"
    )) {
        . (Join-Path $PSScriptRoot "../Scripts/uefi/$component")
    }
}

Describe 'UEFI partition removal retries' {
    BeforeEach {
        $script:InstallerLabel = 'LIBERTIX_INSTALLER'
        $script:removalAttempted = $false
        Mock Get-VerifiedTransactionPartition {
            [pscustomobject]@{ DiskNumber = 1; PartitionNumber = 5; DriveLetter = '' }
        }
        Mock Remove-Partition { $script:removalAttempted = $true; throw 'STORAGE_RESPONSE_LOST' }
        Mock Invoke-DiskpartScript {}
        Mock Assert-LibertixInstallerPartitionRemoved {}
        Mock Write-Log {}
    }

    It 'does not delete a second partition after a successful removal with a lost response' {
        Mock Get-VerifiedTransactionPartition {
            if (-not $script:removalAttempted) {
                [pscustomobject]@{ DiskNumber = 1; PartitionNumber = 5; DriveLetter = '' }
            }
        }
        Remove-LibertixInstallerPartitionIfPresent
        Should -Invoke Invoke-DiskpartScript -Times 0
    }

    It 'resolves the owned partition again before the diskpart fallback' {
        Mock Get-VerifiedTransactionPartition {
            [pscustomobject]@{
                DiskNumber = 1
                PartitionNumber = if ($script:removalAttempted) { 4 } else { 5 }
                DriveLetter = ''
            }
        }
        Remove-LibertixInstallerPartitionIfPresent
        Should -Invoke Invoke-DiskpartScript -Times 1 -Exactly -ParameterFilter {
            $ScriptText -match 'select partition 4' -and $ScriptText -notmatch 'select partition 5'
        }
    }

    It 'refuses the fallback when the storage identity changed after the failed removal' {
        Mock Get-VerifiedTransactionPartition {
            if ($script:removalAttempted) { throw 'DISK_IDENTITY_CHANGED' }
            [pscustomobject]@{ DiskNumber = 1; PartitionNumber = 5; DriveLetter = '' }
        }
        { Remove-LibertixInstallerPartitionIfPresent } | Should -Throw '*DISK_IDENTITY_CHANGED*'
        Should -Invoke Invoke-DiskpartScript -Times 0
    }
}

Describe 'UEFI partition presence verification' {
    BeforeEach {
        $script:installationPlan = New-UefiTransactionTestPlan
        $script:InstallerLabel = 'LIBERTIX_INSTALLER'
        Mock Get-Disk { New-UefiTransactionTestDisk }
        Mock Get-Partition {
            New-CimInstance -Namespace 'root/Microsoft/Windows/Storage' `
                -ClassName MSFT_Partition -ClientOnly -Property @{
                    DiskNumber = [uint32]0; PartitionNumber = [uint32]5
                }
        }
        Mock Get-Volume { [pscustomobject]@{ FileSystemLabel = 'DATA' } }
        Mock Start-Sleep {}
    }

    It 'queries labels only on the planned physical disk' {
        Test-LibertixInstallerPartitionPresent | Should -BeFalse
        Should -Invoke Get-Partition -Times 1 -Exactly -ParameterFilter { $DiskNumber[0] -eq 0 }
        Should -Invoke Get-Volume -Times 0 -ParameterFilter { $null -eq $Partition }
    }

    It 'finds an unowned staging label on the planned disk' {
        Mock Get-Volume { [pscustomobject]@{ FileSystemLabel = 'LIBERTIX_INSTALLER' } }
        Test-LibertixInstallerPartitionPresent | Should -BeTrue
    }

    It 'refuses to report an ext4 transaction partition as removed' {
        Mock Get-VerifiedTransactionPartition {
            [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 5 }
        }
        { Assert-LibertixInstallerPartitionRemoved } | Should -Throw '*still present*'
        Should -Invoke Get-Volume -Times 0
    }

    It 'accepts verified absence without consulting labels on unrelated disks' {
        Mock Get-VerifiedTransactionPartition { $null }
        Assert-LibertixInstallerPartitionRemoved
        Should -Invoke Get-Volume -Times 0
    }
}

Describe 'UEFI separate allocation transaction' {
    BeforeEach {
        $script:installationPlan = New-UefiAllocationTestPlan
        $script:TransactionStatePath = Join-Path $TestDrive "$([Guid]::NewGuid().ToString('N')).json"
        $script:InstallerLabel = 'LIBERTIX_INSTALLER'
        $script:BootStrategy = 'uefi-boot-next'
        $script:RecoveryRoot = 'C:\ProgramData\Libertix\UefiRecovery\0123456789abcdef0123456789abcdef'
        $script:LowMemoryMode = $false
        Mock Get-Disk {
            if ($Number[0] -eq 0) { New-UefiTransactionTestDisk } else { New-UefiAllocationTestDisk }
        }
        Mock Get-Partition {
            if ($DriveLetter -eq 'J') {
                [pscustomobject]@{ DiskNumber = 1; PartitionNumber = 2; Offset = 16MB; Size = 60GB }
            } elseif ($DriveLetter -eq 'C') {
                [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 3; Offset = 256MB; Size = 200GB }
            }
        }
        Mock Get-Volume { [pscustomobject]@{ UniqueId = '\\?\Volume{data}\'; FileSystem = 'NTFS' } }
        Mock Get-HibernateEnabled { $true }
        Mock Get-LibertixNtfsVolumeSerial { '1234567890ABCDEF' }
        Mock Get-LibertixTargetVolumeEncryptionSnapshot {
            [pscustomobject]@{ state = 'FullyDecrypted'; conversionStatus = 0; encryptionPercentage = 0; protectionStatus = 0 }
        }
        Mock Write-Log {}
    }

    It 'persists distinct source and Windows sizes before any source mutation' {
        Save-TransactionPreparationState -SystemPartition (Get-Partition -DriveLetter C)
        $state = Get-TransactionPartitionState
        $state.Version | Should -Be 2
        $state.DiskNumber | Should -Be 1
        $state.DiskUniqueId | Should -Be 'data-disk'
        $state.SystemDrive | Should -Be 'C:'
        $state.OriginalCSize | Should -Be 200GB
        $state.SourceDrive | Should -Be 'J:'
        $state.OriginalSourceSize | Should -Be 60GB
        $state.SourceOffset | Should -Be 16MB
        $state.SourceVolumeId | Should -Be '\\?\Volume{data}\'
        $state.SourceNtfsUuid | Should -Be '1234567890ABCDEF'
        $state.InitialSourceEncryption.state | Should -Be 'FullyDecrypted'
    }

    It 'rejects a replaced source volume before publishing recovery state' {
        Mock Get-Volume { [pscustomobject]@{ UniqueId = 'replacement'; FileSystem = 'NTFS' } }
        { Save-TransactionPreparationState -SystemPartition (Get-Partition -DriveLetter C) } |
            Should -Throw '*source volume changed*'
        Test-Path -LiteralPath $script:TransactionStatePath | Should -BeFalse
    }

    It 'retains the pre-decryption state when preparation is saved a second time' {
        Mock Get-LibertixTargetVolumeEncryptionSnapshot {
            [pscustomobject]@{ state = 'EncryptedOrProtected'; conversionStatus = 1; encryptionPercentage = 100; protectionStatus = 0 }
        }
        Save-TransactionPreparationState -SystemPartition (Get-Partition -DriveLetter C)
        Mock Get-LibertixTargetVolumeEncryptionSnapshot {
            [pscustomobject]@{ state = 'FullyDecrypted'; conversionStatus = 0; encryptionPercentage = 0; protectionStatus = 0 }
        }
        Save-TransactionPreparationState -SystemPartition (Get-Partition -DriveLetter C)
        $state = Get-TransactionPartitionState
        $state.InitialSourceEncryption.conversionStatus | Should -Be 1
        $state.InitialSourceEncryption.encryptionPercentage | Should -Be 100
    }

    It 'preserves the donor proof when persisting the newly created partition' {
        Save-TransactionPreparationState -SystemPartition (Get-Partition -DriveLetter C)
        Save-TransactionPartitionCreationIntent -DiskNumber 1 -Offset 40GB -Size 8GB
        Save-TransactionPartitionState -Partition ([pscustomobject]@{
            DiskNumber = 1; PartitionNumber = 3; Offset = 40GB; Size = 8GB
        })
        $state = Get-TransactionPartitionState
        $state.Version | Should -Be 2
        $state.SourceDrive | Should -Be 'J:'
        $state.OriginalSourceSize | Should -Be 60GB
        $state.OriginalCSize | Should -Be 200GB
        $state.PartitionNumber | Should -Be 3
    }

    It 'refuses to record an unrelated partition without the matching creation intent' {
        Save-TransactionPreparationState -SystemPartition (Get-Partition -DriveLetter C)
        { Save-TransactionPartitionState -Partition ([pscustomobject]@{
            DiskNumber = 1; PartitionNumber = 3; Offset = 40GB; Size = 8GB
        }) } | Should -Throw '*durable allocation intent*'
        (Get-TransactionPartitionState).PartitionNumber | Should -Be 0
    }

    It 'rejects altered source recovery evidence: <Field>' -ForEach @(
        @{ Field = 'Version'; Value = 1 },
        @{ Field = 'SourceDrive'; Value = 'C:' },
        @{ Field = 'SourceVolumeId'; Value = 'replacement' },
        @{ Field = 'SourceNtfsUuid'; Value = '8765432190ABCDEF' },
        @{ Field = 'OriginalSourceSize'; Value = 61GB },
        @{ Field = 'SourceOffset'; Value = 32MB },
        @{ Field = 'DiskNumber'; Value = 0 }
    ) {
        Save-TransactionPreparationState -SystemPartition (Get-Partition -DriveLetter C)
        $state = Get-TransactionPartitionState
        $state.$Field = $Value
        { Get-LibertixTransactionStorageBinding -State $state } | Should -Throw '*transaction*'
    }

    It 'resolves the expanded Linux partition only on the allocation disk' {
        Save-TransactionPreparationState -SystemPartition (Get-Partition -DriveLetter C)
        Save-TransactionPartitionCreationIntent -DiskNumber 1 -Offset 40GB -Size 8GB
        $script:installationPlan.disk.installer = [pscustomobject]@{
            resizeMode = 'live-offline'; finalOffsetBytes = 32GB; finalSizeBytes = 16GB
        }
        Mock Get-Partition {
            @([pscustomobject]@{ DiskNumber = 1; PartitionNumber = 3; Offset = 32GB; Size = 16GB })
        }
        $partition = Get-VerifiedTransactionPartition
        $partition.DiskNumber | Should -Be 1
        $partition.Offset | Should -Be 32GB
        Should -Invoke Get-Partition -Times 2 -ParameterFilter {
            $null -ne $DiskNumber -and $DiskNumber[0] -eq 1
        }
    }
}

Describe "UEFI transaction partition resolution" {
    BeforeEach {
        $script:installationPlan = New-UefiTransactionTestPlan
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
        Mock Get-Disk { New-UefiTransactionTestDisk }
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

    It 'refuses a replacement disk with identical vendor identity and partition geometry' {
        Mock Get-Disk {
            $disk = New-UefiTransactionTestDisk
            $disk.Guid = '87654321-1234-1234-1234-123456789abc'
            $disk
        }
        Mock Get-Partition { throw 'Partition enumeration must not be reached.' }
        { Get-VerifiedTransactionPartition -AllowMissing } | Should -Throw '*Disk identity*'
        Should -Invoke Get-Partition -Times 0
        Should -Invoke Save-LibertixTransactionStateAtomic -Times 0
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
        $script:installationPlan.disk.installer = [pscustomobject]@{
            resizeMode = $resizeMode
            finalOffsetBytes = 172872433664
            finalSizeBytes = 42949672960
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
        $script:installationPlan.disk.installer = [pscustomobject]@{
            resizeMode = 'windows-online'
            finalOffsetBytes = 172872433664
            finalSizeBytes = 42949672960
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
        $script:installationPlan.runtime.recoveryRunId = 'ffffffffffffffffffffffffffffffff'
        $script:installationPlan.disk.installer = [pscustomobject]@{
            resizeMode = 'live-offline'
            finalOffsetBytes = 172872433664
            finalSizeBytes = 42949672960
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

Describe "UEFI durable partition creation intent" {
    BeforeEach {
        $script:TransactionStatePath = Join-Path $TestDrive "transaction.json"
        $script:installationPlan = New-UefiTransactionTestPlan
        $state = [ordered]@{
            Version = 1; DiskNumber = 0; DiskUniqueId = "disk-identity"
            PartitionNumber = 0; PartitionOffset = 0; PartitionSize = 0
            RecoveryRunId = "0123456789abcdef0123456789abcdef"
        }
        $state | ConvertTo-Json | Set-Content -LiteralPath $script:TransactionStatePath -Encoding UTF8
        Mock Get-Disk { New-UefiTransactionTestDisk }
        Mock Get-Partition { @() }
        Mock Write-Log {}
    }

    It "finds a committed partition even when New-Partition never returned its number" {
        Save-TransactionPartitionCreationIntent -DiskNumber 0 -Offset 40GB -Size 8GB
        (Get-TransactionPartitionState).PartitionNumber | Should -Be 0
        Mock Get-Partition { @([pscustomobject]@{ DiskNumber = 0; PartitionNumber = 4; Offset = 40GB; Size = 8GB }) }
        $partition = Get-VerifiedTransactionPartition
        $partition.PartitionNumber | Should -Be 4
        (Get-TransactionPartitionState).PartitionNumber | Should -Be 4
    }

    It "allows rollback when interruption occurred before partition creation" {
        Save-TransactionPartitionCreationIntent -DiskNumber 0 -Offset 40GB -Size 8GB
        Get-VerifiedTransactionPartition -AllowMissing | Should -BeNullOrEmpty
    }

    It "refuses an extent that already contains another partition" {
        Mock Get-Partition { @([pscustomobject]@{ Offset = 41GB; Size = 1GB }) }
        { Save-TransactionPartitionCreationIntent -DiskNumber 0 -Offset 40GB -Size 8GB } | Should -Throw '*overlaps*'
        (Get-TransactionPartitionState).PartitionOffset | Should -Be 0
    }

    It "refuses another disk identity without persisting an intent" {
        Mock Get-Disk { [pscustomobject]@{ Number = 0; UniqueId = "another-disk"; Size = 100GB } }
        { Save-TransactionPartitionCreationIntent -DiskNumber 0 -Offset 40GB -Size 8GB } | Should -Throw '*unverified*'
        (Get-TransactionPartitionState).PartitionOffset | Should -Be 0
    }

    It 'refuses a replaced GPT disk before saving partition creation intent' {
        Mock Get-Disk {
            $disk = New-UefiTransactionTestDisk
            $disk.Guid = '87654321-1234-1234-1234-123456789abc'
            $disk
        }
        { Save-TransactionPartitionCreationIntent -DiskNumber 0 -Offset 40GB -Size 8GB } |
            Should -Throw '*Disk identity*'
        (Get-TransactionPartitionState).PartitionOffset | Should -Be 0
    }

    It "refuses an extent outside the disk without persisting an intent" {
        { Save-TransactionPartitionCreationIntent -DiskNumber 0 -Offset 255GB -Size 8GB } | Should -Throw '*unverified*'
        (Get-TransactionPartitionState).PartitionOffset | Should -Be 0
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
        $script:installationPlan = New-UefiTransactionTestPlan
        $script:RecoveryRunId = "0123456789abcdef0123456789abcdef"
        Mock Write-Log {}
        Mock Get-LibertixNtfsVolumeSerial { '1234567890ABCDEF' }
        Mock Get-TransactionPartitionState {
            [pscustomobject]@{
                RecoveryRunId = $script:RecoveryRunId
                DiskNumber = 0
                DiskUniqueId = 'disk-identity'
                LowMemoryMode = $false
                OriginalHibernateEnabled = $null
            }
        }
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = 0; Offset = 256MB } }
        Mock Get-Disk { New-UefiTransactionTestDisk }
        Mock Assert-LibertixTransactionRecoveryRunId {}
        Mock Mount-Esp { "Y:" }
        Mock Dismount-Letter {}
        Mock Remove-LibertixTemporaryEspFiles {}
        Mock Assert-LibertixInstalledEspOwnership { $false }
        Mock Remove-LibertixTemporaryFirmwareEntries {}
        Mock Restore-OriginalFirmwareBootOrder {}
        Mock Remove-LibertixInstallerPartitionIfPresent {}
        Mock Restore-LibertixSystemDriveInitialSize {}
        Mock Restore-LibertixSourceVolumeInitialSize {}
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

    It 'refuses a replacement disk before touching EFI or removing partitions' {
        Mock Get-Disk {
            $disk = New-UefiTransactionTestDisk
            $disk.Guid = '87654321-1234-1234-1234-123456789abc'
            $disk
        }
        { Invoke-Revert } | Should -Throw '*Disk identity*'
        Should -Invoke Mount-Esp -Times 0
        Should -Invoke Remove-LibertixInstallerPartitionIfPresent -Times 0
        Should -Invoke Restore-LibertixSystemDriveInitialSize -Times 0
    }

    It 'restores only the selected data volume and checks its initial encryption (<EncryptionChanged>)' -ForEach @(
        @{ EncryptionChanged = $false }, @{ EncryptionChanged = $true }
    ) {
        $script:installationPlan = New-UefiAllocationTestPlan
        Mock Get-TransactionPartitionState {
            [pscustomobject]@{
                Version = 2; RecoveryRunId = $script:RecoveryRunId
                DiskNumber = 1; DiskUniqueId = 'data-disk'
                SourceDrive = 'J:'; SourceVolumeId = '\\?\Volume{data}\'
                SourceNtfsUuid = '1234567890ABCDEF'
                InitialSourceEncryption = [pscustomobject]@{
                    state = if ($EncryptionChanged) { 'EncryptedOrProtected' } else { 'FullyDecrypted' }
                    conversionStatus = if ($EncryptionChanged) { 1 } else { 0 }
                    encryptionPercentage = if ($EncryptionChanged) { 100 } else { 0 }
                    protectionStatus = 0
                }
                SourceOffset = 16MB; OriginalSourceSize = 60GB
                LowMemoryMode = $false; OriginalHibernateEnabled = $null
            }
        }
        Mock Get-Partition {
            if ($DriveLetter -eq 'C') {
                [pscustomobject]@{ DiskNumber = 0; Offset = 256MB; Size = 200GB }
            } else {
                [pscustomobject]@{ DiskNumber = 1; Offset = 16MB; Size = 40GB }
            }
        }
        Mock Get-Disk {
            if ($Number[0] -eq 0) { New-UefiTransactionTestDisk } else { New-UefiAllocationTestDisk }
        }
        Mock Get-Volume { [pscustomobject]@{ UniqueId = '\\?\Volume{data}\'; FileSystem = 'NTFS' } }

        Mock Get-LibertixTargetVolumeEncryptionSnapshot {
            [pscustomobject]@{ state = 'FullyDecrypted'; conversionStatus = 0; encryptionPercentage = 0; protectionStatus = 0 }
        }
        if ($EncryptionChanged) {
            { Invoke-Revert } | Should -Throw '*source volume BitLocker state differs*'
            Should -Invoke Complete-LibertixTrackedRollback -Times 0
            Should -Invoke Remove-LibertixRecoveryTasksForRunId -Times 0
            Should -Invoke Save-LibertixRollbackTransactionArchive -Times 0
            return
        }
        Invoke-Revert

        Should -Invoke Restore-LibertixSystemDriveInitialSize -Times 0
        Should -Invoke Restore-LibertixSourceVolumeInitialSize -Times 1 -ParameterFilter {
            $SourceDrive -eq 'J:' -and $PlanDisk.number -eq 1 -and
            $SourcePartition.offsetBytes -eq 16MB -and $SourcePartition.sizeBytes -eq 60GB -and
            $ExpectedVolumeId -eq '\\?\Volume{data}\'
        }
        Should -Invoke Complete-LibertixTrackedRollback -Times 1
    }

    It 'refuses a separate-disk rollback before mutation when <Fault> changed' -ForEach @(
        @{ Fault = 'source-volume' }, @{ Fault = 'source-disk' }, @{ Fault = 'Windows-size' },
        @{ Fault = 'source-filesystem' }
    ) {
        $script:installationPlan = New-UefiAllocationTestPlan
        Mock Get-TransactionPartitionState {
            [pscustomobject]@{
                Version = 2; RecoveryRunId = $script:RecoveryRunId
                DiskNumber = 1; DiskUniqueId = 'data-disk'
                SourceDrive = 'J:'; SourceVolumeId = '\\?\Volume{data}\'
                SourceNtfsUuid = '1234567890ABCDEF'
                InitialSourceEncryption = [pscustomobject]@{ state = 'FullyDecrypted'; conversionStatus = 0; encryptionPercentage = 0; protectionStatus = 0 }
                SourceOffset = 16MB; OriginalSourceSize = 60GB
            }
        }
        Mock Get-Partition {
            if ($DriveLetter -eq 'C') {
                [pscustomobject]@{
                    DiskNumber = 0; Offset = 256MB
                    Size = if ($Fault -eq 'Windows-size') { 199GB } else { 200GB }
                }
            } else { [pscustomobject]@{ DiskNumber = 1; Offset = 16MB; Size = 40GB } }
        }
        Mock Get-Disk {
            if ($Number[0] -eq 0) { New-UefiTransactionTestDisk } else {
                $disk = New-UefiAllocationTestDisk
                if ($Fault -eq 'source-disk') { $disk.Guid = '99999999-1234-1234-1234-123456789abc' }
                $disk
            }
        }
        Mock Get-Volume {
            [pscustomobject]@{
                UniqueId = if ($Fault -eq 'source-volume') { 'replacement' } else { '\\?\Volume{data}\' }
                FileSystem = 'NTFS'
            }
        }
        if ($Fault -eq 'source-filesystem') {
            Mock Get-LibertixNtfsVolumeSerial { 'FEDCBA0987654321' }
        }
        { Invoke-Revert } | Should -Throw
        Should -Invoke Mount-Esp -Times 0
        Should -Invoke Remove-LibertixInstallerPartitionIfPresent -Times 0
        Should -Invoke Restore-LibertixSystemDriveInitialSize -Times 0
        Should -Invoke Restore-LibertixSourceVolumeInitialSize -Times 0
    }
}

Describe 'Completed UEFI rollback retains disk proof without reopening the ledger' {
    It 'retains the plan in the <Context> retry branch' -ForEach @(
        @{ Context = 'previousExecutionState' },
        @{ Context = 'rollbackContext.ExecutionState' }
    ) {
        $path = Join-Path $PSScriptRoot '../Scripts/libertix-uefi-install.ps1'
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
        @($errors).Count | Should -Be 0
        $branches = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
                $node.Clauses[0].Item1.Extent.Text -eq ('[string]$' + $Context + '.status -eq "rolled-back"')
        }, $true))
        $branches.Count | Should -Be 1
        $installationPlan = New-UefiTransactionTestPlan
        $originalPlan = $installationPlan
        $InstallationPlanPath = 'C:\recovery\installation-plan.json'
        $ExecutionStatePath = 'C:\recovery\installation-state.json'
        . ([scriptblock]::Create($branches[0].Clauses[0].Item2.Extent.Text.Trim().Trim('{', '}')))
        $installationPlan | Should -Be $originalPlan
        $InstallationPlanPath | Should -BeNullOrEmpty
        $ExecutionStatePath | Should -BeNullOrEmpty
        Test-LibertixTrackedExecution | Should -BeFalse
    }
}
