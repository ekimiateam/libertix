[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TaskName,

    [Parameter(Mandatory = $true)]
    [string]$RecoveryScriptPath,

    [Parameter(Mandatory = $true)]
    [string]$HiddenHostPath,

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

if (-not (Test-Path -LiteralPath $HiddenHostPath -PathType Leaf)) {
    throw "The console-free scheduled-task host is missing."
}

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false `
    -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $PromptTaskName -Confirm:$false `
    -ErrorAction SilentlyContinue

try {
    $arguments = '--run-hidden-powershell -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f `
        $RecoveryScriptPath
    $action = New-ScheduledTaskAction -Execute $HiddenHostPath -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal `
        -UserId "SYSTEM" `
        -LogonType ServiceAccount `
        -RunLevel Highest
    $startupSettings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -DisallowHardTerminate `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    $promptSettings = New-ScheduledTaskSettingsSet `
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
        -Settings $startupSettings `
        -Force | Out-Null

    $promptArguments = (
        '--run-hidden-powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" ' +
        '-StatePath "{1}" -RecoveryScriptPath "{2}" ' +
        '-Firmware bios -PromptTaskName "{3}"'
    ) -f $ResultScriptPath, $ResultStatePath, $RecoveryScriptPath, $PromptTaskName
    $promptAction = New-ScheduledTaskAction `
        -Execute $HiddenHostPath `
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
        -Settings $promptSettings `
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
