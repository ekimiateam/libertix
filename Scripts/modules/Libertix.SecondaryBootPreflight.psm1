Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Libertix.Process.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Libertix.Firmware.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Libertix.FirmwareRead.psm1') -ErrorAction Stop

function Test-LibertixWindowsBootOptionPartition {
    param(
        [byte[]]$Bytes,
        [Parameter(Mandatory = $true)][object]$Disk,
        [Parameter(Mandatory = $true)][object]$Partition
    )

    if (-not $Bytes -or $Bytes.Length -lt 8 -or
        ([BitConverter]::ToUInt32($Bytes, 0) -band 1) -eq 0 -or
        -not (Test-EfiLoadOptionLoaderPath -Bytes $Bytes -ExpectedPath '\EFI\Microsoft\Boot\bootmgfw.efi')) {
        return $false
    }
    $nodes = @(Get-EfiLoadOptionHardDriveNodes -Bytes $Bytes)
    if ($nodes.Count -ne 1) { return $false }
    $node = $nodes[0]
    $sector = [long]$Disk.LogicalSectorSize
    if ($sector -notin @(512, 4096) -or [long]$Partition.Offset % $sector -ne 0 -or
        [long]$Partition.Size % $sector -ne 0) { return $false }
    return $node.MbrType -eq 2 -and $node.SignatureType -eq 2 -and
        [guid]$node.PartitionGuid -eq [guid]$Partition.Guid -and
        [long]$node.PartitionNumber -eq [long]$Partition.PartitionNumber -and
        [long]$node.PartitionStartLba -eq ([long]$Partition.Offset / $sector) -and
        [long]$node.PartitionSizeLba -eq ([long]$Partition.Size / $sector)
}

function Assert-LibertixSecondaryBootPreflight {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('BIOS', 'UEFI')][string]$Firmware,
        [Parameter(Mandatory = $true)][object]$WindowsDisk,
        [Parameter(Mandatory = $true)][object]$BootPartition,
        [Parameter(Mandatory = $true)][object]$Allocation
    )

    if ([int]$BootPartition.DiskNumber -ne [int]$WindowsDisk.Number -or
        [int]$Allocation.number -eq [int]$WindowsDisk.Number) {
        throw 'Secondary-disk boot verification received inconsistent disk identities.'
    }
    $bcdedit = Get-LibertixNativeSystemExecutable -FileName 'bcdedit.exe'
    foreach ($entry in @('{bootmgr}', '{current}')) {
        $read = Invoke-LibertixNativeCommand -FilePath $bcdedit `
            -ArgumentList @('/enum', $entry) -TimeoutSeconds 15
        if ($read.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($read.StandardOutput)) {
            throw "The Windows BCD entry $entry cannot be read."
        }
    }
    if ($Firmware -eq 'BIOS') {
        if (-not $BootPartition.IsActive) { throw 'The Windows BIOS boot partition is not active.' }
        return [pscustomobject]@{
            status = 'verified'; windowsBoot = 'BCD-and-active-partition'; secondaryFirmwareAccess = 'unverified'
        }
    }

    [byte[]]$orderBytes = Get-LibertixFirmwareVariableBytes -Name 'BootOrder'
    if (-not $orderBytes -or $orderBytes.Length % 2 -ne 0 -or $orderBytes.Length -gt 1024) {
        throw 'UEFI BootOrder is missing, malformed or too large to verify safely.'
    }
    $order = @(ConvertFrom-BootOrderBytes -Bytes $orderBytes)
    if (@($order | Select-Object -Unique).Count -ne $order.Count) {
        throw 'UEFI BootOrder contains duplicate entries.'
    }
    foreach ($name in @('BootCurrent', 'BootNext')) {
        [byte[]]$value = Get-LibertixFirmwareVariableBytes -Name $name
        if ($null -ne $value -and $value.Length -ne 2) {
            throw "UEFI $name is malformed."
        }
        if ($null -ne $value) {
            $variable = 'Boot{0:X4}' -f [BitConverter]::ToUInt16($value, 0)
            [byte[]]$entry = Get-LibertixFirmwareVariableBytes -Name $variable
            if (-not $entry -or $entry.Length -lt 8) {
                throw "UEFI $name refers to a missing or truncated boot entry."
            }
        }
    }
    $windowsEntries = @()
    foreach ($number in $order) {
        $variable = 'Boot{0:X4}' -f [uint16]$number
        [byte[]]$entry = Get-LibertixFirmwareVariableBytes -Name $variable
        if (Test-LibertixWindowsBootOptionPartition -Bytes $entry -Disk $WindowsDisk -Partition $BootPartition) {
            $windowsEntries += $variable
        }
    }
    if ($windowsEntries.Count -eq 0) {
        throw 'UEFI BootOrder has no active Windows loader matching the verified system EFI partition.'
    }
    # BootOrder describes load options, not every disk exposed by firmware Block I/O.
    # A data disk needs no dedicated Boot#### entry, and Windows cannot prove its boot-time visibility.
    [pscustomobject]@{
        status = 'verified'; windowsBoot = $windowsEntries; secondaryFirmwareAccess = 'unverified'
    }
}

Export-ModuleMember -Function Assert-LibertixSecondaryBootPreflight
