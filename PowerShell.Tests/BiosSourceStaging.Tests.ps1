BeforeAll {
    Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.StorageGeometry.psm1" -Force
    Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.StorageTargets.psm1" -Force
    Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.InstallationPolicy.psm1" -Force
    $scriptPath = Join-Path $PSScriptRoot '../Scripts/libertix-bios-storage.ps1'
}

Describe 'BIOS selected-source storage actions' {
    BeforeEach {
        # Keep the real imported functions and their mocked CIM boundary during this unit test.
        Mock Import-Module {}
        Mock Get-LibertixTargetVolumeEncryptionState { 'FullyDecrypted' }
        Mock Get-LibertixNtfsVolumeSerial { '1234567890ABCDEF' }
        $arguments = @{
            Action = 'Shrink'; SystemDrive = 'J:'; DiskNumber = 1
            DiskUniqueId = 'donor-id'; DiskPartitionTableId = 'mbr:22345678'
            WindowsPartitionOffsetBytes = 1MB; OriginalWindowsPartitionSizeBytes = 60GB
            RecoveryPartitionOffsetBytes = 60GB + 1MB; SizeBytes = 20GB
            ExpectedSourceVolumeId = 'donor-volume'; ExpectedDiskSizeBytes = 64GB
            ExpectedSourceNtfsUuid = '1234567890ABCDEF'
            ExpectedLogicalSectorSizeBytes = 512
        }
        $sourceState = [pscustomobject]@{ Size = 60GB }
        $donorDisk = [pscustomobject]@{
            Number = 1; UniqueId = 'donor-id'; PartitionStyle = 'MBR'; Signature = 0x22345678
            Size = 64GB; LogicalSectorSize = 512
        }
        Mock Get-Disk { $donorDisk }
        Mock Get-Partition {
            [pscustomobject]@{
                DiskNumber = 1; PartitionNumber = 1; Offset = 1MB; Size = $sourceState.Size
            }
        }
        Mock Get-Volume {
            [pscustomobject]@{ UniqueId = 'donor-volume'; FileSystem = 'NTFS'; SizeRemaining = 40GB }
        }
        Mock Get-Volume -ModuleName Libertix.StorageGeometry {
            [pscustomobject]@{ UniqueId = 'donor-volume'; FileSystem = 'NTFS'; SizeRemaining = 40GB }
        }
        Mock Get-PartitionSupportedSize { [pscustomobject]@{ SizeMin = 24GB; SizeMax = 60GB } }
        Mock Resize-Partition { $sourceState.Size = [long]$Size }
        Mock New-Partition { throw 'Unexpected partition creation in shrink test.' }
        Mock Format-Volume { throw 'Unexpected formatting in shrink test.' }
    }

    It 'shrinks only the selected donor by the allocation plus MBR metadata' {
        $result = & $scriptPath @arguments | ConvertFrom-Json
        $result.SizeBytes | Should -Be (40GB - 1MB)
        Should -Invoke Resize-Partition -Times 1 -Exactly -ParameterFilter {
            $DriveLetter -eq 'J' -and $Size -eq (40GB - 1MB)
        }
        Should -Invoke Get-Partition -Times 0 -ParameterFilter { $DriveLetter -eq 'C' }
        Should -Invoke Resize-Partition -Times 0 -ParameterFilter { $DriveLetter -ne 'J' }
        Should -Invoke New-Partition -Times 0
        Should -Invoke Format-Volume -Times 0
    }

    It 'refuses <Fault> before resizing' -ForEach @(
        @{ Fault = 'a replaced volume'; ExpectedFailure = '*source NTFS volume changed*' },
        @{ Fault = 'a replaced filesystem'; ExpectedFailure = '*NTFS filesystem identity changed*' },
        @{ Fault = 'a changed disk size'; ExpectedFailure = '*storage identity changed*' },
        @{ Fault = 'a changed sector size'; ExpectedFailure = '*storage identity changed*' },
        @{ Fault = 'suspended encryption'; ExpectedFailure = '*fully decrypted*' }
    ) {
        switch ($Fault) {
            'a replaced volume' { $arguments.ExpectedSourceVolumeId = 'another-volume' }
            'a replaced filesystem' { Mock Get-LibertixNtfsVolumeSerial { '8765432190ABCDEF' } }
            'a changed disk size' { $donorDisk.Size = 128GB }
            'a changed sector size' { $donorDisk.LogicalSectorSize = 4096 }
            'suspended encryption' { Mock Get-LibertixTargetVolumeEncryptionState { 'EncryptedOrProtected' } }
        }
        { & $scriptPath @arguments } | Should -Throw $ExpectedFailure
        Should -Invoke Resize-Partition -Times 0
        Should -Invoke New-Partition -Times 0
        Should -Invoke Format-Volume -Times 0
    }

    It 'verifies the returned staging partition before format with <Fault>' -ForEach @(
        @{ Fault = 'no fault'; ExpectedFailure = '*format-checkpoint*'; FormatCalls = 1 },
        @{ Fault = 'another disk'; ExpectedFailure = '*unexpected geometry*'; FormatCalls = 0 },
        @{ Fault = 'the source partition number'; ExpectedFailure = '*unexpected geometry*'; FormatCalls = 0 },
        @{ Fault = 'a concurrent source change'; ExpectedFailure = '*before staging format*'; FormatCalls = 0 }
    ) {
        $arguments.Action = 'CreateStaging'
        $arguments.SizeBytes = 8GB
        $sourceState.Size = 40GB
        $created = New-CimInstance -Namespace 'root/Microsoft/Windows/Storage' `
            -ClassName MSFT_Partition -ClientOnly -Property @{
                DiskNumber = [uint32]1; PartitionNumber = [uint32]2
                Offset = [uint64](40GB + 1MB); Size = [uint64]8GB
            }
        switch ($Fault) {
            'another disk' { $created.DiskNumber = 0 }
            'the source partition number' { $created.PartitionNumber = 1 }
        }
        Mock New-Partition {
            if ($Fault -eq 'a concurrent source change') { $sourceState.Size = 39GB }
            $created
        }
        Mock Format-Volume { throw 'format-checkpoint' }
        { & $scriptPath @arguments } | Should -Throw $ExpectedFailure
        Should -Invoke New-Partition -Times 1 -Exactly -ParameterFilter {
            $DiskNumber -eq 1 -and $Size -eq 8GB -and $Offset -eq (40GB + 1MB)
        }
        Should -Invoke Format-Volume -Times $FormatCalls -Exactly
        Should -Invoke Resize-Partition -Times 0
    }
}
