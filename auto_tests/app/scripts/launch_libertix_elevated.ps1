param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Result {
    param([string]$Name, [string]$Value)
    Write-Output ("{0}={1}" -f $Name, $Value)
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$exe = [string]$config.executable
$taskName = [string]$config.task_name

if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw ("Libertix.exe local est introuvable: " + $exe)
}

# Le lancement administrateur interactif est nécessaire pour le parcours
# d'installation. sshd seul démarre trop souvent le processus dans une session
# invisible ; /IT force l'attachement à la session utilisateur active.
Stop-Process -Name "Libertix" -Force -ErrorAction SilentlyContinue

# Supprimer l'ancienne tâche si elle existe. schtasks retourne une erreur native
# quand la tâche n'existe pas ; ce cas est normal et ne doit pas interrompre le run.
$oldPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    schtasks.exe /Delete /TN $taskName /F 2>$null | Out-Null
}
finally {
    $ErrorActionPreference = $oldPreference
}

$time = (Get-Date).AddMinutes(1).ToString("HH:mm")
$quotedExe = '"' + $exe + '"'
$interactiveSession = Get-Process -Name explorer -ErrorAction Stop |
    Sort-Object StartTime -Descending |
    Select-Object -First 1 -ExpandProperty SessionId

$createOutput = schtasks.exe `
    /Create `
    /TN $taskName `
    /TR $quotedExe `
    /SC ONCE `
    /ST $time `
    /RL HIGHEST `
    /IT `
    /F 2>&1

if ($LASTEXITCODE -ne 0) {
    throw ("Création tâche planifiée Libertix échouée; sortie=" + ($createOutput -join " | "))
}

$runOutput = schtasks.exe /Run /TN $taskName 2>&1
if ($LASTEXITCODE -ne 0) {
    throw ("Lancement tâche planifiée Libertix échoué; sortie=" + ($runOutput -join " | "))
}

$process = $null
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Seconds 2
    $process = Get-Process -Name "Libertix" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.SessionId -eq $interactiveSession -and
            $_.Path -eq $exe
        } |
        Sort-Object StartTime -Descending |
        Select-Object -First 1
    if ($process) {
        break
    }
}

if (-not $process) {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $taskState = schtasks.exe /Query /TN $taskName /V /FO LIST 2>&1
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }
    throw ("Libertix ne tourne pas après lancement administrateur; tâche=" + ($taskState -join " | "))
}

$processInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$($process.Id)" -ErrorAction Stop
if ($processInfo.ExecutablePath -ne $exe -or $processInfo.SessionId -ne $interactiveSession) {
    throw "Libertix process identity does not match the deployed executable/session"
}

$deleteOutput = schtasks.exe /Delete /TN $taskName /F 2>&1
if ($LASTEXITCODE -ne 0) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    throw ("Libertix started but scheduled task cleanup failed; sortie=" + ($deleteOutput -join " | "))
}

Write-Result -Name "PID" -Value $process.Id
Write-Result -Name "SESSION_ID" -Value $process.SessionId
Write-Result -Name "TASK_NAME" -Value $taskName
Write-Result -Name "EXECUTABLE" -Value $processInfo.ExecutablePath
