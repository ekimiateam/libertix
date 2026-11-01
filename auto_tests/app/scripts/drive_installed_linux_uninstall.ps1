param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,
    [switch]$InteractiveWorker,
    [string]$ResultPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-AtomicJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )
    $temporaryPath = "{0}.tmp-{1}" -f $Path, $PID
    [IO.File]::WriteAllText(
        $temporaryPath,
        ($Value | ConvertTo-Json -Depth 5 -Compress),
        [Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Invoke-ScheduledTaskCommand {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $previousPreference = $ErrorActionPreference
    $output = @()
    $exitCode = -1
    $ErrorActionPreference = "Continue"
    try {
        $output = @(& "$env:SystemRoot\System32\schtasks.exe" @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

function Find-ProcessWindow {
    param([Parameter(Mandatory = $true)][int]$TargetProcessId)
    $condition = New-Object Windows.Automation.PropertyCondition(
        [Windows.Automation.AutomationElement]::ProcessIdProperty,
        $TargetProcessId
    )
    $windows = [Windows.Automation.AutomationElement]::RootElement.FindAll(
        [Windows.Automation.TreeScope]::Children,
        $condition
    )
    for ($index = 0; $index -lt $windows.Count; $index++) {
        $window = $windows.Item($index)
        if ([int64]$window.Current.NativeWindowHandle -ne 0 -and -not $window.Current.IsOffscreen) {
            return $window
        }
    }
    return $null
}

function Find-Control {
    param(
        [Parameter(Mandatory = $true)]$Window,
        [Parameter(Mandatory = $true)][string]$AutomationId
    )
    $condition = New-Object Windows.Automation.PropertyCondition(
        [Windows.Automation.AutomationElement]::AutomationIdProperty,
        $AutomationId
    )
    return $Window.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
}

function Wait-Control {
    param(
        [Parameter(Mandatory = $true)][int]$TargetProcessId,
        [Parameter(Mandatory = $true)][string]$AutomationId,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $processCondition = New-Object Windows.Automation.PropertyCondition(
            [Windows.Automation.AutomationElement]::ProcessIdProperty,
            $TargetProcessId
        )
        $windows = [Windows.Automation.AutomationElement]::RootElement.FindAll(
            [Windows.Automation.TreeScope]::Children,
            $processCondition
        )
        for ($index = 0; $index -lt $windows.Count; $index++) {
            $window = $windows.Item($index)
            if ([int64]$window.Current.NativeWindowHandle -eq 0 -or $window.Current.IsOffscreen) {
                continue
            }
            $control = Find-Control -Window $window -AutomationId $AutomationId
            if ($null -ne $control -and -not $control.Current.IsOffscreen -and $control.Current.IsEnabled) {
                return [pscustomobject]@{ Window = $window; Control = $control }
            }
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for visible enabled control '$AutomationId'."
}

function Invoke-Control {
    param([Parameter(Mandatory = $true)]$Control)
    $pattern = $Control.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)
    if ($null -eq $pattern) { throw "The requested control does not expose InvokePattern." }
    $pattern.Invoke()
}

function Get-ProgressValue {
    param([Parameter(Mandatory = $true)]$Window)
    $progress = Find-Control -Window $Window -AutomationId "UninstallLinuxProgressBar"
    if ($null -eq $progress) { return -1 }
    $pattern = $progress.GetCurrentPattern([Windows.Automation.RangeValuePattern]::Pattern)
    if ($null -eq $pattern) { return -1 }
    return [int][Math]::Round($pattern.Current.Value)
}

function Invoke-UninstallUiAction {
    param(
        [Parameter(Mandatory = $true)][int]$TargetProcessId,
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
    $process = Get-Process -Id $TargetProcessId -ErrorAction Stop
    $interactiveSessions = @(Get-Process -Name explorer -ErrorAction Stop |
        ForEach-Object { [int]$_.SessionId })
    if ($interactiveSessions -notcontains [int]$process.SessionId) {
        throw "Libertix is not running in an interactive Explorer session."
    }

    if ($Action -eq "inspect") {
        $language = Wait-Control $TargetProcessId "LanguageComboBox" 20
        $uninstall = Wait-Control $TargetProcessId "UninstallLinuxButton" 20
        return [ordered]@{
            status = "ok"; action = $Action; session_id = [int]$process.SessionId
            window_handle = [int64]$language.Window.Current.NativeWindowHandle
            language = [string]$language.Control.Current.Name
            uninstall_caption = [string]$uninstall.Control.Current.Name
        }
    }

    if ($Action -eq "request") {
        $uninstall = Wait-Control $TargetProcessId "UninstallLinuxButton" 20
        Invoke-Control $uninstall.Control
        $confirmation = Wait-Control $TargetProcessId "LocalizedConfirmationYesButton" 20
        return [ordered]@{
            status = "ok"; action = $Action; session_id = [int]$process.SessionId
            window_handle = [int64]$confirmation.Window.Current.NativeWindowHandle
            focused_control = "LocalizedConfirmationYesButton"
            confirmation_caption = [string]$confirmation.Control.Current.Name
        }
    }

    if ($Action -eq "confirm") {
        $confirmation = Wait-Control $TargetProcessId "LocalizedConfirmationYesButton" 20
        Invoke-Control $confirmation.Control
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        do {
            $window = Find-ProcessWindow -TargetProcessId $TargetProcessId
            if ($null -ne $window) {
                $retry = Find-Control -Window $window -AutomationId "UninstallLinuxRetryButton"
                if ($null -ne $retry -and -not $retry.Current.IsOffscreen) {
                    throw "Libertix exposed the uninstall retry control after a recovery failure."
                }
                $done = Find-Control -Window $window -AutomationId "UninstallLinuxDoneButton"
                if ($null -ne $done -and -not $done.Current.IsOffscreen -and $done.Current.IsEnabled) {
                    $progress = Get-ProgressValue -Window $window
                    if ($progress -ne 100) {
                        throw "Libertix exposed completion with progress=$progress instead of 100."
                    }
                    return [ordered]@{
                        status = "ok"; action = $Action; session_id = [int]$process.SessionId
                        window_handle = [int64]$window.Current.NativeWindowHandle
                        focused_control = "UninstallLinuxDoneButton"; progress = $progress
                    }
                }
            }
            Start-Sleep -Milliseconds 500
        } while ([DateTime]::UtcNow -lt $deadline)
        throw "The Libertix uninstall UI did not reach its verified completion state."
    }

    if ($Action -eq "complete") {
        $done = Wait-Control $TargetProcessId "UninstallLinuxDoneButton" 20
        Invoke-Control $done.Control
        $start = Wait-Control $TargetProcessId "StartInstallationButton" 20
        $language = Wait-Control $TargetProcessId "LanguageComboBox" 20
        $remainingUninstall = Find-Control -Window $start.Window -AutomationId "UninstallLinuxButton"
        if ($null -ne $remainingUninstall -and -not $remainingUninstall.Current.IsOffscreen) {
            throw "The installed-Linux action remained visible after verified rollback."
        }
        return [ordered]@{
            status = "ok"; action = $Action; session_id = [int]$process.SessionId
            window_handle = [int64]$start.Window.Current.NativeWindowHandle
            focused_control = "StartInstallationButton"
            language = [string]$language.Control.Current.Name
        }
    }

    throw "Unsupported uninstall UI action '$Action'."
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
    ConvertFrom-Json -ErrorAction Stop
$targetProcessId = [int]$config.process_id
$action = [string]$config.action
$timeoutSeconds = if ($config.PSObject.Properties.Name -contains "timeout_seconds") {
    [int]$config.timeout_seconds
} else { 900 }
if ($targetProcessId -le 0) { throw "The Libertix process ID is invalid." }

if ($InteractiveWorker) {
    if ([string]::IsNullOrWhiteSpace($ResultPath) -and
        $config.PSObject.Properties.Name -contains "result_path") {
        $ResultPath = [string]$config.result_path
    }
    if ([string]::IsNullOrWhiteSpace($ResultPath)) { throw "Worker result path is required." }
    try {
        Write-AtomicJson $ResultPath (
            Invoke-UninstallUiAction $targetProcessId $action $timeoutSeconds
        )
        exit 0
    } catch {
        Write-AtomicJson $ResultPath ([ordered]@{
            status = "error"; action = $action; error = $_.Exception.Message
            exception_type = $_.Exception.GetType().FullName; script_stack = $_.ScriptStackTrace
        })
        exit 1
    }
}

$automationRoot = Join-Path $env:ProgramData "Libertix\Automation"
New-Item -ItemType Directory -Path $automationRoot -Force | Out-Null
$operationId = [Guid]::NewGuid().ToString("N").Substring(0, 12)
$workerScriptPath = Join-Path $automationRoot ("u-" + $operationId + ".ps1")
$workerConfigPath = Join-Path $automationRoot ("u-" + $operationId + ".json")
$workerResultPath = Join-Path $automationRoot ("u-" + $operationId + ".result")
Copy-Item -LiteralPath $PSCommandPath -Destination $workerScriptPath -Force
Write-AtomicJson $workerConfigPath ([ordered]@{
    process_id = $targetProcessId; action = $action
    timeout_seconds = $timeoutSeconds; result_path = $workerResultPath
})
$taskName = "LibertixUninstallUi_{0}" -f $operationId
$taskCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass ' +
    '-File "{0}" -ConfigPath "{1}" -InteractiveWorker' -f `
    $workerScriptPath, $workerConfigPath
$startTime = (Get-Date).AddMinutes(2).ToString("HH:mm")

try {
    $created = Invoke-ScheduledTaskCommand @(
        "/Create", "/TN", $taskName, "/TR", $taskCommand, "/SC", "ONCE",
        "/ST", $startTime, "/RL", "HIGHEST", "/IT", "/F"
    )
    if ($created.ExitCode -ne 0) {
        throw "Failed to create interactive uninstall UI task: $($created.Output -join ' | ')"
    }
    $started = Invoke-ScheduledTaskCommand @("/Run", "/TN", $taskName)
    if ($started.ExitCode -ne 0) {
        throw "Failed to start interactive uninstall UI task: $($started.Output -join ' | ')"
    }
    $workerResult = $null
    $deadline = [DateTime]::UtcNow.AddSeconds($timeoutSeconds + 60)
    do {
        Start-Sleep -Milliseconds 200
        if (Test-Path -LiteralPath $workerResultPath -PathType Leaf) {
            try {
                $workerResult = Get-Content -LiteralPath $workerResultPath -Raw -Encoding UTF8 |
                    ConvertFrom-Json -ErrorAction Stop
            } catch { $workerResult = $null }
        }
    } while ($null -eq $workerResult -and [DateTime]::UtcNow -lt $deadline)
    if ($null -eq $workerResult) { throw "Interactive uninstall UI task timed out." }
    if ([string]$workerResult.status -ne "ok") {
        throw "Interactive uninstall UI worker failed: $([string]$workerResult.error)"
    }
    Write-Output ("ACTION={0}" -f [string]$workerResult.action)
    Write-Output ("WINDOW_HANDLE={0}" -f [int64]$workerResult.window_handle)
    Write-Output ("SESSION_ID={0}" -f [int]$workerResult.session_id)
    foreach ($property in @("language", "uninstall_caption", "confirmation_caption", "focused_control", "progress")) {
        if ($workerResult.PSObject.Properties.Name -contains $property) {
            Write-Output ("{0}={1}" -f $property.ToUpperInvariant(), [string]$workerResult.$property)
        }
    }
    Write-Output "RESULT=OK"
} finally {
    $null = Invoke-ScheduledTaskCommand @("/Delete", "/TN", $taskName, "/F")
    Remove-Item -LiteralPath $workerScriptPath, $workerConfigPath, $workerResultPath `
        -Force -ErrorAction SilentlyContinue
}
