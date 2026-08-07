#requires -Version 5.1

# Download transports and verified Mint ISO acquisition.

function Start-BitsDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [ValidateRange(10, 3600)][int]$NoProgressTimeoutSeconds = 120
    )

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
        Invoke-WebRequest -Uri $Aria2ZipUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 120
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

function Start-Aria2Download {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination
    )

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
    if (Test-Path -LiteralPath $downloadPath) {
        Remove-Item -LiteralPath $downloadPath -Force
    }

    Write-Log "Downloading with aria2: $destinationName" "Cyan"
    $aria2Arguments = @(
        "--allow-overwrite=true",
        "--auto-file-renaming=false",
        "--continue=true",
        "--max-connection-per-server=$Aria2Connections",
        "--split=$Aria2Connections",
        "--min-split-size=1M",
        "--summary-interval=5",
        "--console-log-level=warn",
        "--out=$destinationName",
        $Url
    )

    Push-Location -LiteralPath $downloadDir
    try {
        & $aria2 @aria2Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "aria2 failed with exit code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }

    if (-not (Test-Path -LiteralPath $downloadPath)) {
        throw "aria2 completed but downloaded file is missing: $downloadPath"
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
        [Parameter(Mandatory = $true)][string]$Label
    )

    try {
        Start-Aria2Download -Url $Url -Destination $Destination
        return
    } catch {
        Write-Log "aria2 failed for $Label; using BITS fallback: $($_.Exception.Message)" "Yellow"
    }

    try {
        Start-BitsDownload -Url $Url -Destination $Destination
        return
    } catch {
        Write-Log "BITS failed for $Label; using Invoke-WebRequest fallback: $($_.Exception.Message)" "Yellow"
    }

    $ProgressPreference = "SilentlyContinue"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 120
    } finally {
        $ProgressPreference = "Continue"
    }
}

function Set-MintIsoOnWindows {
    $existing = Get-Item -LiteralPath $MintIsoPath -ErrorAction SilentlyContinue
    if ($existing -and $existing.Length -gt 100MB) {
        $existingHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $MintIsoPath).Hash.ToLowerInvariant()
        if ($existingHash -eq $MintIsoSha256) {
            Write-Log "Mint ISO already present and verified: $MintIsoPath" "Green"
            return
        }
        Write-Log "Existing Mint ISO hash mismatch; downloading a verified copy." "Yellow"
        Remove-Item -LiteralPath $MintIsoPath -Force
    }

    Write-Log "Downloading Mint ISO to $MintIsoPath..." "Cyan"
    Start-RobustDownload -Url $MintIsoUrl -Destination $MintIsoPath -Label "Mint ISO"

    $downloadedIso = Get-Item -LiteralPath $MintIsoPath -ErrorAction Stop
    if ($downloadedIso.Length -le 100MB) {
        throw "Mint ISO download is too small: $($downloadedIso.Length) bytes"
    }
    $downloadedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $MintIsoPath).Hash.ToLowerInvariant()
    if ($downloadedHash -ne $MintIsoSha256) {
        throw "Mint ISO hash mismatch. Expected $MintIsoSha256, got $downloadedHash"
    }
    Write-Log "Mint ISO ready: $MintIsoPath" "Green"
}
