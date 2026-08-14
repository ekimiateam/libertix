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
$script:LinuxReadOnlyTaskName = "LibertixLinuxReadOnly"
$script:LinuxReadOnlyPinTaskPrefix = "LibertixLinuxReadOnlyPin_"
$script:QuickAccessNamespace = "shell:::{679f85cb-0220-4080-b29b-5540cc05aab6}"

function Write-ShareLog {
    param([string]$Message)
    $root = Split-Path -Parent $ConfigPath
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $line = "[{0}] {1}" -f (Get-Date -Format o), $Message
    Add-Content -LiteralPath (Join-Path $root "windows-share.log") -Value $line
    $archiveRoot = Join-Path $env:SystemDrive "LibertixInstallLogs\Windows"
    New-Item -ItemType Directory -Path $archiveRoot -Force | Out-Null
    Add-Content -LiteralPath (Join-Path $archiveRoot "windows-share.log") -Value $line
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
        $taskkill = Join-Path $env:SystemRoot "System32\taskkill.exe"
        & $taskkill /PID $process.Id /T /F 2>&1 | Out-Null
        $taskkillExitCode = $LASTEXITCODE
        $process.WaitForExit(10000) | Out-Null
        if ($taskkillExitCode -ne 0 -or -not $process.HasExited) {
            throw "$FilePath timed out and its process tree could not be proven stopped."
        }
        throw "$FilePath timed out after $TimeoutSeconds seconds."
    }
    return $process.ExitCode
}

function Get-Config {
    $config = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
    if (-not $config.Enabled) { return $config }
    if (
        [int]$config.SystemDiskNumber -lt 0 -or
        [string]::IsNullOrWhiteSpace([string]$config.SystemDiskUniqueId) -or
        [int64]$config.ExpectedLinuxPartitionOffset -le 0 -or
        [int64]$config.ExpectedLinuxPartitionSize -le 0 -or
        [int64]$config.PartitionSizeToleranceBytes -le 0 -or
        [int64]$config.PartitionSizeToleranceBytes -gt
            [int64]$config.ExpectedLinuxPartitionSize
    ) {
        throw "Windows share configuration has invalid disk metadata."
    }
    if ([string]::IsNullOrWhiteSpace([string]$config.LinuxUsername)) {
        throw "Windows share configuration has no Linux username."
    }
    if ([string]::IsNullOrWhiteSpace([string]$config.ShortcutDescription)) {
        throw "Windows share configuration has no localized shortcut description."
    }
    return $config
}

function Get-LinuxPartition {
    param([Parameter(Mandatory = $true)]$Config)
    $disk = Get-Disk -Number ([int]$Config.SystemDiskNumber) -ErrorAction Stop
    if (([string]$disk.UniqueId).Trim() -ne ([string]$Config.SystemDiskUniqueId).Trim()) {
        throw "Windows share configuration disk identity no longer matches the system disk."
    }
    $expectedOffset = [int64]$Config.ExpectedLinuxPartitionOffset
    $expected = [int64]$Config.ExpectedLinuxPartitionSize
    $minimum = $expected - [int64]$Config.PartitionSizeToleranceBytes
    $linuxGptType = "{0fc63daf-8483-4772-8e79-3d69d8477de4}"
    $linuxPartitions = @(
        Get-Partition -DiskNumber ([int]$Config.SystemDiskNumber) -ErrorAction Stop |
            Where-Object {
                [int64]$_.Offset -eq $expectedOffset -and
                [int64]$_.Size -le $expected -and
                [int64]$_.Size -ge $minimum -and
                ($_.GptType -eq $linuxGptType -or [int]$_.MbrType -eq 131 -or $_.Type -match "Linux")
            }
    )
    if ($linuxPartitions.Count -ne 1) {
        throw "Expected exactly one Linux partition on disk $($Config.SystemDiskNumber); found $($linuxPartitions.Count)."
    }
    return $linuxPartitions[0]
}

function Get-RealWindowsProfiles {
    $excludedNames = @(
        "DefaultAccount",
        "defaultuser0",
        "WDAGUtilityAccount",
        "WsiAccount"
    )
    return @(
        Get-CimInstance Win32_UserProfile -ErrorAction Stop |
            Where-Object {
                $profileName = Split-Path -Leaf ([string]$_.LocalPath)
                -not $_.Special -and
                [string]$_.SID -match '^S-1-5-21-(?:\d+-){3}\d+$' -and
                $_.LocalPath -like "$env:SystemDrive\Users\*" -and
                $profileName -notin $excludedNames -and
                (Test-Path -LiteralPath $_.LocalPath -PathType Container)
            }
    )
}

function Write-MountStatus {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Partition,
        [Parameter(Mandatory = $true)][string]$Drive,
        [Parameter(Mandatory = $true)]$Process
    )

    $root = Split-Path -Parent $ConfigPath
    $path = Join-Path $root "mount-status.json"
    $temporary = Join-Path $root ".$([IO.Path]::GetFileName($path)).$([Guid]::NewGuid().ToString('N')).tmp"
    $status = [ordered]@{
        schemaVersion = 1
        verifiedAtUtc = [DateTime]::UtcNow.ToString("o")
        diskNumber = [int]$Config.SystemDiskNumber
        diskUniqueId = [string]$Config.SystemDiskUniqueId
        partitionNumber = [int]$Partition.PartitionNumber
        partitionOffset = [int64]$Partition.Offset
        partitionSize = [int64]$Partition.Size
        drive = $Drive
        linuxHome = "$Drive\home\$($Config.LinuxUsername)"
        readOnly = $true
        processId = [int]$Process.ProcessId
    }
    try {
        $encoding = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText(
            $temporary,
            (($status | ConvertTo-Json -Depth 4) + "`n"),
            $encoding
        )
        if ([IO.File]::Exists($path)) {
            $backup = Join-Path $root ".$([IO.Path]::GetFileName($path)).$([Guid]::NewGuid().ToString('N')).bak"
            try {
                [IO.File]::Replace($temporary, $path, $backup)
            } finally {
                if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
            }
        } else {
            [IO.File]::Move($temporary, $path)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-ExpectedExt4MountProcesses {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Partition,
        [Parameter(Mandatory = $true)][string]$Drive
    )

    $ext4Exe = Join-Path $env:ProgramFiles "ext4-win-driver\ext4.exe"
    $device = "\\.\PhysicalDrive$($Config.SystemDiskNumber)"
    $devicePattern = [regex]::Escape($device)
    $drivePattern = [regex]::Escape($Drive)
    $partitionPattern = [regex]::Escape([string]$Partition.PartitionNumber)
    return @(
        Get-CimInstance Win32_Process -Filter "Name='ext4.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $commandLine = [string]$_.CommandLine
                [string]$_.ExecutablePath -ieq $ext4Exe -and
                $commandLine -match '(?i)(?:^|\s)mount(?:\s|$)' -and
                $commandLine -match ('(?i)(?:^|\s)"?{0}"?(?:\s|$)' -f $devicePattern) -and
                $commandLine -match ('(?i)(?:^|\s)--drive\s+"?{0}"?(?:\s|$)' -f $drivePattern) -and
                $commandLine -match ('(?i)(?:^|\s)--part\s+"?{0}"?(?:\s|$)' -f $partitionPattern) -and
                $commandLine -match '(?i)(?:^|\s)--ro(?:\s|$)'
            }
    )
}

function Test-DriveLetterReserved {
    param([Parameter(Mandatory = $true)][string]$Letter)

    if (Test-Path -LiteralPath "${Letter}:\") {
        return $true
    }
    $mappedByAnyUser = @(
        Get-ChildItem -LiteralPath Registry::HKEY_USERS -ErrorAction SilentlyContinue |
            Where-Object {
                Test-Path -LiteralPath ("Registry::{0}\Network\{1}" -f $_.Name, $Letter)
            }
    ).Count -ne 0
    return $mappedByAnyUser
}

function Set-ReadOnlyDriverPolicy {
    $winFspKey = "HKLM:\SOFTWARE\WOW6432Node\WinFsp"
    $launcherKey = "HKLM:\SOFTWARE\WOW6432Node\WinFsp\Services\ext4-mount"
    if (-not (Test-Path -LiteralPath $winFspKey)) {
        throw "WinFsp runtime registration is missing."
    }
    if (-not (Test-Path -LiteralPath $launcherKey)) {
        throw "WinFsp ext4 launcher registration is missing."
    }
    $commandLine = [string](Get-ItemPropertyValue -LiteralPath $launcherKey -Name CommandLine)
    if ($commandLine -notmatch '(?i)(?:^|\s)--ro(?:\s|$)') {
        Set-ItemProperty -LiteralPath $launcherKey -Name CommandLine -Value ($commandLine.Trim() + " --ro")
    }
    New-ItemProperty `
        -LiteralPath $winFspKey `
        -Name MountBroadcastDriveChange `
        -PropertyType DWord `
        -Value 1 `
        -Force | Out-Null
    New-ItemProperty `
        -LiteralPath $launcherKey `
        -Name RunAs `
        -PropertyType String `
        -Value "LocalSystem" `
        -Force | Out-Null
    New-ItemProperty `
        -LiteralPath $launcherKey `
        -Name Recovery `
        -PropertyType DWord `
        -Value 1 `
        -Force | Out-Null
    Set-Service -Name WinFsp.Launcher -StartupType Automatic -ErrorAction Stop
    Start-Service -Name WinFsp.Launcher -ErrorAction Stop
    Stop-Service -Name ExtFsWatcher -Force -ErrorAction SilentlyContinue
    Set-Service -Name ExtFsWatcher -StartupType Disabled -ErrorAction Stop
    $verifiedCommandLine = [string](
        Get-ItemPropertyValue -LiteralPath $launcherKey -Name CommandLine -ErrorAction Stop
    )
    if ($verifiedCommandLine -notmatch '(?i)(?:^|\s)--ro(?:\s|$)') {
        throw "WinFsp ext4 launcher registration is not read-only."
    }
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

    $taskName = $script:LinuxReadOnlyTaskName
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
    $profiles = @(Get-RealWindowsProfiles)
    if ($profiles.Count -eq 0) {
        throw "No real Windows profile is available for Explorer pin task registration."
    }

    foreach ($userProfile in $profiles) {
        $sid = [Security.Principal.SecurityIdentifier]::new([string]$userProfile.SID)
        $userId = $sid.Translate([Security.Principal.NTAccount]).Value
        $taskName = "$($script:LinuxReadOnlyPinTaskPrefix)$(([string]$userProfile.SID).Replace('-', '_'))"
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

        if ($userProfile.Loaded) {
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
        Get-RealWindowsProfiles | ForEach-Object { [string]$_.LocalPath }
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
        $shortcut.Description = [string]$Config.ShortcutDescription
        $shortcut.Save()
        $savedShortcut = $shell.CreateShortcut($shortcutPath)
        if ([string]$savedShortcut.TargetPath -ne $LinuxHome) {
            throw "Explorer shortcut target verification failed: $shortcutPath"
        }
        Write-ShareLog "Explorer shortcut created: $shortcutPath"
    }

    if ($env:USERPROFILE -like "$env:SystemDrive\Users\*") {
        $shellApplication = New-Object -ComObject Shell.Application
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

        $pinFound = $false
        for ($attempt = 1; $attempt -le 5 -and -not $pinFound; $attempt++) {
            $quickAccess = $shellApplication.Namespace($script:QuickAccessNamespace)
            if ($null -eq $quickAccess) {
                throw "Explorer Home/Quick Access namespace is unavailable."
            }
            $pinFound = @(
                $quickAccess.Items() | Where-Object {
                    [string]$_.Path -ieq $junctionPath -or
                    [string]$_.Path -ieq $LinuxHome
                }
            ).Count -ge 1
            if (-not $pinFound) {
                $junctionShellItem = $shellApplication.Namespace($junctionPath)
                if ($null -eq $junctionShellItem -or $null -eq $junctionShellItem.Self) {
                    throw "Explorer cannot resolve the Linux shortcut junction."
                }
                $junctionShellItem.Self.InvokeVerb("pintohome")
                Start-Sleep -Seconds 2
            }
        }
        if (-not $pinFound) {
            throw "Linux shortcut was not visible in Explorer Home/Quick Access after pinning."
        }
        Write-ShareLog "Explorer Home/Quick Access pin verified: $junctionPath"
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
    $matchingMounts = @(
        foreach ($letter in $driveLetters) {
            $drive = "${letter}:"
            foreach ($process in @(Get-ExpectedExt4MountProcesses `
                -Config $Config `
                -Partition $partition `
                -Drive $drive)) {
                [pscustomobject]@{ Drive = $drive; Process = $process }
            }
        }
    )
    if ($matchingMounts.Count -gt 1) {
        throw "Multiple ext4 processes match the configured Linux partition."
    }
    $existingDrive = if ($matchingMounts.Count -eq 1) {
        [string]$matchingMounts[0].Drive
    } else {
        $null
    }
    $driveLetter = if ($existingDrive) {
        $existingDrive.Substring(0, 1)
    } else {
        $driveLetters |
            Where-Object { -not (Test-DriveLetterReserved -Letter $_) } |
            Select-Object -First 1
    }
    if (-not $driveLetter) {
        throw "No free drive letter is available for the Linux read-only volume."
    }

    $drive = "${driveLetter}:"
    $device = "\\.\PhysicalDrive$($Config.SystemDiskNumber)"
    $instance = $script:LinuxReadOnlyTaskName
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

        $mountProcess = $null
        for ($attempt = 0; $attempt -lt 60; $attempt++) {
            $expectedProcesses = @(Get-ExpectedExt4MountProcesses `
                -Config $Config `
                -Partition $partition `
                -Drive $drive)
            if ($expectedProcesses.Count -gt 1) {
                throw "Multiple ext4 processes match the configured Linux mount."
            }
            if ($expectedProcesses.Count -eq 1 -and (Test-Path "$drive\")) {
                $mountProcess = $expectedProcesses[0]
                break
            }
            Start-Sleep -Seconds 1
        }
        if ($null -eq $mountProcess) {
            throw "The verified ext4 read-only mount did not appear as $drive."
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
        Write-MountStatus `
            -Config $Config `
            -Partition $partition `
            -Drive $drive `
            -Process $mountProcess
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
            Unregister-ScheduledTask -TaskName $script:LinuxReadOnlyTaskName -Confirm:$false `
                -ErrorAction SilentlyContinue
            Get-ScheduledTask `
                -TaskName "$($script:LinuxReadOnlyPinTaskPrefix)*" `
                -ErrorAction SilentlyContinue |
                Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
            Remove-ItemProperty `
                -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" `
                -Name $script:LinuxReadOnlyTaskName `
                -ErrorAction SilentlyContinue
        }
        Write-ShareLog "Linux-to-Windows sharing is disabled; the Libertix launcher was removed."
        exit 0
    }
    if ($Finalize) {
        $setup = [string]$config.SetupPath
        $ext4Exe = Join-Path $env:ProgramFiles "ext4-win-driver\ext4.exe"
        $winFspKey = "HKLM:\SOFTWARE\WOW6432Node\WinFsp"
        if (Test-Path -LiteralPath $setup -PathType Leaf) {
            $hash = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($hash -ne [string]$config.SetupSha256) { throw "ext4 setup SHA-256 mismatch." }
            $installerExitCode = Invoke-ProcessWithTimeout `
                -FilePath $setup `
                -ArgumentList @("/quiet", "/norestart") `
                -TimeoutSeconds 1800
            if ($installerExitCode -notin @(0, 3010, 1641)) {
                throw "ext4 setup failed with rc=$installerExitCode."
            }
        } elseif (
            -not (Test-Path -LiteralPath $ext4Exe -PathType Leaf) -or
            -not (Test-Path -LiteralPath $winFspKey)
        ) {
            throw "ext4 setup payload is missing and the installed runtime is incomplete."
        } else {
            Write-ShareLog "Existing ext4 and WinFsp runtime detected; setup does not need to rerun."
        }
        Install-WinFspRuntimeForExt4
        Set-ReadOnlyDriverPolicy
        Install-MountTask -Config $config
        Start-ReadOnlyMount -Config $config
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
    try {
        Write-ShareLog "ERROR: $($_.Exception.Message)"
    } catch {
        Write-Verbose "Unable to persist the sharing failure: $($_.Exception.Message)"
    }
    Write-Error $_.Exception.Message
    exit 1
}
