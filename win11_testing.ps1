#requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$Force = $false,
    [switch]$Revert = $false,
    [switch]$SkipDebian = $false,
    [int]$DebianPartitionSizeGB = 4,
    [switch]$InsecureTls = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Networking defaults
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($InsecureTls) {
    try {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) {
        return true;
    }
}
"@
    } catch {}

    [System.Net.ServicePointManager]::CertificatePolicy =
        New-Object TrustAllCertsPolicy

    if (
        -not (
            [System.Management.Automation.PSTypeName]`
                "ServerCertificateValidationCallback"
        ).Type
    ) {
        $certCallback = @"
using System;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public class ServerCertificateValidationCallback {
    public static void Ignore() {
        ServicePointManager.ServerCertificateValidationCallback +=
            delegate(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors sslPolicyErrors) { return true; };
    }
}
"@
        try { Add-Type $certCallback } catch {}
    }

    try { [ServerCertificateValidationCallback]::Ignore() } catch {}
}

# Downloads
$BaseUrl = "https://tpm28.com/filepool"
$RefindZipUrl = "$BaseUrl/refind-bin-0.14.2.zip"
$PreLoaderUrl = "$BaseUrl/PreLoader.efi"
$HashToolUrl = "$BaseUrl/HashTool.efi"

$DebianIsoUrl =
    "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.3.0-amd64-netinst.iso"
$DebianIsoName = "debian-13.3.0-amd64-netinst.iso"

# Defaults
$EspLetter = "Y"
$DebianLetter = "X"
$DebianLabel = "DEBIAN"

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("Gray", "Cyan", "Green", "Yellow", "Red", "White")]
        [string]$Color = "Gray"
    )

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Invoke-DiskpartScript {
    param([Parameter(Mandatory = $true)][string]$ScriptText)

    $tmp = [IO.Path]::GetTempFileName()
    try {
        $ScriptText | Out-File $tmp -Encoding ASCII
        diskpart /s $tmp 2>&1 | Out-Null
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Get-GuidDLower {
    param([Parameter(Mandatory = $true)][Guid]$Guid)
    $Guid.ToString("D").ToLower()
}

function Mount-Esp {
    param([Parameter(Mandatory = $true)][string]$Letter)

    if (Test-Path "${Letter}:\") {
        Invoke-DiskpartScript -ScriptText @"
select volume $Letter
remove letter=$Letter
exit
"@
        Start-Sleep -Seconds 1
    }

    $winPart = Get-Partition -DriveLetter C
    $espPart =
        Get-Partition -DiskNumber $winPart.DiskNumber |
        Where-Object {
            $_.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}"
        } |
        Select-Object -First 1

    if (-not $espPart) {
        throw "ESP not found on disk $($winPart.DiskNumber)."
    }

    Invoke-DiskpartScript -ScriptText @"
select disk $($espPart.DiskNumber)
select partition $($espPart.PartitionNumber)
assign letter=$Letter
exit
"@

    $tries = 0
    while (-not (Test-Path "${Letter}:\") -and $tries -lt 10) {
        Start-Sleep -Seconds 1
        $tries++
    }

    if (-not (Test-Path "${Letter}:\")) {
        throw "Failed to mount ESP as ${Letter}:"
    }

    return "${Letter}:"
}

function Dismount-Letter {
    param([Parameter(Mandatory = $true)][string]$Letter)

    if (Test-Path "${Letter}:\") {
        Invoke-DiskpartScript -ScriptText @"
select volume $Letter
remove letter=$Letter
exit
"@
    }
}

function Ensure-VolumeLetterByLabel {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Letter
    )

    $vol = Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.FileSystemLabel -eq $Label } |
        Select-Object -First 1

    if ($vol -and $vol.DriveLetter) {
        if ($vol.DriveLetter -ne $Letter) {
            $part = Get-Partition -DriveLetter $vol.DriveLetter
            Set-Partition -DiskNumber $part.DiskNumber `
                -PartitionNumber $part.PartitionNumber `
                -NewDriveLetter $Letter
        }
        return "${Letter}:"
    }

    $cim = Get-CimInstance Win32_Volume -Filter "Label='$Label'" `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $cim) {
        return $null
    }

    if ($cim.DriveLetter -and $cim.DriveLetter.TrimEnd(":") -eq $Letter) {
        return "${Letter}:"
    }

    $deviceId = $cim.DeviceID
    if (-not $deviceId.EndsWith("\")) {
        $deviceId = "$deviceId\"
    }

    # Assign letter using mountvol (works even if previously hidden)
    & mountvol "${Letter}:" $deviceId | Out-Null

    if (-not (Test-Path "${Letter}:\")) {
        throw "Failed to assign ${Letter}: to volume labeled '$Label'."
    }

    return "${Letter}:"
}

function Get-PartitionGuidForLetter {
    param([Parameter(Mandatory = $true)][string]$Letter)

    $p = Get-Partition -DriveLetter $Letter -ErrorAction SilentlyContinue
    if ($p -and $p.Guid) {
        return (Get-GuidDLower -Guid $p.Guid)
    }
    return $null
}

function Write-RefindConfig {
    param(
        [Parameter(Mandatory = $true)][string]$EspPath,
        [Parameter(Mandatory = $true)][bool]$IncludeDebian,
        [Parameter()][string]$DebianGuidD,
        [Parameter()][string]$DebianFsLabel
    )

    $configPath = Join-Path $EspPath "EFI\refind\refind.conf"

    $base = @"
timeout 10
scanfor manual

dont_scan_dirs ESP:/EFI/boot,EFI/boot,EFI/Microsoft
dont_scan_files shimx64.efi,PreLoader.efi,HashTool.efi,loader.efi,refind_x64.efi,bootmgfw.efi,bootx64.efi,grubx64.efi
dont_scan_volumes "Recovery","SYSTEM"

use_graphics_for windows

menuentry "Windows" {
    icon /EFI/refind/icons/os_win8.png
    firmware_bootnum 0001
}
"@

    if (-not $IncludeDebian) {
        Set-Content -Path $configPath -Value $base -Encoding UTF8
        return
    }

    $volumeLine =
        if ($DebianGuidD) {
            "    volume $DebianGuidD"
        } else {
            "    volume `"$DebianFsLabel`""
        }

    $debian = @"

menuentry "Debian Installer" {
    icon /EFI/refind/icons/os_debian.png
$volumeLine
    loader /EFI/BOOT/BOOTX64.EFI
}
"@

    Set-Content -Path $configPath -Value ($base + $debian) -Encoding UTF8
}

function Start-BitsDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $job = Start-BitsTransfer -Source $Url -Destination $Destination `
        -Asynchronous -DisplayName "Download: $([IO.Path]::GetFileName($Destination))" `
        -ErrorAction Stop

    $jobId = $job.JobId

    while ($true) {
        $j = Get-BitsTransfer -Id $jobId -ErrorAction SilentlyContinue
        if (-not $j) { break }

        if ($j.JobState -in @("Connecting", "Transferring")) {
            $pct = 0
            if ($j.BytesTotal -gt 0) {
                $pct = [math]::Round(($j.BytesTransferred / $j.BytesTotal) * 100, 1)
            }
            Write-Progress -Activity "Downloading ISO" -PercentComplete $pct `
                -Status "$pct% ($([math]::Round($j.BytesTransferred / 1MB, 1)) MB)"
            Start-Sleep -Seconds 2
            continue
        }

        if ($j.JobState -eq "Suspended") {
            Resume-BitsTransfer -BitsJob $j | Out-Null
            Start-Sleep -Seconds 1
            continue
        }

        if ($j.JobState -eq "Transferred") {
            Complete-BitsTransfer -BitsJob $j
            break
        }

        if ($j.JobState -eq "Error") {
            try { Remove-BitsTransfer -BitsJob $j } catch {}
            throw "BITS transfer failed."
        }

        if ($j.JobState -in @("Cancelled", "Acknowledged")) {
            throw "BITS ended unexpectedly (state=$($j.JobState))."
        }

        Start-Sleep -Seconds 1
    }

    Write-Progress -Activity "Downloading ISO" -Completed
}

function Ensure-VolumeNotEncrypted {
    param([Parameter(Mandatory = $true)][string]$DriveLetter)

    $out = manage-bde -status "${DriveLetter}:" 2>&1 | Out-String

    $needsDecryption = $false
    if ($out -match "Percentage Encrypted:\s*(\d+\.?\d*)%?") {
        if ([double]$matches[1] -gt 0) { $needsDecryption = $true }
    }

    if (
        $out -match "Conversion Status:\s*(Encryption in Progress|Used Space Only Encrypted|Fully Encrypted)" -or
        $out -match "Protection Status:\s*(Protection On)"
    ) {
        $needsDecryption = $true
    }

    if (-not $needsDecryption) {
        return
    }

    Write-Log "BitLocker detected on ${DriveLetter}:, disabling..." "Yellow"
    manage-bde -off "${DriveLetter}:" 2>&1 | Out-Null

    $timeoutSec = 600
    $elapsed = 0
    $interval = 3

    while ($elapsed -lt $timeoutSec) {
        Start-Sleep -Seconds $interval
        $elapsed += $interval

        $out = manage-bde -status "${DriveLetter}:" 2>&1 | Out-String
        if ($out -match "Percentage Encrypted:\s*(\d+\.?\d*)%?") {
            $enc = [double]$matches[1]
            $pct = [math]::Round(100 - $enc, 1)
            Write-Progress -Activity "Decrypting ${DriveLetter}:" `
                -PercentComplete $pct -Status "$pct% ($elapsed sec)"
            if ($enc -eq 0) { break }
        }

        if ($out -match "Conversion Status:\s*Fully Decrypted") { break }
        if ($out -match "État de la conversion:\s*Intégralement déchiffré") { break }
    }

    Write-Progress -Activity "Decrypting ${DriveLetter}:" -Completed
}


function Invoke-Revert {
    Write-Log "Reverting rEFInd..." "Cyan"

    $esp = $null
    try {
        $esp = Mount-Esp -Letter $EspLetter

        $refindDir = Join-Path $esp "EFI\refind"
        if (Test-Path $refindDir) {
            Remove-Item -Path $refindDir -Recurse -Force
        }

        bcdedit /set "{bootmgr}" path \EFI\Microsoft\Boot\bootmgfw.efi 2>$null |
            Out-Null
        bcdedit /set "{bootmgr}" description "Windows Boot Manager" 2>$null |
            Out-Null

        $fw = bcdedit /enum firmware 2>&1
        if ($fw -match "rEFInd.*\{([a-f0-9\-]+)\}") {
            $id = "{$($matches[1])}"
            bcdedit /delete $id 2>$null | Out-Null
        }

        bcdedit /set "{fwbootmgr}" default "{bootmgr}" 2>$null | Out-Null

        Write-Log "Revert complete." "Green"
    } finally {
        if ($esp) { Dismount-Letter -Letter $EspLetter }
    }

    Write-Host ""
    Write-Host "Note: the DEBIAN partition is not removed." -ForegroundColor Yellow
}

function Install-Refind {
    Write-Log "Installing rEFInd to ESP..." "Cyan"

    $tmpDir = Join-Path $env:TEMP "refind-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    $esp = $null
    try {
        $refindZip = Join-Path $tmpDir "refind.zip"
        $preLoader = Join-Path $tmpDir "PreLoader.efi"
        $hashTool = Join-Path $tmpDir "HashTool.efi"

        Invoke-WebRequest -Uri $RefindZipUrl -OutFile $refindZip -UseBasicParsing
        Invoke-WebRequest -Uri $PreLoaderUrl -OutFile $preLoader -UseBasicParsing
        Invoke-WebRequest -Uri $HashToolUrl -OutFile $hashTool -UseBasicParsing

        $extract = Join-Path $tmpDir "extract"
        Expand-Archive -LiteralPath $refindZip -DestinationPath $extract -Force

        $refindRoot =
            Get-ChildItem -Path $extract -Directory -Filter "refind*" |
            Select-Object -First 1

        if (-not $refindRoot) {
            throw "Failed to locate extracted rEFInd directory."
        }

        $refindSource = Join-Path $refindRoot.FullName "refind"

        $esp = Mount-Esp -Letter $EspLetter
        $dest = Join-Path $esp "EFI\refind"

        if (Test-Path $dest) {
            Remove-Item -Path $dest -Recurse -Force
        }
        New-Item -ItemType Directory -Path $dest -Force | Out-Null

        Copy-Item -Path "$refindSource\*" -Destination $dest -Recurse -Force

        @(
            "drivers_ia32",
            "drivers_aa64",
            "tools_ia32",
            "tools_aa64",
            "refind_ia32.efi",
            "refind_aa64.efi"
        ) | ForEach-Object {
            $p = Join-Path $dest $_
            if (Test-Path $p) {
                Remove-Item -Path $p -Recurse -Force
            }
        }

        Copy-Item -Path $preLoader -Destination (Join-Path $dest "shimx64.efi") `
            -Force
        Copy-Item -Path (Join-Path $dest "refind_x64.efi") `
            -Destination (Join-Path $dest "loader.efi") -Force
        Copy-Item -Path $hashTool -Destination (Join-Path $dest "HashTool.efi") `
            -Force

        # Minimal config now; Debian entry is added later if requested
        Write-RefindConfig -EspPath $esp -IncludeDebian:$false `
            -DebianGuidD $null -DebianFsLabel $DebianLabel

        # Disable hibernation / Fast Startup
        powercfg /h off 2>&1 | Out-Null

        # Create a dedicated UEFI entry (keep Windows Boot Manager intact)
        $bootmgr = bcdedit /enum "{bootmgr}" 2>&1
        if ($bootmgr -match "refind|shimx64") {
            bcdedit /set "{bootmgr}" path \EFI\Microsoft\Boot\bootmgfw.efi |
                Out-Null
            bcdedit /set "{bootmgr}" description "Windows Boot Manager" | Out-Null
        }

        $copy = bcdedit /copy "{bootmgr}" /d "rEFInd Boot Manager" 2>&1
        if ($copy -match "\{([a-f0-9\-]+)\}") {
            $entry = $matches[0]
            bcdedit /set $entry path \EFI\refind\shimx64.efi | Out-Null
            bcdedit /set "{fwbootmgr}" displayorder $entry /addfirst 2>$null
            bcdedit /set "{fwbootmgr}" default $entry 2>$null
        } else {
            # Fallback: modify {bootmgr}
            bcdedit /set "{bootmgr}" path \EFI\refind\shimx64.efi | Out-Null
            bcdedit /set "{bootmgr}" description "rEFInd Boot Manager" | Out-Null
        }

        Write-Log "rEFInd installed." "Green"
    } finally {
        if ($esp) { Dismount-Letter -Letter $EspLetter }
        Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function New-OrReuseDebianPartition {
    param([Parameter(Mandatory = $true)][int]$SizeGB)

    # If it already exists (maybe hidden), bring it back as X:
    $existing = Ensure-VolumeLetterByLabel -Label $DebianLabel -Letter $DebianLetter
    if ($existing) {
        $guid = Get-PartitionGuidForLetter -Letter $DebianLetter
        return @{
            Drive = $existing
            GuidD = $guid
        }
    }

    $sizeMB = $SizeGB * 1024
    $cPart = Get-Partition -DriveLetter C
    $cVol = Get-Volume -DriveLetter C

    $minFree = 10GB
    $need = ($sizeMB * 1MB) + $minFree

    if ($cVol.SizeRemaining -lt $need) {
        throw "Not enough free space on C: (need ~$( [math]::Round($need / 1GB, 1) ) GB)."
    }

    $supported = $cPart | Get-PartitionSupportedSize
    $shrinkBytes = $sizeMB * 1MB
    $maxShrink = $supported.SizeMax - $supported.SizeMin

    if ($shrinkBytes -gt $maxShrink) {
        throw "Cannot shrink C: by ${SizeGB}GB (max ~$( [math]::Round($maxShrink / 1GB, 1) ) GB)."
    }

    Write-Log "Creating ${SizeGB}GB FAT32 partition '$DebianLabel'..." "Cyan"

    Resize-Partition -DriveLetter C -Size ($cPart.Size - $shrinkBytes)
    Start-Sleep -Seconds 2

    Invoke-DiskpartScript -ScriptText @"
select disk $($cPart.DiskNumber)
create partition primary size=$sizeMB
format fs=fat32 quick label=$DebianLabel
assign letter=$DebianLetter
exit
"@

    $tries = 0
    while (-not (Test-Path "${DebianLetter}:\") -and $tries -lt 15) {
        Start-Sleep -Seconds 1
        $tries++
    }

    if (-not (Test-Path "${DebianLetter}:\")) {
        throw "Failed to create/assign ${DebianLetter}: for Debian partition."
    }

    Ensure-VolumeNotEncrypted -DriveLetter $DebianLetter

    $guid = Get-PartitionGuidForLetter -Letter $DebianLetter

    return @{
        Drive = "${DebianLetter}:"
        GuidD = $guid
    }
}

function Install-DebianIsoToPartition {
    param(
        [Parameter(Mandatory = $true)][string]$PartitionDrive
    )

    $tmpDir = Join-Path $env:TEMP "debian-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    $isoPath = Join-Path $tmpDir $DebianIsoName

    try {
        Write-Log "Downloading Debian ISO..." "Cyan"

        $downloaded = $false
        try {
            Start-BitsDownload -Url $DebianIsoUrl -Destination $isoPath
            $downloaded = $true
        } catch {
            Write-Log "BITS failed; using Invoke-WebRequest..." "Yellow"
        }

        if (-not $downloaded) {
            $ProgressPreference = "SilentlyContinue"
            Invoke-WebRequest -Uri $DebianIsoUrl -OutFile $isoPath -UseBasicParsing
            $ProgressPreference = "Continue"
        }

        if (-not (Test-Path $isoPath)) {
            throw "ISO download failed."
        }

        Write-Log "Mounting ISO..." "Cyan"
        $img = Mount-DiskImage -ImagePath $isoPath -PassThru
        $vol = $img | Get-Volume

        if (-not $vol.DriveLetter) {
            Start-Sleep -Seconds 2
            $vol =
                Get-Volume |
                Where-Object { $_.DriveType -eq "CD-ROM" -and $_.Size -gt 0 } |
                Select-Object -First 1
        }

        if (-not $vol -or -not $vol.DriveLetter) {
            throw "ISO mounted but no drive letter was assigned."
        }

        $src = "$($vol.DriveLetter):\*"
        $dst = "$PartitionDrive\"

        Write-Log "Copying ISO contents to $PartitionDrive..." "Cyan"
        Copy-Item -Path $src -Destination $dst -Recurse -Force

        Dismount-DiskImage -ImagePath $isoPath | Out-Null
        Write-Log "Debian installer copied." "Green"
    } finally {
        try {
            Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue |
                Out-Null
        } catch {}

        Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if (-not (Test-Administrator)) {
    Write-Log "Run this script as Administrator." "Red"
    exit 1
}

if ($Revert) {
    Invoke-Revert
    exit 0
}

if (-not $Force) {
    $already = bcdedit /enum firmware 2>$null | Select-String -Pattern "refind"
    if ($already) {
        Write-Log "rEFInd entry detected. Use -Force to reinstall." "Yellow"
    }
}

try {
    Install-Refind

    if ($SkipDebian) {
        $esp = Mount-Esp -Letter $EspLetter
        try {
            Write-RefindConfig -EspPath $esp -IncludeDebian:$false `
                -DebianGuidD $null -DebianFsLabel $DebianLabel
        } finally {
            Dismount-Letter -Letter $EspLetter
        }

        Write-Log "Done (Windows entry only)." "Green"
        exit 0
    }

    $info = New-OrReuseDebianPartition -SizeGB $DebianPartitionSizeGB
    $drive = $info.Drive
    $guidD = $info.GuidD

    Install-DebianIsoToPartition -PartitionDrive $drive

    $esp = Mount-Esp -Letter $EspLetter
    try {
        Write-RefindConfig -EspPath $esp -IncludeDebian:$true `
            -DebianGuidD $guidD -DebianFsLabel $DebianLabel
    } finally {
        Dismount-Letter -Letter $EspLetter
    }

    Dismount-Letter -Letter $DebianLetter

    Write-Host ""
    Write-Log "Complete. rEFInd menu: Windows + Debian Installer." "Green"
    Write-Host ""
    Write-Host "First boot (Secure Boot): enroll loader.efi via HashTool if prompted." `
        -ForegroundColor Yellow

    $r = Read-Host "Restart now? (y/n)"
    if ($r -match "^(y|Y)$") {
        Restart-Computer -Force
    }
} catch {
    Write-Log $_.Exception.Message "Red"
    Write-Log "Tip: you can run with -Revert to restore Windows boot." "Yellow"
    exit 1
}
