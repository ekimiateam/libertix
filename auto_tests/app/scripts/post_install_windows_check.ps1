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

function Get-LibertixRecoveryTasks {
    $tasks = @()
    foreach ($pattern in @(
        "LibertixInstallRecovery",
        "LibertixUefiRecovery_*",
        "LibertixUefiRecoveryPrompt_*"
    )) {
        $tasks += @(Get-ScheduledTask -TaskName $pattern -ErrorAction SilentlyContinue)
    }
    return @($tasks | Sort-Object TaskName -Unique)
}

function Get-ExpectedLinuxMountIdentity {
    $planPath = "C:\LibertixInstallLogs\latest\installation-plan.json"
    Assert-Condition (Test-Path -LiteralPath $planPath -PathType Leaf) `
        "The archived installation plan is missing for Linux mount verification."
    $plan = Get-Content -LiteralPath $planPath -Raw -ErrorAction Stop | ConvertFrom-Json
    $disk = Get-Disk -Number ([int]$plan.disk.number) -ErrorAction Stop
    Assert-Condition (
        ([string]$disk.UniqueId).Trim() -eq ([string]$plan.disk.uniqueId).Trim()
    ) "The Linux mount disk identity differs from the installation plan."
    $partitions = @(
        Get-Partition -DiskNumber $disk.Number -ErrorAction Stop |
            Where-Object {
                [int64]$_.Offset -eq [int64]$plan.disk.installer.offsetBytes -and
                [int64]$_.Size -eq [int64]$plan.disk.installer.finalSizeBytes
            }
    )
    Assert-Condition ($partitions.Count -eq 1) `
        "The Linux mount partition does not match the installation plan."
    return [pscustomobject]@{
        DiskNumber = [int]$disk.Number
        PartitionNumber = [int]$partitions[0].PartitionNumber
    }
}

function Get-CommandLineTokens {
    param([Parameter(Mandatory = $true)][string]$CommandLine)

    $tokens = @()
    foreach ($match in [regex]::Matches($CommandLine, '"([^\"]*)"|([^\s]+)')) {
        if ($match.Groups[1].Success) {
            $tokens += $match.Groups[1].Value
        } else {
            $tokens += $match.Groups[2].Value
        }
    }
    return @($tokens)
}

function Test-CommandLineToken {
    param(
        [Parameter(Mandatory = $true)][string[]]$Tokens,
        [Parameter(Mandatory = $true)][string]$Value
    )

    return @($Tokens | Where-Object { $_ -ieq $Value }).Count -eq 1
}

function Test-CommandLineOptionValue {
    param(
        [Parameter(Mandatory = $true)][string[]]$Tokens,
        [Parameter(Mandatory = $true)][string]$Option,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $optionValues = @()
    for ($index = 0; $index -lt $Tokens.Count; $index++) {
        if ($Tokens[$index] -ieq $Option) {
            if ($index + 1 -ge $Tokens.Count) {
                return $false
            }
            $optionValues += $Tokens[$index + 1]
            continue
        }
        $prefix = "$Option="
        if ($Tokens[$index].StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            $optionValues += $Tokens[$index].Substring($prefix.Length)
        }
    }
    return $optionValues.Count -eq 1 -and $optionValues[0] -ieq $Value
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
$installerIsoPattern = [regex]::Escape([string]$config.installer_iso_file_name)

try {
    switch ($check) {
        "finalization" {
            $deadline = [DateTime]::UtcNow.AddMinutes(5)
            do {
                $biosPending = Test-Path -LiteralPath "C:\LibertixInstallRecovery\pending.env"
                $uefiTransaction = Test-Path -LiteralPath "C:\LibertixTools\uefi-transaction.json"
                $recoveryTasks = @(Get-LibertixRecoveryTasks)
                if (-not $biosPending -and -not $uefiTransaction -and $recoveryTasks.Count -eq 0) {
                    Write-Output "LIBERTIX_FINALIZATION=ready"
                    break
                }
                if ([DateTime]::UtcNow -ge $deadline) {
                    throw (
                        "Libertix Windows finalization timed out: " +
                        "biosPending=$biosPending, uefiTransaction=$uefiTransaction, " +
                        "recoveryTasks=$($recoveryTasks.Count)."
                    )
                }
                Start-Sleep -Seconds 2
            } while ($true)
        }
        "final_state" {
            $os = Get-CimInstance Win32_OperatingSystem
            $firmware = [string](Get-ComputerInfo).BiosFirmwareType
            $volume = Get-Volume -DriveLetter C -ErrorAction Stop
            $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -eq [string]$config.expected_ipv4 })
            $defaultRoutes = @(Get-NetRoute `
                -AddressFamily IPv4 `
                -DestinationPrefix "0.0.0.0/0" `
                -ErrorAction Stop)
            $sshService = Get-Service -Name "sshd" -ErrorAction Stop
            $coreServices = @(Get-Service -Name @("EventLog", "RpcSs", "Schedule") -ErrorAction Stop)
            $biosPending = Test-Path -LiteralPath "C:\LibertixInstallRecovery\pending.env"
            $uefiTransaction = Test-Path -LiteralPath "C:\LibertixTools\uefi-transaction.json"
            $recoveryTasks = @(Get-LibertixRecoveryTasks)
            $bcdEntries = @(& bcdedit.exe /enum all 2>&1)
            Assert-Condition ($LASTEXITCODE -eq 0) "bcdedit failed during the final Windows check."
            $bcdText = $bcdEntries -join "`n"

            Write-Output ("WINDOWS={0} BUILD={1}" -f $os.Caption, $os.BuildNumber)
            Write-Output ("FIRMWARE={0}" -f $firmware)
            Write-Output ("SYSTEM_VOLUME={0} HEALTH={1}" -f $volume.FileSystem, $volume.HealthStatus)
            Write-Output ("EXPECTED_IPV4_PRESENT={0}" -f ($addresses.Count -ge 1))
            Write-Output ("DEFAULT_ROUTES={0}" -f $defaultRoutes.Count)
            Write-Output ("SSHD={0}" -f $sshService.Status)

            Assert-Condition ($os.ProductType -eq 1) "The final system is not a Windows workstation."
            if ([string]$config.expected_firmware -eq "uefi") {
                Assert-Condition ($firmware -match "UEFI") "The final Windows boot is not UEFI."
            } else {
                Assert-Condition ($firmware -match "BIOS|Legacy") "The final Windows boot is not BIOS."
            }
            Assert-Condition ($volume.FileSystem -eq "NTFS") "The final Windows system volume is not NTFS."
            Assert-Condition ($volume.HealthStatus -eq "Healthy") "The final Windows system volume is not healthy."
            Assert-Condition ($addresses.Count -ge 1) "The expected IPv4 address is missing after the final boot."
            Assert-Condition ($defaultRoutes.Count -ge 1) "Windows has no default route after the final boot."
            Assert-Condition ($sshService.Status -eq "Running") "The SSH service stopped after the final boot."
            Assert-Condition (@($coreServices | Where-Object { $_.Status -ne "Running" }).Count -eq 0) `
                "A core Windows service stopped after the final boot."
            Assert-Condition (-not $biosPending) "The BIOS transaction is pending after the final boot."
            Assert-Condition (-not $uefiTransaction) "The UEFI transaction remains after the final boot."
            Assert-Condition ($recoveryTasks.Count -eq 0) "The recovery task remains after the final boot."
            Assert-Condition ($bcdText -match "(?i)winload[.]e(?:xe|fi)") `
                "The Windows loader is absent after the final boot."
            Assert-Condition ($bcdText -notmatch "(?i)Libertix Installer|$installerIsoPattern|grldr") `
                "A temporary Libertix boot entry remains after the final boot."
        }
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
        "partition_geometry" {
            $planPath = "C:\LibertixInstallLogs\latest\installation-plan.json"
            Assert-Condition (Test-Path -LiteralPath $planPath -PathType Leaf) `
                "The archived installation plan is missing."
            $plan = Get-Content -LiteralPath $planPath -Raw -ErrorAction Stop | ConvertFrom-Json
            $systemPartition = Get-Partition -DriveLetter C -ErrorAction Stop
            $systemDisk = Get-Disk -Number $systemPartition.DiskNumber -ErrorAction Stop
            $partitions = @(Get-Partition -DiskNumber $systemDisk.Number -ErrorAction Stop)
            $installerOffset = [int64]$plan.disk.installer.offsetBytes
            $finalLinuxSize = [int64]$plan.disk.installer.finalSizeBytes
            $originalWindowsOffset = [int64]$plan.disk.windows.offsetBytes
            $originalWindowsSize = [int64]$plan.disk.windows.sizeBytes
            $windowsEnd = [int64]$systemPartition.Offset + [int64]$systemPartition.Size
            $gapBeforeLinux = $installerOffset - $windowsEnd
            $actualWindowsShrink = $originalWindowsSize - [int64]$systemPartition.Size
            $linuxMatches = @($partitions | Where-Object {
                [int64]$_.Offset -eq $installerOffset -and
                [int64]$_.Size -eq $finalLinuxSize
            })
            $recoveryMatches = @($partitions | Where-Object {
                [int64]$_.Offset -eq [int64]$plan.disk.recovery.offsetBytes -and
                [int64]$_.Size -eq [int64]$plan.disk.recovery.sizeBytes
            })
            Write-Output ("WINDOWS_OFFSET={0} WINDOWS_SIZE={1}" -f `
                $systemPartition.Offset, $systemPartition.Size)
            Write-Output ("LINUX_OFFSET={0} LINUX_SIZE={1}" -f `
                $installerOffset, $finalLinuxSize)
            Write-Output ("RECOVERY_OFFSET={0} RECOVERY_SIZE={1}" -f `
                $plan.disk.recovery.offsetBytes, $plan.disk.recovery.sizeBytes)
            Assert-Condition ([int]$systemDisk.Number -eq [int]$plan.disk.number) `
                "The installed system disk number differs from the installation plan."
            Assert-Condition (([string]$systemDisk.UniqueId).Trim() -eq `
                ([string]$plan.disk.uniqueId).Trim()) `
                "The installed system disk identity differs from the installation plan."
            Assert-Condition ([int64]$systemPartition.Offset -eq $originalWindowsOffset) `
                "The Windows partition offset changed during installation."
            Assert-Condition ($gapBeforeLinux -ge 0 -and $gapBeforeLinux -le 1MB) `
                "The Windows and Linux partitions are separated by an unexpected gap."
            Assert-Condition ($actualWindowsShrink -ge $finalLinuxSize -and `
                $actualWindowsShrink -le ($finalLinuxSize + 2MB)) `
                "The Windows partition shrink differs from the requested Linux allocation."
            Assert-Condition ($linuxMatches.Count -eq 1) `
                "The final Linux partition offset or size differs from the installation plan."
            Assert-Condition ($recoveryMatches.Count -eq 1) `
                "The Windows Recovery partition geometry changed during installation."
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
            Assert-Condition ($text -notmatch "(?i)Libertix Installer|$installerIsoPattern|grldr") "A temporary Libertix boot entry remains in BCD."
        }
        "recovery" {
            $recoveryPartitions = @(Get-Partition | Where-Object {
                $_.Type -match "Recovery" -or
                $_.GptType -eq "{de94bba4-06d1-4d40-a16a-bfd50179d6ac}" -or
                [int]$_.MbrType -eq 39
            })
            $recoveryPartitions | Format-Table DiskNumber, PartitionNumber, Type, GptType, MbrType, Size -AutoSize
            Assert-Condition ($recoveryPartitions.Count -ge 1) "No Windows recovery partition was found."
            $reagentOutput = @(& reagentc.exe /info 2>&1)
            $reagentOutput | ForEach-Object { Write-Output $_ }
            Assert-Condition ($LASTEXITCODE -eq 0) `
                "reagentc.exe failed to report Windows Recovery Environment status."
            $reagentText = $reagentOutput -join "`n"
            Assert-Condition ($reagentText -match `
                "(?i)(enabled|activ[eé]|habilitado|有効)") `
                "Windows Recovery Environment is not reported as enabled."
            Assert-Condition ($reagentText -notmatch `
                "(?i)(disabled|d[eé]sactiv[eé]|deshabilitado|無効)") `
                "Windows Recovery Environment is disabled."
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
            $recoveryTasks = @(Get-LibertixRecoveryTasks)
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
            $power = Get-ItemProperty `
                -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\Power" `
                -ErrorAction Stop
            $sessionPower = Get-ItemProperty `
                -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" `
                -ErrorAction SilentlyContinue
            $hibernateEnabled = ([int]$power.HibernateEnabled -ne 0)
            $fastStartupConfigured = (
                $sessionPower -and
                $null -ne $sessionPower.HiberbootEnabled -and
                [int]$sessionPower.HiberbootEnabled -ne 0
            )
            $hiberfilePresent = Test-Path -LiteralPath "C:\hiberfil.sys"
            $fastStartupCapable = (
                $fastStartupConfigured -and
                $hibernateEnabled -and
                $hiberfilePresent
            )
            Write-Output ("HIBERNATION_ENABLED={0}" -f $hibernateEnabled)
            Write-Output ("FAST_STARTUP_CONFIGURED={0}" -f $fastStartupConfigured)
            Write-Output ("FAST_STARTUP_CAPABLE={0}" -f $fastStartupCapable)
            Write-Output ("HIBERNATION_FILE_PRESENT={0}" -f $hiberfilePresent)
            if ([bool]$config.share_windows_files_in_linux) {
                # HiberbootEnabled is only a saved preference. Fast Startup
                # cannot run after powercfg disables hibernation, even when a
                # cloned system retains that preference or a stale hiberfile.
                Assert-Condition (-not $hibernateEnabled) `
                    "Windows hibernation remains enabled while Linux mounts Windows read-write."
                Assert-Condition (-not $fastStartupCapable) `
                    "Windows Fast Startup remains enabled while Linux mounts Windows read-write."
            }
        }
        "sharing_disabled" {
            if (-not [bool]$config.share_linux_files_in_windows) {
                $mountTasks = @(Get-ScheduledTask `
                    -TaskName "LibertixLinuxReadOnly" `
                    -ErrorAction SilentlyContinue)
                $pinTasks = @(Get-ScheduledTask `
                    -TaskName "LibertixLinuxReadOnlyPin_*" `
                    -ErrorAction SilentlyContinue)
                $mountProcesses = @(Get-CimInstance `
                    Win32_Process `
                    -Filter "Name='ext4.exe'" `
                    -ErrorAction SilentlyContinue)
                Assert-Condition ($mountTasks.Count -eq 0) `
                    "The disabled Linux-to-Windows share still has a mount task."
                Assert-Condition ($pinTasks.Count -eq 0) `
                    "The disabled Linux-to-Windows share still has a shortcut task."
                Assert-Condition ($mountProcesses.Count -eq 0) `
                    "The disabled Linux-to-Windows share still has an ext4 mount process."
            }
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
            $driveRoot = $drive
            $identity = Get-ExpectedLinuxMountIdentity
            $expectedExecutable = "$env:ProgramFiles\ext4-win-driver\ext4.exe"
            $processes = @(Get-CimInstance Win32_Process -Filter "Name='ext4.exe'")
            Write-Output ("LINUX_DRIVE={0}" -f $drive)
            $processes | Format-List ProcessId, ExecutablePath, CommandLine
            Assert-Condition ($processes.Count -ge 1) "No ext4 mount process is running."
            $writableProcesses = @($processes | Where-Object {
                $_.CommandLine -notmatch "(?i)(?:^|\s)--ro(?:\s|$)"
            })
            Assert-Condition ($writableProcesses.Count -eq 0) `
                "At least one active ext4 mount is not read-only."
            $processIdentityResults = @($processes | ForEach-Object {
                $commandLine = [string]$_.CommandLine
                $commandLineTokens = @(Get-CommandLineTokens -CommandLine $commandLine)
                $executableMatches = [string]$_.ExecutablePath -ieq $expectedExecutable
                $diskMatches = Test-CommandLineToken `
                    -Tokens $commandLineTokens `
                    -Value "\\.\PhysicalDrive$($identity.DiskNumber)"
                $driveMatches = Test-CommandLineOptionValue `
                    -Tokens $commandLineTokens `
                    -Option "--drive" `
                    -Value $driveRoot
                $partitionMatches = Test-CommandLineOptionValue `
                    -Tokens $commandLineTokens `
                    -Option "--part" `
                    -Value ([string]$identity.PartitionNumber)
                $readOnlyMatches = Test-CommandLineToken -Tokens $commandLineTokens -Value "--ro"
                [pscustomobject]@{
                    Process = $_
                    ProcessId = $_.ProcessId
                    ExecutableMatches = $executableMatches
                    DiskMatches = $diskMatches
                    DriveMatches = $driveMatches
                    PartitionMatches = $partitionMatches
                    ReadOnlyMatches = $readOnlyMatches
                    ExpectedDisk = "\\.\PhysicalDrive$($identity.DiskNumber)"
                    ExpectedDrive = $driveRoot
                    ExpectedPartition = [string]$identity.PartitionNumber
                    Tokens = $commandLineTokens -join " | "
                }
            })
            $processIdentityResults |
                Select-Object `
                    ProcessId, `
                    ExecutableMatches, `
                    DiskMatches, `
                    DriveMatches, `
                    PartitionMatches, `
                    ReadOnlyMatches, `
                    ExpectedDisk, `
                    ExpectedDrive, `
                    ExpectedPartition, `
                    Tokens |
                Format-List
            $ownedProcesses = @($processIdentityResults | Where-Object {
                $_.ExecutableMatches -and
                $_.DiskMatches -and
                $_.DriveMatches -and
                $_.PartitionMatches -and
                $_.ReadOnlyMatches
            })
            Assert-Condition ($ownedProcesses.Count -eq 1) `
                "The active ext4 mount is not uniquely tied to the planned disk and partition."
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
