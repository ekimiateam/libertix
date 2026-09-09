#requires -Version 5.1
param([Parameter(Mandatory = $true)][string]$ConfigPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class StorageFixtureKnownFolder {
    private static Guid Documents = new Guid("FDD39AD0-238F-46AF-ADB4-6C85480369C7");
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHGetKnownFolderPath(ref Guid id, uint flags, IntPtr token, out IntPtr path);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHSetKnownFolderPath(ref Guid id, uint flags, IntPtr token, string path);
    public static string Get() {
        IntPtr path = IntPtr.Zero;
        try {
            Marshal.ThrowExceptionForHR(SHGetKnownFolderPath(ref Documents, 0, IntPtr.Zero, out path));
            return Marshal.PtrToStringUni(path);
        } finally { Marshal.FreeCoTaskMem(path); }
    }
    public static void Set(string path) {
        Marshal.ThrowExceptionForHR(SHSetKnownFolderPath(ref Documents, 0, IntPtr.Zero, path));
    }
}
'@
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$interactive = [string](Get-CimInstance Win32_ComputerSystem).UserName
if ([string]::IsNullOrWhiteSpace($interactive) -or $interactive -ine $identity.Name) {
    throw 'Document redirection requires SSH to use the logged-in test account.'
}

function Assert-RegularFixtureTree {
    param([string]$Root)
    $compatibilityTargets = @(
        [Environment]::GetFolderPath('MyMusic'), [Environment]::GetFolderPath('MyPictures'),
        [Environment]::GetFolderPath('MyVideos')
    )
    $pending = New-Object 'Collections.Generic.Queue[string]'
    $pending.Enqueue($Root)
    $count = 0
    $total = 0L
    while ($pending.Count -gt 0) {
        $directory = Get-Item -LiteralPath $pending.Dequeue() -Force
        if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'The document fixture refuses junctions and symbolic links.'
        }
        foreach ($entry in @(Get-ChildItem -LiteralPath $directory.FullName -Force)) {
            $count++
            if ($count -gt 5000) { throw 'The document fixture exceeds its entry limit.' }
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                # Windows creates these legacy links itself. Preserve the links, not their targets' data.
                if ($directory.FullName -ine $Root -or $entry.LinkType -ne 'Junction' -or
                    @($entry.Target).Count -ne 1 -or [string]$entry.Target[0] -notin $compatibilityTargets -or
                    -not ($entry.Attributes -band [IO.FileAttributes]::System) -or
                    -not ($entry.Attributes -band [IO.FileAttributes]::Hidden)) {
                    throw 'The document fixture refuses an unrecognized reparse point.'
                }
                $entry
                continue
            }
            if ($entry.PSIsContainer) { $pending.Enqueue($entry.FullName); $entry }
            else {
                $total += $entry.Length
                if ($total -gt 2GB) { throw 'The document fixture exceeds its copy-size limit.' }
                $entry
            }
        }
    }
}

if ($config.phase -eq 'apply') {
    $disks = @(Get-Disk | Where-Object { [string]$_.Path -ceq [string]$config.disk_device_path })
    if ($disks.Count -ne 1 -or $disks[0].IsBoot -or $disks[0].IsSystem -or
        $disks[0].IsOffline -or $disks[0].IsReadOnly) {
        throw 'The document fixture target is not the inspected writable secondary disk.'
    }
    $volumes = @(Get-Partition -DiskNumber $disks[0].Number | Get-Volume | Where-Object {
        [string]$_.UniqueId -ceq [string]$config.volume_id
    })
    if ($volumes.Count -ne 1 -or [string]$volumes[0].FileSystemType -ne 'NTFS' -or
        [string]$volumes[0].DriveLetter -notmatch '^[A-Za-z]$') {
        throw 'The document fixture data volume is not an accessible NTFS volume.'
    }
    $previous = [StorageFixtureKnownFolder]::Get()
    if ($previous -notmatch '^[A-Za-z]:\\' -or
        $previous.Substring(0, 2) -ine $env:SystemDrive) {
        throw 'The fixture requires Documents to begin on the Windows system volume.'
    }
    $files = @(Assert-RegularFixtureTree $previous)
    $destination = '{0}:\LibertixTestDocuments-{1}' -f $volumes[0].DriveLetter, [Guid]::NewGuid().ToString('N')
    New-Item -ItemType Directory -Path $destination | Out-Null
    $records = @()
    $directories = @()
    $junctions = @()
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($previous.TrimEnd('\').Length + 1)
        $copy = Join-Path $destination $relative
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            New-Item -ItemType Junction -Path $copy -Target ([string]$file.Target[0]) | Out-Null
            $created = Get-Item -LiteralPath $copy -Force
            $created.Attributes = $created.Attributes -bor [IO.FileAttributes]::System -bor [IO.FileAttributes]::Hidden
            $junctions += @{ relative = $relative; target = [string]$file.Target[0] }
            continue
        }
        if ($file.PSIsContainer) {
            [IO.Directory]::CreateDirectory($copy) | Out-Null
            $directories += $relative
            continue
        }
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($copy)) | Out-Null
        [IO.File]::Copy($file.FullName, $copy, $false)
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        if ((Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash -cne $hash) {
            throw 'The copied document does not match its preserved original.'
        }
        $records += @{ relative = $relative; sha256 = $hash }
    }
    $witness = 'libertix-user-data-' + [Guid]::NewGuid().ToString('N') + '.txt'
    $witnessPath = Join-Path $destination $witness
    $bytes = [Text.Encoding]::UTF8.GetBytes('Libertix secondary-disk Documents fixture.')
    $stream = [IO.File]::Open($witnessPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    $records += @{ relative = $witness; sha256 = (Get-FileHash -LiteralPath $witnessPath -Algorithm SHA256).Hash }
    [StorageFixtureKnownFolder]::Set($destination)
    if ([StorageFixtureKnownFolder]::Get() -ine $destination) {
        [StorageFixtureKnownFolder]::Set($previous)
        throw 'Windows did not persist the Documents redirection.'
    }
    Write-Output ('STORAGE_DOCUMENTS_JSON=' + (@{
        user_sid = $identity.User.Value; previous = $previous; destination = $destination
        volume_id = [string]$volumes[0].UniqueId; files = $records; directories = $directories; junctions = $junctions
    } | ConvertTo-Json -Depth 5 -Compress))
    exit 0
}
if ($config.phase -eq 'verify') {
    $receipt = $config.receipt
    if ($identity.User.Value -cne [string]$receipt.user_sid -or
        [StorageFixtureKnownFolder]::Get() -ine [string]$receipt.destination) {
        throw 'The test user no longer resolves Documents on the secondary volume.'
    }
    $volume = Get-Volume -DriveLetter ([string]$receipt.destination).Substring(0, 1)
    if ([string]$volume.UniqueId -cne [string]$receipt.volume_id) {
        throw 'The redirected Documents volume identity changed.'
    }
    Assert-RegularFixtureTree ([string]$receipt.destination) | Out-Null
    foreach ($junction in @($receipt.junctions)) {
        $relative = [string]$junction.relative
        if ([string]::IsNullOrWhiteSpace($relative) -or $relative -match '[\\/:]' -or $relative -in @('.', '..')) {
            throw 'An invalid compatibility junction was recorded.'
        }
        $entry = Get-Item -LiteralPath (Join-Path ([string]$receipt.destination) $relative) -Force
        if ($entry.LinkType -ne 'Junction' -or @($entry.Target).Count -ne 1 -or
            [string]$entry.Target[0] -ine [string]$junction.target) {
            throw 'A Documents compatibility junction was changed.'
        }
    }
    foreach ($relative in @($receipt.directories)) {
        if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)' -or
            -not (Test-Path -LiteralPath (Join-Path ([string]$receipt.destination) $relative) -PathType Container)) {
            throw 'A redirected document directory is invalid or missing.'
        }
    }
    foreach ($file in @($receipt.files)) {
        $relative = [string]$file.relative
        if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') {
            throw 'An invalid document witness path was recorded.'
        }
        $path = Join-Path ([string]$receipt.destination) $relative
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne [string]$file.sha256) {
            throw 'A redirected document was changed or removed.'
        }
    }
    Write-Output 'STORAGE_DOCUMENTS_VERIFIED=True'
    exit 0
}
throw 'Unknown document fixture phase.'
