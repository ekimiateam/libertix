#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$logon = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI'
$provider = Get-ItemProperty ('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\' + $logon.LastLoggedOnProvider)
$winlogon = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$keyboard = Get-ItemProperty 'Registry::HKEY_USERS\.DEFAULT\Keyboard Layout\Preload'
$sessions = @()
foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name = 'explorer.exe'")) {
    $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwner
    if ($owner.ReturnValue -ne 0) { throw 'Cannot identify the Windows desktop owner.' }
    $sessions += [ordered]@{ session = [int]$process.SessionId; user = [string]$owner.User }
}
[ordered]@{
    explorers = $sessions
    logonProcesses = @(Get-Process LogonUI -ErrorAction SilentlyContinue | ForEach-Object {
        [ordered]@{ id = [int]$_.Id; session = [int]$_.SessionId }
    })
    lastUser = [string]$logon.LastLoggedOnSAMUser
    passwordProvider = [string]$provider.'(default)' -eq 'PasswordProvider'
    automaticLogon = [string]$winlogon.AutoAdminLogon -eq '1'
    keyboard = [string]$keyboard.'1'
} | ConvertTo-Json -Depth 4 -Compress
