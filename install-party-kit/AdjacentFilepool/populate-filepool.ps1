<#
.SYNOPSIS
Populates a "filepool" folder that Libertix can use instead of downloading its files.

.DESCRIPTION
Run it once on a computer with a fast Internet connection, then copy the folder next to
Libertix.exe. The signed catalog, every file size and every SHA-256 hash are verified.
Files that are already present and valid are kept and not downloaded again.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\populate-filepool.ps1 -Channel main -Output .\filepool
#>
[CmdletBinding()]
param(
    # Use "main" for a stable Libertix version and "dev" for a development build (dev_<commit>).
    [ValidateSet("main", "dev")][string]$Channel = "main",
    [string]$Output = "filepool"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Copy of Scripts/config/Libertix.CatalogPublicKey.xml, the key Libertix itself uses
# to verify catalog.json. Update both together if the signing key ever changes.
$CatalogPublicKeyXml = '<RSAKeyValue><Modulus>pFvbBspLzX/TS1BoIYOcILD1/VnEL/wYjN3wQAYXDsDeWuW52RFnBXoezrI6ulw8kuowfPvy913+jztUETMlLLabfNB/EXD9ZFjyC4A49HNq6o3L1Z0cTT7GLlWEAyBniZJJ3S5NqR6Zv+1kdE+StWzEm9LD6Ml/f4mR2IJLYxDC8j89jQAueJnFFP8OvTAdnkHECkqilUM8WTuaoZ6FZn8SfCMbYu/ZgoFPjvUl0eP6Z1xMScO6udK9W23JHN6M52Xz99Z7N55p1eItkrTjwSJvO73pAlga7UrUI6BK3uLOAYibzn0mIT3mUwrwXPDFTQ8qIOon7L06yF0fFEOSG9gxAQcf7nlsng2daAq2BqzFQ/oKNosG6IPvTP+ChHB9hgNnbXpZEj9gFC98fl0Il/EH3DVUQ8dwsV1Dij9PzpZyj7c2EmzqE2udCLP8hsqHHmMl4iV9hTjXo1eknORmyYOmK5DJk/Bzwmq4vmxm6iGqyj+BI6Luk0qLeBdT+Xg1</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>'
$BaseUrl = "https://ekimiateam.github.io/libertix/$Channel"

# GitHub and the distribution mirrors require TLS 1.2, which Windows PowerShell 5.1
# does not enable by default on every Windows version.
[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Get-WebBytes {
    param([Parameter(Mandatory = $true)][string]$Url)
    $client = New-Object Net.WebClient
    try { return $client.DownloadData($Url) } finally { $client.Dispose() }
}

function Assert-CatalogSignature {
    param([byte[]]$Catalog, [string]$SignatureBase64)
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    try {
        $rsa.PersistKeyInCsp = $false
        $rsa.FromXmlString($CatalogPublicKeyXml)
        $signature = [Convert]::FromBase64String($SignatureBase64.Trim())
        $sha256 = [Security.Cryptography.CryptoConfig]::MapNameToOID("SHA256")
        if (-not $rsa.VerifyData($Catalog, $sha256, $signature)) {
            throw "The catalog signature is invalid."
        }
    } finally {
        $rsa.Dispose()
    }
}

function Test-ArtifactFile {
    param([string]$Path, [int64]$Size, [string]$Sha256)
    $file = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $file -or $file.PSIsContainer -or
        ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.Length -ne $Size) {
        return $false
    }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() -eq $Sha256
}

function Receive-ToPartialFile {
    param([string]$Url, [string]$Partial, [int64]$Size)
    $existing = 0
    if (Test-Path -LiteralPath $Partial -PathType Leaf) {
        $existing = (Get-Item -LiteralPath $Partial).Length
    }
    $request = [Net.HttpWebRequest]::Create($Url)
    $request.ReadWriteTimeout = 120000
    # Resume an interrupted download; a server that ignores the range restarts it.
    if ($existing -gt 0) { $request.AddRange($existing) }
    $response = $request.GetResponse()
    try {
        $append = $existing -gt 0 -and [int]$response.StatusCode -eq 206
        $mode = if ($append) { [IO.FileMode]::Append } else { [IO.FileMode]::Create }
        $received = if ($append) { $existing } else { 0 }
        $source = $response.GetResponseStream()
        $output = New-Object IO.FileStream($Partial, $mode, [IO.FileAccess]::Write)
        try {
            $buffer = New-Object byte[] 1048576
            $nextReport = 0
            while (($read = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $received += $read
                if ($received -gt $Size) { throw "The server sent more data than the catalog size." }
                $output.Write($buffer, 0, $read)
                if ($received -ge $nextReport) {
                    Write-Progress -Activity (Split-Path -Leaf $Partial) `
                        -Status ("{0:N0} / {1:N0} MiB" -f ($received / 1MB), ($Size / 1MB)) `
                        -PercentComplete ([int](100 * $received / $Size))
                    $nextReport = $received + 16MB
                }
            }
        } finally {
            $output.Dispose()
            $source.Dispose()
        }
    } finally {
        $response.Dispose()
        Write-Progress -Activity (Split-Path -Leaf $Partial) -Completed
    }
}

function Receive-Artifact {
    param([string]$Url, [string]$Path, [int64]$Size, [string]$Sha256)
    $partial = "$Path.partial"
    try {
        Receive-ToPartialFile -Url $Url -Partial $partial -Size $Size
    } catch [Net.WebException] {
        # 416: the partial file is already complete or too large, so it cannot be resumed.
        # Any other error keeps the partial file so that the next run resumes it.
        $response = $_.Exception.Response
        if (-not $response -or [int]$response.StatusCode -ne 416) { throw }
        Remove-Item -LiteralPath $partial -Force
        Receive-ToPartialFile -Url $Url -Partial $partial -Size $Size
    }
    if (-not (Test-ArtifactFile -Path $partial -Size $Size -Sha256 $Sha256)) {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        throw "$(Split-Path -Leaf $Path) does not match the catalog size or SHA-256."
    }
    Move-Item -LiteralPath $partial -Destination $Path -Force
}

New-Item -ItemType Directory -Path $Output -Force | Out-Null
$Output = (Resolve-Path -LiteralPath $Output).ProviderPath

Write-Host "Downloading the signed $Channel catalog..."
$catalogBytes = Get-WebBytes "$BaseUrl/catalog.json"
$signatureBytes = Get-WebBytes "$BaseUrl/catalog.json.sig"
Assert-CatalogSignature -Catalog $catalogBytes -SignatureBase64 ([Text.Encoding]::ASCII.GetString($signatureBytes))
Write-Host "Catalog signature verified."
$catalog = [Text.Encoding]::UTF8.GetString($catalogBytes) | ConvertFrom-Json

# Relative URLs are resolved against the channel, as Libertix does.
$artifacts = New-Object Collections.Generic.List[object]
$required = @($catalog.artifacts.wpf, $catalog.artifacts.miniIso.bios, $catalog.artifacts.miniIso.uefi) +
    @($catalog.artifacts.support.PSObject.Properties | ForEach-Object { $_.Value })
foreach ($item in $required) {
    $artifacts.Add([pscustomobject]@{ Kind = "required"; Name = $item.fileName; Size = [int64]$item.sizeBytes
        Sha256 = $item.sha256.ToLowerInvariant(); Url = $item.url; Label = $item.fileName })
}
foreach ($distribution in $catalog.distributions) {
    $artifacts.Add([pscustomobject]@{ Kind = "distribution"; Name = $distribution.isoInstallerFileName
        Size = [int64]$distribution.isoInstallerSizeBytes; Sha256 = $distribution.isoInstallerSha256.ToLowerInvariant()
        Url = $distribution.isoInstaller; Label = $distribution.name })
}
foreach ($artifact in $artifacts) {
    if ($artifact.Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
        throw "Unsafe file name in the catalog: $($artifact.Name)"
    }
    if ($artifact.Url -notmatch '^https?://') {
        $artifact.Url = "$BaseUrl/" + $artifact.Url.TrimStart('/')
    }
}

$distributions = @($artifacts | Where-Object { $_.Kind -eq "distribution" })
Write-Host ""
Write-Host "Distribution ISO images are optional: Libertix downloads a missing one"
Write-Host "when that distribution is chosen. All other files are always required."
Write-Host "  1) All distributions"
for ($index = 0; $index -lt $distributions.Count; $index++) {
    Write-Host ("  {0}) {1} only" -f ($index + 2), $distributions[$index].Label)
}
$noneChoice = $distributions.Count + 2
Write-Host "  $noneChoice) No distribution ISO (required files only)"
$answer = Read-Host "Choice [1]"
if ([string]::IsNullOrWhiteSpace($answer)) { $answer = "1" }
$choice = 0
if (-not [int]::TryParse($answer, [ref]$choice) -or $choice -lt 1 -or $choice -gt $noneChoice) {
    throw "Invalid choice: $answer"
}
$selected = @(switch ($choice) {
    1 { $distributions.Name }
    $noneChoice { }
    default { $distributions[$choice - 2].Name }
})

$failed = $false
foreach ($artifact in $artifacts) {
    $path = Join-Path $Output $artifact.Name
    if ($artifact.Kind -eq "distribution" -and $selected -notcontains $artifact.Name) {
        # Libertix verifies every distribution ISO found in the folder.
        if ((Test-Path -LiteralPath $path) -and
            -not (Test-ArtifactFile -Path $path -Size $artifact.Size -Sha256 $artifact.Sha256)) {
            Write-Host "ERROR: $($artifact.Name) ($($artifact.Label)) is present but outdated or corrupt." -ForegroundColor Red
            Write-Host "       Delete it or select it so that it is downloaded again." -ForegroundColor Red
            $failed = $true
        }
        continue
    }
    if (Test-ArtifactFile -Path $path -Size $artifact.Size -Sha256 $artifact.Sha256) {
        Write-Host "OK      $($artifact.Name) (already present and verified)"
        continue
    }
    Write-Host ("GET     {0} ({1:N0} MiB) from {2}" -f $artifact.Name, ($artifact.Size / 1MB), $artifact.Url)
    try {
        Receive-Artifact -Url $artifact.Url -Path $path -Size $artifact.Size -Sha256 $artifact.Sha256
        Write-Host "OK      $($artifact.Name) (downloaded and verified)"
    } catch {
        Write-Host "ERROR: Could not obtain $($artifact.Name): $($_.Exception.Message)" -ForegroundColor Red
        $failed = $true
    }
}

Write-Host ""
if ($failed) {
    Write-Host "The folder is NOT ready: fix the errors above and run the script again." -ForegroundColor Red
    exit 1
}
# The catalog is written last, only once every file it requires has been verified.
[IO.File]::WriteAllBytes((Join-Path $Output "catalog.json"), $catalogBytes)
[IO.File]::WriteAllBytes((Join-Path $Output "catalog.json.sig"), $signatureBytes)
Write-Host "The folder is ready: $Output"
Write-Host 'Copy it next to Libertix.exe with the name "filepool".'
