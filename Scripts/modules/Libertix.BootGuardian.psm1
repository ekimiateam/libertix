Set-StrictMode -Version Latest

$script:GuardianServiceName = "LibertixBootGuardian"
$script:GuardianRoot = Join-Path $env:ProgramData "Libertix\BootGuardian"
$script:GuardianConfigPath = Join-Path $script:GuardianRoot "config.json"
$script:GuardianReferenceRelativePath = "EFI\Libertix\BootGuardianReference"

function Initialize-LibertixBootGuardianMoveApi {
    if (([System.Management.Automation.PSTypeName]"LibertixBootGuardianMoveApi").Type) {
        return
    }

    Add-Type @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class LibertixBootGuardianMoveApi {
    private const UInt32 MOVEFILE_REPLACE_EXISTING = 0x00000001;
    private const UInt32 MOVEFILE_WRITE_THROUGH = 0x00000008;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool MoveFileEx(string source, string destination, UInt32 flags);

    public static void ReplaceAtomically(string source, string destination) {
        if (!MoveFileEx(source, destination, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
"@
}

function Move-LibertixBootGuardianFileAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Initialize-LibertixBootGuardianMoveApi
    [LibertixBootGuardianMoveApi]::ReplaceAtomically($Source, $Destination)
}

function Get-LibertixBootGuardianVolumePath {
    param([Parameter(Mandatory = $true)]$EspPartition)

    $partition = Get-Partition `
        -DiskNumber ([int]$EspPartition.DiskNumber) `
        -PartitionNumber ([int]$EspPartition.PartitionNumber) `
        -ErrorAction Stop
    $paths = @(
        $partition.AccessPaths |
            Where-Object {
                $_ -match '^\\\\\?\\Volume\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}\\$'
            } |
            Select-Object -Unique
    )
    if ($paths.Count -ne 1) {
        $volume = Get-Volume -Partition $partition -ErrorAction Stop
        $paths = @(
            [string]$volume.UniqueId |
                Where-Object {
                    $_ -match '^\\\\\?\\Volume\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}\\$'
                }
        )
    }
    if ($paths.Count -ne 1) {
        throw "The recorded ESP does not expose exactly one stable volume path."
    }
    $volume = Get-Volume -UniqueId $paths[0] -ErrorAction Stop
    if ([string]$volume.FileSystemType -ne "FAT32") {
        throw "The recorded ESP volume is not FAT32."
    }
    return [string]$paths[0]
}

function Protect-LibertixBootGuardianDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    [IO.Directory]::CreateDirectory($Path) | Out-Null
    $security = New-Object Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor `
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagation = [Security.AccessControl.PropagationFlags]::None
    foreach ($sidValue in @("S-1-5-18", "S-1-5-32-544")) {
        $sid = New-Object Security.Principal.SecurityIdentifier($sidValue)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            $propagation,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $security.AddAccessRule($rule)
    }
    [IO.Directory]::SetAccessControl($Path, $security)
}

function Write-LibertixBootGuardianJsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path `
        $directory `
        ".$([IO.Path]::GetFileName($Path)).$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText(
            $temporary,
            ($Value | ConvertTo-Json -Depth 12) + "`n",
            (New-Object Text.UTF8Encoding($false))
        )
        Move-LibertixBootGuardianFileAtomic `
            -Source $temporary `
            -Destination $Path
    } finally {
        if ([IO.File]::Exists($temporary)) {
            [IO.File]::Delete($temporary)
        }
    }
}

function Invoke-LibertixBootGuardianCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$Argument
    )

    $process = Start-Process `
        -FilePath $Executable `
        -ArgumentList $Argument `
        -WindowStyle Hidden `
        -Wait `
        -PassThru `
        -ErrorAction Stop
    return [int]$process.ExitCode
}

function Stop-LibertixBootGuardianServiceForUpdate {
    param([Parameter(Mandatory = $true)][string]$RunId)

    $service = Get-Service -Name $script:GuardianServiceName -ErrorAction SilentlyContinue
    if (-not $service) {
        return
    }
    if (-not (Test-Path -LiteralPath $script:GuardianConfigPath -PathType Leaf)) {
        throw "An existing boot guardian service has no owned configuration."
    }
    $existing = Get-Content -LiteralPath $script:GuardianConfigPath -Raw -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop
    if ([int]$existing.version -ne 1 -or [string]$existing.runId -ne $RunId) {
        throw "The existing boot guardian service belongs to another recovery run."
    }
    $existingExe = Join-Path $script:GuardianRoot "Libertix.BootGuardian.exe"
    if (-not (Test-Path -LiteralPath $existingExe -PathType Leaf)) {
        throw "The owned boot guardian service executable is missing."
    }
    $uninstallExitCode = Invoke-LibertixBootGuardianCommand `
        -Executable $existingExe `
        -Argument "--uninstall-service"
    if ($uninstallExitCode -ne 0) {
        throw "Existing boot guardian service removal failed with rc=$uninstallExitCode."
    }
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        if (-not (Get-Service -Name $script:GuardianServiceName -ErrorAction SilentlyContinue)) {
            return
        }
        Start-Sleep -Milliseconds 250
    }
    throw "Existing boot guardian service still exists after the update stop timeout."
}

function Get-LibertixBootGuardianByteHash {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
    }
}

function Get-LibertixBootGuardianOwnerMarker {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$EspPartition,
        [Parameter(Mandatory = $true)][string]$EspRoot
    )

    $path = Join-Path $EspRoot "EFI\Libertix\.libertix-owner"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "The installed Libertix ESP ownership marker is missing."
    }
    $lines = @(Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction Stop)
    $guid = ([Guid]$EspPartition.Guid).ToString("D").ToLowerInvariant()
    if (
        $lines.Count -ne 5 -or
        ([string]$lines[0]).Trim() -ne [string]$State.RunId -or
        ([string]$lines[1]).Trim() -notmatch '^[0-9a-fA-F]{4}$' -or
        ([string]$lines[2]).Trim() -ne [string]$EspPartition.PartitionNumber -or
        ([string]$lines[3]).Trim().ToLowerInvariant() -ne $guid -or
        ([string]$lines[4]).Trim() -ne "\EFI\Libertix\shimx64.efi"
    ) {
        throw "The installed Libertix ESP ownership marker is invalid."
    }
    return [pscustomobject]@{
        Text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
        BootNumber = [Convert]::ToUInt16(([string]$lines[1]).Trim(), 16)
        PartitionGuid = $guid
    }
}

function Initialize-LibertixBootGuardianReference {
    param(
        [Parameter(Mandatory = $true)][string]$EspRoot,
        [Parameter(Mandatory = $true)]$Manifest
    )

    $referenceRoot = Join-Path $EspRoot $script:GuardianReferenceRelativePath
    [IO.Directory]::CreateDirectory($referenceRoot) | Out-Null
    $files = @(
        @{
            Source = Join-Path $EspRoot "EFI\Microsoft\Boot\bootmgfw.efi"
            Destination = Join-Path $referenceRoot "shimx64.efi"
            Hash = [string]$Manifest.preferred.shimSha256
        },
        @{
            Source = Join-Path $EspRoot "EFI\Microsoft\Boot\grubx64.efi"
            Destination = Join-Path $referenceRoot "grubx64.efi"
            Hash = [string]$Manifest.preferred.grubSha256
        },
        @{
            Source = Join-Path $EspRoot "EFI\Microsoft\Boot\mmx64.efi"
            Destination = Join-Path $referenceRoot "mmx64.efi"
            Hash = [string]$Manifest.preferred.mokManagerSha256
        },
        @{
            Source = Join-Path $EspRoot "EFI\Microsoft\Boot\grub.cfg"
            Destination = Join-Path $referenceRoot "grub.cfg"
            Hash = [string]$Manifest.preferred.grubConfigSha256
        }
    )
    foreach ($file in $files) {
        if ([string]$file.Hash -notmatch '^[0-9a-f]{64}$') {
            throw "The preferred boot manifest contains an invalid guardian reference hash."
        }
        Copy-LibertixPreferredPathFileAtomic `
            -Source ([string]$file.Source) `
            -Destination ([string]$file.Destination) `
            -ExpectedSha256 ([string]$file.Hash)
    }
    [IO.File]::WriteAllText(
        (Join-Path $referenceRoot ".libertix-owner"),
        ([string]$Manifest.runId) + "`n",
        (New-Object Text.UTF8Encoding($false))
    )
}

function Install-LibertixBootGuardian {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$EspPartition,
        [Parameter(Mandatory = $true)][string]$EspRoot,
        [Parameter(Mandatory = $true)]
        [ValidateSet("firmware-boot-order", "preferred-windows-path")]
        [string]$Mode,
        [Parameter(Mandatory = $true)][scriptblock]$WriteLog
    )

    $sourceExe = Join-Path $State.PayloadRoot "Libertix.BootGuardian.exe"
    if (-not (Test-Path -LiteralPath $sourceExe -PathType Leaf)) {
        throw "The boot guardian executable is missing from the verified recovery payload."
    }
    $owner = Get-LibertixBootGuardianOwnerMarker `
        -State $State `
        -EspPartition $EspPartition `
        -EspRoot $EspRoot
    $volumePath = Get-LibertixBootGuardianVolumePath -EspPartition $EspPartition
    Stop-LibertixBootGuardianServiceForUpdate -RunId ([string]$State.RunId)
    $archiveRoot = Join-Path $State.RecoveryRoot "boot-guardian"
    $logRoot = Join-Path $env:SystemDrive "LibertixInstallLogs\Windows\$($State.RunId)\BootGuardian"
    Protect-LibertixBootGuardianDirectory -Path $script:GuardianRoot
    Protect-LibertixBootGuardianDirectory -Path $archiveRoot
    Protect-LibertixBootGuardianDirectory -Path $logRoot

    $destinationExe = Join-Path $script:GuardianRoot "Libertix.BootGuardian.exe"
    $sourceHash = (Get-FileHash -LiteralPath $sourceExe -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    Copy-Item -LiteralPath $sourceExe -Destination $destinationExe -Force -ErrorAction Stop
    if ((Get-FileHash -LiteralPath $destinationExe -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sourceHash) {
        throw "The installed boot guardian executable hash is invalid."
    }

    $config = [ordered]@{
        version = 1
        runId = [string]$State.RunId
        mode = $Mode
        esp = [ordered]@{
            volumePath = $volumePath
            partitionNumber = [int]$EspPartition.PartitionNumber
            partitionGuid = [string]$owner.PartitionGuid
            ownerMarker = [string]$owner.Text
        }
        logDirectory = $logRoot
        archiveDirectory = $archiveRoot
        serviceSha256 = $sourceHash
    }
    $firmware = Join-Path $State.PayloadRoot "Scripts\modules\Libertix.Firmware.psm1"
    Import-Module -Name $firmware -Force -ErrorAction Stop
    if ($Mode -eq "firmware-boot-order") {
        $firmwareRead = Join-Path $State.PayloadRoot "Scripts\modules\Libertix.FirmwareRead.psm1"
        Import-Module -Name $firmwareRead -Force -ErrorAction Stop
        $entryName = "Boot{0:X4}" -f [uint16]$owner.BootNumber
        $entryBytes = Get-LibertixFirmwareVariableBytes -Name $entryName
        if (
            -not $entryBytes -or
            (Get-EfiLoadOptionDescription -Bytes $entryBytes) -ne "Libertix" -or
            -not (Test-EfiLoadOptionLoaderPath `
                -Bytes $entryBytes `
                -ExpectedPath "\EFI\Libertix\shimx64.efi")
        ) {
            throw "The owned Libertix firmware entry is missing or invalid."
        }
        $config["bootOrder"] = [ordered]@{
            bootNumber = [int][uint16]$owner.BootNumber
            entryBytesBase64 = [Convert]::ToBase64String([byte[]]$entryBytes)
            entrySha256 = Get-LibertixBootGuardianByteHash -Bytes ([byte[]]$entryBytes)
        }
    } else {
        $manifestPath = Join-Path $EspRoot "EFI\Libertix\preferred-boot-path.json"
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw "The preferred boot manifest is missing before guardian installation."
        }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -ErrorAction Stop
        if (
            [int]$manifest.version -ne 1 -or
            [string]$manifest.runId -ne [string]$State.RunId -or
            [string]$manifest.status -ne "installed" -or
            $manifest.PSObject.Properties.Name -notcontains "windowsBootEntry"
        ) {
            throw "The preferred boot manifest is not installed for this recovery run."
        }
        $windowsEntry = $manifest.windowsBootEntry
        $windowsEntryName = [string]$windowsEntry.name
        try {
            $windowsEntryBytes = [Convert]::FromBase64String(
                [string]$windowsEntry.preferredBytesBase64
            )
        } catch [FormatException] {
            throw "The preferred Windows boot entry encoding is invalid."
        }
        $windowsEntryHash = Get-LibertixBootGuardianByteHash `
            -Bytes ([byte[]]$windowsEntryBytes)
        if (
            $windowsEntryName -notmatch '^Boot[0-9A-F]{4}$' -or
            $windowsEntryHash -ne [string]$windowsEntry.preferredSha256 -or
            (Get-EfiLoadOptionOptionalDataLength -Bytes $windowsEntryBytes) -ne 0 -or
            -not (Test-EfiLoadOptionLoaderPath `
                -Bytes $windowsEntryBytes `
                -ExpectedPath "\EFI\Microsoft\Boot\bootmgfw.efi")
        ) {
            throw "The preferred Windows boot entry contract is invalid."
        }
        Initialize-LibertixBootGuardianReference `
            -EspRoot $EspRoot `
            -Manifest $manifest
        $config["preferredPath"] = [ordered]@{
            manifestPath = "EFI\Libertix\preferred-boot-path.json"
            referenceRoot = $script:GuardianReferenceRelativePath
            bootNumber = [int][Convert]::ToUInt16($windowsEntryName.Substring(4), 16)
            entryBytesBase64 = [Convert]::ToBase64String([byte[]]$windowsEntryBytes)
            entrySha256 = $windowsEntryHash
        }
    }

    $archiveConfig = Join-Path $archiveRoot "config.json"
    Write-LibertixBootGuardianJsonAtomic -Path $archiveConfig -Value $config
    Write-LibertixBootGuardianJsonAtomic -Path $script:GuardianConfigPath -Value $config
    try {
        $installExitCode = Invoke-LibertixBootGuardianCommand `
            -Executable $destinationExe `
            -Argument "--install-service"
        if ($installExitCode -ne 0) {
            throw "Boot guardian service installation failed with rc=$installExitCode."
        }
        $service = Get-CimInstance `
            -ClassName Win32_Service `
            -Filter "Name='$($script:GuardianServiceName)'" `
            -ErrorAction Stop
        if (
            -not $service -or
            [string]$service.StartMode -ne "Auto" -or
            [string]$service.State -ne "Running" -or
            [string]$service.StartName -ne "LocalSystem" -or
            [IO.Path]::GetFullPath(([string]$service.PathName).Trim('"')) -ne `
                [IO.Path]::GetFullPath($destinationExe)
        ) {
            throw "Boot guardian service registration could not be verified."
        }
        $serviceRegistry = Get-ItemProperty `
            -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$script:GuardianServiceName" `
            -ErrorAction Stop
        $requiredPrivileges = @($serviceRegistry.RequiredPrivileges)
        if (
            [int]$serviceRegistry.PreshutdownTimeout -ne 10000 -or
            $requiredPrivileges -notcontains "SeSystemEnvironmentPrivilege"
        ) {
            throw "Boot guardian preshutdown contract could not be verified."
        }
        $repairExitCode = Invoke-LibertixBootGuardianCommand `
            -Executable $destinationExe `
            -Argument "--repair-now"
        if ($repairExitCode -ne 0) {
            throw "Boot guardian initial integrity check failed with rc=$repairExitCode."
        }
        $attemptPath = Join-Path $script:GuardianRoot "last-attempt.state"
        if (-not (Test-Path -LiteralPath $attemptPath -PathType Leaf)) {
            throw "Boot guardian initial integrity check did not publish its state."
        }
        $attempt = @{}
        foreach ($line in @(Get-Content -LiteralPath $attemptPath -Encoding UTF8 -ErrorAction Stop)) {
            if ([string]$line -match '^([^=]+)=(.*)$') {
                $attempt[$Matches[1]] = $Matches[2]
            }
        }
        $attemptRunId = [string]$attempt["runId"]
        $attemptMode = [string]$attempt["mode"]
        $attemptStatus = [string]$attempt["status"]
        if (
            $attemptRunId -ne [string]$State.RunId -or
            $attemptMode -ne $Mode -or
            $attemptStatus -notin @("healthy", "repaired")
        ) {
            throw "Boot guardian initial integrity state is invalid."
        }
    } catch {
        $setupError = $_
        try {
            $failedSetupExitCode = Invoke-LibertixBootGuardianCommand `
                -Executable $destinationExe `
                -Argument "--uninstall-service"
            if ($failedSetupExitCode -ne 0) {
                throw "Boot guardian failed setup service removal returned rc=$failedSetupExitCode."
            }
        } catch {
            & $WriteLog "Boot guardian failed setup could not remove its service: $($_.Exception.Message)"
        }
        throw $setupError
    }
    & $WriteLog "Boot guardian installed and verified for mode=$Mode."
    return [pscustomobject]$config
}

function Remove-LibertixBootGuardian {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$EspRoot,
        [Parameter(Mandatory = $true)][scriptblock]$WriteLog
    )

    $archiveConfig = Join-Path $State.RecoveryRoot "boot-guardian\config.json"
    if (-not (Test-Path -LiteralPath $archiveConfig -PathType Leaf)) {
        return $false
    }
    $config = Get-Content -LiteralPath $archiveConfig -Raw -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop
    if ([int]$config.version -ne 1 -or [string]$config.runId -ne [string]$State.RunId) {
        throw "Boot guardian archive belongs to another recovery run."
    }
    $exe = Join-Path $script:GuardianRoot "Libertix.BootGuardian.exe"
    if (Test-Path -LiteralPath $exe -PathType Leaf) {
        $rollbackExitCode = Invoke-LibertixBootGuardianCommand `
            -Executable $exe `
            -Argument "--uninstall-service"
        if ($rollbackExitCode -ne 0) {
            throw "Boot guardian service removal failed with rc=$rollbackExitCode."
        }
    }
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        if (-not (Get-Service -Name $script:GuardianServiceName -ErrorAction SilentlyContinue)) {
            break
        }
        Start-Sleep -Milliseconds 250
    }
    if (Get-Service -Name $script:GuardianServiceName -ErrorAction SilentlyContinue) {
        throw "Boot guardian service still exists after removal."
    }
    if ([string]$config.mode -eq "preferred-windows-path") {
        $referenceRoot = Join-Path $EspRoot $script:GuardianReferenceRelativePath
        if (Test-Path -LiteralPath $referenceRoot -PathType Container) {
            $referenceOwner = Join-Path $referenceRoot ".libertix-owner"
            $entries = @(
                Get-ChildItem -LiteralPath $referenceRoot -Force -ErrorAction Stop |
                    ForEach-Object { $_.Name }
            )
            $expectedEntries = @(
                ".libertix-owner",
                "shimx64.efi",
                "grubx64.efi",
                "mmx64.efi",
                "grub.cfg"
            )
            if (
                -not (Test-Path -LiteralPath $referenceOwner -PathType Leaf) -or
                ([IO.File]::ReadAllText($referenceOwner, [Text.Encoding]::UTF8)).Trim() -ne `
                    [string]$State.RunId -or
                @($entries | Sort-Object).Count -ne $expectedEntries.Count -or
                @(Compare-Object `
                    -ReferenceObject ($expectedEntries | Sort-Object) `
                    -DifferenceObject ($entries | Sort-Object)).Count -ne 0
            ) {
                throw "Boot guardian reference directory ownership could not be proven."
            }
            Remove-Item -LiteralPath $referenceRoot -Recurse -Force -ErrorAction Stop
        }
    }
    if (Test-Path -LiteralPath $script:GuardianRoot -PathType Container) {
        Remove-Item -LiteralPath $script:GuardianRoot -Recurse -Force -ErrorAction Stop
    }
    & $WriteLog "Boot guardian service and active files were removed during rollback."
    return $true
}

Export-ModuleMember -Function `
    Install-LibertixBootGuardian, `
    Remove-LibertixBootGuardian
