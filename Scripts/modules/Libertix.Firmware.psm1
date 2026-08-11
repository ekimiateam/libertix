Set-StrictMode -Version Latest

function Add-LibertixBytes {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[byte]]$Buffer,
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )
    foreach ($byte in $Bytes) { $Buffer.Add($byte) }
}

function New-EfiFilePathNode {
    param([Parameter(Mandatory = $true)][string]$Path)
    $pathBytes = [Text.Encoding]::Unicode.GetBytes($Path + [char]0)
    $length = [uint16](4 + $pathBytes.Length)
    $buffer = [System.Collections.Generic.List[byte]]::new()
    Add-LibertixBytes $buffer ([byte[]](0x04, 0x04))
    Add-LibertixBytes $buffer ([BitConverter]::GetBytes($length))
    Add-LibertixBytes $buffer $pathBytes
    return [byte[]]$buffer.ToArray()
}

function New-EfiHardDriveNode {
    param([Parameter(Mandatory = $true)]$Partition)
    $disk = Get-Disk -Number $Partition.DiskNumber -ErrorAction Stop
    $sectorSize = [uint64]$disk.LogicalSectorSize
    if ($sectorSize -eq 0) { $sectorSize = 512 }
    $startLba = [uint64]($Partition.Offset / $sectorSize)
    $sizeLba = [uint64]($Partition.Size / $sectorSize)
    $partitionGuid = [Guid]$Partition.Guid
    $buffer = [System.Collections.Generic.List[byte]]::new()
    Add-LibertixBytes $buffer ([byte[]](0x04, 0x01, 0x2A, 0x00))
    Add-LibertixBytes $buffer ([BitConverter]::GetBytes([uint32]$Partition.PartitionNumber))
    Add-LibertixBytes $buffer ([BitConverter]::GetBytes($startLba))
    Add-LibertixBytes $buffer ([BitConverter]::GetBytes($sizeLba))
    Add-LibertixBytes $buffer ($partitionGuid.ToByteArray())
    Add-LibertixBytes $buffer ([byte[]](0x02, 0x02))
    return [byte[]]$buffer.ToArray()
}

function New-EfiEndNode { return [byte[]](0x7F, 0xFF, 0x04, 0x00) }

function New-EfiLoadOption {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)]$Partition,
        [Parameter(Mandatory = $true)][string]$LoaderPath
    )
    $devicePath = [System.Collections.Generic.List[byte]]::new()
    Add-LibertixBytes $devicePath (New-EfiHardDriveNode -Partition $Partition)
    Add-LibertixBytes $devicePath (New-EfiFilePathNode -Path $LoaderPath)
    Add-LibertixBytes $devicePath (New-EfiEndNode)
    $descriptionBytes = [Text.Encoding]::Unicode.GetBytes($Description + [char]0)
    $filePathBytes = [byte[]]$devicePath.ToArray()
    $buffer = [System.Collections.Generic.List[byte]]::new()
    Add-LibertixBytes $buffer ([BitConverter]::GetBytes([uint32]1))
    Add-LibertixBytes $buffer ([BitConverter]::GetBytes([uint16]$filePathBytes.Length))
    Add-LibertixBytes $buffer $descriptionBytes
    Add-LibertixBytes $buffer $filePathBytes
    return [byte[]]$buffer.ToArray()
}

function ConvertFrom-BootOrderBytes {
    param([byte[]]$Bytes)
    $order = New-Object System.Collections.Generic.List[uint16]
    if (-not $Bytes) { return $order }
    for ($offset = 0; $offset + 1 -lt $Bytes.Length; $offset += 2) {
        $order.Add([BitConverter]::ToUInt16($Bytes, $offset))
    }
    return $order
}

function ConvertTo-BootOrderBytes {
    param([Parameter(Mandatory = $true)]$Order)
    $buffer = [System.Collections.Generic.List[byte]]::new()
    foreach ($entry in $Order) {
        Add-LibertixBytes $buffer ([BitConverter]::GetBytes([uint16]$entry))
    }
    return [byte[]]$buffer.ToArray()
}

function Get-EfiLoadOptionDescription {
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -lt 8) { return "" }
    $offset = 6
    $end = $offset
    while ($end + 1 -lt $Bytes.Length) {
        if ($Bytes[$end] -eq 0 -and $Bytes[$end + 1] -eq 0) { break }
        $end += 2
    }
    if ($end -le $offset) { return "" }
    return [Text.Encoding]::Unicode.GetString($Bytes, $offset, $end - $offset)
}

function Get-EfiLoadOptionOptionalDataLength {
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -lt 8) { return -1 }
    $filePathListLength = [BitConverter]::ToUInt16($Bytes, 4)
    $offset = 6
    while ($offset + 1 -lt $Bytes.Length) {
        if ($Bytes[$offset] -eq 0 -and $Bytes[$offset + 1] -eq 0) {
            $offset += 2
            break
        }
        $offset += 2
    }
    $optionalStart = $offset + $filePathListLength
    if ($optionalStart -gt $Bytes.Length) { return -1 }
    return ($Bytes.Length - $optionalStart)
}

function Remove-EfiLoadOptionOptionalData {
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -lt 8) { throw "Invalid EFI load option; too short." }
    $filePathListLength = [BitConverter]::ToUInt16($Bytes, 4)
    $offset = 6
    while ($offset + 1 -lt $Bytes.Length) {
        if ($Bytes[$offset] -eq 0 -and $Bytes[$offset + 1] -eq 0) {
            $offset += 2
            break
        }
        $offset += 2
    }
    $optionalStart = $offset + $filePathListLength
    if ($optionalStart -gt $Bytes.Length) {
        throw "Invalid EFI load option; file path list exceeds variable length."
    }
    $clean = New-Object byte[] $optionalStart
    [Array]::Copy($Bytes, $clean, $optionalStart)
    return $clean
}

Export-ModuleMember -Function `
    New-EfiFilePathNode, New-EfiHardDriveNode, New-EfiEndNode, New-EfiLoadOption, `
    ConvertFrom-BootOrderBytes, ConvertTo-BootOrderBytes, `
    Get-EfiLoadOptionDescription, Get-EfiLoadOptionOptionalDataLength, `
    Remove-EfiLoadOptionOptionalData
