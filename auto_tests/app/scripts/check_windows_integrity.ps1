$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Name)
    Write-Output ""
    Write-Output "===== $Name ====="
}

function Invoke-NativeCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )

    Write-Section $Name
    & $FilePath @Arguments 2>&1
    Write-Output ("{0}_EXIT_CODE={1}" -f $Name.Replace(" ", "_"), $LASTEXITCODE)
}

function Get-FreeDriveLetter {
    foreach ($letter in @("S", "T", "U", "V", "W", "Y", "Z")) {
        if (-not (Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue)) {
            return $letter
        }
    }
    throw "No free drive letter is available for the boot partition check."
}

Write-Output ("REPORT_STARTED={0}" -f (Get-Date -Format o))
Write-Output ("COMPUTER_NAME={0}" -f $env:COMPUTERNAME)
Write-Output ("RUN_AS={0}" -f [Security.Principal.WindowsIdentity]::GetCurrent().Name)

Write-Section "OPERATING SYSTEM"
Get-ComputerInfo |
    Select-Object WindowsProductName, WindowsVersion, OsDisplayVersion, OsBuildNumber,
        OsArchitecture, BiosFirmwareType, CsSystemType, CsTotalPhysicalMemory |
    Format-List
Get-CimInstance Win32_OperatingSystem |
    Select-Object Caption, Version, BuildNumber, OSArchitecture, LastBootUpTime, LocalDateTime |
    Format-List

Write-Section "DISKS PARTITIONS VOLUMES"
Get-Disk |
    Sort-Object Number |
    Format-Table Number, FriendlyName, PartitionStyle, OperationalStatus, HealthStatus,
        IsBoot, IsSystem, Size -AutoSize
Get-Partition |
    Sort-Object DiskNumber, PartitionNumber |
    Format-Table DiskNumber, PartitionNumber, DriveLetter, Type, GptType, IsActive,
        IsBoot, IsSystem, Size -AutoSize
Get-Volume |
    Sort-Object DriveLetter |
    Format-Table DriveLetter, FileSystemLabel, FileSystem, DriveType, HealthStatus,
        OperationalStatus, Size, SizeRemaining -AutoSize

Write-Section "BITLOCKER"
try {
    Get-BitLockerVolume |
        Format-Table MountPoint, VolumeType, VolumeStatus, EncryptionPercentage,
            ProtectionStatus, LockStatus, EncryptionMethod -AutoSize
} catch {
    Write-Output ("GET_BITLOCKER_ERROR={0}" -f $_.Exception.Message)
}
Invoke-NativeCheck -Name "MANAGE BDE STATUS" -FilePath "manage-bde.exe" -Arguments @("-status", "C:")

Invoke-NativeCheck -Name "WINDOWS RECOVERY" -FilePath "reagentc.exe" -Arguments @("/info")

Write-Section "BOOT CONFIGURATION"
$mountedBootPartition = $null
$bootLetter = $null
try {
    $espGuid = "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}"
    $mountedBootPartition = Get-Partition |
        Where-Object { $_.GptType -eq $espGuid } |
        Sort-Object DiskNumber, PartitionNumber |
        Select-Object -First 1

    if (-not $mountedBootPartition) {
        $mountedBootPartition = Get-Partition -DiskNumber 0 |
            Where-Object { $_.IsSystem -or $_.IsActive } |
            Sort-Object PartitionNumber |
            Select-Object -First 1
    }

    if ($mountedBootPartition) {
        $bootLetter = Get-FreeDriveLetter
        Add-PartitionAccessPath -DiskNumber $mountedBootPartition.DiskNumber `
            -PartitionNumber $mountedBootPartition.PartitionNumber `
            -AccessPath "${bootLetter}:\" -ErrorAction Stop

        Write-Output ("BOOT_PARTITION={0}:{1}" -f $mountedBootPartition.DiskNumber,
            $mountedBootPartition.PartitionNumber)
        Get-ChildItem "${bootLetter}:\" -Force -Recurse -ErrorAction SilentlyContinue |
            Select-Object FullName, Length |
            Format-Table -AutoSize

        $temporaryEfiPath = "${bootLetter}:\EFI\LibertixInstaller"
        Write-Output ("TEMPORARY_EFI_DIRECTORY_PRESENT={0}" -f
            (Test-Path -LiteralPath $temporaryEfiPath))

        $bcdCandidates = @(
            "${bootLetter}:\EFI\Microsoft\Boot\BCD",
            "${bootLetter}:\Boot\BCD"
        )
        $bcdStore = $bcdCandidates | Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1
        if ($bcdStore) {
            Write-Output ("BCD_STORE={0}" -f $bcdStore)
            & bcdedit.exe /store $bcdStore /enum all /v 2>&1
            Write-Output ("BCD_STORE_EXIT_CODE={0}" -f $LASTEXITCODE)
        } else {
            Write-Output "BCD_STORE=NOT_FOUND"
        }
    } else {
        Write-Output "BOOT_PARTITION=NOT_FOUND"
    }

    & bcdedit.exe /enum firmware /v 2>&1
    Write-Output ("BCD_FIRMWARE_EXIT_CODE={0}" -f $LASTEXITCODE)
} catch {
    Write-Output ("BOOT_CHECK_ERROR={0}" -f $_.Exception.Message)
} finally {
    if ($mountedBootPartition -and $bootLetter) {
        Remove-PartitionAccessPath -DiskNumber $mountedBootPartition.DiskNumber `
            -PartitionNumber $mountedBootPartition.PartitionNumber `
            -AccessPath "${bootLetter}:\" -ErrorAction SilentlyContinue
    }
}

Write-Section "LIBERTIX ARTIFACTS"
Write-Output ("TRANSACTION_STATE_PRESENT={0}" -f
    (Test-Path -LiteralPath "C:\LibertixTools\uefi-transaction.json"))
Write-Output ("INSTALLER_VOLUME_PRESENT={0}" -f
    [bool](Get-Volume -FileSystemLabel "LIBERTIXEFI" -ErrorAction SilentlyContinue))
$uefiRecoveryRoot = "C:\ProgramData\Libertix\UefiRecovery"
$uefiRecoverySessions = @(
    Get-ChildItem -LiteralPath $uefiRecoveryRoot -Directory -ErrorAction SilentlyContinue
)
Write-Output ("UEFI_RECOVERY_ROOT_PRESENT={0}" -f
    (Test-Path -LiteralPath $uefiRecoveryRoot))
Write-Output ("UEFI_RECOVERY_SESSION_COUNT={0}" -f $uefiRecoverySessions.Count)
if ($uefiRecoverySessions.Count -gt 0) {
    $uefiRecoverySessions |
        Select-Object FullName, CreationTimeUtc, LastWriteTimeUtc |
        Format-Table -AutoSize
    Get-ChildItem -LiteralPath $uefiRecoveryRoot -Force -Recurse -ErrorAction SilentlyContinue |
        Select-Object FullName, Length, LastWriteTimeUtc |
        Format-Table -AutoSize
    foreach ($session in $uefiRecoverySessions) {
        foreach ($diagnosticFile in @("state.json", "recovery-agent.log")) {
            $diagnosticPath = Join-Path $session.FullName $diagnosticFile
            if (Test-Path -LiteralPath $diagnosticPath) {
                Write-Output ("--- {0} ---" -f $diagnosticPath)
                Get-Content -LiteralPath $diagnosticPath -ErrorAction SilentlyContinue
            }
        }
    }
}
Write-Output ("BIOS_RECOVERY_ROOT_PRESENT={0}" -f
    (Test-Path -LiteralPath "C:\LibertixInstallRecovery"))
$libertixTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskName -like "Libertix*" })
$libertixTasks |
    Select-Object TaskName, TaskPath, State |
    Format-Table -AutoSize
foreach ($task in $libertixTasks) {
    Get-ScheduledTaskInfo -TaskName $task.TaskName -TaskPath $task.TaskPath `
        -ErrorAction SilentlyContinue |
        Select-Object @{ Name = "TaskName"; Expression = { $task.TaskName } },
            LastRunTime, LastTaskResult, NextRunTime, NumberOfMissedRuns |
        Format-List
}
Get-Process Libertix -ErrorAction SilentlyContinue |
    Select-Object ProcessName, Id, SessionId, Path |
    Format-Table -AutoSize

Write-Section "WINDOWS LINUX SHARE"
$shareRoot = "C:\ProgramData\Libertix\WindowsShare"
$shareConfigPath = Join-Path $shareRoot "config.json"
$sharePendingPath = Join-Path $shareRoot "pending.marker"
$shareLogPath = Join-Path $shareRoot "windows-share.log"
$ext4Executable = Join-Path $env:ProgramFiles "ext4-win-driver\ext4.exe"
$launcherKey = "HKLM:\SOFTWARE\WOW6432Node\WinFsp\Services\ext4-mount"
$mountTaskName = "LibertixLinuxReadOnly"

Write-Output ("WINDOWS_SHARE_ROOT_PRESENT={0}" -f (Test-Path -LiteralPath $shareRoot))
Write-Output ("WINDOWS_SHARE_CONFIG_PRESENT={0}" -f (Test-Path -LiteralPath $shareConfigPath -PathType Leaf))
Write-Output ("WINDOWS_SHARE_PENDING_PRESENT={0}" -f (Test-Path -LiteralPath $sharePendingPath))
Write-Output ("EXT4_EXECUTABLE_PRESENT={0}" -f (Test-Path -LiteralPath $ext4Executable -PathType Leaf))

$shareConfig = $null
if (Test-Path -LiteralPath $shareConfigPath -PathType Leaf) {
    try {
        $shareConfig = Get-Content -LiteralPath $shareConfigPath -Raw | ConvertFrom-Json
        Write-Output ("WINDOWS_SHARE_ENABLED={0}" -f [bool]$shareConfig.Enabled)
        Write-Output ("WINDOWS_SHARE_LINUX_USERNAME={0}" -f [string]$shareConfig.LinuxUsername)
        Write-Output ("WINDOWS_SHARE_SYSTEM_DISK={0}" -f [int]$shareConfig.SystemDiskNumber)
        Write-Output ("WINDOWS_SHARE_EXPECTED_PARTITION_SIZE={0}" -f [int64]$shareConfig.ExpectedLinuxPartitionSize)
    } catch {
        Write-Output ("WINDOWS_SHARE_CONFIG_ERROR={0}" -f $_.Exception.Message)
    }
}

if (Test-Path -LiteralPath $launcherKey) {
    $launcherCommand = [string](Get-ItemPropertyValue -LiteralPath $launcherKey -Name CommandLine -ErrorAction SilentlyContinue)
    Write-Output ("EXT4_LAUNCHER_COMMAND={0}" -f $launcherCommand)
    Write-Output ("EXT4_LAUNCHER_READ_ONLY={0}" -f [bool]($launcherCommand -match '(?i)(?:^|\s)--ro(?:\s|$)'))
} else {
    Write-Output "EXT4_LAUNCHER_KEY_PRESENT=False"
}

$watcher = Get-CimInstance Win32_Service -Filter "Name='ExtFsWatcher'" -ErrorAction SilentlyContinue
if ($watcher) {
    Write-Output ("EXTFSWATCHER_STATE={0}" -f $watcher.State)
    Write-Output ("EXTFSWATCHER_START_MODE={0}" -f $watcher.StartMode)
} else {
    Write-Output "EXTFSWATCHER_PRESENT=False"
}

$mountTask = Get-ScheduledTask -TaskName $mountTaskName -ErrorAction SilentlyContinue
Write-Output ("WINDOWS_SHARE_MOUNT_TASK_PRESENT={0}" -f [bool]$mountTask)
if ($mountTask) {
    $mountTaskInfo = Get-ScheduledTaskInfo -TaskName $mountTaskName -ErrorAction SilentlyContinue
    Write-Output ("WINDOWS_SHARE_MOUNT_TASK_STATE={0}" -f $mountTask.State)
    Write-Output ("WINDOWS_SHARE_MOUNT_TASK_LAST_RESULT={0}" -f $mountTaskInfo.LastTaskResult)
    Write-Output ("WINDOWS_SHARE_MOUNT_TASK_USER={0}" -f $mountTask.Principal.UserId)
    Write-Output ("WINDOWS_SHARE_MOUNT_TASK_TRIGGER={0}" -f $mountTask.Triggers[0].CimClass.CimClassName)
}
$pinTasks = @(Get-ScheduledTask -TaskName "LibertixLinuxReadOnlyPin_*" -ErrorAction SilentlyContinue)
Write-Output ("WINDOWS_SHARE_PIN_TASK_COUNT={0}" -f $pinTasks.Count)
foreach ($pinTask in $pinTasks) {
    $pinTaskInfo = Get-ScheduledTaskInfo -TaskName $pinTask.TaskName -ErrorAction SilentlyContinue
    Write-Output ("WINDOWS_SHARE_PIN_TASK_NAME={0}" -f $pinTask.TaskName)
    Write-Output ("WINDOWS_SHARE_PIN_TASK_STATE={0}" -f $pinTask.State)
    Write-Output ("WINDOWS_SHARE_PIN_TASK_LAST_RESULT={0}" -f $pinTaskInfo.LastTaskResult)
    Write-Output ("WINDOWS_SHARE_PIN_TASK_USER={0}" -f $pinTask.Principal.UserId)
    Write-Output ("WINDOWS_SHARE_PIN_TASK_TRIGGER={0}" -f $pinTask.Triggers[0].CimClass.CimClassName)
}

$ext4Processes = @(Get-CimInstance Win32_Process -Filter "Name='ext4.exe'" -ErrorAction SilentlyContinue)
$ext4Processes |
    Select-Object ProcessId, ExecutablePath, CommandLine |
    Format-List
Write-Output ("EXT4_MOUNT_PROCESS_COUNT={0}" -f $ext4Processes.Count)
Write-Output ("EXT4_MOUNT_PROCESS_READ_ONLY={0}" -f [bool]($ext4Processes.CommandLine -match '(?i)(?:^|\s)--ro(?:\s|$)'))

$linuxUsername = if ($shareConfig) { [string]$shareConfig.LinuxUsername } else { "test" }
$linuxDrive = $null
$linuxHome = $null
foreach ($letter in @("L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z")) {
    $candidate = "${letter}:\home\$linuxUsername"
    if (Test-Path -LiteralPath $candidate -PathType Container) {
        $linuxDrive = "${letter}:"
        $linuxHome = $candidate
        break
    }
}
Write-Output ("LINUX_READ_ONLY_DRIVE={0}" -f $linuxDrive)
Write-Output ("LINUX_HOME_PRESENT={0}" -f [bool]$linuxHome)
if ($linuxHome) {
    Get-ChildItem -LiteralPath $linuxHome -Force -ErrorAction SilentlyContinue |
        Select-Object -First 50 Name, Mode, Length, LastWriteTime |
        Format-Table -AutoSize

    $writeProbe = Join-Path $linuxDrive (".libertix-audit-write-probe-{0}" -f [Guid]::NewGuid().ToString("N"))
    $linuxWriteAccepted = $false
    try {
        Set-Content -LiteralPath $writeProbe -Value "this write must be refused" -ErrorAction Stop
        $linuxWriteAccepted = $true
    } catch {
        Write-Output ("LINUX_WRITE_REFUSAL={0}" -f $_.Exception.Message)
    } finally {
        if ($linuxWriteAccepted) {
            Remove-Item -LiteralPath $writeProbe -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Output ("LINUX_WRITE_DENIED={0}" -f (-not $linuxWriteAccepted))
}

$shareShortcuts = @(
    Get-ChildItem -Path "C:\Users\*\Links\Linux_*_read-only.lnk" -File -ErrorAction SilentlyContinue
)
$shareShortcuts |
    Select-Object FullName, Length, LastWriteTime |
    Format-Table -AutoSize
Write-Output ("LINUX_EXPLORER_SHORTCUT_COUNT={0}" -f $shareShortcuts.Count)

$mintWriteMarkers = @(
    Get-ChildItem -Path "C:\Users\*\Documents\libertix-mint-write-*.txt" -File -ErrorAction SilentlyContinue
)
$mintWriteMarkers |
    Select-Object FullName, Length, LastWriteTime |
    Format-Table -AutoSize
foreach ($marker in $mintWriteMarkers) {
    Write-Output ("--- {0} ---" -f $marker.FullName)
    Get-Content -LiteralPath $marker.FullName -ErrorAction SilentlyContinue
}
Write-Output ("MINT_TO_WINDOWS_WRITE_MARKER_COUNT={0}" -f $mintWriteMarkers.Count)

if (Test-Path -LiteralPath $shareLogPath -PathType Leaf) {
    Write-Output ("--- {0} ---" -f $shareLogPath)
    Get-Content -LiteralPath $shareLogPath -ErrorAction SilentlyContinue
}

Write-Section "ACCOUNTS AND PROFILE"
Get-LocalUser | Select-Object Name, Enabled, LastLogon, PasswordRequired |
    Format-Table -AutoSize
Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue |
    Select-Object Name, ObjectClass, PrincipalSource |
    Format-Table -AutoSize
Write-Output ("SYSTEM32_PRESENT={0}" -f (Test-Path -LiteralPath "C:\Windows\System32"))
Write-Output ("ADMIN_PROFILE_PRESENT={0}" -f (Test-Path -LiteralPath "C:\Users\admin"))

Write-Section "SERVICES"
Get-Service |
    Where-Object { $_.StartType -eq "Automatic" -and $_.Status -ne "Running" } |
    Sort-Object Name |
    Select-Object Name, DisplayName, Status, StartType |
    Format-Table -AutoSize

Write-Section "PNP DEVICES WITH PROBLEMS"
Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object { $_.Status -ne "OK" } |
    Sort-Object Class, FriendlyName |
    Select-Object Status, Class, FriendlyName, InstanceId |
    Format-Table -AutoSize

Write-Section "NETWORK"
Get-NetAdapter |
    Select-Object Name, InterfaceDescription, Status, LinkSpeed, MacAddress |
    Format-Table -AutoSize
Get-NetIPConfiguration |
    Select-Object InterfaceAlias, IPv4Address, IPv4DefaultGateway, DNSServer |
    Format-List

$bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
Write-Section "CRITICAL AND ERROR EVENTS SINCE BOOT"
Get-WinEvent -FilterHashtable @{ LogName = "System"; Level = 1, 2; StartTime = $bootTime } `
    -ErrorAction SilentlyContinue |
    Select-Object -First 100 TimeCreated, Id, ProviderName, LevelDisplayName, Message |
    Format-List

Invoke-NativeCheck -Name "DISM CHECK HEALTH" -FilePath "dism.exe" `
    -Arguments @("/Online", "/Cleanup-Image", "/CheckHealth")
Invoke-NativeCheck -Name "DISM SCAN HEALTH" -FilePath "dism.exe" `
    -Arguments @("/Online", "/Cleanup-Image", "/ScanHealth")
Invoke-NativeCheck -Name "SFC VERIFY ONLY" -FilePath "sfc.exe" -Arguments @("/verifyonly")
Write-Section "SFC CBS DETAILS"
if (Test-Path -LiteralPath "C:\Windows\Logs\CBS\CBS.log") {
    Select-String -LiteralPath "C:\Windows\Logs\CBS\CBS.log" -Pattern "\[SR\]" `
        -ErrorAction SilentlyContinue |
        Select-Object -Last 200 |
        ForEach-Object { $_.Line }
}
Invoke-NativeCheck -Name "CHKDSK ONLINE SCAN" -FilePath "chkdsk.exe" -Arguments @("C:", "/scan")

Write-Output ""
Write-Output ("REPORT_FINISHED={0}" -f (Get-Date -Format o))
Write-Output "REPORT_COMPLETE=1"
