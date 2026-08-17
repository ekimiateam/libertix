[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$StartupTaskName,

    [Parameter(Mandatory = $true)]
    [string]$AgentPath,

    [Parameter(Mandatory = $true)]
    [string]$HiddenHostPath,

    [Parameter(Mandatory = $true)]
    [string]$PromptTaskName,

    [Parameter(Mandatory = $true)]
    [string]$StatePath,

    [Parameter(Mandatory = $true)]
    [string]$PromptUser
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $HiddenHostPath -PathType Leaf)) {
    throw "The console-free scheduled-task host is missing."
}

function Remove-RecoveryTask {
    param([Parameter(Mandatory = $true)][string]$TaskName)

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false `
        -ErrorAction SilentlyContinue
}

Remove-RecoveryTask -TaskName $StartupTaskName
Remove-RecoveryTask -TaskName $PromptTaskName

try {
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

    $baseArguments = '--run-hidden-powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -StatePath "{1}"' -f `
        $AgentPath, $StatePath
    $startupAction = New-ScheduledTaskAction -Execute $HiddenHostPath -Argument $baseArguments
    $startupTrigger = New-ScheduledTaskTrigger -AtStartup
    $startupPrincipal = New-ScheduledTaskPrincipal `
        -UserId "SYSTEM" `
        -LogonType ServiceAccount `
        -RunLevel Highest
    Register-ScheduledTask `
        -TaskName $StartupTaskName `
        -Action $startupAction `
        -Trigger $startupTrigger `
        -Principal $startupPrincipal `
        -Settings $startupSettings `
        -Force | Out-Null

    $promptAction = New-ScheduledTaskAction `
        -Execute $HiddenHostPath `
        -Argument ($baseArguments + ' -Action Prompt')
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

    Write-Output "RECOVERY_TASKS_REGISTERED=true"
    Write-Output "STARTUP_TASK=$StartupTaskName"
    Write-Output "PROMPT_TASK=$PromptTaskName"
} catch {
    Remove-RecoveryTask -TaskName $StartupTaskName
    Remove-RecoveryTask -TaskName $PromptTaskName
    throw
}
