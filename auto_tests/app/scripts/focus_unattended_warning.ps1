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

function Set-LibertixControlFocus {
    param(
        [Parameter(Mandatory = $true)][int]$TargetProcessId,
        [Parameter(Mandatory = $true)][string]$TargetAutomationId,
        [string]$RequiredSiblingAutomationId = ""
    )

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

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    $visibleWindowCount = 0
    $matchingControlCount = 0
    $targetFocused = $false
    $visibleTitles = @()
    do {
        $visibleWindowCount = 0
        $matchingControlCount = 0
        $targetFocused = $false
        $visibleTitles = @()
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
            if ($window.Current.IsOffscreen -or
                [int64]$window.Current.NativeWindowHandle -eq 0) {
                continue
            }
            $visibleWindowCount++
            $visibleTitles += [string]$window.Current.Name
            $targetCondition = New-Object Windows.Automation.PropertyCondition(
                [Windows.Automation.AutomationElement]::AutomationIdProperty,
                $TargetAutomationId
            )
            $target = $window.FindFirst(
                [Windows.Automation.TreeScope]::Descendants,
                $targetCondition
            )
            if ($null -eq $target) {
                continue
            }
            if (-not [string]::IsNullOrWhiteSpace($RequiredSiblingAutomationId)) {
                $siblingCondition = New-Object Windows.Automation.PropertyCondition(
                    [Windows.Automation.AutomationElement]::AutomationIdProperty,
                    $RequiredSiblingAutomationId
                )
                $sibling = $window.FindFirst(
                    [Windows.Automation.TreeScope]::Descendants,
                    $siblingCondition
                )
                if ($null -eq $sibling) {
                    continue
                }
            }
            $matchingControlCount++
            $window.SetFocus()
            $target.SetFocus()
            Start-Sleep -Milliseconds 100
            $targetFocused = [bool]$target.Current.HasKeyboardFocus
            if (-not $targetFocused) {
                continue
            }
            return [ordered]@{
                status = "ok"
                window_handle = [int64]$window.Current.NativeWindowHandle
                window_title = [string]$window.Current.Name
                focused_control = $TargetAutomationId
            }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)

    throw (
        "The requested visible Libertix control could not receive keyboard focus: " +
        "automationId=$TargetAutomationId visibleWindows=$visibleWindowCount " +
        "matchingControls=$matchingControlCount focused=$targetFocused " +
        "titles=$($visibleTitles -join '|')."
    )
}

function Resolve-PreferredPathUiProcess {
    param([Parameter(Mandatory = $true)][string]$ExpectedPhase)

    $recoveryRoot = Join-Path $env:ProgramData "Libertix\UefiRecovery"
    $deadline = [DateTime]::UtcNow.AddSeconds(150)
    do {
        $statePath = Get-ChildItem `
            -LiteralPath $recoveryRoot `
            -Filter "state.json" `
            -Recurse `
            -File `
            -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1 -ExpandProperty FullName
        if ($statePath) {
            $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 |
                ConvertFrom-Json -ErrorAction Stop
            $phase = [string]$state.Phase
            if ($phase -eq "PreferredPathPreparationFailed") {
                throw "Preferred-path preparation reached a terminal failure."
            }
            if ($phase -eq $ExpectedPhase) {
                $expectedExe = [IO.Path]::GetFullPath(
                    (Join-Path ([string]$state.PayloadRoot) "Libertix.exe")
                )
                $processMatches = @(
                    Get-CimInstance -ClassName Win32_Process -Filter "Name='Libertix.exe'" |
                        Where-Object {
                            $_.ExecutablePath -and
                            [IO.Path]::GetFullPath([string]$_.ExecutablePath) -eq $expectedExe
                        }
                )
                if ($processMatches.Count -eq 1) {
                    return [pscustomobject]@{
                        ProcessId = [int]$processMatches[0].ProcessId
                        StatePath = [string]$statePath
                        Phase = $phase
                    }
                }
                if ($processMatches.Count -gt 1) {
                    throw "More than one cached Libertix fallback UI process is running."
                }
            }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "Timed out waiting for preferred-path phase '$ExpectedPhase' and its Libertix UI."
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
    ConvertFrom-Json -ErrorAction Stop
$mode = if ($config.PSObject.Properties.Name -contains "mode") {
    [string]$config.mode
} else {
    "unattended-warning"
}
$statePath = ""
$statePhase = ""
switch ($mode) {
    "unattended-warning" {
        $targetProcessId = [int]$config.process_id
        $targetAutomationId = "UnattendedWarningNoButton"
        $requiredSiblingAutomationId = "UnattendedWarningYesButton"
    }
    "preferred-accept" {
        $resolved = Resolve-PreferredPathUiProcess -ExpectedPhase "PreferredPathPrompted"
        $targetProcessId = [int]$resolved.ProcessId
        $targetAutomationId = "UefiPreferredPathAcceptButton"
        $requiredSiblingAutomationId = ""
        $statePath = [string]$resolved.StatePath
        $statePhase = [string]$resolved.Phase
    }
    "preferred-reboot" {
        $resolved = Resolve-PreferredPathUiProcess -ExpectedPhase "AwaitingPreferredPathReboot"
        $targetProcessId = [int]$resolved.ProcessId
        $targetAutomationId = "UefiPreferredPathRebootButton"
        $requiredSiblingAutomationId = ""
        $statePath = [string]$resolved.StatePath
        $statePhase = [string]$resolved.Phase
    }
    default {
        throw "The Libertix UI focus mode is unsupported."
    }
}
if ($targetProcessId -le 0) {
    throw "The Libertix process ID is invalid."
}

if ($InteractiveWorker) {
    if ([string]::IsNullOrWhiteSpace($ResultPath) -and
        $config.PSObject.Properties.Name -contains "result_path") {
        $ResultPath = [string]$config.result_path
    }
    if ([string]::IsNullOrWhiteSpace($ResultPath)) {
        throw "The interactive focus result path is required."
    }
    try {
        $workerResult = Set-LibertixControlFocus `
            -TargetProcessId $targetProcessId `
            -TargetAutomationId ([string]$config.target_automation_id) `
            -RequiredSiblingAutomationId ([string]$config.required_sibling_automation_id)
        Write-AtomicJson -Path $ResultPath -Value $workerResult
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
$workerScriptPath = Join-Path $automationRoot ("f-" + $shortFocusId + ".ps1")
$workerConfigPath = Join-Path $automationRoot ("f-" + $shortFocusId + ".json")
$workerResultPath = Join-Path $automationRoot ("f-" + $shortFocusId + ".result")
Copy-Item -LiteralPath $PSCommandPath -Destination $workerScriptPath -Force
Write-AtomicJson -Path $workerConfigPath -Value ([ordered]@{
        process_id = $targetProcessId
        result_path = $workerResultPath
        target_automation_id = $targetAutomationId
        required_sibling_automation_id = $requiredSiblingAutomationId
    })
$taskName = "LibertixAutoFocus_{0}" -f $focusId.Substring(0, 12)
$taskCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass ' +
    '-File "{0}" -ConfigPath "{1}" -InteractiveWorker' -f `
    $workerScriptPath, $workerConfigPath
$startTime = (Get-Date).AddMinutes(2).ToString("HH:mm")

try {
    $createResult = Invoke-ScheduledTaskCommand -Arguments @(
        "/Create", "/TN", $taskName, "/TR", $taskCommand, "/SC", "ONCE",
        "/ST", $startTime, "/RL", "HIGHEST", "/IT", "/F"
    )
    if ($createResult.ExitCode -ne 0) {
        throw "Failed to create the interactive focus task: $($createResult.Output -join ' | ')"
    }
    $runResult = Invoke-ScheduledTaskCommand -Arguments @("/Run", "/TN", $taskName)
    if ($runResult.ExitCode -ne 0) {
        throw "Failed to start the interactive focus task: $($runResult.Output -join ' | ')"
    }

    $workerResult = $null
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
            "The interactive focus task did not report a result within 45 seconds; task=" +
            ($taskState -join " | ")
        )
    }
    if ([string]$workerResult.status -ne "ok") {
        throw "The interactive focus worker failed: $([string]$workerResult.error)"
    }
    Write-Output ("WINDOW_HANDLE={0}" -f [int64]$workerResult.window_handle)
    Write-Output ("WINDOW_TITLE={0}" -f [string]$workerResult.window_title)
    Write-Output ("FOCUSED_CONTROL={0}" -f [string]$workerResult.focused_control)
    Write-Output ("PROCESS_ID={0}" -f $targetProcessId)
    if (-not [string]::IsNullOrWhiteSpace($statePath)) {
        Write-Output ("STATE_PATH={0}" -f $statePath)
        Write-Output ("STATE_PHASE={0}" -f $statePhase)
    }
    Write-Output "RESULT=OK"
} finally {
    $null = Invoke-ScheduledTaskCommand -Arguments @("/Delete", "/TN", $taskName, "/F")
    Remove-Item -LiteralPath $workerScriptPath, $workerConfigPath, $workerResultPath `
        -Force -ErrorAction SilentlyContinue
}
