#requires -Version 5.1

param(
    [string]$ConfigPath = "",
    [switch]$InteractiveWorker,
    [string]$ResultPath = "",
    [int]$ProcessId = 0
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Find-LibertixAutomationControl {
    param(
        [System.Windows.Automation.AutomationElement]$WindowRoot,
        [int]$TargetProcessId,
        [string]$AutomationId
    )

    $automationIdCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
        $AutomationId
    )
    if ($WindowRoot) {
        $control = $WindowRoot.FindFirst(
            [System.Windows.Automation.TreeScope]::Descendants,
            $automationIdCondition
        )
        if ($control) {
            return [pscustomobject]@{ Element = $control; Scope = "window" }
        }
    }

    # WPF can keep Process.MainWindowHandle pointed at the outgoing navigation
    # visual while the new Page is already visible. The desktop automation tree
    # is authoritative here, but it must remain restricted to this exact PID.
    $processCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty,
        $TargetProcessId
    )
    $combinedCondition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.Condition[]]@($processCondition, $automationIdCondition)
    )
    $control = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst(
        [System.Windows.Automation.TreeScope]::Descendants,
        $combinedCondition
    )
    if ($control) {
        return [pscustomobject]@{ Element = $control; Scope = "process" }
    }
    return $null
}

function Invoke-InteractiveWorker {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes

    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ($process.MainWindowHandle -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $process.Refresh()
    }
    if ($process.MainWindowHandle -eq [IntPtr]::Zero) {
        throw "Libertix has no interactive main window."
    }

    $checkbox = $null
    $checkboxScope = "none"
    $root = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $process.Refresh()
        if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle(
                $process.MainWindowHandle
            )
        }
        $checkboxResult = Find-LibertixAutomationControl `
            -WindowRoot $root `
            -TargetProcessId $ProcessId `
            -AutomationId "WarningAcknowledgement"
        if ($checkboxResult) {
            $checkbox = $checkboxResult.Element
            $checkboxScope = $checkboxResult.Scope
        }
        if (-not $checkbox) {
            Start-Sleep -Milliseconds 200
        }
    } while (-not $checkbox -and [DateTime]::UtcNow -lt $deadline)
    if (-not $checkbox) {
        throw "The warning acknowledgement control did not become visible within 15 seconds."
    }

    $toggle = [System.Windows.Automation.TogglePattern]$checkbox.GetCurrentPattern(
        [System.Windows.Automation.TogglePattern]::Pattern
    )
    if ($toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) {
        $toggle.Toggle()
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        Start-Sleep -Milliseconds 100
        $toggle = [System.Windows.Automation.TogglePattern]$checkbox.GetCurrentPattern(
            [System.Windows.Automation.TogglePattern]::Pattern
        )
    } while (
        $toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On -and
        [DateTime]::UtcNow -lt $deadline
    )
    if ($toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) {
        throw "The warning acknowledgement did not remain selected."
    }

    $button = $null
    $buttonScope = "none"
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $buttonResult = Find-LibertixAutomationControl `
            -WindowRoot $root `
            -TargetProcessId $ProcessId `
            -AutomationId "WarningConfirmButton"
        if ($buttonResult) {
            $button = $buttonResult.Element
            $buttonScope = $buttonResult.Scope
        }
        if (-not $button -or -not $button.Current.IsEnabled) {
            Start-Sleep -Milliseconds 100
        }
    } while (
        (-not $button -or -not $button.Current.IsEnabled) -and
        [DateTime]::UtcNow -lt $deadline
    )
    if (-not $button -or -not $button.Current.IsEnabled) {
        throw "The warning confirmation button did not become enabled."
    }

    $checkbox.SetFocus()
    @(
        "ACKNOWLEDGED=True"
        "CONFIRM_ENABLED=True"
        "LIBERTIX_PROCESS_ID=$ProcessId"
        "CHECKBOX_SEARCH_SCOPE=$checkboxScope"
        "BUTTON_SEARCH_SCOPE=$buttonScope"
    ) | Set-Content -LiteralPath $ResultPath -Encoding UTF8
}

if ($InteractiveWorker) {
    try {
        Invoke-InteractiveWorker
    }
    catch {
        @(
            "ACKNOWLEDGED=False"
            "CONFIRM_ENABLED=False"
            "LIBERTIX_PROCESS_ID=$ProcessId"
            "ERROR=$($_.Exception.Message)"
        ) | Set-Content -LiteralPath $ResultPath -Encoding UTF8
        exit 1
    }
    exit 0
}

[string]$ConfigPath = $ConfigPath.Trim()
if (-not $ConfigPath) {
    throw "ConfigPath is required for the controller process."
}
$null = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$interactiveSession = Get-Process -Name explorer -ErrorAction Stop |
    Sort-Object StartTime -Descending |
    Select-Object -First 1 -ExpandProperty SessionId
$libertix = @(
    Get-Process -Name Libertix -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $interactiveSession }
)
if ($libertix.Count -ne 1) {
    throw "Expected exactly one Libertix process in the interactive session; found $($libertix.Count)."
}

$runId = [Guid]::NewGuid().ToString("N")
$taskName = "LibertixWarningAcknowledgement_$runId"
$ResultPath = Join-Path $env:WINDIR "Temp\auto-tests-warning-$runId.result"
$time = (Get-Date).AddMinutes(1).ToString("HH:mm")
$taskCommand = 'powershell.exe -NoP -EP Bypass -File "{0}" -InteractiveWorker -ResultPath "{1}" -ProcessId {2}' -f `
    $PSCommandPath, $ResultPath, $libertix[0].Id
if ($taskCommand.Length -gt 261) {
    throw "The interactive accessibility command exceeds the schtasks.exe limit."
}

try {
    $createOutput = schtasks.exe /Create /TN $taskName /TR $taskCommand /SC ONCE /ST $time /RL HIGHEST /IT /F 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create the interactive accessibility task: $($createOutput -join ' | ')"
    }
    $runOutput = schtasks.exe /Run /TN $taskName 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to run the interactive accessibility task: $($runOutput -join ' | ')"
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(25)
    while (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf)) {
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "Timed out waiting for the interactive accessibility result."
        }
        Start-Sleep -Milliseconds 200
    }
    $result = @(Get-Content -LiteralPath $ResultPath -Encoding UTF8)
    $result | Write-Output
    if ($result -notcontains "ACKNOWLEDGED=True") {
        throw "The interactive worker did not prove the warning acknowledgement."
    }
}
finally {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $null = schtasks.exe /Delete /TN $taskName /F 2>&1
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    Remove-Item -LiteralPath $ResultPath -Force -ErrorAction SilentlyContinue
}
