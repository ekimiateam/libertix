#requires -Version 5.1

# Windows storage, ESP mounting, volume letters, and installer cleanup.

function Remove-LibertixInstallerPartitionIfPresent {
    $partition = Get-VerifiedTransactionPartition
    if (-not $partition) {
        if (Test-LibertixInstallerPartitionPresent) {
            throw "$InstallerLabel exists without a matching transaction state; refusing removal."
        }
        Write-Log "No owned $InstallerLabel partition found." "Gray"
        return
    }

    Write-Log "Removing $InstallerLabel partition on disk $($partition.DiskNumber), partition $($partition.PartitionNumber)..." "Cyan"
    if ($partition.DriveLetter) {
        Dismount-Letter -Letter ([string]$partition.DriveLetter)
    }
    try {
        Remove-Partition `
            -DiskNumber $partition.DiskNumber `
            -PartitionNumber $partition.PartitionNumber `
            -Confirm:$false `
            -ErrorAction Stop
    } catch {
        Write-Log "PowerShell could not remove $InstallerLabel partition; trying diskpart fallback..." "Yellow"
        Invoke-DiskpartScript -ScriptText @"
select disk $($partition.DiskNumber)
select partition $($partition.PartitionNumber)
delete partition override
exit
"@
    }

    Assert-LibertixInstallerPartitionRemoved
}

function Test-LibertixInstallerPartitionPresent {
    $volume = Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.FileSystemLabel -eq $InstallerLabel } |
        Select-Object -First 1
    if ($volume) {
        return $true
    }

    $cim = Get-CimInstance Win32_Volume -Filter "Label='$InstallerLabel'" `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1
    return ($null -ne $cim)
}

function Assert-LibertixInstallerPartitionRemoved {
    Start-Sleep -Seconds 1
    if (Test-LibertixInstallerPartitionPresent) {
        throw "$InstallerLabel partition is still present after revert attempt."
    }
}

function Invoke-DiskpartScript {
    param([Parameter(Mandatory = $true)][string]$ScriptText)

    $tmp = [IO.Path]::GetTempFileName()
    try {
        $ScriptText | Out-File $tmp -Encoding ASCII
        $result = Invoke-LibertixNativeProcess `
            -FilePath "$env:SystemRoot\System32\diskpart.exe" `
            -Arguments ('/s "{0}"' -f $tmp) `
            -TimeoutSeconds 120
        $text = ($result.StandardOutput + [Environment]::NewLine + $result.StandardError).Trim()
        # diskpart output is localized. Callers verify the resulting partition,
        # access path, or absence directly, so only the process contract belongs
        # here.
        if ($result.ExitCode -ne 0) {
            throw "diskpart failed: $text"
        }
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Get-HibernateEnabled {
    # Read the state from the registry rather than parsing `powercfg /a`, whose
    # output is localized. Returns $true, $false, or $null when unknown.
    try {
        $value = Get-ItemProperty `
            -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\Power" `
            -Name "HibernateEnabled" `
            -ErrorAction Stop
        return ([int]$value.HibernateEnabled -ne 0)
    } catch {
        return $null
    }
}

function Set-HibernateEnabled {
    param([Parameter(Mandatory = $true)][bool]$Enabled)

    $argument = if ($Enabled) { "on" } else { "off" }
    $powercfg = Get-NativeSystemExecutable -FileName "powercfg.exe"
    $output = & $powercfg /hibernate $argument 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg failed to turn hibernation $argument (rc=$LASTEXITCODE): $($output -join ' ')"
    }

    $observed = Get-HibernateEnabled
    if ($null -eq $observed -or $observed -ne $Enabled) {
        throw "Windows did not apply the requested hibernation state: $argument"
    }
    Write-Log "Windows hibernation and Fast Startup set to: $argument" "Cyan"
}

function Get-GuidDLower {
    param([Parameter(Mandatory = $true)][Guid]$Guid)
    $Guid.ToString("D").ToLower()
}

function Mount-Esp {
    param([Parameter(Mandatory = $true)][string]$Letter)

    if (Test-Path "${Letter}:\") {
        throw "Drive letter $Letter became occupied before the ESP could be mounted."
    }

    $winPart = Get-Partition -DriveLetter $SystemDriveLetter -ErrorAction Stop
    $espPart =
        Get-Partition -DiskNumber $winPart.DiskNumber |
        Where-Object {
            $_.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}"
        } |
        Select-Object -First 1

    if (-not $espPart) {
        throw "ESP not found on disk $($winPart.DiskNumber)."
    }

    Invoke-DiskpartScript -ScriptText @"
select disk $($espPart.DiskNumber)
select partition $($espPart.PartitionNumber)
assign letter=$Letter
exit
"@

    $tries = 0
    while (-not (Test-Path "${Letter}:\") -and $tries -lt 10) {
        Start-Sleep -Seconds 1
        $tries++
    }

    if (-not (Test-Path "${Letter}:\")) {
        throw "Failed to mount ESP as ${Letter}:"
    }

    return "${Letter}:"
}

function Get-WindowsEspPartition {
    $winPart = Get-Partition -DriveLetter $SystemDriveLetter -ErrorAction Stop
    $espPart =
        Get-Partition -DiskNumber $winPart.DiskNumber -ErrorAction Stop |
        Where-Object {
            $_.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}"
        } |
        Select-Object -First 1

    if (-not $espPart) {
        throw "ESP not found on disk $($winPart.DiskNumber)."
    }

    return $espPart
}

function Remove-LibertixTemporaryEspFiles {
    param([Parameter(Mandatory = $true)][string]$EspDrive)

    $path = Join-Path $EspDrive $InstallerEspDirectory
    if (Test-Path $path) {
        Write-Log "Removing temporary ESP boot directory: $InstallerEspDirectory" "Cyan"
        Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
    }
}

function Install-LibertixTemporaryBootloaderOnEsp {
    param(
        [Parameter(Mandatory = $true)][string]$EspDrive,
        [Parameter(Mandatory = $true)][string]$InstallerDrive
    )

    if (-not (Test-Path "$EspDrive\")) {
        throw "Cannot install temporary bootloader; ESP is not mounted: $EspDrive"
    }
    if (-not (Test-Path "$InstallerDrive\")) {
        throw "Cannot install temporary bootloader; installer partition is not mounted: $InstallerDrive"
    }

    $destination = Join-Path $EspDrive $InstallerEspDirectory
    Remove-LibertixTemporaryEspFiles -EspDrive $EspDrive
    New-Item -ItemType Directory -Path $destination -Force | Out-Null

    $sourceBoot = Join-Path $InstallerDrive "EFI\BOOT"
    $bootx64 = Join-Path $sourceBoot "BOOTX64.EFI"
    $grubx64 = Join-Path $sourceBoot "grubx64.efi"
    $mmx64 = Join-Path $sourceBoot "mmx64.efi"
    foreach ($path in @($bootx64, $grubx64, $mmx64)) {
        if (-not (Test-Path $path)) {
            throw "Installer EFI file not found before ESP copy: $path"
        }
    }

    Copy-Item -LiteralPath $bootx64 -Destination (Join-Path $destination "BOOTX64.EFI") -Force
    Copy-Item -LiteralPath $grubx64 -Destination (Join-Path $destination "grubx64.efi") -Force
    Copy-Item -LiteralPath $mmx64 -Destination (Join-Path $destination "mmx64.efi") -Force

    $grubConfig = Get-LibertixStagingGrubConfig `
        -UseLowMemoryMode ([bool]$LowMemoryMode)
    Set-Content -Path (Join-Path $destination "grub.cfg") -Value $grubConfig -Encoding ASCII

    $hashes = @{}
    foreach ($relativePath in @("BOOTX64.EFI", "grubx64.efi", "mmx64.efi", "grub.cfg")) {
        $fullPath = Join-Path $destination $relativePath
        if (-not (Test-Path $fullPath) -or (Get-Item $fullPath).Length -le 0) {
            throw "Temporary ESP bootloader verification failed: $fullPath"
        }
        $hashes[$relativePath] = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    }

    Write-Log "Temporary UEFI loader installed on Windows ESP: $InstallerEspDirectory" "Green"
    return $hashes
}

function Close-ExplorerWindowsForDrive {
    param(
        [Parameter(Mandatory = $true)][string]$Letter,
        [switch]$IncludeErrorDialogs,
        [int]$RetryCount = 8
    )

    # Windows may open a newly formatted removable-looking volume through
    # AutoPlay. Removing its access path while that Explorer window is still
    # active leaves a misleading "Parameter incorrect" dialog on the desktop.
    # Close only windows that currently browse this temporary drive. The
    # installer is elevated while the user's Explorer is not, so ShellWindows
    # alone cannot always see the medium-integrity window. UI Automation is the
    # targeted cross-integrity fallback and validates the address bar before
    # closing anything.
    $normalizedLetter = $Letter.TrimEnd(":").ToUpperInvariant()
    $driveReferencePattern = "(?i)(^|[^A-Z0-9])$([regex]::Escape($normalizedLetter)):(\\|/|\)|$)"
    $shell = $null
    $closed = 0
    $closedHandles = @{}
    if (-not ([System.Management.Automation.PSTypeName]"LibertixExplorerWindowApi").Type) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Threading;

public static class LibertixExplorerWindowApi {
    private const uint WM_CLOSE = 0x0010;

    [DllImport("user32.dll")]
    private static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PostMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);

    public static bool EnsureClosed(IntPtr hWnd, int timeoutMilliseconds) {
        if (hWnd == IntPtr.Zero || !IsWindow(hWnd)) {
            return true;
        }

        PostMessage(hWnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
        int waited = 0;
        while (IsWindow(hWnd) && waited < timeoutMilliseconds) {
            Thread.Sleep(100);
            waited += 100;
        }
        return !IsWindow(hWnd);
    }
}
"@
    }

    try {
        $shell = New-Object -ComObject Shell.Application
        foreach ($window in @($shell.Windows())) {
            try {
                $locationUrl = [string]$window.LocationURL
                if ($locationUrl -match "^file:///$([regex]::Escape($normalizedLetter)):/") {
                    $windowHandle = [IntPtr]([int64]$window.HWND)
                    $window.Quit()
                    if ([LibertixExplorerWindowApi]::EnsureClosed($windowHandle, 5000)) {
                        $closedHandles[[string]$windowHandle.ToInt64()] = $true
                        $closed++
                    }
                }
            } catch {
                # A shell window can disappear while ShellWindows is enumerated.
            }
        }
    } catch {
        Write-Log "Could not inspect Explorer windows for ${normalizedLetter}:; continuing." "Gray"
    } finally {
        if ($shell) {
            try {
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
            } catch {
                # COM cleanup is best-effort after Explorer inspection; the
                # process teardown releases any remaining proxy reference.
            }
        }
    }

    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
        Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop

        # Retry briefly because AutoPlay can finish creating its window at the
        # same moment as the preparation script removes the access path.
        for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
            $desktopWindows = [Windows.Automation.AutomationElement]::RootElement.FindAll(
                [Windows.Automation.TreeScope]::Children,
                [Windows.Automation.Condition]::TrueCondition
            )
            foreach ($explorerWindow in $desktopWindows) {
                try {
                    $windowClass = [string]$explorerWindow.Current.ClassName
                    $isExplorerWindow = $windowClass -in @("CabinetWClass", "ExploreWClass")
                    $isDriveErrorDialog = $IncludeErrorDialogs -and $windowClass -eq "#32770"
                    if (-not $isExplorerWindow -and -not $isDriveErrorDialog) {
                        continue
                    }

                    $nativeHandle = [IntPtr]([int64]$explorerWindow.Current.NativeWindowHandle)
                    $nativeHandleKey = [string]$nativeHandle.ToInt64()
                    if ($closedHandles.ContainsKey($nativeHandleKey)) {
                        continue
                    }

                    $referencesDrive = $false
                    $descendants = $explorerWindow.FindAll(
                        [Windows.Automation.TreeScope]::Descendants,
                        [Windows.Automation.Condition]::TrueCondition
                    )
                    foreach ($element in $descendants) {
                        $candidateTexts = @(
                            [string]$element.Current.Name,
                            [string]$element.Current.HelpText
                        )
                        $valuePattern = $null
                        if (
                            $element.TryGetCurrentPattern(
                                [Windows.Automation.ValuePattern]::Pattern,
                                [ref]$valuePattern
                            )
                        ) {
                            $candidateTexts += [string]$valuePattern.Current.Value
                        }

                        if ($candidateTexts | Where-Object { $_ -match $driveReferencePattern }) {
                            $referencesDrive = $true
                            break
                        }
                    }

                    if (-not $referencesDrive) {
                        continue
                    }

                    $windowPattern = $null
                    if (
                        $explorerWindow.TryGetCurrentPattern(
                            [Windows.Automation.WindowPattern]::Pattern,
                            [ref]$windowPattern
                        )
                    ) {
                        $windowPattern.Close()
                        if ([LibertixExplorerWindowApi]::EnsureClosed($nativeHandle, 5000)) {
                            $closedHandles[$nativeHandleKey] = $true
                            $closed++
                        }
                    }
                } catch {
                    # An Explorer window can disappear while its UI tree is read.
                }
            }

            Start-Sleep -Milliseconds 200
        }
    } catch {
        Write-Log "Could not inspect Explorer address bars for ${normalizedLetter}:; continuing." "Gray"
    }

    if ($closed -gt 0) {
        Write-Log "Closed $closed Explorer window(s) using temporary drive ${normalizedLetter}:." "Gray"
        # EnsureClosed already verified that the Explorer HWND no longer
        # exists. This final pause lets the shell finish releasing the volume.
        Start-Sleep -Milliseconds 500
    }
}

function Dismount-Letter {
    param([Parameter(Mandatory = $true)][string]$Letter)

    if (Test-Path "${Letter}:\") {
        Close-ExplorerWindowsForDrive -Letter $Letter
        try {
            $part = Get-Partition -DriveLetter $Letter -ErrorAction Stop
            Remove-PartitionAccessPath `
                -DiskNumber $part.DiskNumber `
                -PartitionNumber $part.PartitionNumber `
                -AccessPath "${Letter}:\" `
                -ErrorAction Stop
            # Explorer may create a separate error dialog only after the access
            # path disappears. Close only dialogs whose UI text names this
            # temporary drive, and allow enough time for the asynchronous shell
            # notification to arrive.
            Close-ExplorerWindowsForDrive `
                -Letter $Letter `
                -IncludeErrorDialogs `
                -RetryCount 25
            return
        } catch {
            Write-Log "Could not remove ${Letter}: with PowerShell; trying diskpart best-effort..." "Yellow"
        }

        try {
            Invoke-DiskpartScript -ScriptText @"
select volume $Letter
remove letter=$Letter
exit
"@
            Close-ExplorerWindowsForDrive `
                -Letter $Letter `
                -IncludeErrorDialogs `
                -RetryCount 25
        } catch {
            Write-Log "Could not remove drive letter ${Letter}:; continuing." "Yellow"
        }
    }
}

function Get-FreeDriveLetter {
    param([string[]]$ExcludedLetters = @())

    $used = @{}
    Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter } |
        ForEach-Object { $used[[string]$_.DriveLetter] = $true }

    foreach ($candidate in "X", "W", "V", "U", "T", "S", "R", "Q", "P", "O", "N", "M", "L", "K", "J", "I", "H", "G", "F", "E", "D") {
        if (
            $candidate -notin $ExcludedLetters -and
            -not $used.ContainsKey($candidate) -and
            -not (Test-Path "${candidate}:\")
        ) {
            return $candidate
        }
    }

    throw "No free drive letter available for Libertix installer partition."
}

function Set-VolumeLetterByLabel {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Letter
    )

    $vol = Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.FileSystemLabel -eq $Label } |
        Select-Object -First 1

    if ($vol -and $vol.DriveLetter) {
        return "$($vol.DriveLetter):"
    }

    $cim = Get-CimInstance Win32_Volume -Filter "Label='$Label'" `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $cim) {
        return $null
    }

    if ($cim.DriveLetter) {
        return "$($cim.DriveLetter.TrimEnd(':')):"
    }

    $deviceId = $cim.DeviceID
    if (-not $deviceId.EndsWith("\")) {
        $deviceId = "$deviceId\"
    }

    # Assign letter using mountvol (works even if previously hidden)
    $letterToUse = $Letter
    if (Test-Path "${letterToUse}:\") {
        $letterToUse = Get-FreeDriveLetter
    }

    & mountvol "${letterToUse}:" $deviceId | Out-Null

    if (-not (Test-Path "${letterToUse}:\")) {
        throw "Failed to assign a drive letter to volume labeled '$Label'."
    }

    return "${letterToUse}:"
}

function Set-WindowsVolumeReadableFromLinux {
    $manageBde = Get-NativeSystemExecutable -FileName "manage-bde.exe"

    try {
        $bitlockerVolume = Get-BitLockerVolume -MountPoint $SystemDrive -ErrorAction Stop
    } catch {
        throw "Cannot establish the BitLocker state of $SystemDrive. Refusing disk changes: $($_.Exception.Message)"
    }

    if (-not $bitlockerVolume) {
        throw "Get-BitLockerVolume returned no $SystemDrive volume. Refusing disk changes."
    }

    if (Test-BitLockerVolumeReadable -Volume $bitlockerVolume) {
        Write-Log "Windows $SystemDrive is already readable from Linux." "Green"
        return
    }

    Write-LibertixProgress -Stage "windows-decryption-start" -Percent 18
    Write-Log "Disabling BitLocker/device encryption on $SystemDrive before Linux live boot..." "Cyan"
    Disable-BitLocker -MountPoint $SystemDrive -ErrorAction Continue
    & $manageBde -off $SystemDrive 2>&1 | Out-Null

    $maxDecryptionWait = [TimeSpan]::FromHours(6)
    $decryptionTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $attempt = 0
    $lastEncryptedPercent = $null
    $samePercentCount = 0
    while ($decryptionTimer.Elapsed -lt $maxDecryptionWait) {
        Start-Sleep -Seconds 10
        $attempt++
        $bitlockerVolume = Get-BitLockerVolume -MountPoint $SystemDrive -ErrorAction Stop
        if (Test-BitLockerVolumeReadable -Volume $bitlockerVolume) {
            Write-LibertixProgress -Stage "windows-decryption-complete" -Percent 28
            Write-Log "Windows $SystemDrive decrypted." "Green"
            return
        }

        if ($null -ne $bitlockerVolume.EncryptionPercentage) {
            $encryptedPercent = [int]$bitlockerVolume.EncryptionPercentage
            if ($null -ne $lastEncryptedPercent -and $encryptedPercent -eq $lastEncryptedPercent) {
                $samePercentCount++
            } else {
                $samePercentCount = 0
                $lastEncryptedPercent = $encryptedPercent
            }
            $decryptedPercent = 100 - $encryptedPercent
            $overallPercent = 18 + [int][math]::Round($decryptedPercent * 10 / 100)
            Write-LibertixProgress `
                -Stage "windows-decryption" `
                -Percent $overallPercent `
                -DetailPercent $encryptedPercent
            Write-Log "Waiting for $SystemDrive decryption... $encryptedPercent% encrypted, protection=$($bitlockerVolume.ProtectionStatus)" "Yellow"
        } else {
            Write-Log "Waiting for $SystemDrive decryption... status=$($bitlockerVolume.VolumeStatus), protection=$($bitlockerVolume.ProtectionStatus)" "Yellow"
        }

        if (($attempt % 12) -eq 0 -or $samePercentCount -ge 12) {
            Write-Log "Reasserting BitLocker decryption request for $SystemDrive..." "Yellow"
            Disable-BitLocker -MountPoint $SystemDrive -ErrorAction Continue
            & $manageBde -off $SystemDrive 2>&1 | Out-Null
            $samePercentCount = 0
        }

    }
    $decryptionTimer.Stop()
    $finalStatus = & $manageBde -status $SystemDrive 2>&1 | Out-String
    throw "Timed out waiting for $SystemDrive BitLocker decryption. Final status: $finalStatus"
}
