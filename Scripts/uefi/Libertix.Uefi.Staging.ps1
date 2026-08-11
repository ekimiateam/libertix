#requires -Version 5.1

# Installer partition preparation, ISO deployment, and temporary UEFI boot.

function ConvertTo-LibertixBootOrderArray {
    param([AllowNull()][object]$Order)

    [uint16[]]$normalized = @(
        @($Order) |
            Where-Object { $null -ne $_ } |
            ForEach-Object { [uint16]$_ }
    )
    return ,$normalized
}

function Format-LibertixBootOrderEntries {
    param([AllowNull()][object]$Order)

    [uint16[]]$normalized = ConvertTo-LibertixBootOrderArray -Order $Order
    if ($normalized.Count -eq 0) {
        return "absent"
    }
    return (($normalized | ForEach-Object { "Boot{0:X4}" -f $_ }) -join ",")
}

function Get-LibertixFirmwareBootVariableSummary {
    param([Parameter(Mandatory = $true)][string]$Name)

    try {
        if (-not (Test-FirmwareVariableExists -Name $Name)) {
            return "absent"
        }
        $bytes = Get-FirmwareVariableBytes -Name $Name
        return Format-LibertixBootOrderEntries `
            -Order (ConvertFrom-BootOrderBytes -Bytes $bytes)
    } catch {
        return "unavailable($($_.Exception.GetType().Name))"
    }
}

function New-OrReuseInstallerPartition {
    param([Parameter(Mandatory = $true)][int]$SizeGB)

    $existingPartition = Get-VerifiedTransactionPartition
    if ($existingPartition) {
        if (-not $existingPartition.DriveLetter) {
            $existingDriveLetter = Get-LibertixFreeDriveLetter
            Set-Partition `
                -DiskNumber $existingPartition.DiskNumber `
                -PartitionNumber $existingPartition.PartitionNumber `
                -NewDriveLetter $existingDriveLetter `
                -ErrorAction Stop
            $existingPartition = Get-Partition `
                -DiskNumber $existingPartition.DiskNumber `
                -PartitionNumber $existingPartition.PartitionNumber `
                -ErrorAction Stop
        }
        $existingVolume = $existingPartition | Get-Volume -ErrorAction Stop
        if ($existingVolume.FileSystemLabel -ne $InstallerLabel) {
            throw "Saved transaction partition label changed; refusing reuse."
        }
        $existing = "$($existingPartition.DriveLetter):"
        $guid = $null
        if ($existingPartition.Guid) {
            $guid = Get-GuidDLower -Guid $existingPartition.Guid
        }
        Update-LibertixInstallationPlanPartition -Partition $existingPartition
        return @{
            Drive = $existing
            GuidD = $guid
            DiskNumber = $existingPartition.DiskNumber
            PartitionNumber = $existingPartition.PartitionNumber
        }
    }
    if (Test-LibertixInstallerPartitionPresent) {
        throw "$InstallerLabel exists without an owned transaction state; refusing reuse."
    }

    if (-not $installationPlan) {
        throw "An installation plan is required before partition preparation."
    }
    $requestedBytes = [int64]$installationPlan.disk.installer.finalSizeBytes
    $stagingBytes = [int64]$installationPlan.disk.installer.stagingSizeBytes
    if ($requestedBytes -ne ([int64]$SizeGB * 1GB)) {
        throw "InstallerPartitionSizeGB does not match the installation plan."
    }
    $stagingSizeGB = [int]($stagingBytes / 1GB)
    $systemPartition = Get-Partition -DriveLetter $SystemDriveLetter -ErrorAction Stop
    $systemDisk = Get-Disk -Number $systemPartition.DiskNumber -ErrorAction Stop

    $shrinkGeometry = Get-LibertixAlignedShrinkGeometry `
        -PartitionOffsetBytes ([int64]$systemPartition.Offset) `
        -PartitionSizeBytes ([int64]$systemPartition.Size) `
        -RequestedAllocationBytes $requestedBytes `
        -LogicalSectorSizeBytes ([int64]$systemDisk.LogicalSectorSize)
    $shrinkBytes = [int64]$shrinkGeometry.ShrinkBytes
    $installerOffsetBytes = [int64]$shrinkGeometry.InstallerOffsetBytes
    $recoveryOffsetBytes = [int64]$installationPlan.disk.recovery.offsetBytes
    if (
        $requestedBytes -gt $recoveryOffsetBytes -or
        $installerOffsetBytes -gt $recoveryOffsetBytes - $requestedBytes
    ) {
        throw "The requested Linux partition would overlap Windows Recovery."
    }
    if ($stagingSizeGB -lt $SizeGB) {
        Write-Log "Reserving ${SizeGB}GB for Linux with a compatible ${stagingSizeGB}GB FAT32 staging partition '$InstallerLabel'..." "Cyan"
    } else {
        Write-Log "Creating ${SizeGB}GB FAT32 installer partition '$InstallerLabel'..." "Cyan"
    }

    Start-LibertixTrackedStep -Step "windows.recovery-armed"
    Save-TransactionPreparationState -SystemPartition $systemPartition
    Complete-LibertixTrackedStep -Step "windows.recovery-armed"

    if ($ShareWindowsFilesInLinux) {
        # Fast Startup leaves NTFS metadata cached by Windows. Linux mounts the
        # shared volume read-write, so hibernation must remain disabled for the
        # installed system. Run powercfg even when the registry already says
        # disabled: cloned images can retain a stale hiberfile or inconsistent
        # power state that only the supported Windows command can normalize.
        Set-HibernateEnabled -Enabled $false
    }

    # Read free space after hibernation has been disabled. hiberfil.sys can be
    # several GiB, so checking the earlier volume snapshot rejects layouts that
    # become safely shrinkable as part of this transaction. The shared budget
    # applies the same bounded Windows free-space policy to BIOS and UEFI.
    $freeSpaceBudget = Wait-LibertixWindowsFreeSpaceBudget `
        -DriveLetter $SystemDriveLetter `
        -AllocationBytes $shrinkBytes
    [int64]$remainingBytes = [int64]$freeSpaceBudget.AvailableBytes
    if (-not $freeSpaceBudget.Accepted) {
        throw (
            "Not enough free space on $SystemDrive " +
            "(available=$remainingBytes bytes, " +
            "required=$($freeSpaceBudget.RequiredBytes) bytes, " +
            "acceptedFloor=$($freeSpaceBudget.AcceptedFloorBytes) bytes)."
        )
    }
    if ($freeSpaceBudget.WithinTolerance) {
        Write-Log (
            "Windows free space is within the bounded tolerance: " +
            "available=$remainingBytes required=$($freeSpaceBudget.RequiredBytes)."
        ) "Yellow"
    }

    $supported = $systemPartition | Get-PartitionSupportedSize -ErrorAction Stop
    $maxShrink = [int64]$systemPartition.Size - [int64]$supported.SizeMin
    if ($shrinkBytes -gt $maxShrink) {
        throw "Cannot shrink $SystemDrive by ${SizeGB}GB (max ~$( [math]::Round($maxShrink / 1GB, 1) ) GB)."
    }

    Start-LibertixTrackedStep -Step "windows.system-volume-shrunk"
    # A cloned Windows partition can end between 1 MiB boundaries. Move its
    # new end back to the preceding boundary so CreatePartition does not lose
    # part of the requested extent while aligning the staging partition.
    Resize-Partition `
        -DriveLetter $SystemDriveLetter `
        -Size ($systemPartition.Size - $shrinkBytes) `
        -ErrorAction Stop
    Start-Sleep -Seconds 2
    $systemPartition = Get-Partition -DriveLetter $SystemDriveLetter -ErrorAction Stop
    if (
        [int64]$systemPartition.Offset -ne [int64]$installationPlan.disk.windows.offsetBytes -or
        [int64]$systemPartition.Size -ne [int64]$shrinkGeometry.TargetSizeBytes
    ) {
        throw "Windows partition geometry does not match the aligned shrink target."
    }
    Complete-LibertixTrackedStep -Step "windows.system-volume-shrunk"

    Start-LibertixTrackedStep -Step "windows.installer-partition-created"
    $newPartition = New-Partition `
        -DiskNumber $systemPartition.DiskNumber `
        -Size $stagingBytes `
        -Offset $installerOffsetBytes `
        -Alignment ([int64]$shrinkGeometry.AlignmentBytes) `
        -ErrorAction Stop

    # Persist the returned identity before checking any postcondition. A RAW
    # partition with unexpected geometry still belongs to this transaction and
    # must remain discoverable by rollback.
    Save-TransactionPartitionState -Partition $newPartition

    if (
        [int64]$newPartition.Offset -ne $installerOffsetBytes -or
        [int64]$newPartition.Size -ne $stagingBytes
    ) {
        throw "Windows created the installer partition with unexpected geometry."
    }

    Format-Volume `
        -Partition $newPartition `
        -FileSystem FAT32 `
        -NewFileSystemLabel $InstallerLabel `
        -Confirm:$false `
        -Force `
        -ErrorAction Stop | Out-Null

    # Exposing a RAW partition through a drive letter makes Explorer display a
    # modal format prompt. Assign the access path only after FAT32 exists, while
    # still letting Mount Manager avoid persistent or disconnected mappings.
    $formattedPartition = Get-VerifiedTransactionPartition
    Add-PartitionAccessPath `
        -InputObject $formattedPartition `
        -AssignDriveLetter `
        -ErrorAction Stop | Out-Null
    $verifiedPartition = Get-VerifiedTransactionPartition
    $createdDriveLetter = [string]$verifiedPartition.DriveLetter
    if ([string]::IsNullOrWhiteSpace($createdDriveLetter)) {
        throw "Windows formatted the installer partition but did not assign a drive letter."
    }

    $tries = 0
    while (-not (Test-Path "${createdDriveLetter}:\") -and $tries -lt 15) {
        Start-Sleep -Seconds 1
        $tries++
    }

    if (-not (Test-Path "${createdDriveLetter}:\")) {
        throw "Failed to access ${createdDriveLetter}: after creating the Libertix installer partition."
    }

    # Formatting can cause Windows to renumber a GPT partition that was inserted
    # before WinRE. Persist the post-format object, not New-Partition's stale one.
    Save-TransactionPartitionState -Partition $verifiedPartition
    Update-LibertixInstallationPlanPartition -Partition $verifiedPartition
    Complete-LibertixTrackedStep -Step "windows.installer-partition-created"
    $guid = $null
    if ($verifiedPartition.Guid) {
        $guid = Get-GuidDLower -Guid $verifiedPartition.Guid
    }

    return @{
        Drive = "${createdDriveLetter}:"
        GuidD = $guid
        DiskNumber = $verifiedPartition.DiskNumber
        PartitionNumber = $verifiedPartition.PartitionNumber
    }
}

function Get-ReusablePreparedInstallerPartition {
    $partition = Get-VerifiedTransactionPartition
    if (-not $partition) {
        throw "Owned prepared installer partition is missing; refusing firmware fallback."
    }
    if (-not $partition.DriveLetter) {
        $preparedDriveLetter = Get-LibertixFreeDriveLetter
        Set-Partition `
            -DiskNumber $partition.DiskNumber `
            -PartitionNumber $partition.PartitionNumber `
            -NewDriveLetter $preparedDriveLetter `
            -ErrorAction Stop
        $partition = Get-Partition `
            -DiskNumber $partition.DiskNumber `
            -PartitionNumber $partition.PartitionNumber `
            -ErrorAction Stop
    }
    $volume = $partition | Get-Volume -ErrorAction Stop
    if ($volume.FileSystem -ne "FAT32") {
        throw "Prepared installer partition is not FAT32; refusing firmware fallback."
    }
    if ($volume.FileSystemLabel -ne $InstallerLabel) {
        throw "Prepared installer partition label changed; refusing firmware fallback."
    }
    if ($volume.HealthStatus -ne "Healthy") {
        throw "Prepared installer partition is not healthy; refusing firmware fallback."
    }
    $drive = "$($partition.DriveLetter):"
    if (-not (Test-Path "$drive\")) {
        throw "Prepared installer partition is not accessible after drive-letter assignment."
    }
    return @{
        Drive = $drive
        DiskNumber = [int]$partition.DiskNumber
        PartitionNumber = [int]$partition.PartitionNumber
    }
}

function Install-LibertixIsoToPartition {
    param(
        [Parameter(Mandatory = $true)][string]$PartitionDrive
    )

    if ($RecoveryRunId -notmatch '^[0-9a-f]{32}$') {
        throw "A valid recovery run identifier is required for live-media staging."
    }
    $tmpDir = Join-Path `
        $SystemDrive `
        "ProgramData\Libertix\Downloads\$RecoveryRunId\live-media"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    $isoPath = Join-Path $tmpDir $InstallerIsoName

    try {
        Write-LibertixProgress -Stage "live-iso-download" -Percent 62
        Write-Log "Downloading Libertix UEFI ISO..." "Cyan"
        # Keep the configured canonical URL unchanged. Some filepool frontends
        # redirect only that exact resource and return 404 for arbitrary query
        # parameters; integrity is already enforced by the SHA-256 check below.
        $downloadUrl = $InstallerIsoUrl

        Start-RobustDownload `
            -Url $downloadUrl `
            -Destination $isoPath `
            -Label "Libertix UEFI ISO" `
            -MaxBytes $script:MaximumLiveIsoBytes

        if (-not (Test-Path $isoPath)) {
            throw "ISO download failed."
        }

        $actualIsoHash = (Get-FileHash -Algorithm SHA256 -Path $isoPath).Hash.ToLowerInvariant()
        Write-Log "Libertix UEFI ISO SHA256: $actualIsoHash" "Gray"
        if ($actualIsoHash -ne $InstallerIsoSha256) {
            throw "Downloaded Libertix UEFI ISO hash mismatch. Expected $InstallerIsoSha256, got $actualIsoHash"
        }

        Write-Log "Mounting ISO..." "Cyan"
        Mount-DiskImage -ImagePath $isoPath -PassThru | Out-Null
        $isoDrive = Get-MountedIsoDrive -ImagePath $isoPath

        $src = "$isoDrive\*"
        $dst = "$PartitionDrive\"

        Write-LibertixProgress -Stage "live-iso-copy" -Percent 78
        Write-Log "Copying ISO contents to $PartitionDrive..." "Cyan"
        Copy-Item -Path $src -Destination $dst -Recurse -Force

        # live-boot discovers images with a case-sensitive *.squashfs glob.
        # Its toram copy also recreates directory names on a case-sensitive
        # tmpfs. Windows can expose ISO9660-only names in uppercase while
        # copying to FAT, so force the long VFAT names used by the initramfs.
        $expectedLiveDirectory = Join-Path $PartitionDrive "live"
        $actualLiveDirectories = @(
            Get-ChildItem -LiteralPath $PartitionDrive -Directory -ErrorAction Stop |
                Where-Object { $_.Name -ieq "live" }
        )
        if ($actualLiveDirectories.Count -ne 1) {
            throw "Expected exactly one copied live directory; found $($actualLiveDirectories.Count)."
        }
        if ($actualLiveDirectories[0].Name -cne "live") {
            $temporaryLiveDirectory = Join-Path $PartitionDrive ".libertix-live-case-$([Guid]::NewGuid().ToString('N'))"
            Move-Item -LiteralPath $actualLiveDirectories[0].FullName -Destination $temporaryLiveDirectory -Force
            Move-Item -LiteralPath $temporaryLiveDirectory -Destination $expectedLiveDirectory -Force
        }
        if ((Get-Item -LiteralPath $expectedLiveDirectory -ErrorAction Stop).Name -cne "live") {
            throw "Live directory name case normalization failed."
        }

        foreach ($relativePath in @(
            "live\filesystem.squashfs",
            "live\initrd.img",
            "live\vmlinuz"
        )) {
            $expectedPath = Join-Path $PartitionDrive $relativePath
            $parent = Split-Path -Parent $expectedPath
            $expectedName = Split-Path -Leaf $expectedPath
            $actual = @(
                Get-ChildItem -LiteralPath $parent -File -ErrorAction Stop |
                    Where-Object { $_.Name -ieq $expectedName }
            )
            if ($actual.Count -ne 1) {
                throw "Expected exactly one copied live file for $relativePath; found $($actual.Count)."
            }
            if ($actual[0].Name -cne $expectedName) {
                $temporaryPath = Join-Path $parent ".libertix-case-$([Guid]::NewGuid().ToString('N'))"
                Move-Item -LiteralPath $actual[0].FullName -Destination $temporaryPath -Force
                Move-Item -LiteralPath $temporaryPath -Destination $expectedPath -Force
            }
            $verifiedName = (Get-Item -LiteralPath $expectedPath -ErrorAction Stop).Name
            if ($verifiedName -cne $expectedName) {
                throw "Live file name case normalization failed: expected $expectedName, got $verifiedName."
            }
        }

        if ($LowMemoryMode) {
            $bootConfigs = @(Get-ChildItem -Path $PartitionDrive -Filter "*.cfg" -Recurse -File)
            if ($bootConfigs.Count -eq 0) {
                throw "No boot configuration was found for low-memory mode."
            }
            foreach ($bootConfig in $bootConfigs) {
                $content = Get-Content -LiteralPath $bootConfig.FullName -Raw
                $updated = $content -replace `
                    '(?i)(^|\s)toram(?=\s|$)',
                    '$1toram=filesystem.squashfs'
                if (
                    $updated -eq $content -and
                    $content -notmatch 'toram=filesystem\.squashfs'
                ) {
                    continue
                }
                attrib -R -S -H $bootConfig.FullName 2>$null
                Set-Content -LiteralPath $bootConfig.FullName -Value $updated -Encoding ASCII -NoNewline
            }
            $configured = @(Get-ChildItem -Path $PartitionDrive -Filter "*.cfg" -Recurse -File | Where-Object {
                (Get-Content -LiteralPath $_.FullName -Raw) -match 'toram=filesystem\.squashfs'
            })
            if ($configured.Count -eq 0) {
                throw "Low-memory boot configuration could not be applied."
            }
            Write-Log "Low-memory SquashFS module boot configured in $($configured.Count) boot files." "Green"
        }

        $requiredFiles = @(
            "EFI\debian\shimx64.efi",
            "EFI\debian\grubx64.efi",
            "EFI\debian\mmx64.efi",
            "EFI\debian\grub.cfg",
            "EFI\LibertixInstaller\shimx64.efi",
            "EFI\LibertixInstaller\grubx64.efi",
            "EFI\LibertixInstaller\mmx64.efi",
            "EFI\LibertixInstaller\grub.cfg",
            "live\vmlinuz",
            "live\initrd.img",
            "live\filesystem.squashfs"
        )
        foreach ($relativePath in $requiredFiles) {
            $fullPath = Join-Path $PartitionDrive $relativePath
            if (-not (Test-Path $fullPath)) {
                throw "Installer copy verification failed; missing $fullPath"
            }
            if ((Get-Item $fullPath).Length -le 0) {
                throw "Installer copy verification failed; empty file $fullPath"
            }
        }

        Dismount-DiskImage -ImagePath $isoPath | Out-Null
        Write-Log "Libertix UEFI installer copied." "Green"
    } finally {
        try {
            Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue |
                Out-Null
        } catch {
            Write-Verbose "Best-effort installer image dismount failed: $($_.Exception.Message)"
        }

        Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Set-LibertixUefiBootEntry {
    param(
        [Parameter(Mandatory = $true)][string]$InstallerDrive,
        [Parameter(Mandatory = $true)][int]$InstallerDiskNumber,
        [Parameter(Mandatory = $true)][int]$InstallerPartitionNumber,
        [switch]$ReusePreparedInstaller = $false
    )

    Write-Log "Configuring one-time UEFI boot entry..." "Cyan"

    if (-not (Test-Path "$InstallerDrive\")) {
        $InstallerDrive = Set-VolumeLetterByLabel -Label $InstallerLabel -Letter $InstallerLetter
        if (-not $InstallerDrive -or -not (Test-Path "$InstallerDrive\")) {
            throw "Cannot assign a drive letter to the Libertix installer partition before UEFI boot setup."
        }
    }

    $espDrive = $null
    $loaderHashes = @{}
    $espPartition = Get-WindowsEspPartition
    $loaderPath = "\$InstallerEspDirectory\BOOTX64.EFI"
    try {
        $espDrive = Mount-Esp -Letter $EspLetter
        if ($ReusePreparedInstaller) {
            $state = Get-TransactionPartitionState
            if (-not $state -or -not $state.EspLoaderSha256) {
                throw "Temporary ESP loader SHA256 state is missing; refusing firmware fallback."
            }
            $destination = Join-Path $espDrive $InstallerEspDirectory
            Assert-LibertixTemporaryEspOwnership -Directory $destination
            foreach ($relativePath in @("BOOTX64.EFI", "grubx64.efi", "mmx64.efi", "grub.cfg")) {
                $saved = $state.EspLoaderSha256.PSObject.Properties[$relativePath]
                if (-not $saved -or [string]::IsNullOrWhiteSpace([string]$saved.Value)) {
                    throw "Temporary ESP loader SHA256 state has no hash for $relativePath"
                }
                $fullPath = Join-Path $destination $relativePath
                if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
                    throw "Temporary ESP loader is missing: $relativePath"
                }
                $actual = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                if ($actual -ne ([string]$saved.Value).ToLowerInvariant()) {
                    throw "Temporary ESP loader SHA256 mismatch: $relativePath"
                }
                $loaderHashes[$relativePath] = $actual
            }
            Write-Log "Temporary ESP loader SHA256 verified ($($loaderHashes.Count) files)." "Green"
        } else {
            $loaderHashes = Install-LibertixTemporaryBootloaderOnEsp -EspDrive $espDrive -InstallerDrive $InstallerDrive
        }
    } finally {
        if ($espDrive) {
            Dismount-Letter -Letter ($espDrive.Substring(0, 1))
        }
    }

    if (-not $espPartition) {
        throw "Windows ESP partition could not be resolved for UEFI boot setup."
    }

    if (-not $ReusePreparedInstaller) {
        $driveRoot = "$InstallerDrive\"
        $grubConfig = Get-LibertixStagingGrubConfig `
            -UseLowMemoryMode ([bool]$LowMemoryMode)
        foreach ($grubConfigDir in @(
            (Join-Path $driveRoot "EFI\debian"),
            (Join-Path $driveRoot "EFI\LibertixInstaller"),
            (Join-Path $driveRoot "EFI\BOOT"),
            (Join-Path $driveRoot "boot\grub")
        )) {
            New-Item -ItemType Directory -Path $grubConfigDir -Force | Out-Null
            $grubConfigPath = Join-Path $grubConfigDir "grub.cfg"
            if (Test-Path $grubConfigPath) {
                attrib -R -S -H $grubConfigPath 2>$null
                Remove-Item -Path $grubConfigPath -Force
            }
            Set-Content -Path $grubConfigPath -Value $grubConfig -Encoding ASCII
        }
    }

    Remove-LibertixTemporaryFirmwareEntries
    foreach ($identifier in @("{bootmgr}", "{fwbootmgr}")) {
        try {
            Invoke-BcdeditCommand -Arguments @("/deletevalue", $identifier, "bootsequence") | Out-Null
        } catch {
            Write-Verbose "One-shot BCD sequence was already absent for ${identifier}: $($_.Exception.Message)"
        }
    }

    $transactionState = Get-TransactionPartitionState
    $originalBootOrderRawBytes = $null
    $bootOrderSourceName = "firmware"
    $originalBootOrderSource = if (
        $ReusePreparedInstaller -and $transactionState -and $transactionState.OriginalBootOrder
    ) {
        $bootOrderSourceName = "transaction"
        $transactionState.OriginalBootOrder
    } else {
        [byte[]]$originalBootOrderRawBytes = @(
            Get-FirmwareVariableBytes -Name "BootOrder"
        )
        ConvertFrom-BootOrderBytes -Bytes $originalBootOrderRawBytes
    }
    $sourceRuntimeType = if ($null -eq $originalBootOrderSource) {
        "null"
    } else {
        $originalBootOrderSource.GetType().FullName
    }
    [uint16[]]$originalBootOrder = ConvertTo-LibertixBootOrderArray `
        -Order $originalBootOrderSource
    $rawLength = if ($null -eq $originalBootOrderRawBytes) {
        "not-read"
    } else {
        $originalBootOrderRawBytes.Count
    }
    $bootOrderEntries = Format-LibertixBootOrderEntries -Order $originalBootOrder
    $bootCurrent = Get-LibertixFirmwareBootVariableSummary -Name "BootCurrent"
    $bootNext = Get-LibertixFirmwareBootVariableSummary -Name "BootNext"
    Write-Log (
        "UEFI BootOrder context: source=$bootOrderSourceName; " +
        "rawLength=$rawLength; sourceType=$sourceRuntimeType; " +
        "normalizedType=$($originalBootOrder.GetType().FullName); " +
        "entries=$bootOrderEntries; BootCurrent=$bootCurrent; BootNext=$bootNext"
    ) "Cyan"
    if ($originalBootOrder.Count -eq 0) {
        throw "UEFI BootOrder is empty; refusing to prepare a temporary boot entry."
    }

    if ($BootStrategy -eq "BootNext") {
        $bootVariable = Set-NativeUefiBootOrderOnce `
            -InstallerDrive "${EspLetter}:" `
            -InstallerDiskNumber $espPartition.DiskNumber `
            -InstallerPartitionNumber $espPartition.PartitionNumber `
            -LoaderPath $loaderPath
        $bootVariableMatch = [regex]::Match($bootVariable, "^Boot([0-9A-Fa-f]{4})$")
        if (-not $bootVariableMatch.Success) {
            throw "Unexpected native UEFI boot variable name: $bootVariable"
        }

        $bootNumber = [Convert]::ToUInt16($bootVariableMatch.Groups[1].Value, 16)
        Assert-LibertixFirmwareEntry -BootNumber $bootNumber -LoaderPath $loaderPath
        # Record the exact Boot#### owner before writing BootNext so recovery
        # can remove an entry left by an interruption at either boundary.
        Update-TransactionFirmwareState `
            -BootNumber $bootNumber `
            -BootVariable $bootVariable `
            -EspLoaderSha256 $loaderHashes `
            -OriginalBootOrder $originalBootOrder
        Set-FirmwareVariable -Name "BootNext" -Value (ConvertTo-BootOrderBytes -Order @($bootNumber))
        $bootNext = @(ConvertFrom-BootOrderBytes -Bytes (Get-FirmwareVariableBytes -Name "BootNext"))
        if ($bootNext.Count -ne 1 -or [uint16]$bootNext[0] -ne $bootNumber) {
            throw "UEFI BootNext read-back does not point to $bootVariable."
        }
        Write-Log "BootNext verified: $bootVariable -> ESP:$loaderPath" "Green"
        return
    }

    if (Test-FirmwareVariableExists -Name "BootNext") {
        Remove-FirmwareVariable -Name "BootNext"
    }
    if (Test-FirmwareVariableExists -Name "BootNext") {
        throw "UEFI BootNext still exists; refusing a BootOrder fallback that firmware would bypass."
    }

    $fallbackEspDrive = $null
    try {
        $fallbackEspDrive = Mount-Esp -Letter $EspLetter
        $firmwareEntry = New-LibertixBcdFirmwareEntry `
            -EspDrive $fallbackEspDrive `
            -LoaderPath $loaderPath `
            -EspLoaderSha256 $loaderHashes `
            -OriginalBootOrder $originalBootOrder
    } finally {
        if ($fallbackEspDrive) {
            Dismount-Letter -Letter $EspLetter
        }
    }
    $fallbackOrder = @(
        ConvertFrom-BootOrderBytes -Bytes (Get-FirmwareVariableBytes -Name "BootOrder")
    )
    if ($fallbackOrder.Count -eq 0 -or [uint16]$fallbackOrder[0] -ne $firmwareEntry.BootNumber) {
        throw "BCD firmware fallback did not place $($firmwareEntry.BootVariable) first in UEFI BootOrder."
    }
    Update-TransactionFirmwareState `
        -BootNumber $firmwareEntry.BootNumber `
        -BootVariable $firmwareEntry.BootVariable `
        -FirmwareEntryId $firmwareEntry.EntryId `
        -EspLoaderSha256 $loaderHashes `
        -OriginalBootOrder $originalBootOrder
    Write-Log "Firmware BootOrder fallback verified: $($firmwareEntry.BootVariable) -> ESP:$loaderPath" "Green"
}
