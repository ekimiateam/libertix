Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Libertix.WindowsProfiles.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Libertix.StorageTargets.psm1') -Force -ErrorAction Stop

function Initialize-LibertixSharingPathReader {
    if (-not ('Libertix.Native.WindowsSharingPaths' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot '../native/WindowsSharingPaths.cs') -ErrorAction Stop
    }
}

function Get-LibertixProfileFolderValues {
    param([Parameter(Mandatory = $true)]$UserProfile)
    Initialize-LibertixSharingPathReader
    $values = [Libertix.Native.WindowsSharingPaths]::ReadProfile($UserProfile.SID, $UserProfile.LocalPath)
    [pscustomobject]@{ Folders = $values[0]; Environment = $values[1] }
}

function Resolve-LibertixSharingDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    Initialize-LibertixSharingPathReader
    return [Libertix.Native.WindowsSharingPaths]::ResolveDirectory($Path)
}

function Expand-LibertixProfileFolderPath {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$ProfilePath,
        [Parameter(Mandatory = $true)]$EnvironmentValues
    )
    $variables = @{}
    foreach ($name in $EnvironmentValues.Keys) { $variables[$name] = [string]$EnvironmentValues[$name] }
    $variables['USERPROFILE'] = $ProfilePath
    $variables['HOMEDRIVE'] = $ProfilePath.Substring(0, 2)
    $variables['HOMEPATH'] = $ProfilePath.Substring(2)
    $variables['SystemDrive'] = $env:SystemDrive
    $variables['SystemRoot'] = $env:SystemRoot
    $expanded = $Value
    for ($attempt = 0; $attempt -lt 8 -and $expanded -match '%[^%]+%'; $attempt++) {
        $previous = $expanded
        $expanded = [regex]::Replace($expanded, '%([^%]+)%', {
            param($match)
            $name = $match.Groups[1].Value
            if (-not $variables.ContainsKey($name)) { throw "Unknown profile path variable: $name." }
            return [string]$variables[$name]
        })
        if ($expanded -eq $previous) { break }
    }
    if ($expanded -notmatch '^[A-Za-z]:\\[^\x00-\x1f<>:"/|?*]+$' -or
        $expanded -match '%[^%]+%|(?:^|\\)\.{1,2}(?:\\|$)') {
        throw 'A shared Windows folder has an unsupported or unresolved path.'
    }
    return [IO.Path]::GetFullPath($expanded).TrimEnd('\')
}

function Get-LibertixSharingVolumeIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$VolumePath,
        [Parameter(Mandatory = $true)][string[]]$InstallationDrives
    )
    $volumes = @(Get-Volume -Path $VolumePath -ErrorAction Stop)
    if ($volumes.Count -ne 1 -or [string]$volumes[0].FileSystem -ne 'NTFS') {
        throw 'A shared user directory is not on an unambiguous NTFS volume.'
    }
    $volume = $volumes[0]
    $partitions = @(Get-Partition -Volume $volume -ErrorAction Stop)
    if ($partitions.Count -ne 1 -or [string]$volume.DriveLetter -notmatch '^[A-Za-z]$') {
        throw 'A shared volume has no supported partition or drive letter.'
    }
    $partition = $partitions[0]
    $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
    if ($disk.IsOffline -or $disk.IsReadOnly -or
        [string]$disk.BusType -notin @('SATA', 'ATA', 'NVMe', 'SAS', 'SCSI', 'MMC')) {
        throw 'A user folder depends on external or unsupported storage. Disable Windows file sharing or move that folder first.'
    }
    Get-LibertixStorageControllerNames -DiskNumber $disk.Number -RequireSupported | Out-Null
    $drive = ([string]$volume.DriveLetter).ToUpperInvariant() + ':'
    $encryption = Get-LibertixTargetVolumeEncryptionSnapshot -Drive $drive
    if ($encryption.state -notin @('FullyDecrypted', 'NotEncryptable') -and $drive -notin $InstallationDrives) {
        throw "A shared data volume ($drive) is encrypted; it will not be decrypted implicitly. Disable Windows file sharing or decrypt it first."
    }
    [pscustomobject]@{
        ntfsUuid = Get-LibertixNtfsVolumeSerial -Drive $drive
        disk = [pscustomobject]@{
            partitionTableId = Get-LibertixTargetDiskIdentity -Disk $disk
            partitionStyle = [string]$disk.PartitionStyle; sizeBytes = [long]$disk.Size
            logicalSectorSizeBytes = [int]$disk.LogicalSectorSize
        }
        offsetBytes = [long]$partition.Offset; sizeBytes = [long]$partition.Size
        windowsVolumeId = [string]$volume.UniqueId; windowsDrive = $drive
    }
}

function Get-LibertixWindowsSharingInventory {
    param([Parameter(Mandatory = $true)][string[]]$InstallationDrives)
    $profiles = @(Get-LibertixWindowsUserProfiles -RequireAccessible)
    $volumes = @{}
    $folders = [Collections.Generic.List[object]]::new()
    $names = @{}
    $knownFolders = [ordered]@{
        Desktop = 'Desktop'; Documents = 'Personal'; Downloads = '{374DE290-123F-4565-9164-39C4925E467B}'
        Music = 'My Music'; Pictures = 'My Pictures'; Videos = 'My Video'; Favorites = 'Favorites'
    }
    foreach ($userProfile in $profiles) {
        $profileName = Split-Path -Leaf $userProfile.LocalPath
        $shortcut = 'User_' + $profileName
        if (@($profiles | Where-Object { (Split-Path -Leaf $_.LocalPath) -ieq $profileName }).Count -gt 1) {
            $shortcut += '_' + $userProfile.SID
        }
        $values = Get-LibertixProfileFolderValues -UserProfile $userProfile
        $paths = [ordered]@{ $shortcut = [string]$userProfile.LocalPath }
        foreach ($folder in $knownFolders.Keys) {
            $key = $knownFolders[$folder]
            if (-not $values.Folders.ContainsKey($key)) { continue }
            $path = Expand-LibertixProfileFolderPath -Value $values.Folders[$key] `
                -ProfilePath $userProfile.LocalPath -EnvironmentValues $values.Environment
            $default = Join-Path $userProfile.LocalPath $folder
            if ($path -ieq $default -and -not (Test-Path -LiteralPath $path -PathType Container)) { continue }
            $paths[$shortcut + '_' + $folder] = $path
        }
        foreach ($name in $paths.Keys) {
            if ($names.ContainsKey($name) -or $name.Length -gt 180 -or $name -match '[\x00-\x1f/\\]') {
                throw 'Windows sharing shortcut names are ambiguous or unsupported.'
            }
            $names[$name] = $true
            $resolved = Resolve-LibertixSharingDirectory -Path $paths[$name]
            if ($resolved -notmatch '^(\\\\\?\\Volume\{[0-9a-fA-F-]{36}\}\\)(.+)$') {
                throw 'A shared user directory does not resolve to a local volume.'
            }
            $volumePath = $Matches[1]
            $relative = $Matches[2].Replace('\', '/').TrimEnd('/')
            if ($relative -match '[\x00-\x1f:]|(?:^|/)\.{1,2}(?:/|$)') {
                throw 'A shared user directory has an unsafe relative path.'
            }
            if (-not $volumes.ContainsKey($volumePath)) {
                $volumes[$volumePath] = Get-LibertixSharingVolumeIdentity -VolumePath $volumePath `
                    -InstallationDrives $InstallationDrives
            }
            $folders.Add([pscustomobject]@{
                shortcut = $name; profileSid = [string]$userProfile.SID
                ntfsUuid = $volumes[$volumePath].ntfsUuid; relativePath = $relative
            })
        }
    }
    $volumeList = @($volumes.Values | Sort-Object ntfsUuid)
    if (@($volumeList | Group-Object ntfsUuid | Where-Object Count -gt 1).Count -gt 0) {
        throw 'Shared NTFS volume identities are duplicated.'
    }
    [pscustomobject]@{ version = 1; volumes = $volumeList; folders = @($folders.ToArray()) }
}

Export-ModuleMember -Function Get-LibertixWindowsSharingInventory
