[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TaskName,

    [Parameter(Mandatory = $true)]
    [string]$RecoveryScriptPath,

    [Parameter(Mandatory = $true)]
    [string]$PromptTaskName,

    [Parameter(Mandatory = $true)]
    [string]$ResultScriptPath,

    [Parameter(Mandatory = $true)]
    [string]$ResultStatePath,

    [Parameter(Mandatory = $true)]
    [string]$PromptUser
)

$ErrorActionPreference = "Stop"

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false `
    -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $PromptTaskName -Confirm:$false `
    -ErrorAction SilentlyContinue

try {
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f `
        $RecoveryScriptPath
    $action = New-ScheduledTaskAction -Execute $powerShell -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal `
        -UserId "SYSTEM" `
        -LogonType ServiceAccount `
        -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -DisallowHardTerminate `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Force | Out-Null

    $promptArguments = (
        '-NoProfile -ExecutionPolicy Bypass -File "{0}" ' +
        '-StatePath "{1}" -RecoveryScriptPath "{2}" ' +
        '-Firmware bios -PromptTaskName "{3}"'
    ) -f $ResultScriptPath, $ResultStatePath, $RecoveryScriptPath, $PromptTaskName
    $promptAction = New-ScheduledTaskAction `
        -Execute $powerShell `
        -Argument $promptArguments
    $promptTrigger = New-ScheduledTaskTrigger -AtLogOn -User $PromptUser
    $promptPrincipal = New-ScheduledTaskPrincipal `
        -UserId $PromptUser `
        -LogonType Interactive `
        -RunLevel Highest
    Register-ScheduledTask `
        -TaskName $PromptTaskName `
        -Action $promptAction `
        -Trigger $promptTrigger `
        -Principal $promptPrincipal `
        -Settings $settings `
        -Force | Out-Null

    $registered = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    if (-not [string]::IsNullOrWhiteSpace([string]$registered.Triggers[0].StartBoundary)) {
        throw "The BIOS recovery boot trigger unexpectedly has a clock-dependent start boundary."
    }

    Write-Output "RECOVERY_TASK_REGISTERED=true"
    Write-Output "TASK=$TaskName"
    Write-Output "PROMPT_TASK=$PromptTaskName"
} catch {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false `
        -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $PromptTaskName -Confirm:$false `
        -ErrorAction SilentlyContinue
    throw
}
