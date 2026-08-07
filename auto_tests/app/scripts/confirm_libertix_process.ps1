param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

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

# A scheduled task can remain registered when the SSH channel closes immediately after launch.
# Removing the definition does not terminate its already-running interactive process.
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
}

Write-Output ("PID={0}" -f $process.ProcessId)
Write-Output ("SESSION_ID={0}" -f $process.SessionId)
Write-Output ("TASK_NAME={0}" -f $taskName)
Write-Output ("EXECUTABLE={0}" -f $process.ExecutablePath)
