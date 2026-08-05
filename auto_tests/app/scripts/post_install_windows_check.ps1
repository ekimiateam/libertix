param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Assert-Condition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-LinuxDrive {
    param([Parameter(Mandatory = $true)][string]$LinuxUsername)

    for ($attempt = 0; $attempt -lt 90; $attempt++) {
        foreach ($letter in @("L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z")) {
            if (Test-Path -LiteralPath "${letter}:\home\$LinuxUsername" -PathType Container) {
                return "${letter}:"
            }
        }
        Start-Sleep -Seconds 1
    }
    throw "The read-only Linux volume is not mounted on any supported drive letter."
}

function Invoke-NativeCheck {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = @(& $FilePath @Arguments 2>&1)
    $output | ForEach-Object { Write-Output $_ }
    Assert-Condition ($LASTEXITCODE -eq 0) "$FilePath exited with code $LASTEXITCODE."
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
$check = [string]$config.check

try {
    switch ($check) {
        "identity" {
            $os = Get-CimInstance Win32_OperatingSystem
            Write-Output ("COMPUTER={0}" -f $env:COMPUTERNAME)
            Write-Output ("WINDOWS={0} BUILD={1}" -f $os.Caption, $os.BuildNumber)
            Assert-Condition ($os.ProductType -eq 1) "The installed system is not a Windows workstation."
        }
        "firmware" {
            $firmware = [string](Get-ComputerInfo).BiosFirmwareType
            Write-Output ("FIRMWARE={0}" -f $firmware)
            if ([string]$config.expected_firmware -eq "uefi") {
                Assert-Condition ($firmware -match "UEFI") "Windows did not boot in UEFI mode."
            } else {
                Assert-Condition ($firmware -match "BIOS|Legacy") "Windows did not boot in BIOS mode."
            }
        }
        "system_volume" {
            $volume = Get-Volume -DriveLetter C -ErrorAction Stop
            $partition = Get-Partition -DriveLetter C -ErrorAction Stop
            $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
            $volume | Format-List DriveLetter, FileSystem, HealthStatus, OperationalStatus, Size, SizeRemaining
            $disk | Format-List Number, PartitionStyle, HealthStatus, OperationalStatus
            Assert-Condition ($volume.FileSystem -eq "NTFS") "C: is not NTFS."
            Assert-Condition ($volume.HealthStatus -eq "Healthy") "C: is not healthy."
            Assert-Condition ($disk.HealthStatus -eq "Healthy") "The Windows disk is not healthy."
        }
        "system_resources" {
            $systemDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
            $operatingSystem = Get-CimInstance Win32_OperatingSystem
            $computerSystem = Get-CimInstance Win32_ComputerSystem
            Write-Output ("C_FREE_BYTES={0}" -f $systemDrive.FreeSpace)
            Write-Output ("FREE_PHYSICAL_KIB={0}" -f $operatingSystem.FreePhysicalMemory)
            Write-Output ("TOTAL_MEMORY_BYTES={0}" -f $computerSystem.TotalPhysicalMemory)
            Assert-Condition ([uint64]$systemDrive.FreeSpace -gt 2GB) "C: has less than 2 GiB free."
            Assert-Condition ([uint64]$operatingSystem.FreePhysicalMemory -gt 262144) "Windows has less than 256 MiB free physical memory."
            Assert-Condition ([uint64]$computerSystem.TotalPhysicalMemory -gt 2GB) "Windows has less than 2 GiB total memory."
        }
        "partition_layout" {
            $systemPartition = Get-Partition -DriveLetter C -ErrorAction Stop
            $systemDisk = Get-Disk -Number $systemPartition.DiskNumber -ErrorAction Stop
            $partitions = @(Get-Partition -DiskNumber $systemDisk.Number -ErrorAction Stop)
            $partitions | Format-Table PartitionNumber, DriveLetter, Type, GptType, MbrType, Size -AutoSize
            if ([string]$config.expected_firmware -eq "uefi") {
                Assert-Condition ($systemDisk.PartitionStyle -eq "GPT") "The UEFI system disk is not GPT."
            } else {
                Assert-Condition ($systemDisk.PartitionStyle -eq "MBR") "The BIOS system disk is not MBR."
            }
            Assert-Condition (-not $systemDisk.IsOffline) "The Windows system disk is offline."
            Assert-Condition (-not $systemDisk.IsReadOnly) "The Windows system disk is read-only."
            Assert-Condition ($partitions.Count -ge 3) "The system disk has too few partitions after installation."
        }
        "boot_partition" {
            $systemPartition = Get-Partition -DriveLetter C -ErrorAction Stop
            $partitions = @(Get-Partition -DiskNumber $systemPartition.DiskNumber -ErrorAction Stop)
            if ([string]$config.expected_firmware -eq "uefi") {
                $bootPartitions = @($partitions | Where-Object {
                    $_.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}"
                })
                Assert-Condition ($bootPartitions.Count -eq 1) "The UEFI system disk does not contain exactly one ESP."
                Assert-Condition ([uint64]$bootPartitions[0].Size -ge 64MB) "The EFI system partition is unexpectedly small."
            } else {
                $bootPartitions = @($partitions | Where-Object { $_.IsActive })
                Assert-Condition ($bootPartitions.Count -eq 1) "The BIOS system disk does not contain exactly one active partition."
            }
            $bootPartitions | Format-Table PartitionNumber, Type, GptType, MbrType, IsActive, Size -AutoSize
        }
        "boot_configuration" {
            $entries = @(& bcdedit.exe /enum all 2>&1)
            $entries | ForEach-Object { Write-Output $_ }
            Assert-Condition ($LASTEXITCODE -eq 0) "bcdedit failed to enumerate the boot configuration."
            $text = $entries -join "`n"
            Assert-Condition ($text -match "(?i)winload[.]e(?:xe|fi)") "The Windows loader is absent from BCD."
            Assert-Condition ($text -notmatch "(?i)Libertix Installer|mint[.]iso|grldr") "A temporary Libertix boot entry remains in BCD."
        }
        "recovery" {
            $recoveryPartitions = @(Get-Partition | Where-Object {
                $_.Type -match "Recovery" -or
                $_.GptType -eq "{de94bba4-06d1-4d40-a16a-bfd50179d6ac}" -or
                [int]$_.MbrType -eq 39
            })
            $recoveryPartitions | Format-Table DiskNumber, PartitionNumber, Type, GptType, MbrType, Size -AutoSize
            Assert-Condition ($recoveryPartitions.Count -ge 1) "No Windows recovery partition was found."
            Invoke-NativeCheck -FilePath "reagentc.exe" -Arguments @("/info")
        }
        "bitlocker" {
            $volume = Get-BitLockerVolume -MountPoint "C:" -ErrorAction Stop
            $volume | Format-List MountPoint, VolumeStatus, EncryptionPercentage, ProtectionStatus, LockStatus
            Assert-Condition ($volume.VolumeStatus -eq "FullyDecrypted") "C: is not fully decrypted."
            Assert-Condition ([int]$volume.EncryptionPercentage -eq 0) "C: still contains encrypted data."
        }
        "temporary_artifacts" {
            $installerVolumes = @(Get-Volume -FileSystemLabel "LIBERTIXEFI" -ErrorAction SilentlyContinue)
            $uefiTransaction = Test-Path -LiteralPath "C:\LibertixTools\uefi-transaction.json"
            $biosPending = Test-Path -LiteralPath "C:\LibertixInstallRecovery\pending.env"
            $recoveryTasks = @(Get-ScheduledTask -TaskName "LibertixInstallRecovery" -ErrorAction SilentlyContinue)
            Write-Output ("INSTALLER_VOLUMES={0}" -f $installerVolumes.Count)
            Write-Output ("UEFI_TRANSACTION={0}" -f $uefiTransaction)
            Write-Output ("BIOS_PENDING={0}" -f $biosPending)
            Write-Output ("RECOVERY_TASKS={0}" -f $recoveryTasks.Count)
            Assert-Condition ($installerVolumes.Count -eq 0) "The temporary installer volume still exists."
            Assert-Condition (-not $uefiTransaction) "The UEFI transaction file still exists."
            Assert-Condition (-not $biosPending) "The BIOS recovery transaction is still pending."
            Assert-Condition ($recoveryTasks.Count -eq 0) "The temporary recovery task still exists."
        }
        "network" {
            $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -eq [string]$config.expected_ipv4 })
            $configurations = @(Get-NetIPConfiguration | Where-Object { $_.IPv4Address })
            $defaultRoutes = @(Get-NetRoute `
                -AddressFamily IPv4 `
                -DestinationPrefix "0.0.0.0/0" `
                -ErrorAction Stop)
            $configurations | Format-List InterfaceAlias, IPv4Address, IPv4DefaultGateway, DNSServer
            $defaultRoutes | Format-List InterfaceAlias, NextHop, RouteMetric, State
            Assert-Condition ($addresses.Count -ge 1) "The expected Windows IPv4 address is not configured."
            Assert-Condition ($defaultRoutes.Count -ge 1) "Windows has no IPv4 default route."
            Assert-Condition ([bool]($defaultRoutes.NextHop | Where-Object {
                $_ -and $_ -ne "0.0.0.0"
            })) "Windows has no usable IPv4 gateway."
            Resolve-DnsName -Name "ekimia.fr" -Type A -ErrorAction Stop |
                Format-Table Name, Type, IPAddress -AutoSize
        }
        "locale" {
            $systemLocale = Get-WinSystemLocale
            $languages = @(Get-WinUserLanguageList)
            $timeZone = Get-TimeZone
            Write-Output ("SYSTEM_LOCALE={0}" -f $systemLocale.Name)
            Write-Output ("LANGUAGES={0}" -f (($languages.LanguageTag) -join ","))
            Write-Output ("TIME_ZONE={0}" -f $timeZone.Id)
            Assert-Condition (-not [string]::IsNullOrWhiteSpace($systemLocale.Name)) "Windows has no system locale."
            Assert-Condition ($languages.Count -ge 1) "Windows has no user language."
            Assert-Condition (-not [string]::IsNullOrWhiteSpace($timeZone.Id)) "Windows has no time zone."
        }
        "ssh_service" {
            $service = Get-Service -Name "sshd" -ErrorAction Stop
            $configuration = Get-CimInstance Win32_Service -Filter "Name='sshd'"
            $service | Format-List Name, Status, StartType
            Assert-Condition ($service.Status -eq "Running") "The Windows SSH service is not running."
            Assert-Condition ($configuration.StartMode -eq "Auto") "The Windows SSH service is not configured for automatic startup."
        }
        "core_services" {
            $names = @("EventLog", "PlugPlay", "RpcSs", "Schedule")
            $services = @(Get-Service -Name $names -ErrorAction Stop)
            $services | Format-Table Name, Status, StartType -AutoSize
            $stopped = @($services | Where-Object { $_.Status -ne "Running" })
            Assert-Condition ($stopped.Count -eq 0) "One or more core Windows services are stopped."
        }
        "hibernation" {
            $hibernateEnabled = (Test-Path -LiteralPath "C:\hiberfil.sys")
            Write-Output ("HIBERNATION_FILE_PRESENT={0}" -f $hibernateEnabled)
            Assert-Condition (-not $hibernateEnabled) "Hibernation remains enabled while Windows is mounted read-write from Linux."
        }
        "ext4_driver" {
            $ext4 = "$env:ProgramFiles\ext4-win-driver\ext4.exe"
            $launcher = "HKLM:\SOFTWARE\WOW6432Node\WinFsp\Services\ext4-mount"
            Write-Output ("EXT4={0}" -f $ext4)
            Assert-Condition (Test-Path -LiteralPath $ext4 -PathType Leaf) "ext4.exe is missing."
            Assert-Condition (Test-Path -LiteralPath $launcher) "The WinFsp ext4 launcher is missing."
            $command = [string](Get-ItemPropertyValue -LiteralPath $launcher -Name CommandLine)
            Write-Output ("COMMAND={0}" -f $command)
            Assert-Condition ($command -match "(?i)(?:^|\s)--ro(?:\s|$)") "The ext4 launcher is not read-only."
        }
        "ext4_readonly_mount" {
            $drive = Get-LinuxDrive -LinuxUsername ([string]$config.linux_username)
            $processes = @(Get-CimInstance Win32_Process -Filter "Name='ext4.exe'")
            Write-Output ("LINUX_DRIVE={0}" -f $drive)
            $processes | Format-List ProcessId, ExecutablePath, CommandLine
            Assert-Condition ($processes.Count -ge 1) "No ext4 mount process is running."
            Assert-Condition ([bool]($processes.CommandLine -match "(?i)(?:^|\s)--ro(?:\s|$)")) "The active ext4 mount is not read-only."
        }
        "linux_home" {
            $drive = Get-LinuxDrive -LinuxUsername ([string]$config.linux_username)
            $linuxHomePath = Join-Path $drive "home\$($config.linux_username)"
            Write-Output ("LINUX_HOME={0}" -f $linuxHomePath)
            Assert-Condition (Test-Path -LiteralPath $linuxHomePath -PathType Container) "The Linux home directory is not readable from Windows."
        }
        "linux_home_hash" {
            Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$config.linux_sha256)) "The Linux source hash is unavailable."
            $drive = Get-LinuxDrive -LinuxUsername ([string]$config.linux_username)
            $path = Join-Path $drive "home\$($config.linux_username)\$($config.linux_relative_path)"
            $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            Write-Output ("PATH={0}" -f $path)
            Write-Output ("SHA256={0}" -f $actual)
            Assert-Condition ($actual -eq [string]$config.linux_sha256) "The Linux-home file hash differs between Linux and Windows."
        }
        "ext4_write_denied" {
            $drive = Get-LinuxDrive -LinuxUsername ([string]$config.linux_username)
            $probe = Join-Path $drive (".libertix-write-probe-{0}" -f [Guid]::NewGuid().ToString("N"))
            $accepted = $false
            try {
                Set-Content -LiteralPath $probe -Value "write must fail" -ErrorAction Stop
                $accepted = $true
            } catch {
                Write-Output ("WRITE_REFUSAL={0}" -f $_.Exception.Message)
            } finally {
                if ($accepted) {
                    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
                }
            }
            Assert-Condition (-not $accepted) "The Linux volume accepted a Windows write."
        }
        "explorer_shortcut" {
            $shortcuts = @(Get-ChildItem -Path "C:\Users\*\Links\Linux_*_read-only.lnk" -File -ErrorAction SilentlyContinue)
            $shortcuts | Format-Table FullName, Length, LastWriteTime -AutoSize
            Assert-Condition ($shortcuts.Count -ge 1) "No Linux read-only Explorer shortcut exists."
        }
        "sharing_tasks" {
            $mountTasks = @(Get-ScheduledTask -TaskName "LibertixLinuxReadOnly" -ErrorAction SilentlyContinue)
            $pinTasks = @(Get-ScheduledTask -TaskName "LibertixLinuxReadOnlyPin_*" -ErrorAction SilentlyContinue)
            $mountTasks | Format-Table TaskName, State -AutoSize
            $pinTasks | Format-Table TaskName, State -AutoSize
            Assert-Condition ($mountTasks.Count -eq 1) "The Linux read-only mount task is missing or duplicated."
            Assert-Condition ($mountTasks[0].State -ne "Disabled") "The Linux read-only mount task is disabled."
            Assert-Condition ($pinTasks.Count -ge 1) "No Linux Explorer shortcut task exists."
            Assert-Condition (@($pinTasks | Where-Object { $_.State -eq "Disabled" }).Count -eq 0) "A Linux Explorer shortcut task is disabled."
        }
        "cross_os_hash" {
            Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$config.windows_sha256)) "The Linux-side Windows-file hash is unavailable."
            $path = Join-Path "C:\" ([string]$config.windows_relative_path)
            $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            Write-Output ("PATH={0}" -f $path)
            Write-Output ("SHA256={0}" -f $actual)
            Assert-Condition ($actual -eq [string]$config.windows_sha256) "The 100 MiB shared-file hash differs between Linux and Windows."
        }
        "dism_check_health" {
            Invoke-NativeCheck -FilePath "dism.exe" -Arguments @("/Online", "/Cleanup-Image", "/CheckHealth")
        }
        "sfc_verify_only" {
            Invoke-NativeCheck -FilePath "sfc.exe" -Arguments @("/verifyonly")
        }
        "chkdsk_scan" {
            Invoke-NativeCheck -FilePath "chkdsk.exe" -Arguments @("C:", "/scan")
        }
        default {
            throw "Unknown post-install Windows check: $check"
        }
    }
    Write-Output ("CHECK={0}" -f $check)
    Write-Output "RESULT=OK"
    exit 0
} catch {
    Write-Error ("CHECK={0} ERROR={1}" -f $check, $_.Exception.Message)
    Write-Error $_.ScriptStackTrace
    exit 1
}
