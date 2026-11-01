BeforeAll {
    Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.StorageGeometry.psm1" -Force
    $path = Join-Path $PSScriptRoot '../Scripts/libertix-compatibility-preflight.ps1'
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
    if (@($errors).Count) { throw 'Compatibility preflight does not parse.' }
    $definition = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-CompatibilityAllocationCapacity'
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
    function Stop-Compatibility { param([string]$Code, [object[]]$FormatArguments) throw $Code }
}

Describe 'Capacity selection without requiring Windows to supply Linux space' {
    BeforeEach {
        $windows = [pscustomobject]@{
            isWindows = $true; drive = 'C:'; partitionStyle = 'GPT'; sizeBytes = 60GB
            offsetBytes = 1MB; minimumSizeBytes = 24GB; logicalSectorSizeBytes = 512
        }
        $secondary = $windows.PSObject.Copy()
        $secondary.isWindows = $false
        $secondary.drive = 'J:'
        $arguments = @{
            Targets = @($windows, $secondary); PartitionStyle = 'GPT'
            WindowsShrinkBytes = 30GB; RequiredShrinkBytes = 9GB
            WindowsPartitionSlotAvailable = $true
        }
    }

    It 'retains the normal single-disk shrink allowance' {
        $arguments.Targets = @($windows)
        $result = Get-CompatibilityAllocationCapacity @arguments
        $result.WindowsShrinkBytes | Should -Be 30GB
        @($result.Targets).Count | Should -Be 1
        $result.Targets[0].drive | Should -Be 'C:'
    }

    It 'retains Windows for its download budget but disables its allocation when shrink is insufficient' {
        $arguments.WindowsShrinkBytes = 6GB
        $result = Get-CompatibilityAllocationCapacity @arguments
        $result.WindowsShrinkBytes | Should -Be 0
        @($result.Targets).Count | Should -Be 2
        $result.Targets[0].drive | Should -Be 'C:'
        $result.Targets[1].drive | Should -Be 'J:'
    }

    It 'retains the old refusal when no other usable disk exists' {
        $arguments.WindowsShrinkBytes = 6GB
        $arguments.Targets = @($windows)
        { Get-CompatibilityAllocationCapacity @arguments } | Should -Throw '*COMPAT_E_SHRINK_SPACE*'
    }

    It 'does not count a disk with the wrong firmware partition style' {
        $arguments.WindowsShrinkBytes = 6GB
        $secondary.partitionStyle = 'MBR'
        { Get-CompatibilityAllocationCapacity @arguments } | Should -Throw '*COMPAT_E_SHRINK_SPACE*'
    }

    It 'allows another MBR disk while keeping a full Windows partition table unavailable' {
        $windows.partitionStyle = $secondary.partitionStyle = 'MBR'
        $arguments.PartitionStyle = 'MBR'
        $arguments.WindowsPartitionSlotAvailable = $false
        $result = Get-CompatibilityAllocationCapacity @arguments
        $result.WindowsShrinkBytes | Should -Be 0
        @($result.Targets).Count | Should -Be 2
    }

    It 'retains the MBR primary limit refusal with no secondary destination' {
        $arguments.WindowsPartitionSlotAvailable = $false
        $arguments.Targets = @($windows)
        { Get-CompatibilityAllocationCapacity @arguments } | Should -Throw '*COMPAT_E_MBR_PRIMARY_LIMIT*'
    }

    It 'does not silently lose Windows from the inventory' {
        $arguments.Targets = @($secondary)
        { Get-CompatibilityAllocationCapacity @arguments } | Should -Throw '*COMPAT_E_DISK_INVENTORY*'
    }

    It 'reserves the BIOS metadata alignment unit on the secondary disk' {
        $windows.partitionStyle = $secondary.partitionStyle = 'MBR'
        $secondary.sizeBytes = 31GB
        $secondary.minimumSizeBytes = 22GB
        $arguments.PartitionStyle = 'MBR'
        $arguments.WindowsShrinkBytes = 0
        { Get-CompatibilityAllocationCapacity @arguments } | Should -Throw '*COMPAT_E_SHRINK_SPACE*'
    }

    It 'accepts the exact aligned GPT staging capacity without a BIOS-only reserve' {
        $secondary.sizeBytes = 31GB
        $secondary.minimumSizeBytes = 22GB
        $arguments.WindowsShrinkBytes = 0
        (Get-CompatibilityAllocationCapacity @arguments).WindowsShrinkBytes | Should -Be 0
    }
}
