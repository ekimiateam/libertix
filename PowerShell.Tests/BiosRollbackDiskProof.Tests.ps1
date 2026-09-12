BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../Scripts/modules/Libertix.Rollback.psm1') -Force
    $path = Join-Path $PSScriptRoot '../Scripts/libertix-recovery-guard.ps1'
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    foreach ($name in @('Test-RecoveryRawPartitionGeometry', 'Remove-EmptyTransactionExtendedContainer', 'Write-RecoveryLog')) {
        $function = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        . ([scriptblock]::Create($function.Extent.Text))
    }
    $operation = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
            $node.Extent.Text.StartsWith('Invoke-RecoveryOperation -Name "disk-layout.restore"')
    }, $true)
    $body = $operation.CommandElements | Where-Object {
        $_ -is [Management.Automation.Language.ScriptBlockExpressionAst]
    }
    $restoreDiskLayout = [scriptblock]::Create($body.ScriptBlock.Extent.Text.Trim().Trim('{', '}'))
    $planGuard = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Extent.Text.Contains("throw 'The BIOS rollback plan does not match its pending recovery metadata.'")
    }, $true)
    $assertPendingPlan = [scriptblock]::Create($planGuard.Extent.Text)
}

Describe 'BIOS rollback validates physical identity before removing a partition' {
    BeforeEach {
        $VerifiedUninstall = $false
        $SystemDrive = 'C:'
        $SystemDriveLetter = 'C'
        $diskNumber = 3
        $systemPartitionNumber = 2
        $initialSystemOffset = 256MB
        $initialSystemSize = 60GB
        $initialSystemEnd = $initialSystemOffset + $initialSystemSize
        $expectedDiskId = 'vendor-id'
        $expectedRecoveryRunId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        $recoveryPartitionOffset = 61GB
        $expectedBytes = 20GB
        $stagingBytes = 8GB
        $partitionSizeTolerance = 1MB
        $PartitionAlignmentBytes = 1MB
        $expectedTransactionOffset = 40GB + 256MB
        $minBytes = 20GB - 1MB
        $maxBytes = 20GB + 1MB
        $stagingMinBytes = 8GB - 1MB
        $stagingMaxBytes = 8GB + 1MB
        $StagingVolumeLabel = 'LTXINSTALL'
        $LegacyStagingVolumeLabels = @('LIBERTIX')
        $script:observedDisk = [pscustomobject]@{
            Number = 3; UniqueId = 'vendor-id'; Size = 64GB
            PartitionStyle = 'MBR'; LogicalSectorSize = 512; Signature = 0x12345678
        }
        $script:observedWindows = [pscustomobject]@{
            DiskNumber = 3; PartitionNumber = 2; Offset = 256MB; Size = 40GB; MbrType = 7
        }
        $rollbackPlan = [pscustomobject]@{
            schemaVersion = 4; firmware = 'bios'; planId = $expectedRecoveryRunId
            runtime = [pscustomobject]@{ recoveryRunId = $expectedRecoveryRunId }
            disk = [pscustomobject]@{
                number = 3; uniqueId = 'vendor-id'; sizeBytes = 64GB; partitionStyle = 'MBR'
                logicalSectorSizeBytes = 512; partitionTableId = 'mbr:12345678'; systemDrive = 'C:'
                windows = [pscustomobject]@{ number = 2; offsetBytes = 256MB; sizeBytes = 60GB }
                recovery = [pscustomobject]@{ offsetBytes = 61GB }
                installer = [pscustomobject]@{ finalSizeBytes = 20GB; stagingSizeBytes = 8GB }
            }
        }
        Mock Get-Disk { $script:observedDisk }
        Mock Get-Partition {
            if ($DriveLetter -eq 'C') { $script:observedWindows } else {
                @($script:observedWindows, [pscustomobject]@{
                    DiskNumber = 3; PartitionNumber = 3; Offset = 40GB + 256MB; Size = 20GB; MbrType = 131
                })
            }
        }
        Mock Get-Volume { $null }
        Mock Remove-Partition {}
        Mock Remove-EmptyTransactionExtendedContainer {}
        Mock Restore-LibertixSystemDriveInitialSize {}
        Mock Restore-LibertixSourceVolumeInitialSize {}
        Mock Write-RecoveryLog {}
        Mock Start-Sleep {}
    }

    It 'removes only the owned raw Linux extent and restores the plan source' {
        . $assertPendingPlan
        . $restoreDiskLayout
        Should -Invoke Remove-Partition -Times 1 -ParameterFilter {
            $DiskNumber -eq 3 -and $PartitionNumber -eq 3
        }
        Should -Invoke Restore-LibertixSystemDriveInitialSize -Times 1 -ParameterFilter {
            $PlanDisk.partitionTableId -eq 'mbr:12345678' -and $State.OriginalCSize -eq 60GB
        }
    }

    It 'refuses a clone with the same vendor ID but another MBR signature' {
        $script:observedDisk.Signature = [uint32]2271560481
        { . $restoreDiskLayout } | Should -Throw '*Disk identity*'
        Should -Invoke Remove-Partition -Times 0
        Should -Invoke Restore-LibertixSystemDriveInitialSize -Times 0
    }

    It 'replays after partition removal succeeded but its acknowledgement was interrupted' {
        $script:transactionRemoved = $false
        Mock Get-Partition {
            if ($DriveLetter -eq 'C' -or $script:transactionRemoved) { $script:observedWindows } else {
                @($script:observedWindows, [pscustomobject]@{
                    DiskNumber = 3; PartitionNumber = 3; Offset = 40GB + 256MB; Size = 20GB; MbrType = 131
                })
            }
        }
        Mock Remove-Partition {
            $script:transactionRemoved = $true
            throw 'Injected interruption after physical removal.'
        }
        { . $restoreDiskLayout } | Should -Throw '*Injected interruption*'
        Should -Invoke Restore-LibertixSystemDriveInitialSize -Times 0
        . $restoreDiskLayout
        Should -Invoke Remove-Partition -Times 1 -Exactly
        Should -Invoke Restore-LibertixSystemDriveInitialSize -Times 1 -Exactly
    }

    It 'refuses a moved Windows start before any removal' {
        $script:observedWindows.Offset += 1MB
        { . $restoreDiskLayout } | Should -Throw '*system partition identity changed*'
        Should -Invoke Remove-Partition -Times 0
    }

    It 'rejects inconsistent recovery evidence: <Fault>' -ForEach @(
        @{ Fault = 'run-id' }, @{ Fault = 'source-size' }, @{ Fault = 'recovery-offset' },
        @{ Fault = 'linux-size' }, @{ Fault = 'disk-id' }
    ) {
        switch ($Fault) {
            'run-id' { $rollbackPlan.planId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' }
            'source-size' { $rollbackPlan.disk.windows.sizeBytes = 61GB }
            'recovery-offset' { $rollbackPlan.disk.recovery.offsetBytes = 62GB }
            'linux-size' { $rollbackPlan.disk.installer.finalSizeBytes = 21GB }
            'disk-id' { $expectedDiskId = '' }
        }
        { . $assertPendingPlan } | Should -Throw '*pending recovery metadata*'
        Should -Invoke Get-Disk -Times 0
        Should -Invoke Remove-Partition -Times 0
    }

    It 'handles separate-source rollback with <Fault>' -ForEach @(
        @{ Fault = 'no fault'; ExpectedFailure = '' },
        @{ Fault = 'changed Windows size'; ExpectedFailure = '*without changing Windows*' },
        @{ Fault = 'same physical disk'; ExpectedFailure = '*separate source*' },
        @{ Fault = 'replaced NTFS volume'; ExpectedFailure = '*filesystem identity*' },
        @{ Fault = 'replaced donor disk'; ExpectedFailure = '*Disk identity*' },
        @{ Fault = 'moved source start'; ExpectedFailure = '*source volume start*' },
        @{ Fault = 'source outside disk'; ExpectedFailure = '*source extent is invalid*' }
    ) {
        $rollbackPlan.schemaVersion = 5
        $rollbackPlan | Add-Member allocation ([pscustomobject]@{
            number = 1; uniqueId = 'donor-id'; partitionStyle = 'MBR'; sizeBytes = 64GB
            logicalSectorSizeBytes = 512; partitionTableId = 'mbr:22345678'
            sourceDrive = 'J:'; sourceVolumeId = 'donor-volume'
            sourceNtfsUuid = '1234567890ABCDEF'
            sourcePartition = [pscustomobject]@{ number = 1; offsetBytes = 1MB; sizeBytes = 60GB }
        })
        $script:observedWindows.Size = 60GB
        Mock Get-Disk {
            [pscustomobject]@{
                Number = 1; UniqueId = 'donor-id'; Size = 64GB; PartitionStyle = 'MBR'
                LogicalSectorSize = 512; Signature = 0x22345678
            }
        } -ParameterFilter { $null -ne $Number -and $Number[0] -eq 1 }
        Mock Get-Partition {
            [pscustomobject]@{ DiskNumber = 1; PartitionNumber = 1; Offset = 1MB; Size = 40GB; MbrType = 7 }
        } -ParameterFilter { $DriveLetter -eq 'J' }
        Mock Get-Partition {
            @(
                [pscustomobject]@{ DiskNumber = 1; PartitionNumber = 1; Offset = 1MB; Size = 40GB; MbrType = 7 },
                [pscustomobject]@{ DiskNumber = 1; PartitionNumber = 2; Offset = 40GB + 1MB; Size = 20GB; MbrType = 131 },
                [pscustomobject]@{ DiskNumber = 1; PartitionNumber = 3; Offset = 61GB; Size = 1GB; MbrType = 7 }
            )
        } -ParameterFilter { $null -ne $DiskNumber -and $DiskNumber[0] -eq 1 }
        Mock Get-Disk -ModuleName Libertix.Rollback {
            [pscustomobject]@{
                Number = 1; UniqueId = 'donor-id'; Size = 64GB; PartitionStyle = 'MBR'
                LogicalSectorSize = 512; Signature = 0x22345678
            }
        }
        Mock Get-Volume -ModuleName Libertix.Rollback {
            [pscustomobject]@{ UniqueId = 'donor-volume'; FileSystem = 'NTFS' }
        }
        Mock Get-LibertixNtfsVolumeSerial -ModuleName Libertix.Rollback { '1234567890ABCDEF' }
        switch ($Fault) {
            'changed Windows size' { $script:observedWindows.Size = 59GB }
            'same physical disk' { $rollbackPlan.allocation.number = 3 }
            'replaced NTFS volume' {
                Mock Get-Volume -ModuleName Libertix.Rollback {
                    [pscustomobject]@{ UniqueId = 'replacement-volume'; FileSystem = 'NTFS' }
                }
            }
            'replaced donor disk' {
                Mock Get-Disk -ModuleName Libertix.Rollback {
                    [pscustomobject]@{
                        Number = 1; UniqueId = 'donor-id'; Size = 64GB; PartitionStyle = 'MBR'
                        LogicalSectorSize = 512; Signature = 0x32345678
                    }
                }
            }
            'moved source start' { $rollbackPlan.allocation.sourcePartition.offsetBytes = 2MB }
            'source outside disk' { $rollbackPlan.allocation.sourcePartition.sizeBytes = 64GB }
        }
        . $assertPendingPlan
        if ($ExpectedFailure) {
            { . $restoreDiskLayout } | Should -Throw $ExpectedFailure
            Should -Invoke Remove-Partition -Times 0
            Should -Invoke Restore-LibertixSourceVolumeInitialSize -Times 0
            Should -Invoke Restore-LibertixSystemDriveInitialSize -Times 0
            return
        }
        . $restoreDiskLayout
        Should -Invoke Remove-Partition -Times 1 -Exactly -ParameterFilter {
            $DiskNumber -eq 1 -and $PartitionNumber -eq 2
        }
        Should -Invoke Remove-Partition -Times 0 -ParameterFilter { $DiskNumber -ne 1 }
        Should -Invoke Restore-LibertixSystemDriveInitialSize -Times 0
        Should -Invoke Restore-LibertixSourceVolumeInitialSize -Times 1 -Exactly -ParameterFilter {
            $SourceDrive -eq 'J:' -and $PlanDisk.number -eq 1 -and
            $SourcePartition.sizeBytes -eq 60GB -and $ExpectedVolumeId -eq 'donor-volume'
        }
        $diskNumber | Should -Be 3
        $SystemDrive | Should -Be 'C:'
    }

    It 'rejects schema 5 without allocation evidence before removing anything' {
        $rollbackPlan.schemaVersion = 5
        { . $restoreDiskLayout } | Should -Throw '*allocation does not match*'
        Should -Invoke Remove-Partition -Times 0
    }
}
