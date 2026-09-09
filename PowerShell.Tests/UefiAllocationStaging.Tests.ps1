BeforeAll {
    foreach ($module in @('InstallationState', 'Rollback', 'AtomicFile', 'StorageGeometry', 'StorageTargets')) {
        Import-Module (Join-Path $PSScriptRoot "../Scripts/modules/Libertix.$module.psm1") -Force
    }
    foreach ($component in @('Execution', 'Transaction', 'Storage', 'Staging')) {
        . (Join-Path $PSScriptRoot "../Scripts/uefi/Libertix.Uefi.$component.ps1")
    }
}

Describe 'UEFI source-volume preparation preserves the Windows disk' {
    BeforeEach {
        $script:SystemDrive = 'C:'
        $script:SystemDriveLetter = 'C'
        $script:InstallerLabel = 'LIBERTIX_INSTALLER'
        $script:RecoveryRunId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        $script:RecoveryRoot = 'C:\ProgramData\Libertix\UefiRecovery\aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        $script:BootStrategy = 'uefi-boot-next'
        $script:LowMemoryMode = $false
        $script:ShareWindowsFilesInLinux = $false
        $script:TransactionStatePath = Join-Path $TestDrive "$([Guid]::NewGuid().ToString('N')).json"
        $script:DistributionIsoPath = Join-Path $TestDrive 'distribution.iso'
        [IO.File]::WriteAllText($script:DistributionIsoPath, 'fixture')
        $script:sourceCalls = 0
        $script:sourceSize = 60GB
        $script:sourceOffset = 16MB
        $script:fault = ''
        $script:installationPlan = [pscustomobject]@{
            disk = [pscustomobject]@{
                number = 0; uniqueId = 'windows'; sizeBytes = 256GB
                partitionStyle = 'GPT'; logicalSectorSizeBytes = 512
                partitionTableId = 'gpt:12345678-1234-1234-1234-123456789abc'
                systemDrive = 'C:'
                windows = [pscustomobject]@{ number = 3; offsetBytes = 256MB; sizeBytes = 200GB }
                installer = [pscustomobject]@{
                    number = $null; offsetBytes = $null; finalSizeBytes = 20GB; stagingSizeBytes = 8GB
                    finalOffsetBytes = 40GB + 16MB; resizeMode = 'windows-online'
                }
            }
            allocation = [pscustomobject]@{
                number = 1; uniqueId = 'data'; sizeBytes = 64GB
                partitionStyle = 'GPT'; logicalSectorSizeBytes = 512
                partitionTableId = 'gpt:87654321-1234-1234-1234-123456789abc'
                sourceDrive = 'J:'; sourceVolumeId = '\\?\Volume{data}\'
                sourceNtfsUuid = '1234567890ABCDEF'
                sourcePartition = [pscustomobject]@{ number = 2; offsetBytes = 16MB; sizeBytes = 60GB }
            }
        }
        Mock Get-VerifiedTransactionPartition { $null }
        Mock Test-LibertixInstallerPartitionPresent { $false }
        Mock Get-Disk {
            if ($Number[0] -eq 0) {
                [pscustomobject]@{
                    Number = 0; UniqueId = 'windows'; Size = 256GB; PartitionStyle = 'GPT'
                    LogicalSectorSize = 512; Guid = '12345678-1234-1234-1234-123456789abc'
                }
            } else {
                [pscustomobject]@{
                    Number = 1; UniqueId = 'data'; Size = 64GB; PartitionStyle = 'GPT'
                    LogicalSectorSize = 512; Guid = '87654321-1234-1234-1234-123456789abc'
                }
            }
        }
        Mock Get-Partition {
            if ($DriveLetter -eq 'C') {
                [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 3; Offset = 256MB; Size = 200GB }
            } else {
                if ($DriveLetter -eq 'J') { $script:sourceCalls++ }
                $offset = $script:sourceOffset
                if ($script:fault -eq 'moved-before-shrink' -and $script:sourceCalls -ge 3) { $offset += 1MB }
                [pscustomobject]@{
                    DiskNumber = 1; PartitionNumber = 2; Offset = $offset
                    Size = $script:sourceSize; DriveLetter = 'J'
                }
            }
        }
        Mock Get-Volume { [pscustomobject]@{ UniqueId = '\\?\Volume{data}\'; FileSystem = 'NTFS' } }
        Mock Get-LibertixNtfsVolumeSerial {
            if ($script:fault -eq 'filesystem-before-shrink' -and $script:sourceCalls -ge 3) {
                '8765432190ABCDEF'
            } else { '1234567890ABCDEF' }
        }
        Mock Get-LibertixTargetVolumeEncryptionSnapshot {
            [pscustomobject]@{ state = 'FullyDecrypted'; conversionStatus = 0; encryptionPercentage = 0; protectionStatus = 0 }
        }
        Mock Get-BitLockerVolume {
            [pscustomobject]@{
                VolumeStatus = if ($script:fault -eq 'encrypted') { 'FullyEncrypted' } else { 'FullyDecrypted' }
                EncryptionPercentage = if ($script:fault -eq 'encrypted') { 100 } else { 0 }
                ProtectionStatus = 'Off'
            }
        }
        Mock Get-PartitionSupportedSize { [pscustomobject]@{ SizeMin = 10GB } }
        Mock Wait-LibertixWindowsFreeSpaceBudget {
            [pscustomobject]@{
                Accepted = $true; AvailableBytes = 50GB; ReclaimableArtifactBytes = $ReclaimableArtifactBytes
                EffectiveAvailableBytes = 50GB; WithinTolerance = $false
            }
        }
        Mock Resize-Partition {
            $script:sourceSize = [long]$Size
            if ($script:fault -eq 'wrong-shrink-size') { $script:sourceSize += 1MB }
        }
        Mock New-Partition { throw 'creation checkpoint' }
        Mock Format-Volume { throw 'Formatting must not occur before the creation checkpoint.' }
        Mock Get-HibernateEnabled { $true }
        Mock Set-HibernateEnabled {}
        Mock Start-Sleep {}
        Mock Write-Log {}
        Mock Start-LibertixTrackedStep {}
        Mock Complete-LibertixTrackedStep {}
    }

    It 'reduces J and creates staging on disk 1 without crediting the ISO on C' {
        { New-OrReuseInstallerPartition -SizeGB 20 } | Should -Throw '*creation checkpoint*'
        Should -Invoke Resize-Partition -Times 1 -ParameterFilter { $DriveLetter -eq 'J' -and $Size -eq 40GB }
        Should -Invoke Resize-Partition -Times 0 -ParameterFilter { $DriveLetter -eq 'C' }
        Should -Invoke New-Partition -Times 1 -ParameterFilter {
            $DiskNumber -eq 1 -and $Offset -eq (40GB + 16MB) -and $Size -eq 8GB
        }
        Should -Invoke Wait-LibertixWindowsFreeSpaceBudget -Times 1 -ParameterFilter {
            $DriveLetter -eq 'J' -and $ReclaimableArtifactBytes -eq 0
        }
        $state = Get-TransactionPartitionState
        $state.OriginalCSize | Should -Be 200GB
        $state.OriginalSourceSize | Should -Be 60GB
        $state.PartitionOffset | Should -Be (40GB + 16MB)
        Should -Invoke Format-Volume -Times 0
    }

    It 'refuses <Failure> before reducing any volume' -ForEach @(
        @{ Failure = 'encrypted'; ExpectedError = '*fully decrypted*' },
        @{ Failure = 'filesystem-before-shrink'; ExpectedError = '*source NTFS volume changed*' },
        @{ Failure = 'moved-before-shrink'; ExpectedError = '*source partition geometry*' }
    ) {
        $script:fault = $Failure
        { New-OrReuseInstallerPartition -SizeGB 20 } | Should -Throw $ExpectedError
        Should -Invoke Resize-Partition -Times 0
        Should -Invoke New-Partition -Times 0
        Should -Invoke Format-Volume -Times 0
    }

    It 'refuses unexpected shrink geometry before creating or formatting staging' {
        $script:fault = 'wrong-shrink-size'
        { New-OrReuseInstallerPartition -SizeGB 20 } | Should -Throw '*source partition geometry*'
        Should -Invoke Resize-Partition -Times 1
        Should -Invoke New-Partition -Times 0
        Should -Invoke Format-Volume -Times 0
        (Get-TransactionPartitionState).OriginalSourceSize | Should -Be 60GB
    }
}
