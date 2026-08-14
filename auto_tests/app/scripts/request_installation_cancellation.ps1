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
        ($Value | ConvertTo-Json -Depth 4 -Compress),
        [Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Get-AutomationElementById {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Root,
        [Parameter(Mandatory = $true)]
        [string]$AutomationId
    )

    $condition = New-Object Windows.Automation.PropertyCondition(
        [Windows.Automation.AutomationElement]::AutomationIdProperty,
        $AutomationId
    )
    return $Root.FindFirst(
        [Windows.Automation.TreeScope]::Descendants,
        $condition
    )
}

function Invoke-AutomationButton {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Button
    )

    $pattern = $Button.GetCurrentPattern(
        [Windows.Automation.InvokePattern]::Pattern
    )
    $pattern.Invoke()
}

function Request-InstallationCancellation {
    param([Parameter(Mandatory = $true)][int]$TargetProcessId)

    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
    $process = Get-Process -Id $TargetProcessId -ErrorAction Stop
    $interactiveSessionIds = @(
        Get-Process -Name explorer -ErrorAction Stop |
            ForEach-Object { [int]$_.SessionId }
    )
    if ($interactiveSessionIds -notcontains [int]$process.SessionId) {
        throw "Libertix is not running in an interactive Explorer session."
    }

    $processCondition = New-Object Windows.Automation.PropertyCondition(
        [Windows.Automation.AutomationElement]::ProcessIdProperty,
        $TargetProcessId
    )
    $cancelDeadline = [DateTime]::UtcNow.AddSeconds(15)
    $cancelInvoked = $false
    $mainWindowHandle = 0
    do {
        $windows = [Windows.Automation.AutomationElement]::RootElement.FindAll(
            [Windows.Automation.TreeScope]::Children,
            $processCondition
        )
        for ($index = 0; $index -lt $windows.Count; $index++) {
            $window = $windows.Item($index)
            if ($window.Current.IsOffscreen -or
                [int64]$window.Current.NativeWindowHandle -eq 0) {
                continue
            }
            $cancelButton = Get-AutomationElementById `
                -Root $window `
                -AutomationId "ApplyChangesCancelButton"
            if ($null -eq $cancelButton -or
                -not $cancelButton.Current.IsEnabled -or
                $cancelButton.Current.IsOffscreen) {
                continue
            }
            $window.SetFocus()
            $cancelButton.SetFocus()
            Invoke-AutomationButton -Button $cancelButton
            $mainWindowHandle = [int64]$window.Current.NativeWindowHandle
            $cancelInvoked = $true
            break
        }
        if (-not $cancelInvoked) { Start-Sleep -Milliseconds 100 }
    } while (-not $cancelInvoked -and [DateTime]::UtcNow -lt $cancelDeadline)
    if (-not $cancelInvoked) {
        throw "The visible enabled Libertix cancellation button was not found."
    }

    $confirmationDeadline = [DateTime]::UtcNow.AddSeconds(10)
    $confirmationInvoked = $false
    $confirmationWindowHandle = 0
    do {
        $windows = [Windows.Automation.AutomationElement]::RootElement.FindAll(
            [Windows.Automation.TreeScope]::Children,
            $processCondition
        )
        for ($index = 0; $index -lt $windows.Count; $index++) {
            $window = $windows.Item($index)
            if ($window.Current.IsOffscreen -or
                [int64]$window.Current.NativeWindowHandle -eq 0) {
                continue
            }
            $yesButton = Get-AutomationElementById `
                -Root $window `
                -AutomationId "LocalizedConfirmationYesButton"
            $noButton = Get-AutomationElementById `
                -Root $window `
                -AutomationId "LocalizedConfirmationNoButton"
            if ($null -eq $yesButton -or $null -eq $noButton -or
                -not $yesButton.Current.IsEnabled -or
                $yesButton.Current.IsOffscreen) {
                continue
            }
            $window.SetFocus()
            $yesButton.SetFocus()
            Invoke-AutomationButton -Button $yesButton
            $confirmationWindowHandle = [int64]$window.Current.NativeWindowHandle
            $confirmationInvoked = $true
            break
        }
        if (-not $confirmationInvoked) { Start-Sleep -Milliseconds 100 }
    } while (-not $confirmationInvoked -and [DateTime]::UtcNow -lt $confirmationDeadline)
    if (-not $confirmationInvoked) {
        throw "The Libertix cancellation confirmation could not be accepted."
    }

    return [ordered]@{
        status = "ok"
        main_window_handle = $mainWindowHandle
        confirmation_window_handle = $confirmationWindowHandle
        cancellation_control = "ApplyChangesCancelButton"
        confirmation_control = "LocalizedConfirmationYesButton"
    }
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
    ConvertFrom-Json -ErrorAction Stop
$targetProcessId = [int]$config.process_id
if ($targetProcessId -le 0) {
    throw "The Libertix process ID is invalid."
}

if ($InteractiveWorker) {
    if ([string]::IsNullOrWhiteSpace($ResultPath) -and
        $config.PSObject.Properties.Name -contains "result_path") {
        $ResultPath = [string]$config.result_path
    }
    if ([string]::IsNullOrWhiteSpace($ResultPath)) {
        throw "The interactive cancellation result path is required."
    }
    try {
        Write-AtomicJson -Path $ResultPath -Value (
            Request-InstallationCancellation -TargetProcessId $targetProcessId
        )
        exit 0
    } catch {
        Write-AtomicJson -Path $ResultPath -Value ([ordered]@{
                status = "error"
                error = $_.Exception.Message
                exception_type = $_.Exception.GetType().FullName
                script_stack = $_.ScriptStackTrace
            })
        exit 1
    }
}

$automationRoot = Join-Path $env:ProgramData "Libertix\Automation"
New-Item -ItemType Directory -Path $automationRoot -Force | Out-Null
$runId = [Guid]::NewGuid().ToString("N").Substring(0, 12)
$workerScriptPath = Join-Path $automationRoot ("c-" + $runId + ".ps1")
$workerConfigPath = Join-Path $automationRoot ("c-" + $runId + ".json")
$workerResultPath = Join-Path $automationRoot ("c-" + $runId + ".result")
Copy-Item -LiteralPath $PSCommandPath -Destination $workerScriptPath -Force
Write-AtomicJson -Path $workerConfigPath -Value ([ordered]@{
        process_id = $targetProcessId
        result_path = $workerResultPath
    })
$taskName = "LibertixCancel_{0}" -f $runId
$taskCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass ' +
    '-File "{0}" -ConfigPath "{1}" -InteractiveWorker' -f `
    $workerScriptPath, $workerConfigPath
$startTime = (Get-Date).AddMinutes(1).ToString("HH:mm")

try {
    $createOutput = schtasks.exe /Create /TN $taskName /TR $taskCommand /SC ONCE `
        /ST $startTime /RL HIGHEST /IT /F 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create the interactive cancellation task: $($createOutput -join ' | ')"
    }
    $runOutput = schtasks.exe /Run /TN $taskName 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to start the interactive cancellation task: $($runOutput -join ' | ')"
    }

    $workerResult = $null
    for ($attempt = 0; $attempt -lt 300 -and $null -eq $workerResult; $attempt++) {
        Start-Sleep -Milliseconds 100
        if (Test-Path -LiteralPath $workerResultPath -PathType Leaf) {
            try {
                $workerResult = Get-Content -LiteralPath $workerResultPath -Raw -Encoding UTF8 |
                    ConvertFrom-Json -ErrorAction Stop
            } catch {
                $workerResult = $null
            }
        }
    }
    if ($null -eq $workerResult) {
        throw "The interactive cancellation task did not report a result."
    }
    if ([string]$workerResult.status -ne "ok") {
        throw "The interactive cancellation worker failed: $([string]$workerResult.error)"
    }
    Write-Output ("MAIN_WINDOW_HANDLE={0}" -f [int64]$workerResult.main_window_handle)
    Write-Output (
        "CONFIRMATION_WINDOW_HANDLE={0}" -f `
        [int64]$workerResult.confirmation_window_handle
    )
    Write-Output ("CANCELLATION_CONTROL={0}" -f [string]$workerResult.cancellation_control)
    Write-Output ("CONFIRMATION_CONTROL={0}" -f [string]$workerResult.confirmation_control)
    Write-Output "RESULT=OK"
} finally {
    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        schtasks.exe /Delete /TN $taskName /F 2>&1 | Out-Null
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }
    Remove-Item -LiteralPath $workerScriptPath, $workerConfigPath, $workerResultPath `
        -Force -ErrorAction SilentlyContinue
}
