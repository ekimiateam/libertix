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

function Set-PostInstallResultFocus {
    param([Parameter(Mandatory = $true)][int]$TargetProcessId)

    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
    $process = Get-Process -Id $TargetProcessId -ErrorAction Stop
    $interactiveSessionIds = @(
        Get-Process -Name explorer -ErrorAction Stop |
            ForEach-Object { [int]$_.SessionId }
    )
    if ($interactiveSessionIds -notcontains [int]$process.SessionId) {
        throw "The post-install result is not running in an interactive Explorer session."
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    $visibleWindowCount = 0
    $closeButtonCount = 0
    do {
        $visibleWindowCount = 0
        $closeButtonCount = 0
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
            $handle = [int64]$window.Current.NativeWindowHandle
            if ($handle -eq 0 -or $window.Current.IsOffscreen) { continue }
            $visibleWindowCount++
            $buttonCondition = New-Object Windows.Automation.PropertyCondition(
                [Windows.Automation.AutomationElement]::AutomationIdProperty,
                "LibertixPostInstallCloseButton"
            )
            $button = $window.FindFirst(
                [Windows.Automation.TreeScope]::Descendants,
                $buttonCondition
            )
            if ($null -eq $button) {
                # Older deployed payloads predate the explicit automation id.
                # Their success dialog has exactly one button, so that unique
                # control is still a deterministic close target.
                $buttonTypeCondition = New-Object Windows.Automation.PropertyCondition(
                    [Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [Windows.Automation.ControlType]::Button
                )
                $buttons = $window.FindAll(
                    [Windows.Automation.TreeScope]::Descendants,
                    $buttonTypeCondition
                )
                if ($buttons.Count -ne 1) { continue }
                $button = $buttons.Item(0)
            }
            $closeButtonCount++
            $window.SetFocus()
            $button.SetFocus()
            Start-Sleep -Milliseconds 100
            if (-not [bool]$button.Current.HasKeyboardFocus) { continue }
            return [ordered]@{
                status = "ok"
                window_handle = $handle
                window_title = [string]$window.Current.Name
                focused_control = "LibertixPostInstallCloseButton"
            }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)

    throw (
        "The visible post-install result could not receive keyboard focus: " +
        "visibleWindows=$visibleWindowCount closeButtons=$closeButtonCount."
    )
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
    ConvertFrom-Json -ErrorAction Stop
$targetProcessId = [int]$config.process_id
if ($targetProcessId -le 0) { throw "The post-install result process ID is invalid." }

if ($InteractiveWorker) {
    if ([string]::IsNullOrWhiteSpace($ResultPath) -and
        $config.PSObject.Properties.Name -contains "result_path") {
        $ResultPath = [string]$config.result_path
    }
    if ([string]::IsNullOrWhiteSpace($ResultPath)) {
        throw "The interactive focus result path is required."
    }
    try {
        Write-AtomicJson -Path $ResultPath -Value (
            Set-PostInstallResultFocus -TargetProcessId $targetProcessId
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
$focusId = [Guid]::NewGuid().ToString("N")
$shortFocusId = $focusId.Substring(0, 12)
$workerScriptPath = Join-Path $automationRoot ("p-" + $shortFocusId + ".ps1")
$workerConfigPath = Join-Path $automationRoot ("p-" + $shortFocusId + ".json")
$workerResultPath = Join-Path $automationRoot ("p-" + $shortFocusId + ".result")
Copy-Item -LiteralPath $PSCommandPath -Destination $workerScriptPath -Force
Write-AtomicJson -Path $workerConfigPath -Value ([ordered]@{
        process_id = $targetProcessId
        result_path = $workerResultPath
    })
$taskName = "LibertixResultFocus_{0}" -f $shortFocusId
$taskCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass ' +
    '-File "{0}" -ConfigPath "{1}" -InteractiveWorker' -f `
    $workerScriptPath, $workerConfigPath
$startTime = (Get-Date).AddMinutes(1).ToString("HH:mm")

try {
    $createOutput = schtasks.exe /Create /TN $taskName /TR $taskCommand /SC ONCE `
        /ST $startTime /RL HIGHEST /IT /F 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create the interactive result focus task: $($createOutput -join ' | ')"
    }
    $runOutput = schtasks.exe /Run /TN $taskName 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to start the interactive result focus task: $($runOutput -join ' | ')"
    }

    $workerResult = $null
    for ($attempt = 0; $attempt -lt 150 -and $null -eq $workerResult; $attempt++) {
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
        throw "The interactive result focus task did not report a result."
    }
    if ([string]$workerResult.status -ne "ok") {
        throw "The interactive result focus worker failed: $([string]$workerResult.error)"
    }
    Write-Output ("WINDOW_HANDLE={0}" -f [int64]$workerResult.window_handle)
    Write-Output ("WINDOW_TITLE={0}" -f [string]$workerResult.window_title)
    Write-Output ("FOCUSED_CONTROL={0}" -f [string]$workerResult.focused_control)
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
