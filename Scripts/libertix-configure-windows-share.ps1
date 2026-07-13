#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [switch]$Finalize,
    [switch]$Mount,
    [switch]$Pin
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-ShareLog {
    param([string]$Message)
    $root = Split-Path -Parent $ConfigPath
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Add-Content -LiteralPath (Join-Path $root "windows-share.log") -Value (
        "[{0}] {1}" -f (Get-Date -Format o), $Message
    )
}

function Invoke-ProcessWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )
    $process = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $ArgumentList `
        -PassThru
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "$FilePath timed out after $TimeoutSeconds seconds."
    }
    return $process.ExitCode
}

function Get-Config {
    $config = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
    if (-not $config.Enabled) { return $config }
    if ([int]$config.SystemDiskNumber -lt 0 -or [int64]$config.ExpectedLinuxPartitionSize -le 0) {
        throw "Windows share configuration has invalid disk metadata."
    }
    if ([string]::IsNullOrWhiteSpace([string]$config.LinuxUsername)) {
        throw "Windows share configuration has no Linux username."
    }
    return $config
}

function Get-LinuxPartition {
    param([Parameter(Mandatory = $true)]$Config)
    $tolerance = 256MB
    $expected = [int64]$Config.ExpectedLinuxPartitionSize
    $linuxGptType = "{0fc63daf-8483-4772-8e79-3d69d8477de4}"
    $matches = @(
        Get-Partition -DiskNumber ([int]$Config.SystemDiskNumber) -ErrorAction Stop |
            Where-Object {
                [math]::Abs([int64]$_.Size - $expected) -le $tolerance -and
                ($_.GptType -eq $linuxGptType -or [int]$_.MbrType -eq 131 -or $_.Type -match "Linux")
            }
    )
    if ($matches.Count -ne 1) {
        throw "Expected exactly one Linux partition on disk $($Config.SystemDiskNumber); found $($matches.Count)."
    }
    return $matches[0]
}

function Set-ReadOnlyDriverPolicy {
    $launcherKey = "HKLM:\SOFTWARE\WOW6432Node\WinFsp\Services\ext4-mount"
    if (-not (Test-Path -LiteralPath $launcherKey)) {
        throw "WinFsp ext4 launcher registration is missing."
    }
    $commandLine = [string](Get-ItemPropertyValue -LiteralPath $launcherKey -Name CommandLine)
    if ($commandLine -notmatch '(?i)(?:^|\s)--ro(?:\s|$)') {
        Set-ItemProperty -LiteralPath $launcherKey -Name CommandLine -Value ($commandLine.Trim() + " --ro")
    }
    Stop-Service -Name ExtFsWatcher -Force -ErrorAction SilentlyContinue
    Set-Service -Name ExtFsWatcher -StartupType Disabled -ErrorAction Stop
}

function Install-WinFspRuntimeForExt4 {
    $winFspKey = "HKLM:\SOFTWARE\WOW6432Node\WinFsp"
    if (-not (Test-Path -LiteralPath $winFspKey)) {
        throw "WinFsp runtime registration is missing."
    }

    $settings = Get-ItemProperty -LiteralPath $winFspKey -ErrorAction Stop
    $runtimeCandidates = @()
    foreach ($root in @([string]$settings.SxsDir, [string]$settings.InstallDir)) {
        if (-not [string]::IsNullOrWhiteSpace($root)) {
            $runtimeCandidates += Join-Path $root "bin\winfsp-x64.dll"
        }
    }
    $runtime = $runtimeCandidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
    if (-not $runtime) {
        throw "WinFsp x64 runtime DLL is missing."
    }

    $ext4Directory = Join-Path $env:ProgramFiles "ext4-win-driver"
    $destination = Join-Path $ext4Directory "winfsp-x64.dll"
    Copy-Item -LiteralPath $runtime -Destination $destination -Force -ErrorAction Stop
    Write-ShareLog "WinFsp x64 runtime copied next to ext4.exe: $runtime"
}

function Install-MountTask {
    param([Parameter(Mandatory = $true)]$Config)
    $root = Split-Path -Parent $ConfigPath
    $mountScript = Join-Path $root "mount-linux-readonly.ps1"
    if (-not (Test-Path -LiteralPath $mountScript -PathType Leaf)) {
        throw "Read-only mount launcher is missing."
    }

    $taskName = "LibertixLinuxReadOnly"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -Mount' -f `
        $mountScript, $ConfigPath
    $action = New-ScheduledTaskAction -Execute $powerShell -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal `
        -UserId "SYSTEM" `
        -LogonType ServiceAccount `
        -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop

    Remove-ItemProperty `
        -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" `
        -Name $taskName `
        -ErrorAction SilentlyContinue
    Write-ShareLog "Startup mount task registered as SYSTEM: $taskName"
}

function Install-ExplorerPinTasks {
    $root = Split-Path -Parent $ConfigPath
    $mountScript = Join-Path $root "mount-linux-readonly.ps1"
    if (-not (Test-Path -LiteralPath $mountScript -PathType Leaf)) {
        throw "Read-only mount launcher is missing."
    }

    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -Pin' -f `
        $mountScript, $ConfigPath
    $profiles = @(
        Get-CimInstance Win32_UserProfile -ErrorAction Stop |
            Where-Object {
                -not $_.Special -and
                $_.LocalPath -like "$env:SystemDrive\Users\*" -and
                (Test-Path -LiteralPath $_.LocalPath -PathType Container)
            }
    )
    if ($profiles.Count -eq 0) {
        throw "No real Windows profile is available for Explorer pin task registration."
    }

    foreach ($profile in $profiles) {
        $sid = [Security.Principal.SecurityIdentifier]::new([string]$profile.SID)
        $userId = $sid.Translate([Security.Principal.NTAccount]).Value
        $taskName = "LibertixLinuxReadOnlyPin_$(([string]$profile.SID).Replace('-', '_'))"
        $action = New-ScheduledTaskAction -Execute $powerShell -Argument $arguments
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
        $principal = New-ScheduledTaskPrincipal `
            -UserId $userId `
            -LogonType Interactive `
            -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet `
            -StartWhenAvailable `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
        Register-ScheduledTask `
            -TaskName $taskName `
            -Action $action `
            -Trigger $trigger `
            -Principal $principal `
            -Settings $settings `
            -Force | Out-Null

        if ($profile.Loaded) {
            Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
        }
        Write-ShareLog "Explorer pin task registered for $userId`: $taskName"
    }
}

function Install-ExplorerShortcuts {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$LinuxHome
    )

    $profileRoots = @(
        Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
            Where-Object {
                -not $_.Special -and
                $_.LocalPath -like "$env:SystemDrive\Users\*" -and
                (Test-Path -LiteralPath $_.LocalPath -PathType Container)
            } |
            ForEach-Object { [string]$_.LocalPath }
    )
    if ($env:USERPROFILE -like "$env:SystemDrive\Users\*" -and
        (Test-Path -LiteralPath $env:USERPROFILE -PathType Container)) {
        $profileRoots += $env:USERPROFILE
    }
    $profileRoots = @($profileRoots | Sort-Object -Unique)
    if ($profileRoots.Count -eq 0) {
        throw "No real Windows user profile is available for the Linux shortcut."
    }

    $shell = New-Object -ComObject WScript.Shell
    foreach ($profileRoot in $profileRoots) {
        $links = Join-Path $profileRoot "Links"
        New-Item -ItemType Directory -Path $links -Force | Out-Null
        $shortcutPath = Join-Path $links "Linux_$($Config.LinuxUsername)_read-only.lnk"
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $LinuxHome
        $shortcut.Description = "Fichiers Linux en lecture seule"
        $shortcut.Save()
        Write-ShareLog "Explorer shortcut created: $shortcutPath"
    }

    if ($env:USERPROFILE -like "$env:SystemDrive\Users\*") {
        try {
            $shellApplication = New-Object -ComObject Shell.Application
            $shellApplication.Namespace($LinuxHome).Self.InvokeVerb("unpinfromhome")

            $junctionPath = Join-Path $env:USERPROFILE "Linux_$($Config.LinuxUsername)_read-only"
            if (Test-Path -LiteralPath $junctionPath) {
                $junction = Get-Item -LiteralPath $junctionPath -Force
                if (-not ($junction.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    throw "Refusing to replace a non-junction path: $junctionPath"
                }
            } else {
                $junctionOutput = @(& cmd.exe /d /c mklink /J $junctionPath $LinuxHome 2>&1)
                if ($LASTEXITCODE -ne 0) {
                    throw "Explorer junction creation failed with rc=$LASTEXITCODE`: $($junctionOutput -join ' ')"
                }
            }
            $shellApplication.Namespace($junctionPath).Self.InvokeVerb("pintohome")
        } catch {
            Write-ShareLog "Quick Access pin was unavailable; Links shortcuts remain present: $($_.Exception.Message)"
        }
    }
}

function Start-ReadOnlyMount {
    param([Parameter(Mandatory = $true)]$Config)
    $partition = Get-LinuxPartition -Config $Config
    $ext4Exe = Join-Path $env:ProgramFiles "ext4-win-driver\ext4.exe"
    if (-not (Test-Path -LiteralPath $ext4Exe -PathType Leaf)) {
        throw "ext4.exe is missing after driver installation."
    }

    $launchCtl = Join-Path ${env:ProgramFiles(x86)} "WinFsp\bin\launchctl-x64.exe"
    if (-not (Test-Path -LiteralPath $launchCtl -PathType Leaf)) {
        throw "WinFsp launcher is missing."
    }

    $driveLetters = @("L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z")
    $existingDrive = $driveLetters |
        Where-Object { Test-Path -LiteralPath "${_}:\home\$($Config.LinuxUsername)" -PathType Container } |
        Select-Object -First 1
    $driveLetter = if ($existingDrive) {
        $existingDrive
    } else {
        $driveLetters |
            Where-Object { -not (Test-Path -LiteralPath "${_}:\") } |
            Select-Object -First 1
    }
    if (-not $driveLetter) {
        throw "No free drive letter is available for the Linux read-only volume."
    }

    $drive = "${driveLetter}:"
    $device = "\\.\PhysicalDrive$($Config.SystemDiskNumber)"
    $instance = "LibertixLinuxReadOnly"
    $launched = $false
    try {
        if (-not $existingDrive) {
            & $launchCtl stop "ext4-mount" $instance 2>&1 | Out-Null
            $launchOutput = @(
                & $launchCtl start "ext4-mount" $instance $drive $device ([string]$partition.PartitionNumber) 2>&1
            )
            if ($LASTEXITCODE -ne 0) {
                throw "WinFsp launcher failed with rc=$LASTEXITCODE`: $($launchOutput -join ' ')"
            }
            $launched = $true
            Write-ShareLog "WinFsp launcher started ext4-mount instance $instance on $drive."
        }

        for ($attempt = 0; $attempt -lt 30 -and -not (Test-Path "$drive\"); $attempt++) {
            Start-Sleep -Seconds 1
        }
        if (-not (Test-Path "$drive\")) {
            throw "The ext4 read-only mount did not appear as $drive."
        }
        $linuxHome = "$drive\home\$($Config.LinuxUsername)"
        if (-not (Test-Path -LiteralPath $linuxHome -PathType Container)) {
            throw "The Linux home directory is missing from the mounted partition: $linuxHome"
        }

        $writeProbe = Join-Path $drive ".libertix-write-probe-$([Guid]::NewGuid().ToString('N'))"
        $writeSucceeded = $false
        try {
            Set-Content -LiteralPath $writeProbe -Value "readonly verification" -ErrorAction Stop
            $writeSucceeded = $true
        } catch {
            Write-ShareLog "Read-only write probe was refused as expected."
        } finally {
            if ($writeSucceeded) { Remove-Item -LiteralPath $writeProbe -Force -ErrorAction SilentlyContinue }
        }
        if ($writeSucceeded) {
            throw "SECURITY ERROR: the Linux volume accepted a write despite --ro."
        }

        Install-ExplorerShortcuts -Config $Config -LinuxHome $linuxHome
        Write-ShareLog "Linux mounted read-only on $drive."
    } catch {
        if ($launched) {
            & $launchCtl stop "ext4-mount" $instance 2>&1 | Out-Null
        }
        throw
    }
}

try {
    $config = Get-Config
    if (-not $config.Enabled) {
        if ($Finalize) {
            Unregister-ScheduledTask -TaskName "LibertixLinuxReadOnly" -Confirm:$false `
                -ErrorAction SilentlyContinue
            Get-ScheduledTask -TaskName "LibertixLinuxReadOnlyPin_*" -ErrorAction SilentlyContinue |
                Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
            Remove-ItemProperty `
                -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" `
                -Name "LibertixLinuxReadOnly" `
                -ErrorAction SilentlyContinue
        }
        Write-ShareLog "Linux-to-Windows sharing is disabled; the Libertix launcher was removed."
        exit 0
    }
    if ($Finalize) {
        $setup = [string]$config.SetupPath
        if (-not (Test-Path -LiteralPath $setup -PathType Leaf)) { throw "ext4 setup payload is missing." }
        $hash = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne [string]$config.SetupSha256) { throw "ext4 setup SHA-256 mismatch." }
        $installerExitCode = Invoke-ProcessWithTimeout `
            -FilePath $setup `
            -ArgumentList @("/quiet", "/norestart") `
            -TimeoutSeconds 1800
        if ($installerExitCode -notin @(0, 3010, 1641)) { throw "ext4 setup failed with rc=$installerExitCode." }
        Install-WinFspRuntimeForExt4
        Set-ReadOnlyDriverPolicy
        Install-MountTask -Config $config
        Install-ExplorerPinTasks
        Remove-Item -LiteralPath (Join-Path (Split-Path -Parent $ConfigPath) "pending.marker") -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $setup -Force -ErrorAction SilentlyContinue
        Write-ShareLog "Read-only ext4 support installed and configured."
        exit 0
    }
    if ($Mount) {
        Start-ReadOnlyMount -Config $config
        exit 0
    }
    if ($Pin) {
        $linuxHome = $null
        for ($attempt = 0; $attempt -lt 90 -and -not $linuxHome; $attempt++) {
            foreach ($letter in @("L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z")) {
                $candidate = "${letter}:\home\$($config.LinuxUsername)"
                if (Test-Path -LiteralPath $candidate -PathType Container) {
                    $linuxHome = $candidate
                    break
                }
            }
            if (-not $linuxHome) { Start-Sleep -Seconds 1 }
        }
        if (-not $linuxHome) {
            throw "The Linux read-only home did not become available for Explorer pinning."
        }
        Install-ExplorerShortcuts -Config $config -LinuxHome $linuxHome
        Write-ShareLog "Explorer pinning completed for $env:USERNAME."
        exit 0
    }
    throw "Specify -Finalize, -Mount or -Pin."
} catch {
    try { Write-ShareLog "ERROR: $($_.Exception.Message)" } catch { }
    Write-Error $_.Exception.Message
    exit 1
}
