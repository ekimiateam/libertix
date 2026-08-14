param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,
    [switch]$InteractiveWorker,
    [string]$LaunchId = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Add-Type -AssemblyName UIAutomationClient

function Write-Result {
    param([string]$Name, [string]$Value)
    Write-Output ("{0}={1}" -f $Name, $Value)
}

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

function Write-AtomicJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [object]$Value
    )

    $temporaryPath = "{0}.tmp-{1}" -f $Path, $PID
    $json = $Value | ConvertTo-Json -Depth 4 -Compress
    [System.IO.File]::WriteAllText(
        $temporaryPath,
        $json,
        [System.Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Invoke-InteractiveWorker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkerConfigPath,
        [Parameter(Mandatory = $true)]
        [string]$WorkerResultPath
    )

    try {
        $workerConfig = Get-Content -LiteralPath $WorkerConfigPath -Raw |
            ConvertFrom-Json
        $workerExecutable = [IO.Path]::GetFullPath(
            [string]$workerConfig.executable)
        if (-not (Test-Path -LiteralPath $workerExecutable -PathType Leaf)) {
            throw ("Local Libertix.exe was not found: " + $workerExecutable)
        }

        $workerProcess = Start-Process `
            -FilePath $workerExecutable `
            -ArgumentList ([string]$workerConfig.argument_string) `
            -PassThru
        $windowDeadline = [DateTime]::UtcNow.AddSeconds(30)
        do {
            $workerProcess.Refresh()
            if (Test-VisibleMainWindow -Process $workerProcess) {
                break
            }
            if ($workerProcess.HasExited) {
                throw ("Libertix exited before exposing its interactive main window; exit_code=" +
                    $workerProcess.ExitCode)
            }
            Start-Sleep -Milliseconds 200
        } while ([DateTime]::UtcNow -lt $windowDeadline)
        if (-not (Test-VisibleMainWindow -Process $workerProcess)) {
            throw "Libertix did not expose its identified interactive main window"
        }

        $workerProcess.Refresh()
        $element = [Windows.Automation.AutomationElement]::FromHandle(
            $workerProcess.MainWindowHandle)
        $bounds = $element.Current.BoundingRectangle
        Write-AtomicJson -Path $WorkerResultPath -Value ([ordered]@{
                status = "ok"
                pid = $workerProcess.Id
                session_id = $workerProcess.SessionId
                executable = $workerExecutable
                window_handle = $workerProcess.MainWindowHandle.ToInt64()
                window_title = $workerProcess.MainWindowTitle
                window_visible = $true
                window_width = [int]$bounds.Width
                window_height = [int]$bounds.Height
            })

        # Keep the scheduled action alive with the installer. Some Task
        # Scheduler hosts terminate descendants when their action exits.
        $workerProcess.WaitForExit()
        exit $workerProcess.ExitCode
    }
    catch {
        Write-AtomicJson -Path $WorkerResultPath -Value ([ordered]@{
                status = "error"
                error = $_.Exception.Message
                exception_type = $_.Exception.GetType().FullName
                script_stack = $_.ScriptStackTrace
            })
        exit 1
    }
}

if ($InteractiveWorker) {
    if ($LaunchId -notmatch '^[0-9a-f]{32}$') {
        throw "LaunchId is invalid for the interactive worker"
    }
    $workerRoot = Join-Path $env:ProgramData "Libertix\Automation"
    Invoke-InteractiveWorker `
        -WorkerConfigPath (Join-Path $workerRoot ("launch-" + $LaunchId + ".json")) `
        -WorkerResultPath (Join-Path $workerRoot ("launch-" + $LaunchId + ".result.json"))
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
$unattended = if (
    $config.PSObject.Properties.Name -contains "unattended" -and
    $null -ne $config.unattended
) {
    $config.unattended
} else {
    $null
}
$unattendedConfigPath = ""
$unattendedStatusPath = ""
$unattendedAcknowledgementPath = ""
$automationRoot = Join-Path $env:ProgramData "Libertix\Automation"
New-Item -ItemType Directory -Path $automationRoot -Force | Out-Null
$aclOutput = icacls.exe $automationRoot `
    /inheritance:r `
    /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' 2>&1
if ($LASTEXITCODE -ne 0) {
    throw ("Failed to protect the automation directory: " +
        ($aclOutput -join " | "))
}
$launchId = [Guid]::NewGuid().ToString("N")
$workerConfigPath = Join-Path $automationRoot ("launch-" + $launchId + ".json")
$workerResultPath = Join-Path $automationRoot ("launch-" + $launchId + ".result.json")
$workerScriptPath = Join-Path $automationRoot "launch-worker.ps1"
Copy-Item -LiteralPath $PSCommandPath -Destination $workerScriptPath -Force

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

if ($null -ne $unattended) {
    $unattendedId = [Guid]::NewGuid().ToString("N")
    $unattendedStem = Join-Path $automationRoot ("unattended-" + $unattendedId)
    $unattendedConfigPath = $unattendedStem + ".json"
    $unattendedStatusPath = $unattendedStem + ".status.json"
    $unattendedAcknowledgementPath = $unattendedStem + ".ack"
    $unattendedJson = $unattended | ConvertTo-Json -Depth 4 -Compress
    [System.IO.File]::WriteAllText(
        $unattendedConfigPath,
        $unattendedJson,
        [System.Text.UTF8Encoding]::new($false)
    )
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
$applicationArguments = ""
if (-not $useDefaultFilepool) {
    $applicationArguments += ' --filepool-base-url "{0}"' -f $filepoolBaseUrl
}
if (-not [string]::IsNullOrEmpty($developmentStaticIpv4)) {
    $applicationArguments += ' --dev-ssh-static-ip "{0}"' -f $developmentStaticIpv4
    $applicationArguments += ' --dev-ssh-prefix-length "{0}"' -f $developmentPrefixLength
    $applicationArguments += ' --dev-ssh-gateway "{0}"' -f $developmentGateway
    foreach ($dnsServer in $developmentDnsServers) {
        $applicationArguments += ' --dev-ssh-dns "{0}"' -f $dnsServer
    }
}
if ($null -ne $unattended) {
    $applicationArguments += ' --unattended --unattended-config "{0}"' -f $unattendedConfigPath
}
[System.IO.File]::WriteAllText(
    $workerConfigPath,
    ([ordered]@{
            executable = $exe
            argument_string = $applicationArguments.Trim()
        } | ConvertTo-Json -Compress),
    [System.Text.UTF8Encoding]::new($false)
)
$taskCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass ' +
    '-File "{0}" -ConfigPath ignored -InteractiveWorker -LaunchId {1}' -f `
    $workerScriptPath, $launchId
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
    if ($unattendedConfigPath) {
        Remove-Item -LiteralPath $unattendedConfigPath -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $workerConfigPath, $workerResultPath, $workerScriptPath `
        -Force -ErrorAction SilentlyContinue
    throw ("Failed to create the Libertix scheduled task; output=" + ($createOutput -join " | "))
}

$runOutput = schtasks.exe /Run /TN $taskName 2>&1
if ($LASTEXITCODE -ne 0) {
    if ($unattendedConfigPath) {
        Remove-Item -LiteralPath $unattendedConfigPath -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $workerConfigPath, $workerResultPath, $workerScriptPath `
        -Force -ErrorAction SilentlyContinue
    throw ("Failed to start the Libertix scheduled task; output=" + ($runOutput -join " | "))
}

$workerResult = $null
for ($i = 0; $i -lt 450 -and -not $workerResult; $i++) {
    Start-Sleep -Milliseconds 100
    if (Test-Path -LiteralPath $workerResultPath -PathType Leaf) {
        try {
            $workerResult = Get-Content -LiteralPath $workerResultPath -Raw |
                ConvertFrom-Json
        }
        catch {
            $workerResult = $null
        }
    }
}

if (-not $workerResult) {
    if ($unattendedConfigPath) {
        Remove-Item -LiteralPath $unattendedConfigPath -Force -ErrorAction SilentlyContinue
    }
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $taskState = schtasks.exe /Query /TN $taskName /V /FO LIST 2>&1
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }
    Remove-Item -LiteralPath $workerConfigPath, $workerResultPath, $workerScriptPath `
        -Force -ErrorAction SilentlyContinue
    throw ("The interactive Libertix worker did not report a result; task=" +
        ($taskState -join " | "))
}

if ([string]$workerResult.status -ne "ok") {
    if ($unattendedConfigPath) {
        Remove-Item -LiteralPath $unattendedConfigPath -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $workerConfigPath, $workerResultPath, $workerScriptPath `
        -Force -ErrorAction SilentlyContinue
    throw ("The interactive Libertix worker failed: " + [string]$workerResult.error)
}

$process = Get-Process -Id ([int]$workerResult.pid) -ErrorAction Stop

if ($unattendedConfigPath) {
    for ($i = 0; $i -lt 100 -and (Test-Path -LiteralPath $unattendedConfigPath); $i++) {
        Start-Sleep -Milliseconds 100
    }
    if (Test-Path -LiteralPath $unattendedConfigPath) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $unattendedConfigPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $workerConfigPath, $workerResultPath, $workerScriptPath `
            -Force -ErrorAction SilentlyContinue
        throw "Libertix did not consume the unattended configuration"
    }
}

$processInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$($process.Id)" -ErrorAction Stop
if ($processInfo.ExecutablePath -ne $exe -or $processInfo.SessionId -ne $interactiveSession) {
    Remove-Item -LiteralPath $workerConfigPath, $workerResultPath, $workerScriptPath `
        -Force -ErrorAction SilentlyContinue
    throw "Libertix process identity does not match the deployed executable/session"
}

$deleteOutput = schtasks.exe /Delete /TN $taskName /F 2>&1
if ($LASTEXITCODE -ne 0) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $workerConfigPath, $workerResultPath, $workerScriptPath `
        -Force -ErrorAction SilentlyContinue
    throw ("Libertix started but scheduled task cleanup failed; sortie=" + ($deleteOutput -join " | "))
}

Remove-Item -LiteralPath $workerConfigPath, $workerResultPath, $workerScriptPath `
    -Force -ErrorAction SilentlyContinue

Write-Result -Name "PID" -Value $process.Id
Write-Result -Name "SESSION_ID" -Value $process.SessionId
Write-Result -Name "TASK_NAME" -Value $taskName
Write-Result -Name "EXECUTABLE" -Value $processInfo.ExecutablePath
Write-Result -Name "WINDOW_HANDLE" -Value ([long]$workerResult.window_handle)
Write-Result -Name "WINDOW_TITLE" -Value ([string]$workerResult.window_title)
Write-Result -Name "WINDOW_VISIBLE" -Value "True"
Write-Result -Name "WINDOW_WIDTH" -Value ([int]$workerResult.window_width)
Write-Result -Name "WINDOW_HEIGHT" -Value ([int]$workerResult.window_height)
if ($unattendedStatusPath) {
    Write-Result -Name "UNATTENDED_STATUS_PATH" -Value $unattendedStatusPath
    Write-Result -Name "UNATTENDED_ACKNOWLEDGEMENT_PATH" -Value $unattendedAcknowledgementPath
}
