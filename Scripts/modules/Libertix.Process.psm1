Set-StrictMode -Version Latest

function Get-LibertixNativeSystemExecutable {
    param([Parameter(Mandatory = $true)][string]$FileName)

    if (
        [string]::IsNullOrWhiteSpace($FileName) -or
        $FileName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
        $FileName -match '[\\/]'
    ) {
        throw "Native system executable name is invalid."
    }
    $candidates = @()
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $candidates += (Join-Path $env:SystemRoot "Sysnative\$FileName")
    }
    $candidates += (Join-Path $env:SystemRoot "System32\$FileName")
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    $command = Get-Command -Name $FileName -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
        return [IO.Path]::GetFullPath([string]$command.Source)
    }
    throw "$FileName is unavailable through the native Windows system directory and PATH."
}

function ConvertTo-LibertixNativeArgument {
    param([AllowEmptyString()][string]$Value)

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
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 10
    )

    $taskKillProcess = New-Object Diagnostics.Process
    try {
        $taskKillProcess.StartInfo.FileName = Get-LibertixNativeSystemExecutable -FileName "taskkill.exe"
        $taskKillProcess.StartInfo.Arguments = "/PID $($Process.Id) /T /F"
        $taskKillProcess.StartInfo.UseShellExecute = $false
        $taskKillProcess.StartInfo.CreateNoWindow = $true
        $taskKillProcess.StartInfo.RedirectStandardOutput = $true
        $taskKillProcess.StartInfo.RedirectStandardError = $true
        if (-not $taskKillProcess.Start()) { return $false }
        $null = $taskKillProcess.StandardOutput.ReadToEndAsync()
        $null = $taskKillProcess.StandardError.ReadToEndAsync()
        if (-not $taskKillProcess.WaitForExit($TimeoutSeconds * 1000)) {
            $taskKillProcess.Kill()
            $null = $taskKillProcess.WaitForExit(1000)
            return $false
        }
        $null = $Process.WaitForExit($TimeoutSeconds * 1000)
        return ($taskKillProcess.ExitCode -eq 0 -and $Process.HasExited)
    } catch {
        return $false
    } finally {
        $taskKillProcess.Dispose()
    }
}

function Invoke-LibertixNativeCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory = $true)][ValidateRange(1, 86400)][int]$TimeoutSeconds,
        [string]$StandardInputText = "",
        [scriptblock]$OnStandardOutputLine = $null,
        [scriptblock]$OnStandardErrorLine = $null
    )

    $arguments = @(
        $ArgumentList | ForEach-Object {
            ConvertTo-LibertixNativeArgument -Value ([string]$_)
        }
    ) -join " "
    return Invoke-LibertixNativeProcess `
        -FilePath $FilePath `
        -Arguments $arguments `
        -TimeoutSeconds $TimeoutSeconds `
        -StandardInputText $StandardInputText `
        -OnStandardOutputLine $OnStandardOutputLine `
        -OnStandardErrorLine $OnStandardErrorLine
}

function Invoke-LibertixNativeProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string]$Arguments = "",
        [Parameter(Mandatory = $true)][ValidateRange(1, 86400)][int]$TimeoutSeconds,
        [string]$StandardInputText = "",
        [string]$MonitoredFilePath = "",
        [int64]$MaximumFileBytes = 0,
        [scriptblock]$OnStandardOutputLine = $null,
        [scriptblock]$OnStandardErrorLine = $null
    )

    if ($MaximumFileBytes -lt 0) {
        throw "MaximumFileBytes cannot be negative."
    }
    if ($StandardInputText.Length -gt 65536) {
        throw "Native standard input exceeds its bounded command size."
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
    $startInfo.RedirectStandardInput = $StandardInputText.Length -gt 0
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $processStarted = $false
    try {
        if (-not $process.Start()) {
            throw "Failed to start $FilePath."
        }
        $processStarted = $true
        $output = New-Object Text.StringBuilder
        $errorOutput = New-Object Text.StringBuilder
        $outputTask = $process.StandardOutput.ReadLineAsync()
        $errorTask = $process.StandardError.ReadLineAsync()
        $outputClosed = $false
        $errorClosed = $false
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $inputTask = $null
        if ($startInfo.RedirectStandardInput) {
            $process.StandardInput.AutoFlush = $true
            $inputTask = $process.StandardInput.WriteAsync($StandardInputText)
        }
        $processExited = $false
        while (-not $processExited -or -not $outputClosed -or -not $errorClosed) {
            if ($null -ne $inputTask -and $inputTask.IsCompleted) {
                $null = $inputTask.GetAwaiter().GetResult()
                $process.StandardInput.Close()
                $inputTask = $null
            }
            while (-not $outputClosed -and $outputTask.IsCompleted) {
                if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                    if ($process.HasExited) { throw "PROCESS_TREE_NOT_STOPPED: $FilePath output did not drain before its deadline." }
                    throw "$FilePath timed out while reading standard output."
                }
                $line = $outputTask.GetAwaiter().GetResult()
                if ($null -eq $line) {
                    $outputClosed = $true
                    break
                }
                [void]$output.AppendLine($line)
                if ($null -ne $OnStandardOutputLine) {
                    $null = & $OnStandardOutputLine $line
                }
                $outputTask = $process.StandardOutput.ReadLineAsync()
            }

            while (-not $errorClosed -and $errorTask.IsCompleted) {
                if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                    if ($process.HasExited) { throw "PROCESS_TREE_NOT_STOPPED: $FilePath error output did not drain before its deadline." }
                    throw "$FilePath timed out while reading standard error."
                }
                $line = $errorTask.GetAwaiter().GetResult()
                if ($null -eq $line) {
                    $errorClosed = $true
                    break
                }
                [void]$errorOutput.AppendLine($line)
                if ($null -ne $OnStandardErrorLine) {
                    $null = & $OnStandardErrorLine $line
                }
                $errorTask = $process.StandardError.ReadLineAsync()
            }

            if (-not $processExited) {
                $processExited = $process.WaitForExit(100)
                if (-not $processExited -and $MaximumFileBytes -gt 0) {
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
                if (-not $processExited -and $timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                    $treeStopped = Stop-LibertixNativeProcessTree -Process $process
                    if (-not $treeStopped) {
                        throw "PROCESS_TREE_NOT_STOPPED: $FilePath timed out and its process tree could not be proven stopped."
                    }
                    throw "$FilePath timed out after $TimeoutSeconds seconds."
                }
            } elseif (-not $outputClosed -or -not $errorClosed) {
                if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                    throw "PROCESS_TREE_NOT_STOPPED: $FilePath exited but an inherited output stream remains open."
                }
                Start-Sleep -Milliseconds 10
            }
        }
        $process.WaitForExit()
        if ($process.ExitCode -eq 173) {
            throw "PROCESS_TREE_NOT_STOPPED: $FilePath reported an unverified descendant process."
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StandardOutput = $output.ToString()
            StandardError = $errorOutput.ToString()
        }
    } catch {
        $processError = $_
        if ($processStarted -and -not $process.HasExited -and -not (Stop-LibertixNativeProcessTree -Process $process)) {
            throw "PROCESS_TREE_NOT_STOPPED: $FilePath failed and its process tree could not be proven stopped."
        }
        throw $processError
    } finally {
        $process.Dispose()
    }
}

Export-ModuleMember -Function `
    Get-LibertixNativeSystemExecutable, `
    Invoke-LibertixNativeProcess, `
    Invoke-LibertixNativeCommand, `
    ConvertTo-LibertixNativeArgument
