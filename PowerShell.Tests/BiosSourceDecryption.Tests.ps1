BeforeAll {
    Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.StorageTargets.psm1" -Force
    Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.Process.psm1" -Force
    foreach ($file in @('libertix-storage-preflight.ps1', 'libertix-recovery-guard.ps1')) {
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            "$PSScriptRoot/../Scripts/$file", [ref]$null, [ref]$errors)
        if ($errors.Count) { throw ($errors | Out-String) }
        foreach ($name in @('Get-BitLockerState', 'Set-PreflightVolumeReadable', 'Assert-OriginalSourceEncryption',
            'Assert-StorageMatchesExpectedPlan', 'Assert-PreflightStorageStillMatchesPlan')) {
            $definition = $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true)
            if ($null -ne $definition) { . ([scriptblock]::Create($definition.Extent.Text)) }
        }
    }
}

Describe 'BIOS source identity is bound to the armed plan before decryption' {
    BeforeEach {
        $systemDrive = 'C:'
        $boot = [pscustomobject]@{ PartitionNumber = 1 }
        $recovery = [pscustomobject]@{ PartitionNumber = 3 }
        $expectedStyle = 'MBR'
        $expectedTarget = [pscustomobject]@{ drive = 'J:' }
        $ExpectedPlanPath = Join-Path $TestDrive 'armed-plan.json'
        $allocation = [pscustomobject]@{
            number = 1; uniqueId = 'data-disk'; partitionTableId = 'mbr:12345678'; sizeBytes = 64GB
            logicalSectorSizeBytes = 512; partitionStyle = 'MBR'; sourceDrive = 'J:'
            sourceVolumeId = 'volume-data'; sourceNtfsUuid = 'ABCDEF0123456789'
            sourcePartition = [pscustomobject]@{ number = 1; offsetBytes = 1MB; sizeBytes = 60GB }
        }
        @{ allocation = $allocation } | ConvertTo-Json -Depth 5 | Set-Content $ExpectedPlanPath -Encoding UTF8
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = 0 } }
        Mock Get-Disk { [pscustomobject]@{ Number = 0 } }
        Mock Assert-StorageMatchesExpectedPlan {}
        Mock Get-LibertixInstallationAllocation { $allocation }
    }

    It 'accepts the unchanged source and rechecks Windows before the donor' {
        { Assert-PreflightStorageStillMatchesPlan } | Should -Not -Throw
        Should -Invoke Assert-StorageMatchesExpectedPlan -Times 1 -ParameterFilter { $PlanPath -eq $ExpectedPlanPath }
        Should -Invoke Get-LibertixInstallationAllocation -Times 1 -ParameterFilter {
            $ExpectedTarget.drive -eq 'J:' -and $SystemPartition.DiskNumber -eq 0 -and $RequiredPartitionStyle -eq 'MBR'
        }
    }

    It 'rejects changed source evidence: <Field>' -ForEach @(
        @{ Field = 'number'; Value = 2 }, @{ Field = 'uniqueId'; Value = 'other' },
        @{ Field = 'partitionTableId'; Value = 'mbr:87654321' }, @{ Field = 'sizeBytes'; Value = 63GB },
        @{ Field = 'logicalSectorSizeBytes'; Value = 4096 }, @{ Field = 'partitionStyle'; Value = 'GPT' },
        @{ Field = 'sourceDrive'; Value = 'L:' }, @{ Field = 'sourceVolumeId'; Value = 'other-volume' },
        @{ Field = 'sourceNtfsUuid'; Value = '1111111111111111' }
    ) {
        $allocation.$Field = $Value
        { Assert-PreflightStorageStillMatchesPlan } | Should -Throw '*source volume no longer matches*'
    }

    It 'rejects a moved or resized source before decryption: <Field>' -ForEach @(
        @{ Field = 'number'; Value = 2 }, @{ Field = 'offsetBytes'; Value = 2MB },
        @{ Field = 'sizeBytes'; Value = 59GB }
    ) {
        $allocation.sourcePartition.$Field = $Value
        { Assert-PreflightStorageStillMatchesPlan } | Should -Throw '*source partition no longer matches*'
    }
}

Describe 'BIOS volume decryption requires continuous identity proof' {
    BeforeEach {
        $script:identityChecks = 0
        $script:statusReads = 0
        Mock Start-Sleep {}
        Mock Get-Command { [pscustomobject]@{ Source = 'manage-bde.exe' } } -ParameterFilter {
            $Name -eq 'manage-bde.exe'
        }
        Mock Invoke-LibertixNativeCommand { [pscustomobject]@{ ExitCode = 0 } }
        Mock Get-LibertixTargetVolumeEncryptionSnapshot {
            $script:statusReads++
            if ($script:statusReads -eq 1) {
                [pscustomobject]@{ state = 'EncryptedOrProtected'; conversionStatus = 1; encryptionPercentage = 100; protectionStatus = 0 }
            } else {
                [pscustomobject]@{ state = 'FullyDecrypted'; conversionStatus = 0; encryptionPercentage = 0; protectionStatus = 0 }
            }
        }
    }

    It 'decrypts only the selected volume and waits for full decryption despite suspended protection' {
        $null = Set-PreflightVolumeReadable -Drive 'J:' -VerifyIdentity { $script:identityChecks++ }
        $script:identityChecks | Should -Be 3
        Should -Invoke Invoke-LibertixNativeCommand -Times 1 -ParameterFilter {
            $ArgumentList.Count -eq 2 -and $ArgumentList[0] -eq '-off' -and $ArgumentList[1] -eq 'J:'
        }
        Should -Invoke Get-LibertixTargetVolumeEncryptionSnapshot -Times 2 -ParameterFilter { $Drive -eq 'J:' }
    }

    It 'does not start decryption if identity changes before the request' {
        { Set-PreflightVolumeReadable -Drive 'J:' -VerifyIdentity {
            $script:identityChecks++
            if ($script:identityChecks -eq 2) { throw 'source-replaced' }
        } } | Should -Throw '*source-replaced*'
        Should -Invoke Invoke-LibertixNativeCommand -Times 0
    }

    It 'stops polling the drive letter when identity changes after the request' {
        { Set-PreflightVolumeReadable -Drive 'J:' -VerifyIdentity {
            $script:identityChecks++
            if ($script:identityChecks -eq 3) { throw 'source-replaced' }
        } } | Should -Throw '*source-replaced*'
        Should -Invoke Invoke-LibertixNativeCommand -Times 1
        Should -Invoke Get-LibertixTargetVolumeEncryptionSnapshot -Times 1
    }

    It 'fails closed when encryption evidence is unavailable' {
        Mock Get-LibertixTargetVolumeEncryptionSnapshot { throw 'unknown-encryption' }
        { Set-PreflightVolumeReadable -Drive 'J:' -VerifyIdentity {} } | Should -Throw '*unknown-encryption*'
        Should -Invoke Invoke-LibertixNativeCommand -Times 0
    }
}

Describe 'BIOS recovery retains the initial source encryption evidence' {
    BeforeEach {
        $Root = $TestDrive
        $plan = @{
            schemaVersion = 5
            runtime = @{ recoveryRunId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }
            allocation = @{ sourceDrive = 'J:'; sourceNtfsUuid = 'ABCDEF0123456789' }
        }
        $original = @{
            recoveryRunId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            sourceDrive = 'J:'; sourceNtfsUuid = 'ABCDEF0123456789'
            snapshot = @{ state = 'EncryptedOrProtected'; conversionStatus = 1; encryptionPercentage = 100; protectionStatus = 0 }
        }
        $plan | ConvertTo-Json -Depth 5 | Set-Content "$Root/installation-plan.json" -Encoding UTF8
        $original | ConvertTo-Json -Depth 5 | Set-Content "$Root/source-encryption-original.json" -Encoding UTF8
        Mock Get-LibertixNtfsVolumeSerial { 'ABCDEF0123456789' }
        Mock Get-LibertixTargetVolumeEncryptionSnapshot { [pscustomobject]$original.snapshot }
    }

    It 'accepts the unchanged initial state on the same filesystem' {
        { Assert-OriginalSourceEncryption } | Should -Not -Throw
    }

    It 'does not claim full rollback after decryption changed the source state' {
        Mock Get-LibertixTargetVolumeEncryptionSnapshot {
            [pscustomobject]@{ state = 'FullyDecrypted'; conversionStatus = 0; encryptionPercentage = 0; protectionStatus = 0 }
        }
        { Assert-OriginalSourceEncryption } | Should -Throw '*BitLocker state differs*'
    }

    It 'rejects encryption evidence from another filesystem' {
        Mock Get-LibertixNtfsVolumeSerial { '1111111111111111' }
        { Assert-OriginalSourceEncryption } | Should -Throw '*does not match this recovery transaction*'
        Should -Invoke Get-LibertixTargetVolumeEncryptionSnapshot -Times 0
    }
}
