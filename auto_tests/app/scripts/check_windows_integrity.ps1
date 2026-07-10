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
