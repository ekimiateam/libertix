#requires -Version 5.1

# Download transports and verified distribution ISO acquisition.

$script:MaximumDistributionIsoBytes = 8GB
$script:MaximumLiveIsoBytes = 2GB
$script:MaximumHelperArchiveBytes = 128MB

function Invoke-BoundedHttpDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][int64]$MaxBytes,
        [ValidateRange(10, 3600)][int]$TimeoutSeconds = 120
    )

    if ($MaxBytes -le 0) { throw "MaxBytes must be positive." }

    $request = [Net.HttpWebRequest]::Create($Url)
    $request.AllowAutoRedirect = $true
    $request.Timeout = $TimeoutSeconds * 1000
    $request.ReadWriteTimeout = $TimeoutSeconds * 1000
    $response = $null
    $inputStream = $null
    $outputStream = $null
    try {
        $response = $request.GetResponse()
        if ([int64]$response.ContentLength -gt $MaxBytes) {
            throw "DOWNLOAD_SIZE_LIMIT_EXCEEDED: $Url exceeds $MaxBytes bytes."
        }
        $inputStream = $response.GetResponseStream()
        $outputStream = [IO.File]::Open(
            $Destination,
            [IO.FileMode]::Create,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        $buffer = New-Object byte[] (1MB)
        [int64]$total = 0
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($total -gt $MaxBytes - $read) {
                throw "DOWNLOAD_SIZE_LIMIT_EXCEEDED: $Url exceeds $MaxBytes bytes."
            }
            $outputStream.Write($buffer, 0, $read)
            $total += $read
        }
    } catch {
        if ($outputStream) {
            $outputStream.Dispose()
            $outputStream = $null
        }
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Dispose() }
    }
}

function Start-BitsDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][int64]$MaxBytes,
        [ValidateRange(10, 3600)][int]$NoProgressTimeoutSeconds = 120
    )

    if ($MaxBytes -le 0) { throw "MaxBytes must be positive." }

    $job = Start-BitsTransfer -Source $Url -Destination $Destination `
        -Asynchronous -DisplayName "Download: $([IO.Path]::GetFileName($Destination))" `
        -ErrorAction Stop

    $jobId = $job.JobId
    $completed = $false
    $lastBytesTransferred = [uint64]0
    $lastProgressAt = [DateTime]::UtcNow

    try {
        while ($true) {
            $j = Get-BitsTransfer -Id $jobId -ErrorAction SilentlyContinue
            if (-not $j) {
                throw "BITS transfer disappeared before completion."
            }

            $bytesTransferred = [uint64]$j.BytesTransferred
            if (
                ($j.BytesTotal -ne [uint64]::MaxValue -and [uint64]$j.BytesTotal -gt [uint64]$MaxBytes) -or
                $bytesTransferred -gt [uint64]$MaxBytes
            ) {
                throw "DOWNLOAD_SIZE_LIMIT_EXCEEDED: $Url exceeds $MaxBytes bytes."
            }
            if ($bytesTransferred -gt $lastBytesTransferred) {
                $lastBytesTransferred = $bytesTransferred
                $lastProgressAt = [DateTime]::UtcNow
            }
            $idleSeconds = ([DateTime]::UtcNow - $lastProgressAt).TotalSeconds

            if ($j.JobState -in @("Connecting", "Transferring", "TransientError")) {
                if ($idleSeconds -ge $NoProgressTimeoutSeconds) {
                    $details = [string]$j.ErrorDescription
                    throw "BITS transfer made no progress for $NoProgressTimeoutSeconds seconds " +
                        "(state=$($j.JobState), error=$details)."
                }

                $pct = 0
                if ($j.BytesTotal -gt 0 -and $j.BytesTotal -ne [uint64]::MaxValue) {
                    $pct = [math]::Round(($j.BytesTransferred / $j.BytesTotal) * 100, 1)
                }
                $status =
                    if ($j.JobState -eq "TransientError") {
                        "Temporary network error; waiting for BITS retry ($([math]::Round($idleSeconds)) sec)"
                    } else {
                        "$pct% ($([math]::Round($j.BytesTransferred / 1MB, 1)) MB)"
                    }
                Write-Progress -Activity "Downloading ISO" -PercentComplete $pct -Status $status
                Start-Sleep -Seconds 2
                continue
            }

            if ($j.JobState -eq "Suspended") {
                Resume-BitsTransfer -BitsJob $j | Out-Null
                Start-Sleep -Seconds 1
                continue
            }

            if ($j.JobState -eq "Transferred") {
                Complete-BitsTransfer -BitsJob $j
                $completed = $true
                break
            }

            if ($j.JobState -eq "Error") {
                throw "BITS transfer failed: $($j.ErrorDescription)"
            }

            if ($j.JobState -in @("Cancelled", "Acknowledged")) {
                throw "BITS ended unexpectedly (state=$($j.JobState))."
            }

            throw "BITS entered an unsupported state: $($j.JobState)."
        }
    } finally {
        if (-not $completed) {
            $remainingJob = Get-BitsTransfer -Id $jobId -ErrorAction SilentlyContinue
            if ($remainingJob) {
                Remove-BitsTransfer -BitsJob $remainingJob -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
        Write-Progress -Activity "Downloading ISO" -Completed
    }

    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        throw "BITS completed but the downloaded file is missing: $Destination"
    }
    if ([int64](Get-Item -LiteralPath $Destination -ErrorAction Stop).Length -gt $MaxBytes) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw "DOWNLOAD_SIZE_LIMIT_EXCEEDED: $Url exceeds $MaxBytes bytes."
    }
}

function Get-Aria2Exe {
    if (-not [string]::IsNullOrWhiteSpace($Aria2ExePath)) {
        $resolved = [IO.Path]::GetFullPath($Aria2ExePath)
        if (-not (Test-Path -LiteralPath $resolved)) {
            throw "Provided aria2 executable was not found: $resolved"
        }
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolved).Hash.ToLowerInvariant()
        if ($actualHash -ne $Aria2ExeSha256) {
            throw "Provided aria2 executable hash mismatch. Expected $Aria2ExeSha256, got $actualHash"
        }
        return $resolved
    }

    $existing =
        if (Test-Path -LiteralPath $Aria2CacheDir) {
            Get-ChildItem -LiteralPath $Aria2CacheDir -Filter "aria2c.exe" `
                -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1
        } else {
            $null
        }
    if ($existing) {
        $existingHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $existing.FullName).Hash.ToLowerInvariant()
        if ($existingHash -eq $Aria2ExeSha256) {
            return $existing.FullName
        }
        Write-Log "Cached aria2 hash mismatch; replacing the cache." "Yellow"
        Remove-Item -LiteralPath $Aria2CacheDir -Recurse -Force
    }

    [IO.Directory]::CreateDirectory($Aria2CacheDir) | Out-Null
    $zipPath = Join-Path $Aria2CacheDir "aria2.zip"

    Write-Log "Downloading aria2 download helper..." "Cyan"
    $ProgressPreference = "SilentlyContinue"
    try {
        Invoke-BoundedHttpDownload `
            -Url $Aria2ZipUrl `
            -Destination $zipPath `
            -MaxBytes $script:MaximumHelperArchiveBytes `
            -TimeoutSeconds 120
    } finally {
        $ProgressPreference = "Continue"
    }

    if (-not (Test-Path -LiteralPath $zipPath)) {
        throw "aria2 download helper was not downloaded."
    }

    $zipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
    if ($zipHash -ne $Aria2ZipSha256) {
        throw "aria2 archive hash mismatch. Expected $Aria2ZipSha256, got $zipHash"
    }

    Expand-Archive -LiteralPath $zipPath -DestinationPath $Aria2CacheDir -Force
    $aria2 = Get-ChildItem -LiteralPath $Aria2CacheDir -Filter "aria2c.exe" `
        -Recurse -ErrorAction Stop |
        Select-Object -First 1

    if (-not $aria2) {
        throw "aria2c.exe was not found after extraction."
    }

    $aria2Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $aria2.FullName).Hash.ToLowerInvariant()
    if ($aria2Hash -ne $Aria2ExeSha256) {
        throw "aria2 executable hash mismatch after extraction. Expected $Aria2ExeSha256, got $aria2Hash"
    }

    return $aria2.FullName
}

function New-Aria2DownloadArguments {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$DownloadDir,
        [Parameter(Mandatory = $true)][string]$DestinationName
    )

    return @(
        "--allow-overwrite=true",
        "--auto-file-renaming=false",
        "--continue=true",
        "--max-connection-per-server=$Aria2Connections",
        "--split=$Aria2Connections",
        "--min-split-size=1M",
        "--max-tries=5",
        "--retry-wait=10",
        "--connect-timeout=30",
        "--timeout=60",
        "--summary-interval=5",
        "--console-log-level=warn",
        "--enable-color=false",
        "--dir=$DownloadDir",
        "--out=$DestinationName",
        $Url
    )
}

function Start-Aria2Download {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][int64]$MaxBytes
    )

    if ($MaxBytes -le 0) { throw "MaxBytes must be positive." }

    $aria2 = Get-Aria2Exe
    $destinationFullPath = [IO.Path]::GetFullPath($Destination)
    $destinationDir = [IO.Path]::GetDirectoryName($destinationFullPath)
    $destinationName = [IO.Path]::GetFileName($destinationFullPath)

    if ([string]::IsNullOrWhiteSpace($destinationDir)) {
        throw "Cannot resolve download destination directory for: $Destination"
    }

    $downloadDir = $destinationDir
    $downloadPath = $destinationFullPath
    if ($destinationDir -match '^[A-Za-z]:\\?$') {
        # aria2 rejects drive-root output directories on some Windows setups.
        # Download to a normal directory first, then move atomically to the
        # destination on the Windows system volume.
        $downloadDir = $Aria2DownloadDir
        $downloadPath = Join-Path $downloadDir $destinationName
    }
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
    if (Test-Path -LiteralPath $downloadPath -PathType Leaf) {
        $existingLength = [int64](Get-Item -LiteralPath $downloadPath -ErrorAction Stop).Length
        if ($existingLength -gt $MaxBytes) {
            Remove-Item -LiteralPath $downloadPath -Force
            Remove-Item -LiteralPath "$downloadPath.aria2" -Force -ErrorAction SilentlyContinue
            throw "DOWNLOAD_SIZE_LIMIT_EXCEEDED: $Url exceeds $MaxBytes bytes."
        }
        Write-Log "Resuming the partial aria2 download at $existingLength bytes." "Yellow"
    }

    Write-Log "Downloading with aria2: $destinationName" "Cyan"
    $aria2Arguments = New-Aria2DownloadArguments `
        -Url $Url `
        -DownloadDir $downloadDir `
        -DestinationName $destinationName
    $nativeArguments = ($aria2Arguments | ForEach-Object {
        ConvertTo-LibertixNativeArgument -Value ([string]$_)
    }) -join " "
    $aria2Result = Invoke-LibertixNativeProcess `
        -FilePath $aria2 `
        -Arguments $nativeArguments `
        -TimeoutSeconds 14400 `
        -MonitoredFilePath $downloadPath `
        -MaximumFileBytes $MaxBytes
    if ($aria2Result.ExitCode -ne 0) {
        $diagnostic = ($aria2Result.StandardOutput + [Environment]::NewLine +
            $aria2Result.StandardError).Trim()
        throw "aria2 failed with exit code $($aria2Result.ExitCode): $diagnostic"
    }

    if (-not (Test-Path -LiteralPath $downloadPath)) {
        throw "aria2 completed but downloaded file is missing: $downloadPath"
    }
    if ([int64](Get-Item -LiteralPath $downloadPath -ErrorAction Stop).Length -gt $MaxBytes) {
        throw "DOWNLOAD_SIZE_LIMIT_EXCEEDED: $Url exceeds $MaxBytes bytes."
    }

    if ($downloadPath -ne $destinationFullPath) {
        if (Test-Path -LiteralPath $destinationFullPath) {
            Remove-Item -LiteralPath $destinationFullPath -Force
        }
        Move-Item -LiteralPath $downloadPath -Destination $destinationFullPath -Force
    }
}

function Start-RobustDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][int64]$MaxBytes
    )

    if ($MaxBytes -le 0) { throw "MaxBytes must be positive." }

    $maximumAria2Attempts = 3
    for ($attempt = 1; $attempt -le $maximumAria2Attempts; $attempt++) {
        try {
            Start-Aria2Download -Url $Url -Destination $Destination -MaxBytes $MaxBytes
            return
        } catch {
            if (
                $_.Exception.Message -like "PROCESS_TREE_NOT_STOPPED:*" -or
                $_.Exception.Message -like "DOWNLOAD_SIZE_LIMIT_EXCEEDED:*"
            ) {
                throw
            }
            if ($attempt -lt $maximumAria2Attempts) {
                Write-Log (
                    "aria2 attempt $attempt/$maximumAria2Attempts failed for $Label; " +
                    "retaining the partial download and retrying: $($_.Exception.Message)"
                ) "Yellow"
                Start-Sleep -Seconds (10 * $attempt)
                continue
            }
            Write-Log (
                "aria2 failed after $maximumAria2Attempts attempts for $Label; " +
                "using BITS fallback: $($_.Exception.Message)"
            ) "Yellow"
        }
    }

    Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "$Destination.aria2" -Force -ErrorAction SilentlyContinue

    try {
        Start-BitsDownload -Url $Url -Destination $Destination -MaxBytes $MaxBytes
        return
    } catch {
        if ($_.Exception.Message -like "DOWNLOAD_SIZE_LIMIT_EXCEEDED:*") {
            throw
        }
        Write-Log "BITS failed for $Label; using Invoke-WebRequest fallback: $($_.Exception.Message)" "Yellow"
    }

    $ProgressPreference = "SilentlyContinue"
    try {
        Invoke-BoundedHttpDownload `
            -Url $Url `
            -Destination $Destination `
            -MaxBytes $MaxBytes `
            -TimeoutSeconds 120
    } finally {
        $ProgressPreference = "Continue"
    }
}

function Set-DistributionIsoOnWindows {
    $existing = Get-Item -LiteralPath $DistributionIsoPath -ErrorAction SilentlyContinue
    if ($existing -and $existing.Length -gt $script:MaximumDistributionIsoBytes) {
        Write-Log "Existing distribution ISO exceeds the supported size limit; replacing it." "Yellow"
        Remove-Item -LiteralPath $DistributionIsoPath -Force
        $existing = $null
    }
    if ($existing -and $existing.Length -gt 100MB) {
        $existingHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $DistributionIsoPath).Hash.ToLowerInvariant()
        if ($existingHash -eq $DistributionIsoSha256) {
            Write-Log "Distribution ISO already present and verified: $DistributionIsoPath" "Green"
            return
        }
        Write-Log "Existing distribution ISO hash mismatch; downloading a verified copy." "Yellow"
        Remove-Item -LiteralPath $DistributionIsoPath -Force
    }

    Write-Log "Downloading distribution ISO to $DistributionIsoPath..." "Cyan"
    Start-RobustDownload `
        -Url $DistributionIsoUrl `
        -Destination $DistributionIsoPath `
        -Label "distribution ISO" `
        -MaxBytes $script:MaximumDistributionIsoBytes

    $downloadedIso = Get-Item -LiteralPath $DistributionIsoPath -ErrorAction Stop
    if ($downloadedIso.Length -le 100MB) {
        throw "Distribution ISO download is too small: $($downloadedIso.Length) bytes"
    }
    $downloadedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $DistributionIsoPath).Hash.ToLowerInvariant()
    if ($downloadedHash -ne $DistributionIsoSha256) {
        throw "Distribution ISO hash mismatch. Expected $DistributionIsoSha256, got $downloadedHash"
    }
    Write-Log "Distribution ISO ready: $DistributionIsoPath" "Green"
}
