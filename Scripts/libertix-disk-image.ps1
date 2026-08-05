#requires -Version 5.1

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Mount", "Dismount")]
    [string]$Action,
    [Parameter(Mandatory = $true)]
    [string]$ImagePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($Action -eq "Dismount") {
    Dismount-DiskImage -ImagePath $ImagePath -ErrorAction Stop
    exit 0
}

$diskImage = Mount-DiskImage -ImagePath $ImagePath -PassThru -ErrorAction Stop
for ($attempt = 0; $attempt -lt 120; $attempt++) {
    $volume = $diskImage | Get-Volume -ErrorAction SilentlyContinue |
        Where-Object DriveLetter |
        Select-Object -First 1
    if ($volume) {
        Write-Output ([string]$volume.DriveLetter)
        exit 0
    }
    Start-Sleep -Milliseconds 250
}

throw "Windows mounted the ISO but did not expose a drive letter within 30 seconds."
