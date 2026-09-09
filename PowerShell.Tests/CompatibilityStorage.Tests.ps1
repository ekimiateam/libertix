BeforeAll {
    Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.StorageTargets.psm1" -Force
    $path = Join-Path $PSScriptRoot '../Scripts/libertix-compatibility-preflight.ps1'
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
    if (@($errors).Count -ne 0) { throw 'Compatibility preflight does not parse.' }
    $function = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Resolve-CompatibilitySystemStorage'
    }, $true)
    . ([scriptblock]::Create($function.Extent.Text))
    function Stop-Compatibility { param([string]$Code, [object[]]$FormatArguments) throw $Code }
    function New-TestDisk {
        param([int]$Number, [string]$BusType = 'SATA')
        [pscustomobject]@{
            Number = $Number; Size = 64GB; BusType = $BusType
            IsOffline = $false; IsReadOnly = $false; PartitionStyle = 'GPT'
            Guid = ('12345678-1234-1234-1234-{0:d12}' -f $Number)
        }
    }
}

Describe 'Compatibility storage selection' {
    BeforeEach {
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = 3; PartitionNumber = 2; DriveLetter = 'C' } }
    }

    It 'selects the Windows disk rather than the first enumerated disk' {
        $disks = @((New-TestDisk 0), (New-TestDisk 3))
        $selected = Resolve-CompatibilitySystemStorage -SystemDrive 'C:' -VisibleDisks $disks
        $selected.Disk.Number | Should -Be 3
        $selected.Partition.PartitionNumber | Should -Be 2
        Should -Invoke Get-Partition -Times 1 -Exactly -ParameterFilter { $DriveLetter -eq 'C' }
    }

    It 'ignores an unrelated <BusType> device' -TestCases @(
        @{ BusType = 'USB' }, @{ BusType = 'SD' }, @{ BusType = 'SATA' }, @{ BusType = 'File Backed Virtual' }
    ) {
        param($BusType)
        $other = New-TestDisk 0 $BusType
        $other.IsReadOnly = $true
        $selected = Resolve-CompatibilitySystemStorage -SystemDrive 'C:' -VisibleDisks @($other, (New-TestDisk 3))
        $selected.Disk.Number | Should -Be 3
        $other.IsReadOnly | Should -BeTrue
    }

    It 'still rejects Windows itself being on an unsupported <BusType> disk' -TestCases @(
        @{ BusType = 'USB' }, @{ BusType = 'iSCSI' }, @{ BusType = 'RAID' }, @{ BusType = 'Spaces' }
    ) {
        param($BusType)
        { Resolve-CompatibilitySystemStorage -SystemDrive 'C:' -VisibleDisks @((New-TestDisk 3 $BusType)) } |
            Should -Throw '*COMPAT_E_STORAGE_BUS_UNSUPPORTED*'
    }

    It 'rejects an absent system disk rather than selecting another one' {
        { Resolve-CompatibilitySystemStorage -SystemDrive 'C:' -VisibleDisks @((New-TestDisk 0)) } |
            Should -Throw '*COMPAT_E_SYSTEM_DISK_UNRESOLVED*'
    }

    It 'rejects an ambiguous inventory' {
        { Resolve-CompatibilitySystemStorage -SystemDrive 'C:' -VisibleDisks @((New-TestDisk 3), (New-TestDisk 3)) } |
            Should -Throw '*COMPAT_E_SYSTEM_DISK_UNRESOLVED*'
    }

    It 'rejects a read-only system disk' {
        $disk = New-TestDisk 3
        $disk.IsReadOnly = $true
        { Resolve-CompatibilitySystemStorage -SystemDrive 'C:' -VisibleDisks @($disk) } |
            Should -Throw '*COMPAT_E_DISK_NOT_WRITABLE*'
    }

    It 'rejects an ambiguous system volume' {
        Mock Get-Partition { @([pscustomobject]@{ DiskNumber = 0 }, [pscustomobject]@{ DiskNumber = 3 }) }
        { Resolve-CompatibilitySystemStorage -SystemDrive 'C:' -VisibleDisks @((New-TestDisk 3)) } |
            Should -Throw '*COMPAT_E_SYSTEM_DISK_UNRESOLVED*'
    }

    It 'rejects a <Style> clone even on an offline USB disk with a different size' -ForEach @(
        @{ Style = 'GPT' }, @{ Style = 'MBR' }
    ) {
        $system = New-TestDisk 3
        $clone = New-TestDisk 0 'USB'
        $clone.Guid = $system.Guid
        $clone.IsOffline = $true
        $clone.Size = 128GB
        foreach ($disk in @($system, $clone)) {
            $disk.PartitionStyle = $Style
            $disk | Add-Member Signature ([uint32]305419896)
        }
        { Resolve-CompatibilitySystemStorage -SystemDrive 'C:' -VisibleDisks @($clone, $system) } |
            Should -Throw '*COMPAT_E_DISK_IDENTITY_AMBIGUOUS*'
    }

    It 'rejects a Windows disk without a provable GPT identity' {
        $system = New-TestDisk 3
        $system.Guid = [guid]::Empty
        { Resolve-CompatibilitySystemStorage -SystemDrive 'C:' -VisibleDisks @($system) } |
            Should -Throw '*COMPAT_E_DISK_IDENTITY_AMBIGUOUS*'
    }
}
