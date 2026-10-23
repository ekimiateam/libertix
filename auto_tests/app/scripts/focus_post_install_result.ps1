param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,
    [switch]$InteractiveWorker,
    [string]$ResultPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$script:focusDiagnostic = [ordered]@{}

function Write-AtomicJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $temporaryPath = "{0}.tmp-{1}" -f $Path, $PID
    [IO.File]::WriteAllText(
        $temporaryPath,
        ($Value | ConvertTo-Json -Depth 8 -Compress),
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

function Set-PostInstallResultFocus {
    param([Parameter(Mandatory = $true)][int]$TargetProcessId)

    $script:focusDiagnostic = [ordered]@{
        target_process_id = $TargetProcessId
        worker_process_id = $PID
        worker_session_id = (Get-Process -Id $PID).SessionId
        is_64_bit_process = [Environment]::Is64BitProcess
        windows = @()
    }
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
    if (-not ("LibertixTestKeyboard" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class LibertixTestKeyboard {
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll")] static extern IntPtr GetKeyboardLayout(uint threadId);
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr ActivateKeyboardLayout(IntPtr layout, uint flags);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)] static extern bool GetKeyboardLayoutName(StringBuilder name);
    public static string Read(IntPtr window, int expectedProcessId) {
        uint processId;
        uint thread = GetWindowThreadProcessId(window, out processId);
        if (thread == 0 || processId != expectedProcessId)
            throw new InvalidOperationException("The keyboard target window changed owner.");
        IntPtr layout = GetKeyboardLayout(thread);
        if (layout == IntPtr.Zero) throw new InvalidOperationException("The target keyboard is unavailable.");
        // Affect only this disposable worker thread, never the application or global layout.
        IntPtr previous = ActivateKeyboardLayout(layout, 0);
        if (previous == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            var name = new StringBuilder(9);
            if (!GetKeyboardLayoutName(name)) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (GetKeyboardLayout(thread) != layout)
                throw new InvalidOperationException("The target keyboard changed during verification.");
            return name.ToString();
        } finally {
            if (ActivateKeyboardLayout(previous, 0) == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
'@ -ErrorAction Stop
    }
    $process = Get-Process -Id $TargetProcessId -ErrorAction Stop
    $script:focusDiagnostic.target_process_name = $process.ProcessName
    $script:focusDiagnostic.target_session_id = $process.SessionId
    try {
        $script:focusDiagnostic.target_started_utc = $process.StartTime.ToUniversalTime().ToString('o')
    } catch {
        $script:focusDiagnostic.target_start_time_error = $_.Exception.Message
    }
    $interactiveSessionIds = @(
        Get-Process -Name explorer -ErrorAction Stop |
            ForEach-Object { [int]$_.SessionId }
    )
    if ($interactiveSessionIds -notcontains [int]$process.SessionId) {
        throw "The post-install result is not running in an interactive Explorer session."
    }

    $focusClock = [Diagnostics.Stopwatch]::StartNew()
    $visibleWindowCount = 0
    $closeButtonCount = 0
    do {
        $script:focusDiagnostic.observed_at = [DateTime]::UtcNow.ToString('o')
        $script:focusDiagnostic.windows = @()
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
            $windowDiagnostic = [ordered]@{ handle = $handle; buttons = @() }
            $script:focusDiagnostic.windows += $windowDiagnostic
            try {
                $windowDiagnostic.title = [string]$window.Current.Name
                $windowDiagnostic.class_name = [string]$window.Current.ClassName
                $windowDiagnostic.framework = [string]$window.Current.FrameworkId
                $windowDiagnostic.offscreen = [bool]$window.Current.IsOffscreen
            } catch {
                $windowDiagnostic.collection_error = $_.Exception.Message
            }
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
                $buttonTypeCondition = New-Object Windows.Automation.PropertyCondition(
                    [Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [Windows.Automation.ControlType]::Button
                )
                $buttons = $window.FindAll(
                    [Windows.Automation.TreeScope]::Descendants,
                    $buttonTypeCondition
                )
                $windowDiagnostic.button_count = $buttons.Count
                # Record only button metadata, never edit values or a full desktop tree.
                for ($buttonIndex = 0; $buttonIndex -lt [Math]::Min($buttons.Count, 20); $buttonIndex++) {
                    try {
                        $candidate = $buttons.Item($buttonIndex).Current
                        $windowDiagnostic.buttons += [ordered]@{
                            automation_id = [string]$candidate.AutomationId
                            name = [string]$candidate.Name
                            enabled = [bool]$candidate.IsEnabled
                            offscreen = [bool]$candidate.IsOffscreen
                            focused = [bool]$candidate.HasKeyboardFocus
                        }
                    } catch {
                        $windowDiagnostic.buttons += [ordered]@{ collection_error = $_.Exception.Message }
                    }
                }
                continue
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
                focused_control = [string]$button.Current.AutomationId
                active_keyboard_identifier = [LibertixTestKeyboard]::Read([IntPtr]$handle, $TargetProcessId)
                ui_culture = [string](Get-UICulture).Name
                session_id = [int]$process.SessionId
            }
        }
        Start-Sleep -Milliseconds 100
    } while ($focusClock.Elapsed.TotalSeconds -lt 10)

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
                focus_diagnostic = $script:focusDiagnostic
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
$workerResultPath = Join-Path $automationRoot ("p-" + $shortFocusId + ".result.json")
Copy-Item -LiteralPath $PSCommandPath -Destination $workerScriptPath -Force
Write-AtomicJson -Path $workerConfigPath -Value ([ordered]@{
        process_id = $targetProcessId
        result_path = $workerResultPath
    })
$taskName = "LibertixResultFocus_{0}" -f $shortFocusId
$taskCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass ' +
    '-File "{0}" -ConfigPath "{1}" -InteractiveWorker' -f `
    $workerScriptPath, $workerConfigPath
$startTime = (Get-Date).AddMinutes(2).ToString("HH:mm")
$workerResult = $null

try {
    $createResult = Invoke-ScheduledTaskCommand -Arguments @(
        "/Create", "/TN", $taskName, "/TR", $taskCommand, "/SC", "ONCE",
        "/ST", $startTime, "/RL", "HIGHEST", "/IT", "/F"
    )
    if ($createResult.ExitCode -ne 0) {
        throw "Failed to create the interactive result focus task: $($createResult.Output -join ' | ')"
    }
    $runResult = Invoke-ScheduledTaskCommand -Arguments @("/Run", "/TN", $taskName)
    if ($runResult.ExitCode -ne 0) {
        throw "Failed to start the interactive result focus task: $($runResult.Output -join ' | ')"
    }

    for ($attempt = 0; $attempt -lt 450 -and $null -eq $workerResult; $attempt++) {
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
        $taskState = (Invoke-ScheduledTaskCommand -Arguments @(
                "/Query", "/TN", $taskName, "/V", "/FO", "LIST"
            )).Output
        throw (
            "The interactive result focus task did not report a result within 45 seconds; task=" +
            ($taskState -join " | ")
        )
    }
    if ([string]$workerResult.status -ne "ok") {
        Write-Output ("FOCUS_FAILURE_JSON=" + ($workerResult | ConvertTo-Json -Depth 8 -Compress))
        Write-Output ("FOCUS_FAILURE_PATH=" + $workerResultPath)
        throw "The interactive result focus worker failed: $([string]$workerResult.error)"
    }
    Write-Output ("WINDOW_HANDLE={0}" -f [int64]$workerResult.window_handle)
    Write-Output ("WINDOW_TITLE={0}" -f [string]$workerResult.window_title)
    Write-Output ("FOCUSED_CONTROL={0}" -f [string]$workerResult.focused_control)
    Write-Output ("ACTIVE_KEYBOARD_IDENTIFIER={0}" -f [string]$workerResult.active_keyboard_identifier)
    Write-Output ("INTERACTIVE_UI_CULTURE={0}" -f [string]$workerResult.ui_culture)
    Write-Output ("INTERACTIVE_SESSION_ID={0}" -f [int]$workerResult.session_id)
    Write-Output "RESULT=OK"
} finally {
    $null = Invoke-ScheduledTaskCommand -Arguments @("/Delete", "/TN", $taskName, "/F")
    Remove-Item -LiteralPath $workerScriptPath, $workerConfigPath `
        -Force -ErrorAction SilentlyContinue
    if ($null -ne $workerResult -and [string]$workerResult.status -eq 'ok') {
        Remove-Item -LiteralPath $workerResultPath -Force -ErrorAction SilentlyContinue
    }
}
