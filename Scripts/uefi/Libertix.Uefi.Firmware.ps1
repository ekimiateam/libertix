#requires -Version 5.1

# UEFI firmware variables, BCD integration, and Secure Boot checks.

$script:LibertixFirmwarePrivilegeEnabled = $false
$script:Win32ErrorEnvironmentVariableNotFound = 203
$script:Win32ErrorNotFound = 1168

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Assert-LibertixPlanMatchesCurrentStorage {
    if ($null -eq $installationPlan) {
        return
    }
    if ([string]$installationPlan.disk.systemDrive -ne "$env:SystemDrive") {
        throw "Windows system drive does not match the installation plan."
    }

    # Fail before resizing if Windows now exposes a different disk topology
    # than the one approved by the compatibility preflight.
    $systemPartition = Get-Partition `
        -DriveLetter $env:SystemDrive.TrimEnd(":") `
        -ErrorAction Stop
    $systemDisk = Get-Disk -Number $systemPartition.DiskNumber -ErrorAction Stop
    if (
        [int]$systemDisk.Number -ne [int]$installationPlan.disk.number -or
        ([string]$systemDisk.UniqueId).Trim() -ne ([string]$installationPlan.disk.uniqueId).Trim() -or
        [int64]$systemDisk.Size -ne [int64]$installationPlan.disk.sizeBytes -or
        [string]$systemDisk.PartitionStyle -ne [string]$installationPlan.disk.partitionStyle -or
        [int]$systemDisk.LogicalSectorSize -ne [int]$installationPlan.disk.logicalSectorSizeBytes
    ) {
        throw "Windows system disk no longer matches the installation plan."
    }
    if (
        [int]$systemPartition.PartitionNumber -ne [int]$installationPlan.disk.windows.number -or
        [int64]$systemPartition.Offset -ne [int64]$installationPlan.disk.windows.offsetBytes -or
        [int64]$systemPartition.Size -ne [int64]$installationPlan.disk.windows.sizeBytes
    ) {
        throw "Windows system partition no longer matches the installation plan."
    }

    foreach ($name in @("boot", "recovery")) {
        $expected = $installationPlan.disk.$name
        $partitionMatches = @(
            Get-Partition -DiskNumber $systemDisk.Number -ErrorAction Stop |
                Where-Object {
                    [int64]$_.Offset -eq [int64]$expected.offsetBytes -and
                    [int64]$_.Size -eq [int64]$expected.sizeBytes
                }
        )
        if ($partitionMatches.Count -ne 1) {
            throw "Windows $name partition no longer matches the installation plan."
        }
    }
}

function Get-NativeSystemExecutable {
    param([Parameter(Mandatory = $true)][string]$FileName)

    foreach ($candidate in @(
        (Join-Path $env:SystemRoot "Sysnative\$FileName"),
        (Join-Path $env:SystemRoot "System32\$FileName")
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    $command = Get-Command $FileName -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    throw "$FileName is unavailable through Sysnative, System32, and PATH."
}

function Invoke-BcdeditCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $bcdedit = Get-NativeSystemExecutable -FileName "bcdedit.exe"
    $output = & $bcdedit @Arguments 2>&1
    $text = $output | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "bcdedit failed ($($Arguments -join ' ')): $text"
    }

    return $text
}

function Initialize-FirmwareApi {
    if (([System.Management.Automation.PSTypeName]"LibertixFirmwareApi").Type) {
        return
    }

    Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class LibertixFirmwareApi {
    private const UInt32 TOKEN_ADJUST_PRIVILEGES = 0x0020;
    private const UInt32 TOKEN_QUERY = 0x0008;
    private const UInt32 SE_PRIVILEGE_ENABLED = 0x00000002;

    [StructLayout(LayoutKind.Sequential)]
    private struct LUID {
        public UInt32 LowPart;
        public Int32 HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_PRIVILEGES {
        public UInt32 PrivilegeCount;
        public LUID Luid;
        public UInt32 Attributes;
    }

    [DllImport("advapi32.dll", SetLastError=true)]
    private static extern bool OpenProcessToken(
        IntPtr ProcessHandle,
        UInt32 DesiredAccess,
        out IntPtr TokenHandle
    );

    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    private static extern bool LookupPrivilegeValue(
        string lpSystemName,
        string lpName,
        out LUID lpLuid
    );

    [DllImport("advapi32.dll", SetLastError=true)]
    private static extern bool AdjustTokenPrivileges(
        IntPtr TokenHandle,
        bool DisableAllPrivileges,
        ref TOKEN_PRIVILEGES NewState,
        UInt32 BufferLength,
        IntPtr PreviousState,
        IntPtr ReturnLength
    );

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern UInt32 GetFirmwareEnvironmentVariable(
        string lpName,
        string lpGuid,
        byte[] pBuffer,
        UInt32 nSize
    );

    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool SetFirmwareEnvironmentVariableEx(
        string lpName,
        string lpGuid,
        byte[] pValue,
        UInt32 nSize,
        UInt32 dwAttributes
    );

    public static bool DeleteFirmwareEnvironmentVariable(
        string lpName,
        string lpGuid,
        UInt32 dwAttributes
    ) {
        return SetFirmwareEnvironmentVariableEx(lpName, lpGuid, null, 0, dwAttributes);
    }

    public static void EnableSystemEnvironmentPrivilege() {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token)) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }

        try {
            LUID luid;
            if (!LookupPrivilegeValue(null, "SeSystemEnvironmentPrivilege", out luid)) {
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }

            TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
            tp.PrivilegeCount = 1;
            tp.Luid = luid;
            tp.Attributes = SE_PRIVILEGE_ENABLED;

            if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) {
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }

            int error = Marshal.GetLastWin32Error();
            if (error != 0) {
                throw new System.ComponentModel.Win32Exception(error);
            }
        } finally {
            CloseHandle(token);
        }
    }

    public static int LastError() {
        return Marshal.GetLastWin32Error();
    }
}
"@
}

function Enable-FirmwareAccessOnce {
    if ($script:LibertixFirmwarePrivilegeEnabled) {
        return
    }
    Initialize-FirmwareApi
    [LibertixFirmwareApi]::EnableSystemEnvironmentPrivilege()
    $script:LibertixFirmwarePrivilegeEnabled = $true
}

function Get-FirmwareVariableReadResult {
    param([Parameter(Mandatory = $true)][string]$Name)

    Enable-FirmwareAccessOnce
    $global = "{8BE4DF61-93CA-11D2-AA0D-00E098032B8C}"
    $buffer = New-Object byte[] 65536
    $size = [LibertixFirmwareApi]::GetFirmwareEnvironmentVariable($Name, $global, $buffer, [uint32]$buffer.Length)
    if ($size -eq 0) {
        $errorCode = [LibertixFirmwareApi]::LastError()
        if ($errorCode -in @(
            $script:Win32ErrorEnvironmentVariableNotFound,
            $script:Win32ErrorNotFound
        )) {
            return [pscustomobject]@{
                Exists = $false
                Bytes = $null
            }
        }
        throw "GetFirmwareEnvironmentVariable failed for ${Name}: Win32 error ${errorCode}"
    }

    $result = New-Object byte[] $size
    [Array]::Copy($buffer, $result, $size)
    return [pscustomobject]@{
        Exists = $true
        Bytes = $result
    }
}

function Test-FirmwareVariableExists {
    param([Parameter(Mandatory = $true)][string]$Name)

    return [bool](Get-FirmwareVariableReadResult -Name $Name).Exists
}

function Get-FirmwareVariableBytes {
    param([Parameter(Mandatory = $true)][string]$Name)

    $readResult = Get-FirmwareVariableReadResult -Name $Name
    if (-not $readResult.Exists) {
        return $null
    }
    return [byte[]]$readResult.Bytes
}

function Set-FirmwareVariable {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][byte[]]$Value
    )

    Enable-FirmwareAccessOnce
    $global = "{8BE4DF61-93CA-11D2-AA0D-00E098032B8C}"
    $attributes = [uint32]0x00000007
    $ok = [LibertixFirmwareApi]::SetFirmwareEnvironmentVariableEx(
        $Name,
        $global,
        $Value,
        [uint32]$Value.Length,
        $attributes
    )

    if (-not $ok) {
        $err = [LibertixFirmwareApi]::LastError()
        throw "SetFirmwareEnvironmentVariableEx failed for ${Name}: Win32 error ${err}"
    }
}

function Remove-FirmwareVariable {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Test-FirmwareVariableExists -Name $Name)) {
        return
    }

    Enable-FirmwareAccessOnce
    $global = "{8BE4DF61-93CA-11D2-AA0D-00E098032B8C}"
    $attributes = [uint32]0x00000007
    $ok = [LibertixFirmwareApi]::DeleteFirmwareEnvironmentVariable($Name, $global, $attributes)
    if (-not $ok) {
        $errorCode = [LibertixFirmwareApi]::LastError()
        throw "SetFirmwareEnvironmentVariableEx failed to delete ${Name}: Win32 error ${errorCode}"
    }
    if (Test-FirmwareVariableExists -Name $Name) {
        throw "Firmware variable ${Name} still exists after deletion."
    }
}

function Remove-FirmwareBootNumberFromOrder {
    param([Parameter(Mandatory = $true)][uint16]$BootNumber)

    $currentOrder = ConvertFrom-BootOrderBytes -Bytes (Get-FirmwareVariableBytes -Name "BootOrder")
    $newOrder = New-Object System.Collections.Generic.List[uint16]
    $changed = $false
    foreach ($entry in $currentOrder) {
        if ([uint16]$entry -eq [uint16]$BootNumber) {
            $changed = $true
            continue
        }
        $newOrder.Add([uint16]$entry)
    }

    if ($changed) {
        Set-FirmwareVariable -Name "BootOrder" -Value (ConvertTo-BootOrderBytes -Order $newOrder)
    }
}

function Write-LibertixFirmwareOwnershipLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Color = "Gray"
    )

    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log $Message $Color
    } else {
        Write-Verbose $Message
    }
}

function Get-BcdFirmwareEntriesByDescription {
    param([Parameter(Mandatory = $true)][string[]]$Descriptions)

    $firmwareText = Invoke-BcdeditCommand -Arguments @("/enum", "firmware", "/v")
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($entryBlock in ($firmwareText -split "(?:`r?`n){2,}")) {
        foreach ($description in $Descriptions) {
            $descriptionAtLineEnd = "(?m)^[^`r`n]+\s+$([regex]::Escape($description))\s*$"
            if ($entryBlock -notmatch $descriptionAtLineEnd) {
                continue
            }
            # bcdedit localizes field labels but keeps object identifiers in
            # braces. Match the stable identifier token only after the exact
            # description has selected the entry block.
            $identifierMatches = [regex]::Matches(
                $entryBlock,
                "\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}"
            )
            if ($identifierMatches.Count -ne 1) {
                throw "A BCD firmware entry named '$description' does not contain exactly one canonical object identifier."
            }
            $entries.Add([pscustomobject]@{
                Identifier = $identifierMatches[0].Value
                Description = $description
                Block = $entryBlock
            })
            break
        }
    }

    return $entries.ToArray()
}

function Get-BcdFirmwareEntryIdsByDescription {
    param([Parameter(Mandatory = $true)][string[]]$Descriptions)

    return @(
        Get-BcdFirmwareEntriesByDescription -Descriptions $Descriptions |
            ForEach-Object { $_.Identifier }
    )
}

function Test-BcdFirmwareEntryLoaderPath {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][string]$ExpectedLoaderPath
    )

    $pathAtLineEnd = "(?im)^[^`r`n]+\s+$([regex]::Escape($ExpectedLoaderPath))\s*$"
    return [regex]::IsMatch([string]$Entry.Block, $pathAtLineEnd)
}

function Get-ValidatedTemporaryFirmwareCleanupState {
    $state = Get-TransactionPartitionState
    if (-not $state) {
        Write-LibertixFirmwareOwnershipLog `
            -Message "UEFI cleanup skipped: no transaction ownership state exists." `
            -Color "Yellow"
        return $null
    }
    if (
        $RecoveryRunId -notmatch '^[0-9a-f]{32}$' -or
        -not ($state.PSObject.Properties.Name -contains "RecoveryRunId") -or
        [string]$state.RecoveryRunId -ne $RecoveryRunId -or
        $InstallerBootDescription -ne "Libertix UEFI Installer $RecoveryRunId"
    ) {
        throw "Temporary UEFI cleanup ownership does not match the active recovery run."
    }
    if (
        $state.PSObject.Properties.Name -contains "FirmwareEntryId" -and
        -not [string]::IsNullOrWhiteSpace([string]$state.FirmwareEntryId) -and
        [string]$state.FirmwareEntryId -notmatch '^\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}$'
    ) {
        throw "Saved BCD firmware ownership identifier is invalid."
    }
    return $state
}

function Remove-OwnedBcdFirmwareEntries {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$ExpectedLoaderPath
    )

    $trackedIdentifier = if (
        $State.PSObject.Properties.Name -contains "FirmwareEntryId"
    ) {
        [string]$State.FirmwareEntryId
    } else {
        ""
    }
    $entries = @(
        Get-BcdFirmwareEntriesByDescription -Descriptions @($InstallerBootDescription)
    )
    foreach ($entry in $entries) {
        $tracked = (
            -not [string]::IsNullOrWhiteSpace($trackedIdentifier) -and
            $entry.Identifier.Equals($trackedIdentifier, [StringComparison]::OrdinalIgnoreCase)
        )
        $pathMatches = Test-BcdFirmwareEntryLoaderPath `
            -Entry $entry `
            -ExpectedLoaderPath $ExpectedLoaderPath
        if (-not $tracked -and -not $pathMatches) {
            throw (
                "BCD entry $($entry.Identifier) uses this recovery description but has " +
                "neither the tracked identifier nor the expected loader path; refusing deletion."
            )
        }
        $proof = if ($tracked -and $pathMatches) {
            "transaction identifier and loader path"
        } elseif ($tracked) {
            "transaction identifier and recovery-specific description"
        } else {
            "recovery-specific description and loader path"
        }
        Write-LibertixFirmwareOwnershipLog `
            -Message "Deleting owned BCD firmware entry $($entry.Identifier); proof=$proof." `
            -Color "Cyan"
        Invoke-BcdeditCommand -Arguments @("/delete", $entry.Identifier, "/f") | Out-Null
    }

    $remaining = @(
        Get-BcdFirmwareEntriesByDescription -Descriptions @($InstallerBootDescription)
    )
    if ($remaining.Count -ne 0) {
        throw "Temporary Libertix BCD firmware entries remain after cleanup."
    }
}

function Remove-FirmwareBootReferenceAndVariable {
    param(
        [Parameter(Mandatory = $true)][uint16]$BootNumber,
        [Parameter(Mandatory = $true)][string]$BootVariable
    )

    $bootNext = @(ConvertFrom-BootOrderBytes -Bytes (Get-FirmwareVariableBytes -Name "BootNext"))
    if ($bootNext.Count -eq 1 -and [uint16]$bootNext[0] -eq $BootNumber) {
        Remove-FirmwareVariable -Name "BootNext"
    }
    Remove-FirmwareBootNumberFromOrder -BootNumber $BootNumber
    Remove-FirmwareVariable -Name $BootVariable
}

function Assert-FirmwareBootNumberAbsent {
    param([Parameter(Mandatory = $true)][uint16]$BootNumber)

    $bootVariable = "Boot{0:X4}" -f $BootNumber
    if (Test-FirmwareVariableExists -Name $bootVariable) {
        throw "Owned UEFI firmware entry $bootVariable remains after cleanup."
    }
    foreach ($referenceName in @("BootNext", "BootOrder")) {
        $references = @(
            ConvertFrom-BootOrderBytes -Bytes (
                Get-FirmwareVariableBytes -Name $referenceName
            )
        )
        if (@($references | Where-Object { [uint16]$_ -eq $BootNumber }).Count -ne 0) {
            throw "$referenceName still references removed UEFI entry $bootVariable."
        }
    }
}

function Remove-TrackedLibertixFirmwareEntry {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$ExpectedLoaderPath
    )

    if (
        -not ($State.PSObject.Properties.Name -contains "InstallerBootNumber") -or
        -not ($State.PSObject.Properties.Name -contains "InstallerBootVariable") -or
        $null -eq $State.InstallerBootNumber -or
        [string]::IsNullOrWhiteSpace([string]$State.InstallerBootVariable)
    ) {
        return $null
    }

    [int]$savedNumber = [int]$State.InstallerBootNumber
    [string]$savedVariable = [string]$State.InstallerBootVariable
    if ($savedNumber -lt 0 -or $savedNumber -gt 0xFFFF) {
        throw "Saved UEFI firmware ownership number is invalid."
    }
    [uint16]$bootNumber = [uint16]$savedNumber
    $expectedVariable = "Boot{0:X4}" -f $bootNumber
    if ($savedVariable -ne $expectedVariable) {
        throw "Saved UEFI firmware ownership variable is invalid."
    }

    $bytes = Get-FirmwareVariableBytes -Name $savedVariable
    if ($bytes) {
        if ((Get-EfiLoadOptionDescription -Bytes $bytes) -ne $InstallerBootDescription) {
            throw "$savedVariable exists but its description is not owned by this recovery run."
        }
        if (-not (Test-EfiLoadOptionLoaderPath -Bytes $bytes -ExpectedPath $ExpectedLoaderPath)) {
            throw "$savedVariable exists but its loader path is not owned by this recovery run."
        }
        $proof = "transaction, description, loader path"
    } else {
        $proof = "transaction; firmware variable already absent"
    }
    Write-LibertixFirmwareOwnershipLog `
        -Message "Cleaning tracked UEFI entry $savedVariable; proof=$proof." `
        -Color "Cyan"
    Remove-FirmwareBootReferenceAndVariable `
        -BootNumber $bootNumber `
        -BootVariable $savedVariable
    Assert-FirmwareBootNumberAbsent -BootNumber $bootNumber
    return $bootNumber
}

function Remove-OtherOwnedNativeFirmwareEntries {
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedLoaderPath,
        $ExcludedBootNumber = $null
    )

    $knownNumbers = @(
        ConvertFrom-BootOrderBytes -Bytes (Get-FirmwareVariableBytes -Name "BootOrder")
        ConvertFrom-BootOrderBytes -Bytes (Get-FirmwareVariableBytes -Name "BootNext")
    ) | Sort-Object -Unique
    foreach ($candidate in $knownNumbers) {
        if (
            $null -ne $ExcludedBootNumber -and
            [uint16]$candidate -eq [uint16]$ExcludedBootNumber
        ) {
            continue
        }
        $name = "Boot{0:X4}" -f $candidate
        $bytes = Get-FirmwareVariableBytes -Name $name
        if (-not $bytes) {
            continue
        }

        $description = Get-EfiLoadOptionDescription -Bytes $bytes
        if ($description -ne $InstallerBootDescription) {
            continue
        }
        if (-not (Test-EfiLoadOptionLoaderPath -Bytes $bytes -ExpectedPath $ExpectedLoaderPath)) {
            throw "$name has this recovery description but an unexpected loader path; refusing deletion."
        }
        Write-LibertixFirmwareOwnershipLog `
            -Message "Deleting owned UEFI entry $name; proof=recovery-specific description and loader path." `
            -Color "Cyan"
        Remove-FirmwareBootReferenceAndVariable `
            -BootNumber ([uint16]$candidate) `
            -BootVariable $name
        Assert-FirmwareBootNumberAbsent -BootNumber ([uint16]$candidate)
    }
}

function Remove-LibertixTemporaryFirmwareEntries {
    param([Parameter(Mandatory = $true)][string]$ExpectedLoaderPath)

    # A Boot#### variable can exist without appearing in BootOrder or BootNext
    # if firmware setup was interrupted between those writes. Transaction state
    # is the authoritative ownership proof for that orphaned entry.
    $state = Get-ValidatedTemporaryFirmwareCleanupState
    if (-not $state) { return }

    Remove-OwnedBcdFirmwareEntries `
        -State $state `
        -ExpectedLoaderPath $ExpectedLoaderPath
    $trackedBootNumber = Remove-TrackedLibertixFirmwareEntry `
        -State $state `
        -ExpectedLoaderPath $ExpectedLoaderPath
    Remove-OtherOwnedNativeFirmwareEntries `
        -ExpectedLoaderPath $ExpectedLoaderPath `
        -ExcludedBootNumber $trackedBootNumber

    $remainingNativeEntry = Get-FirmwareBootNumberByDescription `
        -Description $InstallerBootDescription
    if ($null -ne $remainingNativeEntry) {
        throw ("Temporary Libertix firmware entry Boot{0:X4} remains after cleanup." -f `
            [uint16]$remainingNativeEntry)
    }
    Write-LibertixFirmwareOwnershipLog `
        -Message "Temporary UEFI and BCD ownership cleanup verified; no owned entry remains." `
        -Color "Green"
}

function Remove-LibertixInstalledFirmwareEntries {
    param([Parameter(Mandatory = $true)][string]$EspDrive)

    $ownerPath = Join-Path (Join-Path $EspDrive $InstalledEspDirectory) $InstallerEspOwnershipFile
    $ownerLines = @(Get-Content -LiteralPath $ownerPath -ErrorAction Stop)
    if (
        $ownerLines.Count -ne 5 -or
        $ownerLines[0].Trim() -ne $RecoveryRunId -or
        $ownerLines[4].Trim() -ne $InstalledBootLoaderPath
    ) {
        throw "Installed Libertix firmware ownership marker is invalid."
    }
    $bootNumberText = $ownerLines[1].Trim()
    if ($bootNumberText -notmatch '^[0-9a-fA-F]{4}$') {
        throw "Installed Libertix firmware ownership number is invalid."
    }
    [uint16]$bootNumber = [Convert]::ToUInt16($bootNumberText, 16)
    $bootVariable = "Boot{0:X4}" -f $bootNumber
    $bytes = Get-FirmwareVariableBytes -Name $bootVariable
    if ($bytes) {
        if ((Get-EfiLoadOptionDescription -Bytes $bytes) -ne $InstalledBootDescription) {
            throw "$bootVariable exists but is not the installed Libertix entry owned by this recovery run."
        }
        if (-not (Test-EfiLoadOptionLoaderPath -Bytes $bytes -ExpectedPath $InstalledBootLoaderPath)) {
            throw "$bootVariable exists but its loader path does not match the owned installed entry."
        }
        $proof = "ESP owner, description, loader path"
    } else {
        $proof = "ESP owner; firmware variable already absent"
    }
    Write-LibertixFirmwareOwnershipLog `
        -Message "Cleaning installed UEFI entry $bootVariable; proof=$proof." `
        -Color "Cyan"
    Remove-FirmwareBootReferenceAndVariable `
        -BootNumber $bootNumber `
        -BootVariable $bootVariable
    Assert-FirmwareBootNumberAbsent -BootNumber $bootNumber
    Write-LibertixFirmwareOwnershipLog `
        -Message "Installed UEFI ownership cleanup verified for $bootVariable." `
        -Color "Green"
}

function Set-NativeUefiBootOrderOnce {
    param(
        [Parameter(Mandatory = $true)][string]$InstallerDrive,
        [Parameter(Mandatory = $true)][int]$InstallerDiskNumber,
        [Parameter(Mandatory = $true)][int]$InstallerPartitionNumber,
        [Parameter(Mandatory = $true)][string]$LoaderPath
    )

    $driveLetter = ""
    if (-not [string]::IsNullOrWhiteSpace($InstallerDrive)) {
        $driveLetter = $InstallerDrive.Substring(0, 1)
    }

    $partition = $null
    if (-not [string]::IsNullOrWhiteSpace($driveLetter)) {
        $partition = Get-Partition -DriveLetter $driveLetter -ErrorAction SilentlyContinue
    }
    if (-not $partition) {
        $partition = Get-Partition `
            -DiskNumber $InstallerDiskNumber `
            -PartitionNumber $InstallerPartitionNumber `
            -ErrorAction SilentlyContinue
    }

    if (-not $partition) {
        throw "Cannot find Libertix installer partition by drive ${InstallerDrive} or disk $InstallerDiskNumber partition $InstallerPartitionNumber."
    }

    # Skip the numbers the firmware already advertises before probing, so the
    # common case costs a handful of NVRAM reads instead of a linear scan in
    # which every step re-enables the privilege and allocates a 64 KiB buffer.
    $usedNumbers = @{}
    foreach ($known in @(
        ConvertFrom-BootOrderBytes -Bytes (Get-FirmwareVariableBytes -Name "BootOrder")
        ConvertFrom-BootOrderBytes -Bytes (Get-FirmwareVariableBytes -Name "BootNext")
    )) {
        $usedNumbers[[int]$known] = $true
    }

    $bootNumber = $null
    for ($candidate = 0x0000; $candidate -le 0xFFFF; $candidate++) {
        if ($usedNumbers.ContainsKey($candidate)) {
            continue
        }
        $name = "Boot{0:X4}" -f $candidate
        if (-not (Test-FirmwareVariableExists -Name $name)) {
            $bootNumber = [uint16]$candidate
            break
        }
    }

    if ($null -eq $bootNumber) {
        throw "No free UEFI Boot#### slot found."
    }

    $loadOption = New-EfiLoadOption `
        -Description $InstallerBootDescription `
        -Partition $partition `
        -LoaderPath $LoaderPath

    $bootVariable = "Boot{0:X4}" -f $bootNumber
    Set-FirmwareVariable -Name $bootVariable -Value $loadOption

    return $bootVariable
}

function Get-FirmwareBootNumberByDescription {
    param([Parameter(Mandatory = $true)][string]$Description)

    $knownCandidates = @(
        ConvertFrom-BootOrderBytes -Bytes (Get-FirmwareVariableBytes -Name "BootOrder")
        ConvertFrom-BootOrderBytes -Bytes (Get-FirmwareVariableBytes -Name "BootNext")
    ) | Sort-Object -Unique
    foreach ($candidate in $knownCandidates) {
        $name = "Boot{0:X4}" -f $candidate
        $bytes = Get-FirmwareVariableBytes -Name $name
        if ($bytes -and (Get-EfiLoadOptionDescription -Bytes $bytes) -eq $Description) {
            return [uint16]$candidate
        }
    }

    return $null
}

function Restore-OriginalFirmwareBootOrder {
    $state = Get-TransactionPartitionState
    if (-not $state -or -not $state.OriginalBootOrder) {
        return
    }

    $rawOriginal = @($state.OriginalBootOrder)
    if (
        $rawOriginal.Count -eq 1 -and
        $rawOriginal[0] -is [pscustomobject] -and
        @($rawOriginal[0].PSObject.Properties).Count -eq 0
    ) {
        return
    }
    $original = @($rawOriginal | ForEach-Object { [Convert]::ToUInt16($_) })
    if ($original.Count -eq 0) {
        return
    }

    foreach ($bootNumber in $original) {
        if (-not (Test-FirmwareVariableExists -Name ("Boot{0:X4}" -f $bootNumber))) {
            throw ("Cannot restore the saved UEFI BootOrder because Boot{0:X4} no longer exists." -f $bootNumber)
        }
    }

    Set-FirmwareVariable -Name "BootOrder" -Value (ConvertTo-BootOrderBytes -Order $original)
    $verified = @(ConvertFrom-BootOrderBytes -Bytes (Get-FirmwareVariableBytes -Name "BootOrder"))
    if (($verified -join ",") -ne ($original -join ",")) {
        throw "UEFI BootOrder restore verification failed."
    }
    Write-Log "Original UEFI BootOrder restored." "Green"
}

function Assert-LibertixFirmwareEntry {
    param(
        [Parameter(Mandatory = $true)][uint16]$BootNumber,
        [Parameter(Mandatory = $true)][string]$LoaderPath
    )

    $bootVariable = "Boot{0:X4}" -f $BootNumber
    $bytes = Get-FirmwareVariableBytes -Name $bootVariable
    if (-not $bytes) {
        throw "$bootVariable cannot be read back after it was created."
    }
    if ((Get-EfiLoadOptionDescription -Bytes $bytes) -ne $InstallerBootDescription) {
        throw "$bootVariable description does not match '$InstallerBootDescription'."
    }

    if (-not (Test-EfiLoadOptionLoaderPath -Bytes $bytes -ExpectedPath $LoaderPath)) {
        throw "$bootVariable does not contain the expected loader path $LoaderPath."
    }
}

function New-LibertixBcdFirmwareEntry {
    param(
        [Parameter(Mandatory = $true)][string]$EspDrive,
        [Parameter(Mandatory = $true)][string]$LoaderPath,
        [hashtable]$EspLoaderSha256 = @{},
        [uint16[]]$OriginalBootOrder = @()
    )

    $copyText = Invoke-BcdeditCommand -Arguments @("/copy", "{bootmgr}", "/d", $InstallerBootDescription)
    $entryIdMatches = [regex]::Matches(
        $copyText,
        "\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}"
    )
    if ($entryIdMatches.Count -ne 1) {
        throw "Could not parse exactly one canonical firmware entry identifier from bcdedit output: $copyText"
    }
    $entryId = $entryIdMatches[0].Value
    # Persist the exact BCD owner before any follow-up mutation. If Windows is
    # interrupted here, rollback can still remove only this copied object.
    Update-TransactionBcdEntryState -FirmwareEntryId $entryId

    Invoke-BcdeditCommand -Arguments @("/set", $entryId, "device", "partition=$EspDrive") | Out-Null
    Invoke-BcdeditCommand -Arguments @("/set", $entryId, "path", $LoaderPath) | Out-Null
    foreach ($value in @("locale", "inherit", "default", "resumeobject", "toolsdisplayorder", "timeout")) {
        try {
            Invoke-BcdeditCommand -Arguments @("/deletevalue", $entryId, $value) | Out-Null
        } catch {
            Write-Verbose "Optional BCD value '$value' could not be removed: $($_.Exception.Message)"
        }
    }
    Invoke-BcdeditCommand -Arguments @("/set", "{fwbootmgr}", "displayorder", $entryId, "/addfirst") | Out-Null

    $bootNumber = $null
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        $bootNumber = Get-FirmwareBootNumberByDescription -Description $InstallerBootDescription
        if ($null -ne $bootNumber) {
            break
        }
        Start-Sleep -Seconds 1
    }
    if ($null -eq $bootNumber) {
        throw "BCD created a firmware entry but no matching UEFI Boot#### variable appeared."
    }

    $bootVariable = "Boot{0:X4}" -f $bootNumber
    # Persist ownership immediately. A crash after Boot#### materialization but
    # before BootOrder verification must still leave rollback an exact target.
    Update-TransactionFirmwareState `
        -BootNumber $bootNumber `
        -BootVariable $bootVariable `
        -FirmwareEntryId $entryId `
        -EspLoaderSha256 $EspLoaderSha256 `
        -OriginalBootOrder $OriginalBootOrder
    $loadOption = Get-FirmwareVariableBytes -Name $bootVariable
    $optionalLength = Get-EfiLoadOptionOptionalDataLength -Bytes $loadOption
    if ($optionalLength -lt 0) {
        throw "Cannot parse the BCD-created $bootVariable load option."
    }
    if ($optionalLength -gt 0) {
        Set-FirmwareVariable -Name $bootVariable -Value (Remove-EfiLoadOptionOptionalData -Bytes $loadOption)
    }
    Assert-LibertixFirmwareEntry -BootNumber $bootNumber -LoaderPath $LoaderPath

    # bcdedit /copy creates a source BCD object. Updating the materialized
    # Boot#### load option through the firmware API leaves that source object
    # visible as a duplicate. Remove only the source and require one surviving
    # firmware entry with the expected description.
    Invoke-BcdeditCommand -Arguments @("/delete", $entryId, "/f") | Out-Null
    $survivingEntries = @(
        Get-BcdFirmwareEntriesByDescription -Descriptions @($InstallerBootDescription)
    )
    if ($survivingEntries.Count -ne 1) {
        throw "Expected one materialized Libertix firmware entry after BCD source cleanup; found $($survivingEntries.Count)."
    }
    if (-not (Test-BcdFirmwareEntryLoaderPath `
        -Entry $survivingEntries[0] `
        -ExpectedLoaderPath $LoaderPath
    )) {
        throw "The materialized Libertix BCD firmware entry does not contain the expected loader path."
    }

    return [pscustomobject]@{
        EntryId = $survivingEntries[0].Identifier
        BootNumber = [uint16]$bootNumber
        BootVariable = $bootVariable
    }
}

function Get-SecureBootDbCertificates {
    $db = Get-SecureBootUEFI -Name db
    [byte[]]$bytes = $db.Bytes
    $x509SignatureType = [Guid]"a5c059a1-94e4-4aa7-87b5-ab155c2bf072"
    $certificates = New-Object System.Collections.Generic.List[Security.Cryptography.X509Certificates.X509Certificate2]
    $offset = 0

    while ($offset + 28 -le $bytes.Length) {
        $guidBytes = New-Object byte[] 16
        [Array]::Copy($bytes, $offset, $guidBytes, 0, 16)
        $signatureType = New-Object Guid (,$guidBytes)
        $listSize = [BitConverter]::ToUInt32($bytes, $offset + 16)
        $headerSize = [BitConverter]::ToUInt32($bytes, $offset + 20)
        $signatureSize = [BitConverter]::ToUInt32($bytes, $offset + 24)
        if ($listSize -lt 28 -or $offset + $listSize -gt $bytes.Length) {
            throw "Secure Boot db contains an invalid EFI signature list."
        }
        if ($signatureSize -lt 16) {
            throw "Secure Boot db contains an invalid EFI signature size."
        }

        if ($signatureType -eq $x509SignatureType) {
            $signatureOffset = $offset + 28 + $headerSize
            $listEnd = $offset + $listSize
            while ($signatureOffset + $signatureSize -le $listEnd) {
                $certificateLength = [int]$signatureSize - 16
                $certificateBytes = New-Object byte[] $certificateLength
                [Array]::Copy($bytes, $signatureOffset + 16, $certificateBytes, 0, $certificateLength)
                try {
                    $certificates.Add((New-Object Security.Cryptography.X509Certificates.X509Certificate2 (,$certificateBytes)))
                } catch {
                    throw "Secure Boot db contains an invalid X.509 certificate: $($_.Exception.Message)"
                }
                $signatureOffset += $signatureSize
            }
        }
        $offset += $listSize
    }
    return $certificates
}

function Get-TrustedMicrosoftUefiAuthorities {
    $subjects = @(Get-SecureBootDbCertificates | ForEach-Object { $_.Subject })
    $authorities = @()
    if (@($subjects | Where-Object {
        $_ -match "CN=Microsoft Corporation UEFI CA 2011(?:,|$)"
    }).Count -gt 0) {
        $authorities += "2011"
    }
    if (@($subjects | Where-Object {
        $_ -match "CN=Microsoft(?: Corporation)? UEFI CA 2023(?:,|$)"
    }).Count -gt 0) {
        $authorities += "2023"
    }
    return $authorities
}

function Test-LibertixSecureBootCompatibility {
    param(
        [Parameter(Mandatory = $true)][object]$InstallationPlan
    )

    Write-LibertixProgress -Stage "secure-boot" -Percent 8
    Write-Log "Checking Secure Boot certificate compatibility..." "Cyan"

    try {
        $secureBootEnabled = Confirm-SecureBootUEFI
    } catch {
        throw "Cannot read Secure Boot state. Refusing to continue on an unknown UEFI state: $($_.Exception.Message)"
    }

    if (-not $secureBootEnabled) {
        Write-Log "Secure Boot is disabled; signed-chain check is not required." "Yellow"
        return
    }

    $subjects = @(Get-SecureBootDbCertificates | ForEach-Object { $_.Subject })
    $trustedAuthorities = @(Get-TrustedMicrosoftUefiAuthorities)
    $hasWindows2023 = @($subjects | Where-Object { $_ -match "CN=Windows UEFI CA 2023(?:,|$)" }).Count -gt 0
    if ($trustedAuthorities.Count -eq 0) {
        if ($hasWindows2023) {
            throw "Secure Boot DB contains Windows UEFI CA 2023, but not Microsoft UEFI CA 2023 for third-party bootloaders. Disable Secure Boot or enroll the Microsoft third-party UEFI CA before installing Libertix."
        }
        throw "Secure Boot is enabled but neither Microsoft Corporation UEFI CA 2011 nor Microsoft UEFI CA 2023 was detected in db. This looks like a custom/professional Secure Boot trust store. Disable Secure Boot or enroll the Microsoft third-party UEFI CA before installing Libertix."
    }

    $distributionAuthorities = @(
        $InstallationPlan.distribution.secureBootMicrosoftAuthorities |
            ForEach-Object { [string]$_ }
    )
    $compatibleAuthorities = @(
        $trustedAuthorities | Where-Object { $_ -in $distributionAuthorities }
    )
    $trustedAuthoritiesText = $trustedAuthorities -join ", "
    $distributionAuthoritiesText = $distributionAuthorities -join ", "
    if ($compatibleAuthorities.Count -eq 0) {
        $message = (
            "Secure Boot trusts Microsoft UEFI CA [{0}], but the selected distribution " +
            "provides an installed-system shim for [{1}]. The dual-signed Libertix mini-ISO " +
            "would boot, but the installed system would not. Refusing before disk mutation."
        ) -f $trustedAuthoritiesText, $distributionAuthoritiesText
        throw $message
    }

    $compatibleAuthoritiesText = $compatibleAuthorities -join ", "
    $message = (
        "Secure Boot installed-system chain is compatible through Microsoft UEFI CA {0}. " +
        "Firmware=[{1}], distribution=[{2}]."
    ) -f $compatibleAuthoritiesText, $trustedAuthoritiesText, $distributionAuthoritiesText
    Write-Log $message "Green"
}
