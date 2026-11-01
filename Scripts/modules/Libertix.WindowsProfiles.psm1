Set-StrictMode -Version Latest

function Get-LibertixWindowsUserProfiles {
    param([switch]$RequireAccessible)
    $excludedNames = @('DefaultAccount', 'defaultuser0', 'WDAGUtilityAccount', 'WsiAccount')
    $seenSids = @{}
    $seenPaths = @{}
    foreach ($userProfile in @(Get-CimInstance Win32_UserProfile -ErrorAction Stop)) {
        $path = [string]$userProfile.LocalPath
        $sid = [string]$userProfile.SID
        if ($userProfile.Special -or $sid -notmatch '^S-1-5-21-(?:\d+-){3}\d+$') { continue }
        if ((Split-Path -Leaf $path) -in $excludedNames) { continue }
        if ($path -notmatch '^[A-Za-z]:\\[^\x00-\x1f<>:"/|?*]+$' -or
            $path -match '(?:^|\\)\.{1,2}(?:\\|$)') {
            if ($RequireAccessible) { throw "A Windows profile has an unsupported location: $sid." }
            continue
        }
        $normalized = [IO.Path]::GetFullPath($path).TrimEnd('\')
        if (-not (Test-Path -LiteralPath $normalized -PathType Container)) {
            if ($RequireAccessible) { throw "A Windows profile directory is unavailable: $normalized." }
            continue
        }
        if ($seenSids.ContainsKey($sid) -or $seenPaths.ContainsKey($normalized)) {
            throw 'Windows profile identity or directory is ambiguous.'
        }
        $seenSids[$sid] = $true
        $seenPaths[$normalized] = $true
        [pscustomobject]@{
            SID = $sid
            LocalPath = $normalized
            Loaded = [bool]$userProfile.Loaded
        }
    }
}

function Get-LibertixLinuxShortcutFiles {
    param([Parameter(Mandatory = $true)][string]$LinuxUsername)

    if ($LinuxUsername -cnotmatch '^[a-z_][a-z0-9_-]{0,31}$') {
        throw 'Linux shortcut account name is invalid.'
    }
    foreach ($userProfile in @(Get-LibertixWindowsUserProfiles)) {
        $path = Join-Path ([string]$userProfile.LocalPath) "Links\Linux_${LinuxUsername}_read-only.lnk"
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Get-Item -LiteralPath $path -ErrorAction Stop
        }
    }
}

Export-ModuleMember -Function Get-LibertixWindowsUserProfiles, Get-LibertixLinuxShortcutFiles
