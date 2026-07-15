[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$StartupTaskName,

    [Parameter(Mandatory = $true)]
    [string]$AgentPath,

    [Parameter(Mandatory = $true)]
    [string]$PromptTaskName,

    [Parameter(Mandatory = $true)]
    [string]$StatePath,

    [Parameter(Mandatory = $true)]
    [string]$PromptUser
)

$ErrorActionPreference = "Stop"

function Remove-RecoveryTask {
    param([Parameter(Mandatory = $true)][string]$TaskName)

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false `
        -ErrorAction SilentlyContinue
}

Remove-RecoveryTask -TaskName $StartupTaskName
Remove-RecoveryTask -TaskName $PromptTaskName

try {
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries

    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $baseArguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -StatePath "{1}"' -f `
        $AgentPath, $StatePath
    $startupAction = New-ScheduledTaskAction -Execute $powerShell -Argument $baseArguments
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
        -Settings $settings `
        -Force | Out-Null

    $promptAction = New-ScheduledTaskAction `
        -Execute $powerShell `
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
        -Settings $settings `
        -Force | Out-Null

    Write-Output "RECOVERY_TASKS_REGISTERED=true"
    Write-Output "STARTUP_TASK=$StartupTaskName"
    Write-Output "PROMPT_TASK=$PromptTaskName"
} catch {
    Remove-RecoveryTask -TaskName $StartupTaskName
    Remove-RecoveryTask -TaskName $PromptTaskName
    throw
}
