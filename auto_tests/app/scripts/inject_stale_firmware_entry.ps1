param([Parameter(Mandatory = $true)][string]$ConfigPath)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$releaseRoot = [IO.Path]::GetFullPath([string]$config.release_root)
$firmwareModule = Join-Path $releaseRoot "Scripts\modules\Libertix.Firmware.psm1"
$firmwareScript = Join-Path $releaseRoot "Scripts\uefi\Libertix.Uefi.Firmware.ps1"
if (
    -not (Test-Path -LiteralPath $firmwareModule -PathType Leaf) -or
    -not (Test-Path -LiteralPath $firmwareScript -PathType Leaf)
) {
    throw "The deployed Libertix release does not contain its UEFI firmware helpers."
}
Import-Module -Name $firmwareModule -Force -ErrorAction Stop
. $firmwareScript

$systemPartition = Get-Partition `
    -DriveLetter $env:SystemDrive.TrimEnd(":") `
    -ErrorAction Stop
$espType = "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}"
$espPartitions = @(
    Get-Partition -DiskNumber $systemPartition.DiskNumber -ErrorAction Stop |
        Where-Object { [string]$_.GptType -eq $espType }
)
if ($espPartitions.Count -ne 1) {
    throw "The stale firmware-entry fixture requires exactly one ESP on the Windows system disk."
}
$esp = $espPartitions[0]
$staleGuid = [Guid]::NewGuid()
if ($staleGuid -eq [Guid]$esp.Guid) {
    throw "The generated stale ESP identifier unexpectedly equals the current ESP."
}
$stalePartition = [pscustomobject]@{
    DiskNumber = [int]$esp.DiskNumber
    PartitionNumber = [int]$esp.PartitionNumber
    Offset = [uint64]$esp.Offset
    Size = [uint64]$esp.Size
    Guid = $staleGuid
}
$loadOption = New-EfiLoadOption `
    -Description "Libertix" `
    -Partition $stalePartition `
    -LoaderPath "\EFI\Libertix\shimx64.efi"

$usedNumbers = @{}
foreach ($known in @(
    ConvertFrom-BootOrderBytes -Bytes (Get-FirmwareVariableBytes -Name "BootOrder")
    ConvertFrom-BootOrderBytes -Bytes (Get-FirmwareVariableBytes -Name "BootNext")
)) {
    $usedNumbers[[int]$known] = $true
}
$bootNumber = $null
for ($candidate = 0; $candidate -le 0xFFFF; $candidate++) {
    if ($usedNumbers.ContainsKey($candidate)) { continue }
    $candidateName = "Boot{0:X4}" -f $candidate
    if (-not (Test-FirmwareVariableExists -Name $candidateName)) {
        $bootNumber = [uint16]$candidate
        break
    }
}
if ($null -eq $bootNumber) {
    throw "No free UEFI Boot#### variable is available for the stale firmware-entry fixture."
}
$bootVariable = "Boot{0:X4}" -f $bootNumber
Set-FirmwareVariable -Name $bootVariable -Value $loadOption

$existingOrder = @(ConvertFrom-BootOrderBytes -Bytes (Get-FirmwareVariableBytes -Name "BootOrder"))
$newOrder = @([uint16]$bootNumber) + @(
    $existingOrder | Where-Object { [uint16]$_ -ne [uint16]$bootNumber }
)
Set-FirmwareVariable -Name "BootOrder" -Value (ConvertTo-BootOrderBytes -Order $newOrder)
$readBack = Get-FirmwareVariableBytes -Name $bootVariable
if (-not $readBack -or (Get-EfiLoadOptionDescription -Bytes $readBack) -ne "Libertix") {
    throw "The stale UEFI boot entry was not retained by firmware."
}

Write-Output "STALE_BOOT_VARIABLE=$bootVariable"
Write-Output "STALE_PARTITION_GUID=$($staleGuid.ToString('D').ToLowerInvariant())"
