param([Parameter(Mandatory = $true)][string]$ConfigPath)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-FirmwareFixtureScripts {
    param([Parameter(Mandatory = $true)][string]$ReleaseRoot)

    $names = @("Scripts/modules/Libertix.Firmware.psm1", "Scripts/uefi/Libertix.Uefi.Firmware.ps1")
    $scripts = @{}
    if (@($names | Where-Object { -not (Test-Path -LiteralPath (Join-Path $ReleaseRoot $_)) }).Count -eq 0) {
        foreach ($name in $names) {
            $scripts[$name] = [IO.File]::ReadAllText((Join-Path $ReleaseRoot $name))
        }
        return $scripts
    }

    Add-Type -AssemblyName System.IO.Compression
    $assembly = [Reflection.Assembly]::ReflectionOnlyLoad(
        [IO.File]::ReadAllBytes((Join-Path $ReleaseRoot "Libertix.exe"))
    )
    $manifestStream = $assembly.GetManifestResourceStream("Libertix.Standalone.PayloadManifest.json")
    $payload = $assembly.GetManifestResourceStream("Libertix.Standalone.Payload.zip")
    $archive = $null
    try {
        if (-not $manifestStream -or -not $payload -or $manifestStream.Length -gt 1MB) {
            throw "The standalone release firmware payload or manifest is unavailable."
        }
        $reader = [IO.StreamReader]::new($manifestStream, [Text.Encoding]::UTF8)
        try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json }
        finally { $reader.Dispose() }
        if ([int]$manifest.schemaVersion -ne 1) { throw "Unsupported standalone manifest version." }
        $archive = [IO.Compression.ZipArchive]::new($payload, [IO.Compression.ZipArchiveMode]::Read)
        foreach ($name in $names) {
            $entries = @($archive.Entries | Where-Object FullName -eq $name)
            $records = @($manifest.files | Where-Object path -eq $name)
            if ($entries.Count -ne 1 -or $records.Count -ne 1 -or
                $entries[0].Length -gt 1MB -or $entries[0].Length -ne [long]$records[0].size) {
                throw "The standalone firmware helper is missing, ambiguous or invalid: $name"
            }
            $stream = $entries[0].Open()
            $buffer = [IO.MemoryStream]::new()
            $algorithm = [Security.Cryptography.SHA256]::Create()
            try {
                $stream.CopyTo($buffer)
                $bytes = $buffer.ToArray()
                $hash = ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
                if ($hash -ne [string]$records[0].sha256) {
                    throw "The standalone firmware helper hash is invalid: $name"
                }
                $scripts[$name] = [Text.UTF8Encoding]::new($false, $true).GetString($bytes).TrimStart([char]0xFEFF)
            } finally {
                $algorithm.Dispose()
                $buffer.Dispose()
                $stream.Dispose()
            }
        }
        return $scripts
    } finally {
        if ($archive) { $archive.Dispose() }
        if ($payload) { $payload.Dispose() }
        if ($manifestStream) { $manifestStream.Dispose() }
    }
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$releaseRoot = [IO.Path]::GetFullPath([string]$config.release_root)
$scripts = Get-FirmwareFixtureScripts -ReleaseRoot $releaseRoot
Import-Module (New-Module -Name LibertixFirmwareFixture -ScriptBlock (
    [scriptblock]::Create($scripts["Scripts/modules/Libertix.Firmware.psm1"])
)) -Force -ErrorAction Stop
. ([scriptblock]::Create($scripts["Scripts/uefi/Libertix.Uefi.Firmware.ps1"]))

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
