Set-StrictMode -Version Latest

function New-LibertixDownloadUrls {
    param(
        [Parameter(Mandatory = $true)][string]$FilepoolBaseUrl,
        [Parameter(Mandatory = $true)][string]$Aria2ZipName
    )
    $baseUrl = $FilepoolBaseUrl.TrimEnd("/")
    return [pscustomobject]@{
        InstallerIso = "$baseUrl/libertix-installer-uefi.iso"
        MintIso = "$baseUrl/mint.iso"
        Aria2Zip = "$baseUrl/$Aria2ZipName"
    }
}

function Get-MountedIsoDrive {
    param([Parameter(Mandatory = $true)][string]$ImagePath)
    $resolvedImagePath = [IO.Path]::GetFullPath($ImagePath)
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        $letters = @()
        $image = Get-DiskImage -ImagePath $resolvedImagePath -ErrorAction SilentlyContinue
        if ($image) {
            try {
                $letters += @(
                    $image | Get-Volume -ErrorAction SilentlyContinue |
                        Where-Object { $_.PSObject.Properties.Name -contains "DriveLetter" -and $_.DriveLetter } |
                        Select-Object -ExpandProperty DriveLetter
                )
            } catch {}
            try {
                $letters += @(
                    $image | Get-Disk -ErrorAction SilentlyContinue |
                        Get-Partition -ErrorAction SilentlyContinue |
                        Where-Object { $_.DriveLetter } |
                        Select-Object -ExpandProperty DriveLetter
                )
            } catch {}
        }
        $letter = $letters |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Select-Object -First 1
        if ($letter) { return "$letter`:" }
        Start-Sleep -Milliseconds 500
    }
    $diagnostic = Get-DiskImage -ImagePath $resolvedImagePath -ErrorAction SilentlyContinue |
        Format-List * | Out-String
    throw "ISO mounted, but no usable drive letter was found for $resolvedImagePath. DiskImage=$diagnostic"
}

Export-ModuleMember -Function New-LibertixDownloadUrls, Get-MountedIsoDrive
