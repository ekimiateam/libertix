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
$filepoolBaseUrl = [string]$config.filepool_base_url
$developmentStaticIpv4 = if (
    $config.PSObject.Properties.Name -contains "development_static_ipv4"
) {
    [string]$config.development_static_ipv4
} else {
    ""
}

if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw ("Libertix.exe local est introuvable: " + $exe)
}

$parsedFilepoolUri = $null
if (
    [string]::IsNullOrWhiteSpace($filepoolBaseUrl) -or
    -not [Uri]::TryCreate($filepoolBaseUrl, [UriKind]::Absolute, [ref]$parsedFilepoolUri) -or
    $parsedFilepoolUri.Scheme -notin @("http", "https") -or
    -not [string]::IsNullOrEmpty($parsedFilepoolUri.UserInfo) -or
    -not [string]::IsNullOrEmpty($parsedFilepoolUri.Query) -or
    -not [string]::IsNullOrEmpty($parsedFilepoolUri.Fragment)
) {
    throw "filepool_base_url must be an absolute HTTP(S) URL without credentials, a query or a fragment"
}
$filepoolBaseUrl = $parsedFilepoolUri.AbsoluteUri.TrimEnd("/")

if (-not [string]::IsNullOrWhiteSpace($developmentStaticIpv4)) {
    [System.Net.IPAddress]$parsedDevelopmentAddress = $null
    if (
        -not [System.Net.IPAddress]::TryParse(
            $developmentStaticIpv4,
            [ref]$parsedDevelopmentAddress
        ) -or
        $parsedDevelopmentAddress.AddressFamily -ne
            [System.Net.Sockets.AddressFamily]::InterNetwork
    ) {
        throw "development_static_ipv4 must be an IPv4 address"
    }
    $octets = $parsedDevelopmentAddress.GetAddressBytes()
    if (
        $octets[0] -ne 192 -or $octets[1] -ne 168 -or $octets[2] -ne 1 -or
        $octets[3] -le 1 -or $octets[3] -ge 255
    ) {
        throw "development_static_ipv4 must be usable in 192.168.1.0/24"
    }
    $developmentStaticIpv4 = $parsedDevelopmentAddress.ToString()
}

# SSH starts elevated processes in a non-interactive session. A scheduled task
# with /IT attaches the installer to the active desktop where VNC can drive it.
Stop-Process -Name "Libertix" -Force -ErrorAction SilentlyContinue

# schtasks reports a native error when the old task is absent. That expected
# condition must not abort creation of the new interactive task.
$oldPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    schtasks.exe /Delete /TN $taskName /F 2>$null | Out-Null
}
finally {
    $ErrorActionPreference = $oldPreference
}

$time = (Get-Date).AddMinutes(1).ToString("HH:mm")
$taskCommand = '"{0}" --filepool-base-url "{1}"' -f $exe, $filepoolBaseUrl
if (-not [string]::IsNullOrEmpty($developmentStaticIpv4)) {
    $taskCommand += ' --dev-ssh-static-ip "{0}"' -f $developmentStaticIpv4
}
$interactiveSession = Get-Process -Name explorer -ErrorAction Stop |
    Sort-Object StartTime -Descending |
    Select-Object -First 1 -ExpandProperty SessionId

$createOutput = schtasks.exe `
    /Create `
    /TN $taskName `
    /TR $taskCommand `
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
