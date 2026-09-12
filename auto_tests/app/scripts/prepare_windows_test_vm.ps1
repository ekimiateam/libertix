#requires -Version 5.1

param([Parameter(Mandatory = $true)][string]$ConfigPath)

$ErrorActionPreference = "Stop"

function Set-RegistryDwordValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Value
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
    $observed = Get-ItemPropertyValue -LiteralPath $Path -Name $Name -ErrorAction Stop
    if ([int]$observed -ne $Value) {
        throw "Registry value $Path\$Name was not set to $Value."
    }
}

function Get-DirectoryFileBytes {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [int64]0
    }
    $measurement = Get-ChildItem -LiteralPath $Path -File -Recurse -Force `
        -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
    return [int64]$measurement.Sum
}

function Clear-TestVmTemporaryFiles {
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    [int64]$beforeBytes = 0
    [int64]$afterBytes = 0
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            continue
        }
        $beforeBytes += Get-DirectoryFileBytes -Path $path
        Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -notlike "auto-tests-*" -and
                $_.Name -notlike "libertix-ssh-*"
            } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $afterBytes += Get-DirectoryFileBytes -Path $path
    }
    return [Math]::Max([int64]0, $beforeBytes - $afterBytes)
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

# This script runs only on disposable test VMs. Apply the policy before
# advancing a restored clock, which can make scheduled updates immediately due.
$windowsUpdatePolicyPath = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
Set-RegistryDwordValue -Path "$windowsUpdatePolicyPath\AU" -Name NoAutoUpdate -Value 1
Set-RegistryDwordValue -Path $windowsUpdatePolicyPath -Name SetDisableUXWUAccess -Value 1
Set-Service -Name wuauserv -StartupType Disabled -ErrorAction Stop
$updateService = Get-Service -Name wuauserv -ErrorAction Stop
if ($updateService.Status -notin @("Stopped", "StopPending")) {
    $updateService.Stop()
}
$updateService.WaitForStatus(
    [System.ServiceProcess.ServiceControllerStatus]::Stopped,
    [TimeSpan]::FromSeconds(30)
)
$observedUpdateService = Get-CimInstance Win32_Service -Filter "Name='wuauserv'" -ErrorAction Stop
if ($observedUpdateService.State -ne "Stopped" -or $observedUpdateService.StartMode -ne "Disabled") {
    throw "Windows Update must be stopped and disabled before the test starts."
}
$temporaryBytesReclaimed = Clear-TestVmTemporaryFiles -Paths @(
    $env:TEMP,
    "C:\Windows\Temp",
    "C:\Windows\SoftwareDistribution\Download"
)
foreach ($pendingRestartPath in @(
    "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
    "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
)) {
    if (Test-Path -LiteralPath $pendingRestartPath) {
        throw "The test snapshot already has a pending Windows servicing restart: $pendingRestartPath."
    }
}

$target = [DateTimeOffset]::Parse(
    [string]$config.utc_now,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::RoundtripKind
)
$before = [DateTimeOffset]::Now
$beforeSkew = [math]::Abs(($before - $target).TotalSeconds)

# Restored test snapshots keep their historical RTC value. Correct only a
# material skew so HTTPS validation exercises the server certificate rather
# than an obsolete snapshot date.
if ($beforeSkew -gt 120) {
    Set-Date -Date $target.LocalDateTime | Out-Null
}

$after = [DateTimeOffset]::Now
$afterSkew = [math]::Abs(($after - $target).TotalSeconds)
if ($afterSkew -gt 300) {
    throw "Windows test VM clock remains $([math]::Round($afterSkew)) seconds from the controller."
}

$explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop |
    Sort-Object CreationDate -Descending |
    Select-Object -First 1
if (-not $explorer) {
    throw "No interactive Explorer session is available for notification policy preparation."
}

$owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwnerSid -ErrorAction Stop
if ([string]::IsNullOrWhiteSpace([string]$owner.Sid)) {
    throw "The interactive Windows user SID could not be resolved."
}

# Disable toast notifications for the exact interactive profile so a transient
# banner cannot take focus from deterministic unattended keyboard actions.
$notificationPolicyPath = "Registry::HKEY_USERS\$($owner.Sid)\Software\Policies\Microsoft\Windows\CurrentVersion\PushNotifications"
$notificationPreferencePath = "Registry::HKEY_USERS\$($owner.Sid)\Software\Microsoft\Windows\CurrentVersion\PushNotifications"
$machineNotificationPolicyPath = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications"
$taskbarPolicyPath = "Registry::HKEY_USERS\$($owner.Sid)\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
$accountNotificationPath = "Registry::HKEY_USERS\$($owner.Sid)\Software\Policies\Microsoft\Windows\CurrentVersion\AccountNotifications"
$windowsBackupPath = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsBackup"
$windowsSecurityNotificationPath = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications"
$senderSettingsRoot = "Registry::HKEY_USERS\$($owner.Sid)\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings"
$cloudContentPolicyPath = "Registry::HKEY_USERS\$($owner.Sid)\Software\Policies\Microsoft\Windows\CloudContent"
$machineCloudContentPolicyPath = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
$profileEngagementPath = "Registry::HKEY_USERS\$($owner.Sid)\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement"

Set-RegistryDwordValue -Path $notificationPolicyPath -Name NoToastApplicationNotification -Value 1
Set-RegistryDwordValue -Path $notificationPreferencePath -Name ToastEnabled -Value 0
Set-RegistryDwordValue -Path $machineNotificationPolicyPath -Name NoToastApplicationNotification -Value 1
Set-RegistryDwordValue -Path $taskbarPolicyPath -Name TaskbarNoNotification -Value 1
Set-RegistryDwordValue -Path $accountNotificationPath -Name DisableAccountNotifications -Value 1
Set-RegistryDwordValue -Path $windowsBackupPath -Name DisableMonitoring -Value 1
Set-RegistryDwordValue -Path $windowsSecurityNotificationPath -Name DisableNotifications -Value 1
Set-RegistryDwordValue `
    -Path $cloudContentPolicyPath `
    -Name DisableWindowsSpotlightWindowsWelcomeExperience `
    -Value 1
Set-RegistryDwordValue `
    -Path $machineCloudContentPolicyPath `
    -Name DisableSoftLanding `
    -Value 1
Set-RegistryDwordValue `
    -Path $profileEngagementPath `
    -Name ScoobeSystemSettingEnabled `
    -Value 0

foreach ($notificationSenderId in @(
    "Microsoft.SkyDrive.Desktop",
    "Windows.SystemToast.BackupReminder",
    "Windows.SystemToast.Suggested"
)) {
    Set-RegistryDwordValue `
        -Path "$senderSettingsRoot\$notificationSenderId" `
        -Name Enabled `
        -Value 0
}

# WpnUserService is the Windows transport for local, push, toast, tile, and raw
# notifications. Policies alone intentionally leave some system senders
# enabled, so stop and disable both notification service layers on disposable
# test snapshots. The next snapshot rollback restores their original state.
Set-RegistryDwordValue `
    -Path "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\WpnUserService" `
    -Name Start `
    -Value 4
foreach ($service in @(Get-Service -Name "WpnUserService*" -ErrorAction SilentlyContinue)) {
    Set-RegistryDwordValue `
        -Path "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$($service.Name)" `
        -Name Start `
        -Value 4
    if ($service.Status -ne "Stopped") {
        Stop-Service -Name $service.Name -Force -ErrorAction Stop
    }
}

Set-Service -Name WpnService -StartupType Disabled -ErrorAction Stop
$systemNotificationService = Get-Service -Name WpnService -ErrorAction Stop
if ($systemNotificationService.Status -ne "Stopped") {
    Stop-Service -Name WpnService -Force -ErrorAction Stop
}

$runningNotificationServices = @(
    Get-Service -Name "WpnService", "WpnUserService*" -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -ne "Stopped" }
)
if ($runningNotificationServices.Count -ne 0) {
    throw "Windows notification services remain active: $($runningNotificationServices.Name -join ', ')."
}

# Remove a banner that was already queued before the policies were written.
# ShellExperienceHost can restart, but the disabled transport cannot deliver a
# replacement toast to the interactive desktop.
Get-Process -Name SystemSettings, ShellExperienceHost -ErrorAction SilentlyContinue |
    Where-Object { $_.SessionId -eq $explorer.SessionId } |
    Stop-Process -Force -ErrorAction Stop
Start-Sleep -Seconds 3

Write-Output "UTC_NOW=$($after.UtcDateTime.ToString('o'))"
Write-Output "CLOCK_SKEW_SECONDS=$([math]::Round($afterSkew))"
Write-Output "TOAST_NOTIFICATIONS_DISABLED=True"
Write-Output "WINDOWS_BACKUP_NOTIFICATIONS_DISABLED=True"
Write-Output "WINDOWS_NOTIFICATION_SERVICES_DISABLED=True"
Write-Output "WINDOWS_SETUP_REMINDER_DISABLED=True"
Write-Output "WINDOWS_UPDATES_DISABLED=True"
Write-Output "TEMPORARY_FILES_RECLAIMED_BYTES=$temporaryBytesReclaimed"
