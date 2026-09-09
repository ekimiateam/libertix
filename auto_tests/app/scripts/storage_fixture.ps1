#requires -Version 5.1
param([Parameter(Mandatory = $true)][string]$ConfigPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

function Get-FixtureInventory {
    $letter = $env:SystemDrive.TrimEnd(':').ToUpperInvariant()
    $windows = Get-Partition -DriveLetter $letter
    $volume = $windows | Get-Volume
    $minimum = Get-PartitionSupportedSize -DiskNumber $windows.DiskNumber -PartitionNumber $windows.PartitionNumber
    $decrypted = $false
    $encryptedVolumes = @(Get-CimInstance -Namespace 'root/CIMV2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume)
    foreach ($encrypted in $encryptedVolumes) {
        if ([string]$encrypted.DriveLetter -ieq $env:SystemDrive) {
            $conversion = Invoke-CimMethod -InputObject $encrypted -MethodName GetConversionStatus
            $decrypted = $conversion.ReturnValue -eq 0 -and
                $conversion.ConversionStatus -eq 0 -and $conversion.EncryptionPercentage -eq 0
        }
    }
    $disks = @(foreach ($disk in @(Get-Disk | Where-Object { $_.Size -gt 0 } | Sort-Object Number)) {
        $partitions = @()
        if ([string]$disk.PartitionStyle -ne 'RAW') {
            $partitions = @(foreach ($part in @(Get-Partition -DiskNumber $disk.Number | Sort-Object Offset)) {
                $partVolume = @($part | Get-Volume -ErrorAction SilentlyContinue)
                $filesystem = if ($partVolume.Count -eq 1) { [string]$partVolume[0].FileSystemType } else { '' }
                $type = if ([string]$disk.PartitionStyle -eq 'GPT') { [string]$part.GptType } else { [string][int]$part.MbrType }
                [ordered]@{
                    number = [int]$part.PartitionNumber
                    offset = [long]$part.Offset
                    size = [long]$part.Size
                    drive_letter = ([string]$part.DriveLetter).Trim([char]0).ToUpperInvariant()
                    type = $type.ToLowerInvariant()
                    filesystem = $filesystem
                }
            })
        }
        [ordered]@{
            number = [int]$disk.Number
            unique_id = ([string]$disk.UniqueId).Trim()
            device_path = [string]$disk.Path
            serial_number = ([string]$disk.SerialNumber).Trim()
            partition_table_id = if ([string]$disk.PartitionStyle -eq 'GPT') { [string]$disk.Guid } elseif ([string]$disk.PartitionStyle -eq 'MBR') { [string]$disk.Signature } else { '' }
            size = [long]$disk.Size
            style = [string]$disk.PartitionStyle
            bus_type = [string]$disk.BusType
            offline = [bool]$disk.IsOffline
            read_only = [bool]$disk.IsReadOnly
            boot = [bool]$disk.IsBoot
            system = [bool]$disk.IsSystem
            partitions = $partitions
        }
    })
    $letters = @(@(Get-Volume | ForEach-Object { ([string]$_.DriveLetter).Trim([char]0) }) +
        @(Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Name) |
        Where-Object { $_ -match '^[A-Za-z]$' } | ForEach-Object { $_.ToUpperInvariant() } | Sort-Object -Unique)
    [ordered]@{
        system_drive = $letter
        system_disk_number = [int]$windows.DiskNumber
        disks = $disks
        system_min_size = [long]$minimum.SizeMin
        system_volume_healthy = ([string]$volume.HealthStatus -eq 'Healthy')
        system_volume_decrypted = $decrypted
        used_drive_letters = $letters
    }
}

function Resolve-FixtureDisk {
    param([string]$DevicePath)
    $diskMatches = @(Get-Disk | Where-Object { [string]$_.Path -ceq $DevicePath })
    if ($diskMatches.Count -ne 1 -or $diskMatches[0].IsOffline -or $diskMatches[0].IsReadOnly) {
        throw 'The fixture disk identity is missing, ambiguous or not writable.'
    }
    $diskMatches[0]
}

function Assert-FixtureHardwareIdentity {
    param([object[]]$Disks)
    $paths = @($Disks | ForEach-Object { ([string]$_.device_path).Trim().ToLowerInvariant() })
    if (@($paths | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -ne 0 -or
        @($paths | Sort-Object -Unique).Count -ne $paths.Count) {
        throw 'The test baseline reports duplicate or missing disk device paths.'
    }
    # Vendor-format UniqueId values can repeat for distinct virtual disks.
    $tableIds = @(foreach ($disk in $Disks) {
        if ([string]$disk.style -eq 'RAW') { continue }
        $identity = ([string]$disk.partition_table_id).Trim().Trim('{', '}').ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($identity)) {
            throw 'The test baseline reports duplicate or missing partition-table identifiers.'
        }
        ([string]$disk.style) + ':' + $identity
    })
    if (@($tableIds | Sort-Object -Unique).Count -ne $tableIds.Count) {
        throw 'The test baseline reports duplicate or missing partition-table identifiers.'
    }
}

function New-FixtureWitness {
    param($Disk, $Partition, [string]$Name)
    $volumes = @($Partition | Get-Volume)
    if ($volumes.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$volumes[0].Path)) {
        throw 'The new fixture volume has no unambiguous volume path.'
    }
    $relative = 'libertix-test-witness-' + [Guid]::NewGuid().ToString('N') + '.txt'
    $path = Join-Path ([string]$volumes[0].Path) $relative
    $bytes = [Text.Encoding]::UTF8.GetBytes('Libertix storage preservation fixture: ' + $Name + ' ' + [Guid]::NewGuid().ToString('N'))
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    [ordered]@{
        disk_device_path = [string]$Disk.Path
        partition_offset = [long]$Partition.Offset
        partition_size = [long]$Partition.Size
        volume_id = [string]$volumes[0].UniqueId
        drive_letter = ([string]$volumes[0].DriveLetter).Trim([char]0).ToUpperInvariant()
        relative_path = $relative
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Invoke-FixtureDiskPart {
    param([Parameter(Mandatory = $true)][string]$Commands)

    $process = New-Object Diagnostics.Process
    try {
        $nativeDirectory = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
            'Sysnative'
        } else { 'System32' }
        $process.StartInfo.FileName = Join-Path $env:SystemRoot "$nativeDirectory\diskpart.exe"
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardInput = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        if (-not $process.Start()) { throw 'The fixture DiskPart process did not start.' }
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.WriteLine($Commands)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(60000)) {
            $process.Kill()
            $null = $process.WaitForExit(5000)
            throw 'The fixture DiskPart creation timed out; installation must not start.'
        }
        if (-not $output.Wait(5000) -or -not $errors.Wait(5000)) {
            throw 'The fixture DiskPart output did not close.'
        }
        if ($process.ExitCode -ne 0) {
            throw "The fixture DiskPart creation failed ($($process.ExitCode)): $($output.Result) $($errors.Result)"
        }
    } finally { $process.Dispose() }
}

function New-FixtureSystemPartition {
    param(
        [Parameter(Mandatory = $true)][object]$Disk,
        [Parameter(Mandatory = $true)][long]$Offset,
        [Parameter(Mandatory = $true)][long]$Size,
        [switch]$Recovery
    )

    $current = Resolve-FixtureDisk ([string]$Disk.Path)
    if ($current.Number -ne $Disk.Number -or $current.PartitionStyle -ne $Disk.PartitionStyle -or
        $current.Size -ne $Disk.Size -or $current.Guid -ne $Disk.Guid -or $current.Signature -ne $Disk.Signature) {
        throw 'The fixture disk changed before partition creation.'
    }
    $before = @(Get-Partition -DiskNumber $current.Number)
    if ($Offset -le 0 -or $Offset % 1MB -ne 0 -or $Size % 1MB -ne 0 -or
        $Size -lt 256MB -or $Size -gt 4GB -or $Offset -gt ([long]$current.Size - $Size) -or
        @($before | Where-Object { $_.Offset -lt ($Offset + $Size) -and ($_.Offset + $_.Size) -gt $Offset }).Count) {
        throw 'The fixture creation extent is invalid or overlaps an existing partition.'
    }
    if ([string]$current.PartitionStyle -eq 'MBR') {
        if ($before.Count -ge 4 -or @($before | Where-Object { [int]$_.MbrType -in @(5, 15, 133) }).Count) {
            throw 'The fixture has no free primary MBR partition slot.'
        }
        # New-Partition may consume the fourth slot as an extended container instead of the requested primary.
        $typeArgument = if ($Recovery) { ' id=27' } else { '' }
        $commands = "select disk $([int]$current.Number)`r`ncreate partition primary size=$($Size / 1MB) offset=$($Offset / 1KB)$typeArgument`r`nexit"
        Invoke-FixtureDiskPart -Commands $commands
    } elseif ([string]$current.PartitionStyle -eq 'GPT') {
        $arguments = @{ DiskNumber = $current.Number; Offset = $Offset; Size = $Size }
        # Set the final type before a filesystem is mounted, avoiding a live type conversion.
        if ($Recovery) { $arguments.GptType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}' }
        New-Partition @arguments | Out-Null
    } else { throw 'The fixture requires a basic GPT or MBR disk.' }

    $after = @(Get-Partition -DiskNumber $current.Number)
    $created = @($after | Where-Object { $_.Offset -eq $Offset -and $_.Size -eq $Size })
    if ($after.Count -ne ($before.Count + 1) -or $created.Count -ne 1 -or
        ([string]$current.PartitionStyle -eq 'MBR' -and
            ($created[0].PartitionNumber -gt 4 -or @($after | Where-Object { [int]$_.MbrType -in @(5, 15, 133) }).Count))) {
        throw 'The fixture primary partition creation was not verified; formatting is refused.'
    }
    if ($Recovery -and (([string]$current.PartitionStyle -eq 'GPT' -and
            [string]$created[0].GptType -ne '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}') -or
        ([string]$current.PartitionStyle -eq 'MBR' -and [int]$created[0].MbrType -ne 39))) {
        throw 'The fixture Recovery type was not verified; formatting is refused.'
    }
    foreach ($original in $before) {
        $preserved = @($after | Where-Object {
            $_.Offset -eq $original.Offset -and $_.Size -eq $original.Size -and
            $_.GptType -eq $original.GptType -and $_.MbrType -eq $original.MbrType
        })
        if ($preserved.Count -ne 1) { throw 'An existing fixture partition changed; formatting is refused.' }
    }
    return $created[0]
}

if ($config.phase -eq 'inspect') {
    Write-Output ('STORAGE_INVENTORY_JSON=' + (Get-FixtureInventory | ConvertTo-Json -Depth 10 -Compress))
    exit 0
}
if ($config.phase -eq 'apply') {
    # A plan is bound to the inspected VM state, not to whichever disk has a given number later.
    $observed = Get-FixtureInventory
    Assert-FixtureHardwareIdentity -Disks $observed.disks
    $baseline = $config.plan.baseline
    if (($observed.disks | ConvertTo-Json -Depth 10 -Compress) -cne
        ($baseline.disks | ConvertTo-Json -Depth 10 -Compress) -or
        $observed.system_drive -cne $baseline.system_drive -or
        $observed.system_disk_number -ne $baseline.system_disk_number) {
        throw 'The test storage layout changed after the fixture dry-run.'
    }
    $witnesses = @()
    foreach ($action in @($config.plan.actions)) {
        $disk = Resolve-FixtureDisk ([string]$action.disk_device_path)
        switch ([string]$action.kind) {
            'extra-system-partition' {
                $windows = Get-Partition -DriveLetter $observed.system_drive
                if ($disk.Number -ne $windows.DiskNumber -or $windows.PartitionNumber -ne $action.partition_number -or
                    -not $observed.system_volume_healthy -or -not $observed.system_volume_decrypted) {
                    throw 'The system-volume fixture preconditions are not satisfied.'
                }
                $newSize = [long]$action.new_system_size
                $offset = [long]$action.offset
                $size = [long]$action.size
                $limits = Get-PartitionSupportedSize -DiskNumber $disk.Number -PartitionNumber $windows.PartitionNumber
                if ($newSize -lt $limits.SizeMin -or $newSize -lt 24GB -or $newSize -ge $windows.Size -or
                    $offset -ne ([long]$windows.Offset + $newSize) -or $size -lt 256MB -or $size -gt 4GB -or
                    ($offset + $size) -gt ([long]$windows.Offset + [long]$windows.Size) -or
                    [string]$action.format -notin @('fat32', 'ntfs', 'recovery')) {
                    throw 'The fixture shrink geometry is invalid.'
                }
                if ([string]$disk.PartitionStyle -eq 'MBR') {
                    $existing = @(Get-Partition -DiskNumber $disk.Number)
                    if ($existing.Count -ge 4 -or @($existing | Where-Object { [int]$_.MbrType -in @(5, 15, 133) }).Count -gt 0) {
                        throw 'The fixture has no free primary MBR partition slot.'
                    }
                }
                if ([string](Repair-Volume -DriveLetter $observed.system_drive -Scan) -ne 'NoErrorsFound') {
                    throw 'The fixture NTFS scan did not succeed.'
                }
                Resize-Partition -DiskNumber $disk.Number -PartitionNumber $windows.PartitionNumber -Size $newSize
                $updated = Get-Partition -DriveLetter $observed.system_drive
                if ($updated.Offset -ne $windows.Offset -or $updated.Size -ne $newSize) {
                    throw 'The fixture Windows shrink was not verified.'
                }
                $part = New-FixtureSystemPartition -Disk $disk -Offset $offset -Size $size -Recovery:($action.format -eq 'recovery')
                $filesystem = if ($action.format -eq 'fat32') { 'FAT32' } else { 'NTFS' }
                $part | Format-Volume -FileSystem $filesystem -NewFileSystemLabel 'LIBERTIX_TEST' -Confirm:$false | Out-Null
                $witnesses += New-FixtureWitness -Disk $disk -Partition $part -Name ([string]$action.format)
            }
            'secondary-data' {
                if ($disk.Number -eq $observed.system_disk_number -or $disk.IsBoot -or $disk.IsSystem -or
                    [string]$disk.PartitionStyle -ne 'RAW' -or [long]$disk.Size -lt 8GB) {
                    throw 'The secondary fixture disk is not an unused non-boot disk.'
                }
                $letter = [string]$action.drive_letter
                if ($letter -cnotmatch '^[D-Z]$' -or
                    @(Get-Volume | Where-Object { [string]$_.DriveLetter -ieq $letter }).Count -ne 0 -or
                    @(Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Name -ieq $letter }).Count -ne 0) {
                    throw 'The fixture drive letter is invalid or already occupied.'
                }
                Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
                $disk = Resolve-FixtureDisk ([string]$action.disk_device_path)
                $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $letter
                $part | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'LIBERTIX_DATA_TEST' -Confirm:$false | Out-Null
                $witnesses += New-FixtureWitness -Disk $disk -Partition $part -Name 'secondary-data'
            }
            'existing-secondary-data' {
                if ($disk.Number -eq $observed.system_disk_number -or $disk.IsBoot -or $disk.IsSystem) {
                    throw 'The existing secondary fixture volume belongs to a boot disk.'
                }
                $parts = @(Get-Partition -DiskNumber $disk.Number | Where-Object {
                    $_.Offset -eq [long]$action.partition_offset -and $_.Size -eq [long]$action.partition_size
                })
                if ($parts.Count -ne 1) { throw 'The existing secondary data partition is ambiguous.' }
                $volumes = @($parts[0] | Get-Volume)
                if ($volumes.Count -ne 1 -or [string]$volumes[0].FileSystemType -ne 'NTFS' -or
                    [string]$volumes[0].HealthStatus -ne 'Healthy') {
                    throw 'The existing secondary data volume is not healthy NTFS.'
                }
                # Existing snapshot data is never reformatted, relabelled or assigned another letter.
                $witnesses += New-FixtureWitness -Disk $disk -Partition $parts[0] -Name 'existing-secondary-data'
            }
            default { throw 'Unknown storage fixture action.' }
        }
    }
    Write-Output ('STORAGE_FIXTURE_JSON=' + (@{ inventory = Get-FixtureInventory; witnesses = $witnesses } | ConvertTo-Json -Depth 10 -Compress))
    exit 0
}
function Test-FixtureAllocationSource {
    param([object]$Disk, [object]$Partition, [long]$OriginalSize)
    if ($null -eq $script:fixtureAllocation -or
        [int]$Disk.Number -ne [int]$script:fixtureAllocation.number -or
        [long]$Partition.Offset -ne [long]$script:fixtureAllocation.sourcePartition.offsetBytes) { return $false }
    $definition = $script:fixtureAllocation
    $identity = if ([string]$Disk.PartitionStyle -eq 'GPT') {
        'gpt:' + ([guid]$Disk.Guid).ToString('D').ToLowerInvariant()
    } else { 'mbr:' + ([uint32]$Disk.Signature).ToString('x8') }
    if ($identity -cne [string]$definition.partitionTableId -or
        [int]$Partition.PartitionNumber -ne [int]$definition.sourcePartition.number -or
        $OriginalSize -ne [long]$definition.sourcePartition.sizeBytes -or
        [long]$Partition.Size -le 0) { throw 'The allocation source differs from its fixture baseline.' }
    [long]$shrink = $OriginalSize - [long]$Partition.Size
    if ($shrink -lt $script:fixtureLinuxSize -or $shrink -gt ($script:fixtureLinuxSize + 2MB)) {
        throw 'The fixture source shrink does not match the requested Linux allocation.'
    }
    return $true
}

if ($config.phase -eq 'verify') {
    $script:fixtureAllocation = $null
    $script:fixtureLinuxSize = 0L
    if ($config.PSObject.Properties.Name -contains 'installation_target' -and
        [string]$config.installation_target -eq 'secondary') {
        $planPath = Join-Path $env:SystemDrive 'LibertixInstallLogs\Linux\latest\installation-plan.json'
        $plan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ([int]$plan.schemaVersion -ne 5 -or [int]$plan.allocation.number -eq [int]$plan.disk.number) {
            throw 'The secondary installation did not produce a distinct allocation disk.'
        }
        $script:fixtureAllocation = $plan.allocation
        $script:fixtureLinuxSize = [long]$plan.disk.installer.finalSizeBytes
    }
    if (@($config.receipt.witnesses).Count -eq 0) { throw 'No storage fixture witness was recorded.' }
    foreach ($expectedDisk in @($config.receipt.inventory.disks)) {
        $disk = Resolve-FixtureDisk ([string]$expectedDisk.device_path)
        $tableId = if ([string]$disk.PartitionStyle -eq 'GPT') { [string]$disk.Guid } elseif ([string]$disk.PartitionStyle -eq 'MBR') { [string]$disk.Signature } else { '' }
        if ([long]$disk.Size -ne [long]$expectedDisk.size -or [string]$disk.PartitionStyle -cne [string]$expectedDisk.style -or
            $tableId -cne [string]$expectedDisk.partition_table_id -or
            ([string]$disk.SerialNumber).Trim() -cne [string]$expectedDisk.serial_number) {
            throw 'A preserved fixture disk no longer matches its recorded identity.'
        }
        $partitions = @(Get-Partition -DiskNumber $disk.Number)
        foreach ($expectedPart in @($expectedDisk.partitions)) {
            $partitionMatches = @($partitions | Where-Object { $_.Offset -eq [long]$expectedPart.offset })
            if ($partitionMatches.Count -ne 1) { throw 'A pre-existing test partition was moved or removed.' }
            $part = $partitionMatches[0]
            $type = if ([string]$disk.PartitionStyle -eq 'GPT') { [string]$part.GptType } else { [string][int]$part.MbrType }
            if ($type.ToLowerInvariant() -cne [string]$expectedPart.type) {
                throw 'A pre-existing test partition type was changed.'
            }
            $isSystemVolume = [string]$expectedPart.drive_letter -ceq [string]$config.receipt.inventory.system_drive -and
                [int]$expectedDisk.number -eq [int]$config.receipt.inventory.system_disk_number
            $isAllocationSource = Test-FixtureAllocationSource -Disk $disk -Partition $part -OriginalSize ([long]$expectedPart.size)
            if (-not $isSystemVolume -and -not $isAllocationSource -and [long]$part.Size -ne [long]$expectedPart.size) {
                throw 'An unrelated test partition was resized.'
            }
            if ($isSystemVolume -and $null -ne $script:fixtureAllocation -and [long]$part.Size -ne [long]$expectedPart.size) {
                throw 'Windows was resized despite the secondary-disk allocation request.'
            }
            if ($isSystemVolume -and ([long]$part.Size -le 0 -or [long]$part.Size -gt [long]$expectedPart.size)) {
                throw 'The Windows partition escaped its original fixture extent.'
            }
        }
    }
    foreach ($witness in @($config.receipt.witnesses)) {
        $disk = Resolve-FixtureDisk ([string]$witness.disk_device_path)
        $partitions = @(Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Offset -eq [long]$witness.partition_offset })
        if ($partitions.Count -ne 1) { throw 'A storage fixture partition was moved or removed.' }
        $isAllocationSource = Test-FixtureAllocationSource -Disk $disk -Partition $partitions[0] -OriginalSize ([long]$witness.partition_size)
        if (-not $isAllocationSource -and $partitions[0].Size -ne [long]$witness.partition_size) {
            throw 'A storage fixture partition was moved, resized or removed.'
        }
        $volumes = @($partitions[0] | Get-Volume)
        if ($volumes.Count -ne 1 -or [string]$volumes[0].UniqueId -cne [string]$witness.volume_id -or
            [string]$witness.relative_path -cnotmatch '^libertix-test-witness-[a-f0-9]{32}\.txt$') {
            throw 'The storage fixture volume identity or witness path is invalid.'
        }
        $path = Join-Path ([string]$volumes[0].Path) ([string]$witness.relative_path)
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$witness.sha256) {
            throw 'A storage fixture witness was changed.'
        }
    }
    Write-Output 'STORAGE_FIXTURE_VERIFIED=True'
    exit 0
}
throw 'Unknown storage fixture phase.'
