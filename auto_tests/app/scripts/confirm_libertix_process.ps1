param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Add-Type -AssemblyName UIAutomationClient

function Test-VisibleMainWindow {
    param([System.Diagnostics.Process]$Process)

    if ($Process.MainWindowHandle -eq [IntPtr]::Zero -or
        $Process.MainWindowTitle -ne "Libertix") {
        return $false
    }
    $element = [Windows.Automation.AutomationElement]::FromHandle(
        $Process.MainWindowHandle)
    if ($null -eq $element -or $element.Current.IsOffscreen) {
        return $false
    }
    $bounds = $element.Current.BoundingRectangle
    return $bounds.Width -ge 100 -and $bounds.Height -ge 100
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
$executable = [IO.Path]::GetFullPath([string]$config.executable)
$taskName = [string]$config.task_name
$interactiveSession = Get-Process -Name explorer -ErrorAction Stop |
    Sort-Object StartTime -Descending |
    Select-Object -First 1 -ExpandProperty SessionId

$process = Get-CimInstance Win32_Process -Filter "Name='Libertix.exe'" -ErrorAction Stop |
    Where-Object {
        $_.SessionId -eq $interactiveSession -and
        -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) -and
        [IO.Path]::GetFullPath($_.ExecutablePath) -eq $executable
    } |
    Sort-Object CreationDate -Descending |
    Select-Object -First 1

if (-not $process) {
    $taskState = schtasks.exe /Query /TN $taskName /V /FO LIST 2>&1
    throw ("Libertix is absent from the interactive session; task=" + ($taskState -join " | "))
}

# Removing the task definition does not terminate its already-running process.
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
}

$graphicalProcess = Get-Process -Id $process.ProcessId -ErrorAction Stop
$windowDeadline = [DateTime]::UtcNow.AddSeconds(30)
do {
    $graphicalProcess.Refresh()
    if (Test-VisibleMainWindow -Process $graphicalProcess) {
        break
    }
    Start-Sleep -Milliseconds 200
} while ([DateTime]::UtcNow -lt $windowDeadline)
if (-not (Test-VisibleMainWindow -Process $graphicalProcess)) {
    throw "Libertix is running but did not expose its identified interactive main window"
}

Write-Output ("PID={0}" -f $process.ProcessId)
Write-Output ("SESSION_ID={0}" -f $process.SessionId)
Write-Output ("TASK_NAME={0}" -f $taskName)
Write-Output ("EXECUTABLE={0}" -f $process.ExecutablePath)
Write-Output ("WINDOW_HANDLE={0}" -f $graphicalProcess.MainWindowHandle.ToInt64())
Write-Output ("WINDOW_TITLE={0}" -f $graphicalProcess.MainWindowTitle)
Write-Output "WINDOW_VISIBLE=True"
