BeforeAll {
    $path = Join-Path $PSScriptRoot '../Scripts/modules/Libertix.StorageTargets.psm1'
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
    if (@($errors).Count) { throw 'Storage target module does not parse.' }
    $definition = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-LibertixStorageControllerNames'
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}

Describe 'Storage controller refusal is scoped to the selected physical disk' {
    BeforeEach {
        $script:controllers = @(
            [pscustomobject]@{ Name = 'Standard SATA AHCI Controller'; PNPDeviceID = 'PCI\AHCI' },
            [pscustomobject]@{ Name = 'Intel RST RAID Controller'; PNPDeviceID = 'PCI\RAID' }
        )
        $script:parents = @{
            'SCSI\DISK3' = 'PCI\AHCI'; 'PCI\AHCI' = 'ACPI\PCI'; 'PCI\RAID' = 'ACPI\PCI'
            'ACPI\PCI' = 'HTREE\ROOT\0'
        }
        Mock Get-CimInstance {
            if ($ClassName -eq 'Win32_IDEController') { return $script:controllers }
            if ($ClassName -eq 'Win32_SCSIController') { return @() }
            if ($ClassName -eq 'Win32_DiskDrive') {
                return [pscustomobject]@{ Index = 3; DeviceID = '\\.\PHYSICALDRIVE3'; PNPDeviceID = 'SCSI\DISK3' }
            }
            throw 'Unexpected CIM class.'
        }
        Mock Get-PnpDeviceProperty {
            [pscustomobject]@{ Data = $script:parents[[string]$InstanceId] }
        }
    }

    It 'ignores RAID hardware outside the Windows disk parent chain' {
        @(Get-LibertixStorageControllerNames -DiskNumber 3) | Should -Be @('Standard SATA AHCI Controller')
        Should -Invoke Get-CimInstance -Times 1 -ParameterFilter {
            $ClassName -eq 'Win32_DiskDrive' -and $Filter -eq 'Index = 3'
        }
    }

    It 'keeps the RAID refusal when that controller actually owns the disk' {
        $script:parents['SCSI\DISK3'] = 'PCI\RAID'
        @(Get-LibertixStorageControllerNames -DiskNumber 3) | Should -Be @('Intel RST RAID Controller')
    }

    It 'refuses using a secondary target behind its own RAID controller' {
        $script:parents['SCSI\DISK3'] = 'PCI\RAID'
        { Get-LibertixStorageControllerNames -DiskNumber 3 -RequireSupported } |
            Should -Throw '*unsupported storage controller*'
    }

    It 'accepts a secondary target when RAID belongs to a different disk' {
        @(Get-LibertixStorageControllerNames -DiskNumber 3 -RequireSupported) |
            Should -Be @('Standard SATA AHCI Controller')
    }

    It 'does not require extra PnP queries when every controller is already supported' {
        $script:controllers = @($script:controllers[0])
        @(Get-LibertixStorageControllerNames -DiskNumber 3) | Should -Be @('Standard SATA AHCI Controller')
        Should -Invoke Get-PnpDeviceProperty -Times 0
    }

    It 'refuses an incomplete parent chain instead of silently ignoring RAID' {
        $script:parents.Remove('PCI\AHCI')
        { Get-LibertixStorageControllerNames -DiskNumber 3 } | Should -Throw '*incomplete PnP ancestry*'
    }

    It 'bounds a cyclic parent chain' {
        $script:parents['PCI\AHCI'] = 'SCSI\DISK3'
        { Get-LibertixStorageControllerNames -DiskNumber 3 } | Should -Throw '*cyclic*'
        Should -Invoke Get-PnpDeviceProperty -Times 2
    }

    It 'rejects an ambiguous physical disk query' {
        Mock Get-CimInstance {
            @(
                [pscustomobject]@{ DeviceID = '\\.\PHYSICALDRIVE3'; PNPDeviceID = 'SCSI\DISK3' },
                [pscustomobject]@{ DeviceID = '\\.\PHYSICALDRIVE4'; PNPDeviceID = 'SCSI\DISK4' }
            )
        } -ParameterFilter { $ClassName -eq 'Win32_DiskDrive' }
        { Get-LibertixStorageControllerNames -DiskNumber 3 } | Should -Throw '*unambiguous*'
    }

    It 'does not ignore a controller without a physical identity' {
        $script:controllers[1].PNPDeviceID = ''
        { Get-LibertixStorageControllerNames -DiskNumber 3 } | Should -Throw '*no PnP identity*'
        Should -Invoke Get-PnpDeviceProperty -Times 0
    }
}
