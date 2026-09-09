BeforeAll {
    $path = Join-Path $PSScriptRoot '../Scripts/libertix-uefi-recovery-agent.ps1'
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    foreach ($name in @('Test-LinuxPartitionPresent', 'Get-VerifiedEspPartition')) {
        $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.Rollback.psm1" -Force
    function Read-ValidatedRecoveryPlan { param($State) }
}

Describe 'UEFI recovery plan binding' {
    BeforeAll {
        $path = Join-Path $PSScriptRoot '../Scripts/libertix-uefi-recovery-agent.ps1'
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Read-ValidatedRecoveryPlan'
        }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
        function Read-LibertixInstallationPlan { param($Path) }
    }
    BeforeEach {
        $script:plan = [pscustomobject]@{
            planId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; firmware = 'uefi'
            runtime = [pscustomobject]@{ recoveryRunId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }
            disk = [pscustomobject]@{
                number = 0; uniqueId = 'vendor'; sizeBytes = 128GB
                partitionTableId = 'gpt:12345678-1234-1234-1234-123456789abc'
                installer = [pscustomobject]@{ finalOffsetBytes = 40GB; finalSizeBytes = 20GB }
            }
        }
        $script:state = [pscustomobject]@{
            PayloadRoot = $TestDrive; RecoveryRoot = $TestDrive
            PlanId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; RunId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            SystemDiskNumber = 0; SystemDiskUniqueId = '     vendor'; SystemDiskSize = 128GB
            SystemDiskPartitionTableId = 'gpt:12345678-1234-1234-1234-123456789abc'
            ExpectedLinuxPartitionOffset = 40GB; ExpectedLinuxPartitionSize = 20GB
        }
        Mock Import-Module {}
        Mock Read-LibertixInstallationPlan { $script:plan }
    }
    It 'uses the full plan validator and normalizes storage vendor padding consistently' {
        (Read-ValidatedRecoveryPlan -State $script:state).planId | Should -Be $script:state.PlanId
        Should -Invoke Read-LibertixInstallationPlan -Times 1 -Exactly -ParameterFilter {
            $Path -eq (Join-Path $TestDrive 'installation-plan.json')
        }
    }
    It 'refuses a changed state field <Field>' -ForEach @(
        @{ Field = 'PlanId'; Value = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' },
        @{ Field = 'RunId'; Value = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' },
        @{ Field = 'SystemDiskNumber'; Value = 1 },
        @{ Field = 'SystemDiskUniqueId'; Value = 'another-vendor' },
        @{ Field = 'SystemDiskSize'; Value = 64GB },
        @{ Field = 'SystemDiskPartitionTableId'; Value = 'gpt:87654321-1234-1234-1234-123456789abc' },
        @{ Field = 'ExpectedLinuxPartitionOffset'; Value = 41GB },
        @{ Field = 'ExpectedLinuxPartitionSize'; Value = 21GB }
    ) {
        $script:state.$Field = $Value
        { Read-ValidatedRecoveryPlan -State $script:state } | Should -Throw '*does not match*'
    }
    It 'does not bypass plan validation failure' {
        Mock Read-LibertixInstallationPlan { throw 'Invalid allocation.' }
        { Read-ValidatedRecoveryPlan -State $script:state } | Should -Throw '*Invalid allocation*'
    }
}

Describe 'UEFI recovery real module import order' {
    BeforeAll {
        $agent = [Management.Automation.Language.Parser]::ParseFile(
            "$PSScriptRoot/../Scripts/libertix-uefi-recovery-agent.ps1", [ref]$null, [ref]$null)
        foreach ($name in @('Read-ValidatedRecoveryPlan', 'Test-LinuxPartitionPresent')) {
            $definition = $agent.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        $contracts = [Management.Automation.Language.Parser]::ParseFile(
            "$PSScriptRoot/InstallationContracts.Tests.ps1", [ref]$null, [ref]$null)
        $factory = $contracts.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'New-ValidInstallationPlan'
        }, $true)
        . ([scriptblock]::Create($factory.Extent.Text))
    }

    It 'loads the real validators and policy on repeated invocations under Windows PowerShell' {
        $plan = New-ValidInstallationPlan
        $plan.runtime.recoveryRunId = $plan.planId
        $plan | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $TestDrive 'installation-plan.json') -Encoding UTF8
        $state = [pscustomobject]@{
            PayloadRoot = (Resolve-Path "$PSScriptRoot/..").Path; RecoveryRoot = $TestDrive
            PlanId = $plan.planId; RunId = $plan.planId
            SystemDiskNumber = $plan.disk.number; SystemDiskUniqueId = '     disk-0'
            SystemDiskPartitionTableId = $plan.disk.partitionTableId; SystemDiskSize = $plan.disk.sizeBytes
            ExpectedLinuxPartitionOffset = $plan.disk.installer.finalOffsetBytes
            ExpectedLinuxPartitionSize = $plan.disk.installer.finalSizeBytes
        }
        Mock Get-Disk {
            [pscustomobject]@{
                Number = 0; UniqueId = '     disk-0'; Size = 256GB; LogicalSectorSize = 512
                PartitionStyle = 'GPT'; Guid = '12345678-1234-1234-1234-123456789abc'
            }
        }
        Mock Get-Partition {
            [pscustomobject]@{
                Offset = 172872433664; Size = 40GB
                GptType = '{0fc63daf-8483-4772-8e79-3d69d8477de4}'
            }
        }
        Test-LinuxPartitionPresent -State $state | Should -BeTrue
        Test-LinuxPartitionPresent -State $state | Should -BeTrue
    }
}

Describe 'UEFI recovery Linux partition selection' {
    BeforeAll {
        # Keep the unit-test stub out of the real module-loading regression test.
        function Get-LibertixInstallationPolicy {}
    }
    BeforeEach {
        $script:windowsDisk = [pscustomobject]@{
            Number = 0; UniqueId = 'vendor'; Size = 128GB; LogicalSectorSize = 512
            PartitionStyle = 'GPT'; Guid = '12345678-1234-1234-1234-123456789abc'
        }
        $script:linuxDisk = [pscustomobject]@{
            Number = 1; UniqueId = 'vendor'; Size = 64GB; LogicalSectorSize = 512
            PartitionStyle = 'GPT'; Guid = '87654321-1234-1234-1234-123456789abc'
        }
        $script:linux = [pscustomobject]@{
            DiskNumber = 1; PartitionNumber = 3; Offset = 40GB; Size = 20GB
            GptType = '{0fc63daf-8483-4772-8e79-3d69d8477de4}'; Type = 'Unknown'; MbrType = 0
        }
        $script:esp = [pscustomobject]@{
            DiskNumber = 0; PartitionNumber = 1; Offset = 1MB; Size = 100MB
            GptType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
            Guid = '11111111-1234-1234-1234-123456789abc'
        }
        $script:state = [pscustomobject]@{
            PayloadRoot = $TestDrive
            SystemDiskNumber = 0; SystemDiskUniqueId = 'vendor'; SystemDiskSize = 128GB
            SystemDiskPartitionTableId = 'gpt:12345678-1234-1234-1234-123456789abc'
            ExpectedLinuxPartitionOffset = 40GB; ExpectedLinuxPartitionSize = 20GB
            BootPartitionNumber = 1; BootPartitionOffset = 1MB; BootPartitionSize = 100MB
        }
        $script:plan = [pscustomobject]@{
            schemaVersion = 5
            disk = [pscustomobject]@{
                number = 0; uniqueId = 'vendor'; sizeBytes = 128GB; logicalSectorSizeBytes = 512
                partitionStyle = 'GPT'; partitionTableId = 'gpt:12345678-1234-1234-1234-123456789abc'
                installer = [pscustomobject]@{ finalOffsetBytes = 40GB; finalSizeBytes = 20GB }
            }
            allocation = [pscustomobject]@{
                number = 1; uniqueId = 'vendor'; sizeBytes = 64GB; logicalSectorSizeBytes = 512
                partitionStyle = 'GPT'; partitionTableId = 'gpt:87654321-1234-1234-1234-123456789abc'
            }
        }
        Mock Read-ValidatedRecoveryPlan { $script:plan }
        Mock Import-Module {}
        Mock Get-LibertixInstallationPolicy { @{ storage = @{ partitionAlignmentBytes = 1MB } } }
        Mock Get-Disk {
            if ($Number[0] -eq 0) { $script:windowsDisk }
            elseif ($Number[0] -eq 1) { $script:linuxDisk }
            else { throw 'Unexpected disk.' }
        }
        Mock Get-Partition {
            if ($DiskNumber[0] -eq 0) {
                $script:esp
                if ($script:plan.schemaVersion -eq 4) { $script:linux }
            } elseif ($DiskNumber[0] -eq 1) { $script:linux }
            else { throw 'Unexpected disk.' }
        }
    }

    It 'finds Linux on the selected second disk while keeping the ESP on Windows' {
        Test-LinuxPartitionPresent -State $script:state | Should -BeTrue
        (Get-VerifiedEspPartition -State $script:state).DiskNumber | Should -Be 0
        Should -Invoke Get-Partition -Times 1 -ParameterFilter { $DiskNumber[0] -eq 1 }
    }

    It 'preserves the original single-disk plan' {
        $script:plan.schemaVersion = 4
        $script:plan.PSObject.Properties.Remove('allocation')
        $script:linux.DiskNumber = 0
        Test-LinuxPartitionPresent -State $script:state | Should -BeTrue
        Should -Invoke Get-Disk -Times 0 -ParameterFilter { $Number[0] -eq 1 }
    }

    It 'accepts a Linux MBR partition on the secondary disk with a Windows GPT ESP' {
        $script:linuxDisk.PartitionStyle = 'MBR'
        $script:linuxDisk | Add-Member -NotePropertyName Signature -NotePropertyValue 0x12345678
        $script:plan.allocation.partitionStyle = 'MBR'
        $script:plan.allocation.partitionTableId = 'mbr:12345678'
        $script:linux.GptType = ''
        $script:linux.MbrType = 0x83
        Test-LinuxPartitionPresent -State $script:state | Should -BeTrue
    }

    It 'accepts only the alignment tolerance allowed by the shared policy' {
        $script:linux.Size -= 1MB
        Test-LinuxPartitionPresent -State $script:state | Should -BeTrue
        $script:linux.Size -= 512
        Test-LinuxPartitionPresent -State $script:state | Should -BeFalse
    }

    It 'rejects a clone with the same vendor identifier but another partition table' {
        $script:linuxDisk.Guid = 'ffffffff-1234-1234-1234-123456789abc'
        { Test-LinuxPartitionPresent -State $script:state } | Should -Throw '*Disk identity*'
        Should -Invoke Get-Partition -Times 0
    }

    It 'rejects an incorrect partition <Field>' -ForEach @(
        @{ Field = 'Offset'; Value = 41GB }, @{ Field = 'Size'; Value = 21GB },
        @{ Field = 'GptType'; Value = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' }
    ) {
        $script:linux.$Field = $Value
        Test-LinuxPartitionPresent -State $script:state | Should -BeFalse
    }

    It 'rejects duplicate matching partitions' {
        Mock Get-Partition { $script:linux; $script:linux }
        Test-LinuxPartitionPresent -State $script:state | Should -BeFalse
    }
}
