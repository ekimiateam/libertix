param(
    [Parameter(Mandatory = $true)][string]$InputDirectory,
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$ZipPath,
    [Parameter(Mandatory = $true)][string]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$inputRoot = [IO.Path]::GetFullPath($InputDirectory).TrimEnd('\') + '\'
$projectRootPath = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\') + '\'
if (-not (Test-Path -LiteralPath (Join-Path $inputRoot "Libertix.exe") -PathType Leaf)) {
    throw "The compiled Libertix runtime is missing from the payload input directory."
}
if (-not (Test-Path -LiteralPath (Join-Path $inputRoot "Libertix.BootGuardian.exe") -PathType Leaf)) {
    throw "The compiled boot guardian is missing from the payload input directory."
}

$files = @(
    Get-ChildItem -LiteralPath $inputRoot -File -Recurse -ErrorAction Stop |
        Where-Object {
            $_.Extension -notin @(".pdb", ".xml") -and
            $_.Name -notmatch '^Libertix\.Standalone\.'
        } |
        ForEach-Object {
            [pscustomobject]@{
                Source = $_.FullName
                RelativePath = $_.FullName.Substring($inputRoot.Length).Replace('\', '/')
            }
        }
)
foreach ($name in @("LICENSE", "THIRD_PARTY.md")) {
    $source = Join-Path $projectRootPath $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Required notice is missing from the standalone payload: $name"
    }
    $files += [pscustomobject]@{ Source = $source; RelativePath = $name }
}
$files = @($files | Sort-Object RelativePath)
$duplicates = @($files | Group-Object RelativePath | Where-Object Count -ne 1)
if ($duplicates.Count -ne 0) {
    throw "Standalone payload contains duplicate relative paths."
}

$entries = @()
foreach ($file in $files) {
    $info = Get-Item -LiteralPath $file.Source -ErrorAction Stop
    $entries += [ordered]@{
        path = [string]$file.RelativePath
        size = [int64]$info.Length
        sha256 = (Get-FileHash -LiteralPath $info.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
$manifest = [ordered]@{
    schemaVersion = 1
    files = $entries
}

$zipDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($ZipPath))
$manifestDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($ManifestPath))
[IO.Directory]::CreateDirectory($zipDirectory) | Out-Null
[IO.Directory]::CreateDirectory($manifestDirectory) | Out-Null
$temporaryZip = Join-Path $zipDirectory ".payload.$([Guid]::NewGuid().ToString('N')).zip"
$temporaryManifest = Join-Path $manifestDirectory ".manifest.$([Guid]::NewGuid().ToString('N')).json"
try {
    $stream = [IO.File]::Open(
        $temporaryZip,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None
    )
    try {
        $archive = New-Object IO.Compression.ZipArchive(
            $stream,
            [IO.Compression.ZipArchiveMode]::Create,
            $true
        )
        try {
            foreach ($file in $files) {
                $entry = $archive.CreateEntry(
                    [string]$file.RelativePath,
                    [IO.Compression.CompressionLevel]::Optimal
                )
                $entry.LastWriteTime = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
                $sourceStream = [IO.File]::OpenRead([string]$file.Source)
                $destinationStream = $entry.Open()
                try {
                    $sourceStream.CopyTo($destinationStream)
                } finally {
                    $destinationStream.Dispose()
                    $sourceStream.Dispose()
                }
            }
        } finally {
            $archive.Dispose()
        }
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
    [IO.File]::WriteAllText(
        $temporaryManifest,
        ($manifest | ConvertTo-Json -Depth 6) + "`n",
        (New-Object Text.UTF8Encoding($false))
    )
    Move-Item -LiteralPath $temporaryZip -Destination $ZipPath -Force
    Move-Item -LiteralPath $temporaryManifest -Destination $ManifestPath -Force
} finally {
    if ([IO.File]::Exists($temporaryZip)) { [IO.File]::Delete($temporaryZip) }
    if ([IO.File]::Exists($temporaryManifest)) { [IO.File]::Delete($temporaryManifest) }
}
