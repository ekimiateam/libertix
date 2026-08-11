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
$useDefaultFilepool = [string]::IsNullOrWhiteSpace($filepoolBaseUrl)
$developmentStaticIpv4 = if (
    $config.PSObject.Properties.Name -contains "development_static_ipv4"
) {
    [string]$config.development_static_ipv4
} else {
    ""
}
$developmentPrefixLength = if (
    $config.PSObject.Properties.Name -contains "development_static_ipv4_prefix_length"
) {
    [int]$config.development_static_ipv4_prefix_length
} else {
    0
}
$developmentGateway = if (
    $config.PSObject.Properties.Name -contains "development_static_ipv4_gateway"
) {
    [string]$config.development_static_ipv4_gateway
} else {
    ""
}
$developmentDnsServers = if (
    $config.PSObject.Properties.Name -contains "development_dns_servers"
) {
    @($config.development_dns_servers)
} else {
    @()
}

if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw ("Local Libertix.exe was not found: " + $exe)
}

$parsedFilepoolUri = $null
if (-not $useDefaultFilepool) {
    if (
        -not [Uri]::TryCreate($filepoolBaseUrl, [UriKind]::Absolute, [ref]$parsedFilepoolUri) -or
        $parsedFilepoolUri.Scheme -notin @("http", "https") -or
        -not [string]::IsNullOrEmpty($parsedFilepoolUri.UserInfo) -or
        -not [string]::IsNullOrEmpty($parsedFilepoolUri.Query) -or
        -not [string]::IsNullOrEmpty($parsedFilepoolUri.Fragment)
    ) {
        throw "filepool_base_url must be an absolute HTTP(S) URL without credentials, a query or a fragment"
    }
    $filepoolBaseUrl = $parsedFilepoolUri.AbsoluteUri.TrimEnd("/")
}

if (-not [string]::IsNullOrWhiteSpace($developmentStaticIpv4)) {
    [System.Net.IPAddress]$parsedDevelopmentAddress = $null
    [System.Net.IPAddress]$parsedDevelopmentGateway = $null
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
    if (
        $developmentPrefixLength -lt 1 -or $developmentPrefixLength -gt 30
    ) {
        throw "development_static_ipv4_prefix_length must be between 1 and 30"
    }
    if (
        -not [System.Net.IPAddress]::TryParse(
            $developmentGateway,
            [ref]$parsedDevelopmentGateway
        ) -or
        $parsedDevelopmentGateway.AddressFamily -ne
            [System.Net.Sockets.AddressFamily]::InterNetwork
    ) {
        throw "development_static_ipv4_gateway must be an IPv4 address"
    }
    if ($developmentDnsServers.Count -lt 1) {
        throw "development_dns_servers must contain at least one IPv4 address"
    }
    $normalizedDnsServers = @()
    foreach ($dnsServer in $developmentDnsServers) {
        [System.Net.IPAddress]$parsedDnsServer = $null
        if (
            -not [System.Net.IPAddress]::TryParse(
                [string]$dnsServer,
                [ref]$parsedDnsServer
            ) -or
            $parsedDnsServer.AddressFamily -ne
                [System.Net.Sockets.AddressFamily]::InterNetwork
        ) {
            throw "development_dns_servers must contain only IPv4 addresses"
        }
        $normalizedDnsServers += $parsedDnsServer.ToString()
    }
    $developmentStaticIpv4 = $parsedDevelopmentAddress.ToString()
    $developmentGateway = $parsedDevelopmentGateway.ToString()
    $developmentDnsServers = $normalizedDnsServers
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
$taskCommand = '"{0}"' -f $exe
if (-not $useDefaultFilepool) {
    $taskCommand += ' --filepool-base-url "{0}"' -f $filepoolBaseUrl
}
if (-not [string]::IsNullOrEmpty($developmentStaticIpv4)) {
    $taskCommand += ' --dev-ssh-static-ip "{0}"' -f $developmentStaticIpv4
    $taskCommand += ' --dev-ssh-prefix-length "{0}"' -f $developmentPrefixLength
    $taskCommand += ' --dev-ssh-gateway "{0}"' -f $developmentGateway
    foreach ($dnsServer in $developmentDnsServers) {
        $taskCommand += ' --dev-ssh-dns "{0}"' -f $dnsServer
    }
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
    throw ("Failed to create the Libertix scheduled task; output=" + ($createOutput -join " | "))
}

$runOutput = schtasks.exe /Run /TN $taskName 2>&1
if ($LASTEXITCODE -ne 0) {
    throw ("Failed to start the Libertix scheduled task; output=" + ($runOutput -join " | "))
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
    throw ("Libertix is not running after elevated launch; task=" + ($taskState -join " | "))
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
