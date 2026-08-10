Set-StrictMode -Version Latest

function ConvertTo-LibertixNativeArgument {
    param([AllowEmptyString()][string]$Value)

    if ($null -eq $Value) { return '""' }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }

    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        [void]$builder.Append(('\' * $backslashes))
        [void]$builder.Append($character)
        $backslashes = 0
    }
    [void]$builder.Append(('\' * ($backslashes * 2)))
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Stop-LibertixNativeProcessTree {
    param([Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process)

    try {
        $taskKill = Join-Path $env:SystemRoot "System32\taskkill.exe"
        & $taskKill /PID $Process.Id /T /F 2>&1 | Out-Null
        $taskkillExitCode = $LASTEXITCODE
        $Process.WaitForExit(10000) | Out-Null
        return ($taskkillExitCode -eq 0 -and $Process.HasExited)
    } catch {
        return $false
    }
}

function Invoke-LibertixNativeProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string]$Arguments = "",
        [Parameter(Mandatory = $true)][ValidateRange(1, 86400)][int]$TimeoutSeconds,
        [string]$MonitoredFilePath = "",
        [int64]$MaximumFileBytes = 0
    )

    if ($MaximumFileBytes -lt 0) {
        throw "MaximumFileBytes cannot be negative."
    }
    if (($MaximumFileBytes -gt 0) -ne (-not [string]::IsNullOrWhiteSpace($MonitoredFilePath))) {
        throw "MonitoredFilePath and MaximumFileBytes must be provided together."
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Failed to start $FilePath."
        }
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while (-not $process.WaitForExit(250)) {
            if ($MaximumFileBytes -gt 0) {
                [int64]$length = 0
                try {
                    if (Test-Path -LiteralPath $MonitoredFilePath) {
                        $length = [int64](Get-Item `
                            -LiteralPath $MonitoredFilePath `
                            -ErrorAction Stop).Length
                    }
                } catch {
                    $length = 0
                }
                if ($length -gt $MaximumFileBytes) {
                    $treeStopped = Stop-LibertixNativeProcessTree -Process $process
                    if (-not $treeStopped) {
                        throw "PROCESS_TREE_NOT_STOPPED: $FilePath exceeded its file size limit and its process tree could not be proven stopped."
                    }
                    throw "DOWNLOAD_SIZE_LIMIT_EXCEEDED: $MonitoredFilePath exceeds $MaximumFileBytes bytes."
                }
            }
            if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                $treeStopped = Stop-LibertixNativeProcessTree -Process $process
                if (-not $treeStopped) {
                    throw "PROCESS_TREE_NOT_STOPPED: $FilePath timed out and its process tree could not be proven stopped."
                }
                throw "$FilePath timed out after $TimeoutSeconds seconds."
            }
        }
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StandardOutput = $outputTask.GetAwaiter().GetResult()
            StandardError = $errorTask.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
}

Export-ModuleMember -Function Invoke-LibertixNativeProcess, ConvertTo-LibertixNativeArgument
