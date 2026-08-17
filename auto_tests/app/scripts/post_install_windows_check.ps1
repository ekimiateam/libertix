param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop

function Assert-Condition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Test-ObjectProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return $null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name
}

function Read-JsonFileWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [int]$TimeoutMilliseconds = 10000
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        try {
            return Get-Content -LiteralPath $LiteralPath -Raw -Encoding UTF8 -ErrorAction Stop |
                ConvertFrom-Json -ErrorAction Stop
        } catch {
            if ($stopwatch.ElapsedMilliseconds -ge $TimeoutMilliseconds) {
                throw
            }
            # The verifier replaces this file while the test is polling it. Windows can
            # briefly deny access or expose an incomplete replacement between two reads.
            Start-Sleep -Milliseconds 200
        }
    } while ($true)
}

function Get-LinuxDrive {
    param([Parameter(Mandatory = $true)][string]$LinuxUsername)

    for ($attempt = 0; $attempt -lt 90; $attempt++) {
        foreach ($letter in @("L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z")) {
            if (Test-Path -LiteralPath "${letter}:\home\$LinuxUsername" -PathType Container) {
                return "${letter}:"
            }
        }
        Start-Sleep -Seconds 1
    }
    throw "The read-only Linux volume is not mounted on any supported drive letter."
}

function Get-LibertixRecoveryTasks {
    $tasks = @()
    foreach ($pattern in @(
        "LibertixInstallRecovery",
        "LibertixInstallRecoveryPrompt",
        "LibertixUefiRecovery_*",
        "LibertixUefiRecoveryPrompt_*"
    )) {
        $tasks += @(Get-ScheduledTask -TaskName $pattern -ErrorAction SilentlyContinue)
    }
    return @($tasks | Sort-Object TaskName -Unique)
}

function Get-LibertixRecoverySession {
    param([Parameter(Mandatory = $true)][string]$ExpectedFirmware)

    $archivedPlanPath = "C:\LibertixInstallLogs\Linux\latest\installation-plan.json"
    Assert-Condition (Test-Path -LiteralPath $archivedPlanPath -PathType Leaf) `
        "The archived installation plan is missing for recovery verification."
    $archivedPlan = Get-Content -LiteralPath $archivedPlanPath -Raw -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop
    $candidateRoots = if ($ExpectedFirmware -eq "bios") {
        @("C:\LibertixInstallRecovery")
    } else {
        @(
            Get-ChildItem `
                -LiteralPath "C:\ProgramData\Libertix\UefiRecovery" `
                -Directory `
                -ErrorAction SilentlyContinue |
                ForEach-Object { $_.FullName }
        )
    }
    $matchingSessions = @()
    foreach ($root in $candidateRoots) {
        $planPath = Join-Path $root "installation-plan.json"
        if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) { continue }
        $plan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -ErrorAction Stop
        if ([string]$plan.planId -eq [string]$archivedPlan.planId) {
            $matchingSessions += [pscustomobject]@{ Root = $root; Plan = $plan }
        }
    }
    Assert-Condition ($matchingSessions.Count -eq 1) `
        "The permanent recovery session for the current installation is absent or ambiguous."
    return $matchingSessions[0]
}

function Get-PostInstallResultUiProcesses {
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][string]$ExpectedFirmware
    )

    $resultStatePath = Join-Path $Session.Root "post-install-verification.json"
    $resultStatePattern = [regex]::Escape($resultStatePath)
    $recoveryStatePath = Join-Path $Session.Root "state.json"
    $recoveryStatePattern = [regex]::Escape($recoveryStatePath)
    $interactiveSessionIds = @(
        Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" |
            ForEach-Object { [int]$_.SessionId }
    )
    $resultProcesses = @()
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'")) {
        $commandLine = [string]$process.CommandLine
        $matchesCommand = if ($ExpectedFirmware -eq "uefi") {
            $commandLine -match '(?i)libertix-uefi-recovery-agent\.ps1' -and
            $commandLine -match '(?i)-Action\s+Prompt(?:\s|$)' -and
            $commandLine -match $recoveryStatePattern
        } else {
            $commandLine -match '(?i)libertix-post-install-result\.ps1' -and
            $commandLine -match $resultStatePattern
        }
        if (-not $matchesCommand -or
            $interactiveSessionIds -notcontains [int]$process.SessionId) {
            continue
        }

        $resultProcesses += [pscustomobject]@{
            ProcessId = [int]$process.ProcessId
            SessionId = [int]$process.SessionId
            CommandLine = $commandLine
        }
    }
    return @($resultProcesses)
}

function Assert-LibertixPostInstallResult {
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][string]$ExpectedFirmware
    )

    $root = [string]$Session.Root
    $resultPath = Join-Path $root "post-install-verification.json"
    Assert-Condition (Test-Path -LiteralPath $resultPath -PathType Leaf) `
        "The post-install verification result is missing."
    $result = Read-JsonFileWithRetry -LiteralPath $resultPath
    Assert-Condition ([string]$result.status -eq "succeeded") `
        "The post-install verification did not succeed: $($result.error)"
    Assert-Condition ([string]$result.planId -eq [string]$Session.Plan.planId) `
        "The post-install verification belongs to another plan."
    $expectedChecks = @(
        "execution-ledger",
        "installed-linux-boot",
        "disk-geometry",
        "windows-read-only-linux-share",
        "windows-health",
        "boot-configuration",
        "temporary-boot-cleanup",
        "permanent-recovery-archive"
    )
    if ([bool]$Session.Plan.features.shareLinuxFilesInWindows) {
        $expectedChecks += "explorer-integration"
    }
    if ($ExpectedFirmware -eq "uefi") {
        $expectedChecks += "boot-guardian"
    }
    $actualChecks = @($result.checks | ForEach-Object { [string]$_.name })
    Assert-Condition ($actualChecks.Count -ge $expectedChecks.Count) `
        "The post-install verification check count is incomplete."
    Assert-Condition (@($actualChecks | Select-Object -Unique).Count -eq $actualChecks.Count) `
        "The post-install verification contains duplicate check names."
    Assert-Condition (@($result.checks | Where-Object { -not [bool]$_.passed }).Count -eq 0) `
        "At least one post-install verification check failed."
    foreach ($expectedCheck in $expectedChecks) {
        Assert-Condition ($actualChecks -contains $expectedCheck) `
            "The post-install verification omitted '$expectedCheck'."
    }
    foreach ($relativePath in @(
        "installation-plan.json",
        "installation-state.json",
        "installed-linux-boot.json",
        "post-install-verification.json"
    )) {
        Assert-Condition (Test-Path -LiteralPath (Join-Path $root $relativePath) -PathType Leaf) `
            "Permanent recovery evidence is missing: $relativePath"
    }
    $evidence = Get-Content `
        -LiteralPath (Join-Path $root "installed-linux-boot.json") `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop
    Assert-Condition ([bool]$evidence.grub.bootChain.verified) `
        "The installed boot chain was not proven by the first Linux boot."
    Assert-Condition ([bool]$evidence.system.rootReadWrite) `
        "The first Linux boot did not prove a read-write root filesystem."
    Assert-Condition (
        [string]$evidence.system.fstabRootUuid -eq [string]$evidence.root.uuid
    ) "The first Linux boot did not prove the root UUID in fstab."
    Assert-Condition (
        [string]$evidence.system.username -eq [string]$Session.Plan.account.username
    ) "The first Linux boot did not prove the planned user account."
    Assert-Condition (
        [bool]$evidence.system.sudoMember -and
        [bool]$evidence.system.passwordActive -and
        [bool]$evidence.system.dpkgAuditClean -and
        [int]$evidence.system.failedSystemdUnits -eq 0
    ) "The first Linux boot did not prove a healthy installed system."
    Assert-Condition (
        [bool]$evidence.localization.verified -and
        [string]$evidence.localization.languageCode -eq [string]$Session.Plan.locale.languageCode -and
        [string]$evidence.localization.systemLocale -eq [string]$Session.Plan.locale.systemLanguage -and
        [string]$evidence.localization.keyboardLayout -eq [string]$Session.Plan.locale.keyboardLayout -and
        [string]$evidence.localization.keyboardVariant -eq [string]$Session.Plan.locale.keyboardVariant
    ) "The first Linux boot did not prove the planned locale and keyboard configuration."
    if ($ExpectedFirmware -eq "uefi") {
        $bootChainType = [string]$evidence.grub.bootChain.type
        $bootCurrentVerified = $bootChainType -eq "uefi-boot-current"
        $preferredPathVerified = $false
        if ($bootChainType -eq "uefi-preferred-windows-path") {
            $preferred = $evidence.grub.bootChain.preferredPath
            $preferredPathVerified = (
                (Test-ObjectProperty -Object $preferred -Name "manifestPath") -and
                (Test-ObjectProperty -Object $preferred -Name "manifestSha256") -and
                (Test-ObjectProperty -Object $preferred -Name "secureBootEvidencePath") -and
                (Test-ObjectProperty -Object $preferred -Name "verifiedHashes") -and
                [string]$preferred.manifestPath -eq (
                    "/boot/efi/EFI/Libertix/preferred-boot-path.json"
                ) -and
                [string]$preferred.manifestSha256 -match '^[0-9a-f]{64}$' -and
                [string]$preferred.secureBootEvidencePath -eq (
                    "/boot/efi/EFI/Libertix/secure-boot-chain.json"
                )
            )
            if ($preferredPathVerified) {
                foreach ($name in @(
                    "bootmgfw.efi", "grubx64.efi", "mmx64.efi", "grub.cfg",
                    "bootmgfw.libertix-windows.efi"
                )) {
                    if (
                        -not (Test-ObjectProperty -Object $preferred.verifiedHashes -Name $name) -or
                        [string]$preferred.verifiedHashes.PSObject.Properties[$name].Value -notmatch (
                            '^[0-9a-f]{64}$'
                        )
                    ) {
                        $preferredPathVerified = $false
                        break
                    }
                }
            }
        }
        Assert-Condition ($bootCurrentVerified -or $preferredPathVerified) `
            "The verified UEFI BootCurrent or preferred Windows-path proof is missing."
        Assert-Condition (Test-Path -LiteralPath (Join-Path $root "uefi-transaction.json") -PathType Leaf) `
            "The permanent UEFI rollback transaction is missing."
        $guardian = Get-CimInstance `
            -ClassName Win32_Service `
            -Filter "Name='LibertixBootGuardian'" `
            -ErrorAction Stop
        Assert-Condition (
            $null -ne $guardian -and
            [string]$guardian.State -eq "Running" -and
            [string]$guardian.StartMode -eq "Auto"
        ) "The boot guardian service is not running automatically."
        $guardianConfigPath = "C:\ProgramData\Libertix\BootGuardian\config.json"
        Assert-Condition (Test-Path -LiteralPath $guardianConfigPath -PathType Leaf) `
            "The boot guardian configuration is missing."
        $guardianConfig = Read-JsonFileWithRetry -LiteralPath $guardianConfigPath
        Assert-Condition (
            [int]$guardianConfig.version -eq 1 -and
            [string]$guardianConfig.runId -eq [string]$Session.Plan.planId -and
            [string]$guardianConfig.mode -in @(
                "firmware-boot-order",
                "preferred-windows-path"
            )
        ) "The boot guardian configuration identity or mode is invalid."
    } else {
        Assert-Condition ([string]$evidence.grub.bootChain.type -eq "bios-mbr") `
            "The BIOS MBR boot proof is missing."
        Assert-Condition (Test-Path -LiteralPath (Join-Path $root "bcd-backup") -PathType Leaf) `
            "The permanent BIOS BCD backup is missing."
    }
    return $result
}

function Get-PlannedLinuxOffset {
    param([Parameter(Mandatory = $true)]$Plan)

    if ([string]$Plan.disk.installer.resizeMode -eq "live-offline") {
        return [int64]$Plan.disk.installer.finalOffsetBytes
    }
    return [int64]$Plan.disk.installer.offsetBytes
}

function Get-ExpectedLinuxMountIdentity {
    $planPath = "C:\LibertixInstallLogs\Linux\latest\installation-plan.json"
    Assert-Condition (Test-Path -LiteralPath $planPath -PathType Leaf) `
        "The archived installation plan is missing for Linux mount verification."
    $plan = Get-Content -LiteralPath $planPath -Raw -ErrorAction Stop | ConvertFrom-Json
    $disk = Get-Disk -Number ([int]$plan.disk.number) -ErrorAction Stop
    Assert-Condition (
        ([string]$disk.UniqueId).Trim() -eq ([string]$plan.disk.uniqueId).Trim()
    ) "The Linux mount disk identity differs from the installation plan."
    [int64]$plannedSize = [int64]$plan.disk.installer.finalSizeBytes
    [int64]$plannedOffset = Get-PlannedLinuxOffset -Plan $plan
    [int64]$alignmentBytes = [int64]$config.partition_alignment_bytes
    Assert-Condition ($alignmentBytes -gt 0 -and $alignmentBytes -le $plannedSize) `
        "The partition alignment contract is invalid."
    $partitions = @(
        Get-Partition -DiskNumber $disk.Number -ErrorAction Stop |
            Where-Object {
                [int64]$_.Offset -eq $plannedOffset -and
                [int64]$_.Size -le $plannedSize -and
                [int64]$_.Size -ge ($plannedSize - $alignmentBytes)
            }
    )
    Assert-Condition ($partitions.Count -eq 1) `
        "The Linux mount partition does not match the installation plan."
    return [pscustomobject]@{
        DiskNumber = [int]$disk.Number
        PartitionNumber = [int]$partitions[0].PartitionNumber
        PartitionOffset = [int64]$partitions[0].Offset
        PartitionSize = [int64]$partitions[0].Size
    }
}

function Get-CommandLineTokens {
    param([Parameter(Mandatory = $true)][string]$CommandLine)

    $tokens = @()
    foreach ($match in [regex]::Matches($CommandLine, '"([^\"]*)"|([^\s]+)')) {
        if ($match.Groups[1].Success) {
            $tokens += $match.Groups[1].Value
        } else {
            $tokens += $match.Groups[2].Value
        }
    }
    return @($tokens)
}

function Test-CommandLineToken {
    param(
        [Parameter(Mandatory = $true)][string[]]$Tokens,
        [Parameter(Mandatory = $true)][string]$Value
    )

    return @($Tokens | Where-Object { $_ -ieq $Value }).Count -eq 1
}

function Test-CommandLineOptionValue {
    param(
        [Parameter(Mandatory = $true)][string[]]$Tokens,
        [Parameter(Mandatory = $true)][string]$Option,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $optionValues = @()
    for ($index = 0; $index -lt $Tokens.Count; $index++) {
        if ($Tokens[$index] -ieq $Option) {
            if ($index + 1 -ge $Tokens.Count) {
                return $false
            }
            $optionValues += $Tokens[$index + 1]
            continue
        }
        $prefix = "$Option="
        if ($Tokens[$index].StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            $optionValues += $Tokens[$index].Substring($prefix.Length)
        }
    }
    return $optionValues.Count -eq 1 -and $optionValues[0] -ieq $Value
}

function ConvertFrom-NativeOutputBytes {
    param([byte[]]$Bytes)

    if ($null -eq $Bytes -or $Bytes.Length -eq 0) {
        return ""
    }

    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
    if ($Bytes.Length -ge 4 -and
        $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE -and
        $Bytes[2] -eq 0x00 -and $Bytes[3] -eq 0x00) {
        return [Text.Encoding]::UTF32.GetString($Bytes, 4, $Bytes.Length - 4)
    }
    if ($Bytes.Length -ge 4 -and
        $Bytes[0] -eq 0x00 -and $Bytes[1] -eq 0x00 -and
        $Bytes[2] -eq 0xFE -and $Bytes[3] -eq 0xFF) {
        $utf32BigEndian = New-Object Text.UTF32Encoding($true, $false, $true)
        return $utf32BigEndian.GetString($Bytes, 4, $Bytes.Length - 4)
    }
    if ($Bytes.Length -ge 3 -and
        $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return $utf8NoBom.GetString($Bytes, 3, $Bytes.Length - 3)
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return [Text.Encoding]::Unicode.GetString($Bytes, 2, $Bytes.Length - 2)
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        return [Text.Encoding]::BigEndianUnicode.GetString($Bytes, 2, $Bytes.Length - 2)
    }

    $sampleLength = [Math]::Min($Bytes.Length, 4096)
    $pairCount = [Math]::Floor($sampleLength / 2)
    if ($pairCount -gt 0) {
        $evenNulls = 0
        $oddNulls = 0
        for ($index = 0; $index -lt ($pairCount * 2); $index += 2) {
            if ($Bytes[$index] -eq 0) { $evenNulls++ }
            if ($Bytes[$index + 1] -eq 0) { $oddNulls++ }
        }
        $nullThreshold = [Math]::Max(2, [Math]::Floor($pairCount / 4))
        if ($oddNulls -ge $nullThreshold -and $oddNulls -gt ($evenNulls * 2)) {
            return [Text.Encoding]::Unicode.GetString($Bytes)
        }
        if ($evenNulls -ge $nullThreshold -and $evenNulls -gt ($oddNulls * 2)) {
            return [Text.Encoding]::BigEndianUnicode.GetString($Bytes)
        }
    }

    try {
        return $strictUtf8.GetString($Bytes)
    } catch [Text.DecoderFallbackException] {
        $oemCodePage = [Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
        return [Text.Encoding]::GetEncoding($oemCodePage).GetString($Bytes)
    }
}

function Read-NativeOutputText {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        return ""
    }
    return (ConvertFrom-NativeOutputBytes ([IO.File]::ReadAllBytes($LiteralPath))).Replace(
        ([string][char]0),
        ""
    )
}

function Invoke-NativeCommandDecoded {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $temporaryPrefix = Join-Path $env:TEMP ("libertix-native-" + [Guid]::NewGuid().ToString("N"))
    $stdoutPath = "$temporaryPrefix.out"
    $stderrPath = "$temporaryPrefix.err"
    try {
        $process = Start-Process `
            -FilePath $FilePath `
            -ArgumentList $Arguments `
            -Wait `
            -PassThru `
            -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -ErrorAction Stop
        $stdout = Read-NativeOutputText -LiteralPath $stdoutPath
        $stderr = Read-NativeOutputText -LiteralPath $stderrPath
        $combinedOutput = @($stdout, $stderr) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.TrimEnd("`r", "`n") } |
            Out-String
        [PSCustomObject]@{
            ExitCode = [int]$process.ExitCode
            StdOut = $stdout
            StdErr = $stderr
            CombinedOutput = $combinedOutput.TrimEnd("`r", "`n")
        }
    } finally {
        Remove-Item -LiteralPath @($stdoutPath, $stderrPath) -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-NativeCheck {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $result = Invoke-NativeCommandDecoded -FilePath $FilePath -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        $diagnostic = $result.CombinedOutput.Replace("`r", "").Replace("`n", " | ").Trim()
        if ($diagnostic.Length -gt 2000) {
            $diagnostic = $diagnostic.Substring($diagnostic.Length - 2000)
        }
        $suffix = if ([string]::IsNullOrWhiteSpace($diagnostic)) { "" } else { " Output: $diagnostic" }
        throw "$FilePath exited with code $($result.ExitCode).$suffix"
    }
    Write-Output "NATIVE_COMMAND=$FilePath EXIT_CODE=$($result.ExitCode)"
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
$check = [string]$config.check
$installerIsoPattern = [regex]::Escape([string]$config.installer_iso_file_name)

try {
    switch ($check) {
        "waiting_for_linux" {
            $deadline = [DateTime]::UtcNow.AddMinutes(3)
            do {
                $session = Get-LibertixRecoverySession `
                    -ExpectedFirmware ([string]$config.expected_firmware)
                $evidencePath = Join-Path $session.Root "installed-linux-boot.json"
                $resultPath = Join-Path $session.Root "post-install-verification.json"
                $waitingResult = if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
                    Read-JsonFileWithRetry -LiteralPath $resultPath
                } else { $null }
                $startupTasks = @(Get-LibertixRecoveryTasks | Where-Object {
                    (
                        $_.TaskName -eq "LibertixInstallRecovery" -or
                        $_.TaskName -like "LibertixUefiRecovery_*"
                    ) -and $_.TaskName -notmatch "Prompt"
                })
                $promptTasks = @(Get-LibertixRecoveryTasks | Where-Object {
                    $_.TaskName -eq "LibertixInstallRecoveryPrompt" -or
                    $_.TaskName -like "LibertixUefiRecoveryPrompt_*"
                })
                $waitingReady = (
                    -not (Test-Path -LiteralPath $evidencePath -PathType Leaf) -and
                    $null -ne $waitingResult -and
                    [string]$waitingResult.status -eq "waiting-linux-boot" -and
                    [string]$waitingResult.waitingFor -eq "installed-linux-boot.json" -and
                    $startupTasks.Count -eq 1 -and
                    $promptTasks.Count -eq 1
                )
                if ($waitingReady) { break }
                if ([DateTime]::UtcNow -ge $deadline) {
                    $waitingStatus = if ($null -eq $waitingResult) {
                        "missing"
                    } else {
                        [string]$waitingResult.status
                    }
                    throw (
                        "Windows did not enter the durable first-Linux-boot wait state: " +
                        "resultStatus=$waitingStatus, " +
                        "startupTasks=$($startupTasks.Count), promptTasks=$($promptTasks.Count), " +
                        "evidencePresent=$(Test-Path -LiteralPath $evidencePath -PathType Leaf)."
                    )
                }
                Start-Sleep -Seconds 2
            } while ($true)
            Assert-Condition ([string]$waitingResult.status -notin @("succeeded", "failed", "rolled-back")) `
                "Windows reached a terminal post-install result before Linux first boot."
            Assert-Condition ([string]::IsNullOrWhiteSpace([string]$waitingResult.error)) `
                "Windows recorded an error while it should only wait for Linux first boot."
            Assert-Condition (@($waitingResult.checks | Where-Object { -not [bool]$_.passed }).Count -eq 0) `
                "Windows recorded a failed check before Linux first boot."
            Assert-Condition (@($startupTasks | Where-Object { $_.State -eq "Disabled" }).Count -eq 0) `
                "The startup recovery task is disabled while waiting for Linux first boot."
            Assert-Condition (@($promptTasks | Where-Object { $_.State -eq "Disabled" }).Count -eq 0) `
                "The result prompt task is disabled while waiting for Linux first boot."
            if ([string]$config.expected_firmware -eq "uefi") {
                $recoveryState = Get-Content `
                    -LiteralPath (Join-Path $session.Root "state.json") `
                    -Raw `
                    -Encoding UTF8 |
                    ConvertFrom-Json -ErrorAction Stop
                Assert-Condition ([string]$recoveryState.Phase -eq "AwaitingInstalledLinuxBoot") `
                    "The UEFI agent did not persist AwaitingInstalledLinuxBoot."
            }
            Start-Sleep -Seconds 5
            $unexpectedResultUi = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
                Where-Object {
                    [string]$_.CommandLine -match '(?i)libertix-post-install-result\.ps1'
                })
            Assert-Condition ($unexpectedResultUi.Count -eq 0) `
                "The Windows result window started before Linux first-boot evidence existed."
            Write-Output "LIBERTIX_WAITING_FOR_LINUX=verified"
        }
        "filesystem_repair_state" {
            $session = Get-LibertixRecoverySession `
                -ExpectedFirmware ([string]$config.expected_firmware)
            $currentBootId = ([DateTime](
                Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            ).LastBootUpTime).ToUniversalTime().ToString("o")
            $repairPath = Join-Path $session.Root "windows-filesystem-repair.json"
            if ([string]$session.Plan.disk.installer.resizeMode -ne "live-offline") {
                Write-Output "WINDOWS_FILESYSTEM_REPAIR_STATUS=not-required"
                Write-Output "WINDOWS_FILESYSTEM_REPAIR_ATTEMPT=0"
                Write-Output "WINDOWS_FILESYSTEM_REPAIR_SCHEDULED_BOOT="
                Write-Output "WINDOWS_CURRENT_BOOT=$currentBootId"
                break
            }
            if (-not (Test-Path -LiteralPath $repairPath -PathType Leaf)) {
                Write-Output "WINDOWS_FILESYSTEM_REPAIR_STATUS=pending"
                Write-Output "WINDOWS_FILESYSTEM_REPAIR_ATTEMPT=0"
                Write-Output "WINDOWS_FILESYSTEM_REPAIR_SCHEDULED_BOOT="
                Write-Output "WINDOWS_CURRENT_BOOT=$currentBootId"
                break
            }
            $repair = Read-JsonFileWithRetry -LiteralPath $repairPath
            Assert-Condition (
                [int]$repair.schemaVersion -eq 1 -and
                [string]$repair.planId -eq [string]$session.Plan.planId
            ) "Windows filesystem repair state belongs to another installation plan."
            Write-Output "WINDOWS_FILESYSTEM_REPAIR_STATUS=$([string]$repair.status)"
            Write-Output "WINDOWS_FILESYSTEM_REPAIR_ATTEMPT=$([int]$repair.attemptCount)"
            Write-Output "WINDOWS_FILESYSTEM_REPAIR_SCHEDULED_BOOT=$([string]$repair.scheduledFromBootId)"
            Write-Output "WINDOWS_CURRENT_BOOT=$currentBootId"
        }
        "finalization" {
            $deadline = [DateTime]::UtcNow.AddMinutes(5)
            do {
                $session = Get-LibertixRecoverySession `
                    -ExpectedFirmware ([string]$config.expected_firmware)
                $resultPath = Join-Path $session.Root "post-install-verification.json"
                $savedResult = if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
                    Read-JsonFileWithRetry -LiteralPath $resultPath
                } else { $null }
                $resultStatus = if ($null -ne $savedResult) {
                    [string]$savedResult.status
                } else { "missing" }
                $uefiTransaction = Test-Path -LiteralPath "C:\LibertixTools\uefi-transaction.json"
                $startupTasks = @(Get-LibertixRecoveryTasks | Where-Object {
                    (
                        $_.TaskName -eq "LibertixInstallRecovery" -or
                        $_.TaskName -like "LibertixUefiRecovery_*"
                    ) -and $_.TaskName -notmatch "Prompt"
                })
                $interactiveCheckPassed = -not [bool]$config.share_linux_files_in_windows
                if ($resultStatus -in @("failed", "rolled-back")) {
                    $failedChecks = @($savedResult.checks | Where-Object { -not [bool]$_.passed } |
                        ForEach-Object { "{0}: {1}" -f [string]$_.name, [string]$_.message })
                    throw (
                        "Libertix Windows finalization reached terminal status '$resultStatus'. " +
                        "Error='$([string]$savedResult.error)'. " +
                        "FailedChecks='$($failedChecks -join '; ')'. " +
                        "LogPath='$([string]$savedResult.logPath)'."
                    )
                }
                if ($resultStatus -eq "succeeded" -and [bool]$config.share_linux_files_in_windows) {
                    $interactiveCheckPassed = @($savedResult.checks | Where-Object {
                        [string]$_.name -eq "explorer-integration" -and [bool]$_.passed
                    }).Count -eq 1
                }
                if (
                    $resultStatus -eq "succeeded" -and
                    $interactiveCheckPassed -and
                    -not $uefiTransaction -and
                    $startupTasks.Count -eq 0
                ) {
                    $null = Assert-LibertixPostInstallResult `
                        -Session $session `
                        -ExpectedFirmware ([string]$config.expected_firmware)
                    Write-Output "LIBERTIX_FINALIZATION=ready"
                    break
                }
                if ([DateTime]::UtcNow -ge $deadline) {
                    throw (
                        "Libertix Windows finalization timed out: " +
                        "resultStatus=$resultStatus, uefiTransaction=$uefiTransaction, " +
                        "startupTasks=$($startupTasks.Count), " +
                        "explorerIntegration=$interactiveCheckPassed."
                    )
                }
                Start-Sleep -Seconds 2
            } while ($true)
        }
        "final_state" {
            $os = Get-CimInstance Win32_OperatingSystem
            $firmware = [string](Get-ComputerInfo).BiosFirmwareType
            $volume = Get-Volume -DriveLetter C -ErrorAction Stop
            $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -eq [string]$config.expected_ipv4 })
            $defaultRoutes = @(Get-NetRoute `
                -AddressFamily IPv4 `
                -DestinationPrefix "0.0.0.0/0" `
                -ErrorAction Stop)
            $sshService = Get-Service -Name "sshd" -ErrorAction Stop
            $coreServices = @(Get-Service -Name @("EventLog", "RpcSs", "Schedule") -ErrorAction Stop)
            $session = Get-LibertixRecoverySession `
                -ExpectedFirmware ([string]$config.expected_firmware)
            $postInstallResult = Assert-LibertixPostInstallResult `
                -Session $session `
                -ExpectedFirmware ([string]$config.expected_firmware)
            $uefiTransaction = Test-Path -LiteralPath "C:\LibertixTools\uefi-transaction.json"
            $uefiToolsRoot = Test-Path -LiteralPath "C:\LibertixTools"
            $transactionDownloads = @(
                Get-ChildItem `
                    -LiteralPath "C:\ProgramData\Libertix\Downloads" `
                    -Force `
                    -ErrorAction SilentlyContinue
            )
            $startupRecoveryTasks = @(Get-LibertixRecoveryTasks | Where-Object {
                $_.TaskName -eq "LibertixInstallRecovery" -or
                $_.TaskName -like "LibertixUefiRecovery_*"
            })
            $bcdResult = Invoke-NativeCommandDecoded -FilePath "bcdedit.exe" -Arguments @("/enum", "all")
            Assert-Condition ($bcdResult.ExitCode -eq 0) "bcdedit failed during the final Windows check."
            $bcdText = $bcdResult.CombinedOutput

            Write-Output ("WINDOWS={0} BUILD={1}" -f $os.Caption, $os.BuildNumber)
            Write-Output ("FIRMWARE={0}" -f $firmware)
            Write-Output ("SYSTEM_VOLUME={0} HEALTH={1}" -f $volume.FileSystem, $volume.HealthStatus)
            Write-Output ("EXPECTED_IPV4_PRESENT={0}" -f ($addresses.Count -ge 1))
            Write-Output ("DEFAULT_ROUTES={0}" -f $defaultRoutes.Count)
            Write-Output ("SSHD={0}" -f $sshService.Status)

            Assert-Condition ($os.ProductType -eq 1) "The final system is not a Windows workstation."
            if ([string]$config.expected_firmware -eq "uefi") {
                Assert-Condition ($firmware -match "UEFI") "The final Windows boot is not UEFI."
            } else {
                Assert-Condition ($firmware -match "BIOS|Legacy") "The final Windows boot is not BIOS."
            }
            Assert-Condition ($volume.FileSystem -eq "NTFS") "The final Windows system volume is not NTFS."
            Assert-Condition ($volume.HealthStatus -eq "Healthy") "The final Windows system volume is not healthy."
            Assert-Condition ($addresses.Count -ge 1) "The expected IPv4 address is missing after the final boot."
            Assert-Condition ($defaultRoutes.Count -ge 1) "Windows has no default route after the final boot."
            Assert-Condition ($sshService.Status -eq "Running") "The SSH service stopped after the final boot."
            Assert-Condition (@($coreServices | Where-Object { $_.Status -ne "Running" }).Count -eq 0) `
                "A core Windows service stopped after the final boot."
            Assert-Condition (-not $uefiTransaction) "The UEFI transaction remains after the final boot."
            Assert-Condition (-not $uefiToolsRoot) "The temporary UEFI tools directory remains after the final boot."
            Assert-Condition ([string]$postInstallResult.status -eq "succeeded") `
                "The permanent post-install verification result is not successful."
            Assert-Condition ($transactionDownloads.Count -eq 0) `
                "Transaction downloads remain after the final boot."
            Assert-Condition ($startupRecoveryTasks.Count -eq 0) `
                "A recovery startup task remains after the final boot."
            Assert-Condition ($bcdText -match "(?i)winload[.]e(?:xe|fi)") `
                "The Windows loader is absent after the final boot."
            Assert-Condition ($bcdText -notmatch "(?i)Libertix Installer|$installerIsoPattern|grldr") `
                "A temporary Libertix boot entry remains after the final boot."
        }
        "identity" {
            $os = Get-CimInstance Win32_OperatingSystem
            Write-Output ("COMPUTER={0}" -f $env:COMPUTERNAME)
            Write-Output ("WINDOWS={0} BUILD={1}" -f $os.Caption, $os.BuildNumber)
            Assert-Condition ($os.ProductType -eq 1) "The installed system is not a Windows workstation."
        }
        "firmware" {
            $firmware = [string](Get-ComputerInfo).BiosFirmwareType
            Write-Output ("FIRMWARE={0}" -f $firmware)
            if ([string]$config.expected_firmware -eq "uefi") {
                Assert-Condition ($firmware -match "UEFI") "Windows did not boot in UEFI mode."
            } else {
                Assert-Condition ($firmware -match "BIOS|Legacy") "Windows did not boot in BIOS mode."
            }
        }
        "system_volume" {
            $volume = Get-Volume -DriveLetter C -ErrorAction Stop
            $partition = Get-Partition -DriveLetter C -ErrorAction Stop
            $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
            $volume | Format-List DriveLetter, FileSystem, HealthStatus, OperationalStatus, Size, SizeRemaining
            $disk | Format-List Number, PartitionStyle, HealthStatus, OperationalStatus
            Assert-Condition ($volume.FileSystem -eq "NTFS") "C: is not NTFS."
            Assert-Condition ($volume.HealthStatus -eq "Healthy") "C: is not healthy."
            Assert-Condition ($disk.HealthStatus -eq "Healthy") "The Windows disk is not healthy."
        }
        "system_resources" {
            $systemDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
            $operatingSystem = Get-CimInstance Win32_OperatingSystem
            $computerSystem = Get-CimInstance Win32_ComputerSystem
            Write-Output ("C_FREE_BYTES={0}" -f $systemDrive.FreeSpace)
            Write-Output ("FREE_PHYSICAL_KIB={0}" -f $operatingSystem.FreePhysicalMemory)
            Write-Output ("TOTAL_MEMORY_BYTES={0}" -f $computerSystem.TotalPhysicalMemory)
            Assert-Condition ([uint64]$systemDrive.FreeSpace -gt 2GB) "C: has less than 2 GiB free."
            Assert-Condition ([uint64]$operatingSystem.FreePhysicalMemory -gt 262144) "Windows has less than 256 MiB free physical memory."
            Assert-Condition ([uint64]$computerSystem.TotalPhysicalMemory -gt 2GB) "Windows has less than 2 GiB total memory."
        }
        "partition_layout" {
            $systemPartition = Get-Partition -DriveLetter C -ErrorAction Stop
            $systemDisk = Get-Disk -Number $systemPartition.DiskNumber -ErrorAction Stop
            $partitions = @(Get-Partition -DiskNumber $systemDisk.Number -ErrorAction Stop)
            $partitions | Format-Table PartitionNumber, DriveLetter, Type, GptType, MbrType, Size -AutoSize
            if ([string]$config.expected_firmware -eq "uefi") {
                Assert-Condition ($systemDisk.PartitionStyle -eq "GPT") "The UEFI system disk is not GPT."
            } else {
                Assert-Condition ($systemDisk.PartitionStyle -eq "MBR") "The BIOS system disk is not MBR."
            }
            Assert-Condition (-not $systemDisk.IsOffline) "The Windows system disk is offline."
            Assert-Condition (-not $systemDisk.IsReadOnly) "The Windows system disk is read-only."
            Assert-Condition ($partitions.Count -ge 3) "The system disk has too few partitions after installation."
        }
        "partition_geometry" {
            $planPath = "C:\LibertixInstallLogs\Linux\latest\installation-plan.json"
            Assert-Condition (Test-Path -LiteralPath $planPath -PathType Leaf) `
                "The archived installation plan is missing."
            $plan = Get-Content -LiteralPath $planPath -Raw -ErrorAction Stop | ConvertFrom-Json
            $systemPartition = Get-Partition -DriveLetter C -ErrorAction Stop
            $systemDisk = Get-Disk -Number $systemPartition.DiskNumber -ErrorAction Stop
            $partitions = @(Get-Partition -DiskNumber $systemDisk.Number -ErrorAction Stop)
            $installerOffset = Get-PlannedLinuxOffset -Plan $plan
            $finalLinuxSize = [int64]$plan.disk.installer.finalSizeBytes
            $recoverySession = Get-LibertixRecoverySession `
                -ExpectedFirmware ([string]$config.expected_firmware)
            $linuxEvidence = Get-Content `
                -LiteralPath (Join-Path $recoverySession.Root "installed-linux-boot.json") `
                -Raw `
                -Encoding UTF8 |
                ConvertFrom-Json -ErrorAction Stop
            $observedLinuxSize = [int64]$linuxEvidence.root.sizeBytes
            $alignmentTolerance = [int64]$linuxEvidence.root.alignmentToleranceBytes
            $originalWindowsOffset = [int64]$plan.disk.windows.offsetBytes
            $originalWindowsSize = [int64]$plan.disk.windows.sizeBytes
            $windowsEnd = [int64]$systemPartition.Offset + [int64]$systemPartition.Size
            $gapBeforeLinux = $installerOffset - $windowsEnd
            $actualWindowsShrink = $originalWindowsSize - [int64]$systemPartition.Size
            $linuxMatches = @($partitions | Where-Object {
                [int64]$_.Offset -eq $installerOffset -and
                [int64]$_.Size -eq $observedLinuxSize
            })
            $recoveryMatches = @($partitions | Where-Object {
                [int64]$_.Offset -eq [int64]$plan.disk.recovery.offsetBytes -and
                [int64]$_.Size -eq [int64]$plan.disk.recovery.sizeBytes
            })
            Write-Output ("WINDOWS_OFFSET={0} WINDOWS_SIZE={1}" -f `
                $systemPartition.Offset, $systemPartition.Size)
            Write-Output ("LINUX_OFFSET={0} LINUX_SIZE={1}" -f `
                $installerOffset, $observedLinuxSize)
            Write-Output ("RECOVERY_OFFSET={0} RECOVERY_SIZE={1}" -f `
                $plan.disk.recovery.offsetBytes, $plan.disk.recovery.sizeBytes)
            Assert-Condition ([int]$systemDisk.Number -eq [int]$plan.disk.number) `
                "The installed system disk number differs from the installation plan."
            Assert-Condition (([string]$systemDisk.UniqueId).Trim() -eq `
                ([string]$plan.disk.uniqueId).Trim()) `
                "The installed system disk identity differs from the installation plan."
            Assert-Condition ([int64]$systemPartition.Offset -eq $originalWindowsOffset) `
                "The Windows partition offset changed during installation."
            Assert-Condition ($gapBeforeLinux -ge 0 -and $gapBeforeLinux -le 1MB) `
                "The Windows and Linux partitions are separated by an unexpected gap."
            Assert-Condition ($actualWindowsShrink -ge $finalLinuxSize -and `
                $actualWindowsShrink -le ($finalLinuxSize + 2MB)) `
                "The Windows partition shrink differs from the requested Linux allocation."
            Assert-Condition ($linuxMatches.Count -eq 1) `
                "The final Linux partition offset or size differs from the installation plan."
            Assert-Condition ($observedLinuxSize -le $finalLinuxSize -and `
                $observedLinuxSize -ge ($finalLinuxSize - $alignmentTolerance)) `
                "The final Linux partition exceeds the policy alignment tolerance."
            Assert-Condition ($recoveryMatches.Count -eq 1) `
                "The Windows Recovery partition geometry changed during installation."
        }
        "boot_partition" {
            $systemPartition = Get-Partition -DriveLetter C -ErrorAction Stop
            $partitions = @(Get-Partition -DiskNumber $systemPartition.DiskNumber -ErrorAction Stop)
            if ([string]$config.expected_firmware -eq "uefi") {
                $bootPartitions = @($partitions | Where-Object {
                    $_.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}"
                })
                Assert-Condition ($bootPartitions.Count -eq 1) "The UEFI system disk does not contain exactly one ESP."
                Assert-Condition ([uint64]$bootPartitions[0].Size -ge 64MB) "The EFI system partition is unexpectedly small."
            } else {
                $bootPartitions = @($partitions | Where-Object { $_.IsSystem })
                if ($bootPartitions.Count -eq 0) {
                    $bootPartitions = @($partitions | Where-Object { $_.IsActive })
                }
                Assert-Condition ($bootPartitions.Count -eq 1) `
                    "The BIOS system disk does not contain exactly one Windows boot partition."
            }
            $bootPartitions | Format-Table PartitionNumber, Type, GptType, MbrType, IsActive, Size -AutoSize
        }
        "boot_configuration" {
            $bcdResult = Invoke-NativeCommandDecoded -FilePath "bcdedit.exe" -Arguments @("/enum", "all")
            Write-Output $bcdResult.CombinedOutput
            Assert-Condition ($bcdResult.ExitCode -eq 0) "bcdedit failed to enumerate the boot configuration."
            $text = $bcdResult.CombinedOutput
            Assert-Condition ($text -match "(?i)winload[.]e(?:xe|fi)") "The Windows loader is absent from BCD."
            Assert-Condition ($text -notmatch "(?i)Libertix Installer|$installerIsoPattern|grldr") "A temporary Libertix boot entry remains in BCD."
        }
        "recovery" {
            $recoveryPartitions = @(Get-Partition | Where-Object {
                $_.Type -match "Recovery" -or
                $_.GptType -eq "{de94bba4-06d1-4d40-a16a-bfd50179d6ac}" -or
                [int]$_.MbrType -eq 39
            })
            $recoveryPartitions | Format-Table DiskNumber, PartitionNumber, Type, GptType, MbrType, Size -AutoSize
            Assert-Condition ($recoveryPartitions.Count -ge 1) "No Windows recovery partition was found."
            $reagentResult = Invoke-NativeCommandDecoded -FilePath "reagentc.exe" -Arguments @("/enable")
            Write-Output $reagentResult.CombinedOutput
            Assert-Condition ($reagentResult.ExitCode -eq 0) `
                "reagentc.exe failed to enable Windows Recovery Environment."
        }
        "bitlocker" {
            $volume = Get-BitLockerVolume -MountPoint "C:" -ErrorAction Stop
            $volume | Format-List MountPoint, VolumeStatus, EncryptionPercentage, ProtectionStatus, LockStatus
            Assert-Condition ($volume.VolumeStatus -eq "FullyDecrypted") "C: is not fully decrypted."
            Assert-Condition ([int]$volume.EncryptionPercentage -eq 0) "C: still contains encrypted data."
        }
        "temporary_artifacts" {
            $stagingVolumeLabels = @($config.staging_volume_labels | ForEach-Object { [string]$_ })
            Assert-Condition ($stagingVolumeLabels.Count -gt 0) `
                "The staging-volume label contract is missing from the validation request."
            $installerVolumes = @(
                Get-Volume -ErrorAction SilentlyContinue |
                    Where-Object { [string]$_.FileSystemLabel -in $stagingVolumeLabels }
            )
            $uefiTransaction = Test-Path -LiteralPath "C:\LibertixTools\uefi-transaction.json"
            $biosPending = Test-Path -LiteralPath "C:\LibertixInstallRecovery\pending.env"
            $recoveryTasks = @(Get-LibertixRecoveryTasks)
            $startupRecoveryTasks = @($recoveryTasks | Where-Object {
                $_.TaskName -notmatch "Prompt"
            })
            $promptTasks = @($recoveryTasks | Where-Object {
                $_.TaskName -match "Prompt"
            })
            Write-Output ("INSTALLER_VOLUMES={0}" -f $installerVolumes.Count)
            Write-Output ("UEFI_TRANSACTION={0}" -f $uefiTransaction)
            Write-Output ("BIOS_PENDING={0}" -f $biosPending)
            Write-Output ("STARTUP_RECOVERY_TASKS={0}" -f $startupRecoveryTasks.Count)
            Write-Output ("RESULT_PROMPT_TASKS={0}" -f $promptTasks.Count)
            Assert-Condition ($installerVolumes.Count -eq 0) "The temporary installer volume still exists."
            Assert-Condition (-not $uefiTransaction) "The UEFI transaction file still exists."
            if ([string]$config.expected_firmware -eq "bios") {
                Assert-Condition $biosPending `
                    "The durable BIOS rollback metadata is missing."
            } else {
                Assert-Condition (-not $biosPending) `
                    "Unexpected BIOS rollback metadata exists on a UEFI system."
            }
            Assert-Condition ($startupRecoveryTasks.Count -eq 0) `
                "The startup recovery task still exists."
            Assert-Condition ($promptTasks.Count -le 1) `
                "Multiple post-install result prompt tasks exist."
        }
        "network" {
            $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -eq [string]$config.expected_ipv4 })
            $configurations = @(Get-NetIPConfiguration | Where-Object { $_.IPv4Address })
            $defaultRoutes = @(Get-NetRoute `
                -AddressFamily IPv4 `
                -DestinationPrefix "0.0.0.0/0" `
                -ErrorAction Stop)
            $configurations | Format-List InterfaceAlias, IPv4Address, IPv4DefaultGateway, DNSServer
            $defaultRoutes | Format-List InterfaceAlias, NextHop, RouteMetric, State
            Assert-Condition ($addresses.Count -ge 1) "The expected Windows IPv4 address is not configured."
            Assert-Condition ($defaultRoutes.Count -ge 1) "Windows has no IPv4 default route."
            Assert-Condition ([bool]($defaultRoutes.NextHop | Where-Object {
                $_ -and $_ -ne "0.0.0.0"
            })) "Windows has no usable IPv4 gateway."
            Resolve-DnsName -Name "ekimia.fr" -Type A -ErrorAction Stop |
                Format-Table Name, Type, IPAddress -AutoSize
        }
        "locale" {
            $session = Get-LibertixRecoverySession `
                -ExpectedFirmware ([string]$config.expected_firmware)
            $plannedLocale = $session.Plan.locale
            $systemLocale = Get-WinSystemLocale
            $languages = @(Get-WinUserLanguageList)
            $uiCulture = Get-UICulture
            $timeZone = Get-TimeZone
            $inputMethodTips = @(
                $languages |
                    ForEach-Object { @($_.InputMethodTips) } |
                    ForEach-Object { [string]$_ }
            )
            $supportedUiLanguage = switch ($uiCulture.TwoLetterISOLanguageName.ToLowerInvariant()) {
                { $_ -in @("en", "fr", "es") } { $_; break }
                default { "en" }
            }
            $exactKeyboardMappings = @{
                "00000409" = "us|"; "00010409" = "us|dvorak"; "00020409" = "us|intl"
                "00030409" = "us|dvorak-l"; "00040409" = "us|dvorak-r"; "00000809" = "gb|"
                "0000040C" = "fr|"; "0000080C" = "be|"; "00000C0C" = "ca|fr-legacy"
                "00001009" = "ca|"; "00011009" = "ca|multix"; "0000100C" = "ch|fr"
                "0000040A" = "es|winkeys"; "0000080A" = "latam|"
            }
            $languageKeyboardMappings = @{
                "0409" = "us|"; "0809" = "gb|"; "040C" = "fr|"; "080C" = "be|"
                "0C0C" = "ca|fr-legacy"; "1009" = "ca|"; "1109" = "ca|multix"
                "100C" = "ch|fr"; "040A" = "es|winkeys"; "080A" = "latam|"
            }
            $uiKeyboardFallbacks = @{ "en" = "us|"; "fr" = "fr|"; "es" = "es|" }
            $windowsKeyboardMappings = @(
                foreach ($tip in $inputMethodTips) {
                    $identifier = (($tip -split ":")[-1]).ToUpperInvariant()
                    if ($exactKeyboardMappings.ContainsKey($identifier)) {
                        $exactKeyboardMappings[$identifier]
                    } elseif ($identifier.Length -eq 8 -and
                        $languageKeyboardMappings.ContainsKey($identifier.Substring(4))) {
                        $languageKeyboardMappings[$identifier.Substring(4)]
                    } else {
                        $uiKeyboardFallbacks[$supportedUiLanguage]
                    }
                }
            )
            $plannedKeyboard = "{0}|{1}" -f `
                [string]$plannedLocale.keyboardLayout, [string]$plannedLocale.keyboardVariant
            Write-Output ("SYSTEM_LOCALE={0}" -f $systemLocale.Name)
            Write-Output ("UI_CULTURE={0}" -f $uiCulture.Name)
            Write-Output ("LANGUAGES={0}" -f (($languages.LanguageTag) -join ","))
            Write-Output ("INPUT_METHOD_TIPS={0}" -f ($inputMethodTips -join ","))
            Write-Output ("TIME_ZONE={0}" -f $timeZone.Id)
            Assert-Condition (-not [string]::IsNullOrWhiteSpace($systemLocale.Name)) "Windows has no system locale."
            Assert-Condition ($languages.Count -ge 1) "Windows has no user language."
            Assert-Condition ($inputMethodTips.Count -ge 1) "Windows has no configured input method."
            Assert-Condition (-not [string]::IsNullOrWhiteSpace($timeZone.Id)) "Windows has no time zone."
            Assert-Condition (
                [string]$plannedLocale.languageCode -eq $supportedUiLanguage
            ) "The Linux interface language differs from the Windows UI language selected by unattended mode."
            Assert-Condition (
                -not [string]::IsNullOrWhiteSpace([string]$plannedLocale.keyboardLayout)
            ) "The installation plan has no Linux keyboard layout."
            Assert-Condition (
                $windowsKeyboardMappings -contains $plannedKeyboard
            ) "The planned Linux keyboard does not match any configured Windows input method."
        }
        "ssh_service" {
            $service = Get-Service -Name "sshd" -ErrorAction Stop
            $configuration = Get-CimInstance Win32_Service -Filter "Name='sshd'"
            $service | Format-List Name, Status, StartType
            Assert-Condition ($service.Status -eq "Running") "The Windows SSH service is not running."
            Assert-Condition ($configuration.StartMode -eq "Auto") "The Windows SSH service is not configured for automatic startup."
        }
        "core_services" {
            $names = @("EventLog", "PlugPlay", "RpcSs", "Schedule")
            $services = @(Get-Service -Name $names -ErrorAction Stop)
            $services | Format-Table Name, Status, StartType -AutoSize
            $stopped = @($services | Where-Object { $_.Status -ne "Running" })
            Assert-Condition ($stopped.Count -eq 0) "One or more core Windows services are stopped."
        }
        "hibernation" {
            $power = Get-ItemProperty `
                -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\Power" `
                -ErrorAction Stop
            $sessionPower = Get-ItemProperty `
                -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" `
                -ErrorAction SilentlyContinue
            $hibernateEnabled = ([int]$power.HibernateEnabled -ne 0)
            $fastStartupConfigured = (
                $sessionPower -and
                $null -ne $sessionPower.HiberbootEnabled -and
                [int]$sessionPower.HiberbootEnabled -ne 0
            )
            $hiberfilePresent = Test-Path -LiteralPath "C:\hiberfil.sys"
            $fastStartupCapable = (
                $fastStartupConfigured -and
                $hibernateEnabled -and
                $hiberfilePresent
            )
            Write-Output ("HIBERNATION_ENABLED={0}" -f $hibernateEnabled)
            Write-Output ("FAST_STARTUP_CONFIGURED={0}" -f $fastStartupConfigured)
            Write-Output ("FAST_STARTUP_CAPABLE={0}" -f $fastStartupCapable)
            Write-Output ("HIBERNATION_FILE_PRESENT={0}" -f $hiberfilePresent)
            if ([bool]$config.share_windows_files_in_linux) {
                # HiberbootEnabled is only a saved preference. Fast Startup
                # cannot run after powercfg disables hibernation, even when a
                # cloned system retains that preference or a stale hiberfile.
                Assert-Condition (-not $hibernateEnabled) `
                    "Windows hibernation remains enabled while Linux mounts Windows read-write."
                Assert-Condition (-not $fastStartupCapable) `
                    "Windows Fast Startup remains enabled while Linux mounts Windows read-write."
            }
        }
        "sharing_disabled" {
            if (-not [bool]$config.share_linux_files_in_windows) {
                $mountTasks = @(Get-ScheduledTask `
                    -TaskName "LibertixLinuxReadOnly" `
                    -ErrorAction SilentlyContinue)
                $pinTasks = @(Get-ScheduledTask `
                    -TaskName "LibertixLinuxReadOnlyPin_*" `
                    -ErrorAction SilentlyContinue)
                $mountProcesses = @(Get-CimInstance `
                    Win32_Process `
                    -Filter "Name='ext4.exe'" `
                    -ErrorAction SilentlyContinue)
                Assert-Condition ($mountTasks.Count -eq 0) `
                    "The disabled Linux-to-Windows share still has a mount task."
                Assert-Condition ($pinTasks.Count -eq 0) `
                    "The disabled Linux-to-Windows share still has a shortcut task."
                Assert-Condition ($mountProcesses.Count -eq 0) `
                    "The disabled Linux-to-Windows share still has an ext4 mount process."
            }
        }
        "ext4_driver" {
            $ext4 = "$env:ProgramFiles\ext4-win-driver\ext4.exe"
            $launcher = "HKLM:\SOFTWARE\WOW6432Node\WinFsp\Services\ext4-mount"
            Write-Output ("EXT4={0}" -f $ext4)
            Assert-Condition (Test-Path -LiteralPath $ext4 -PathType Leaf) "ext4.exe is missing."
            Assert-Condition (Test-Path -LiteralPath $launcher) "The WinFsp ext4 launcher is missing."
            $command = [string](Get-ItemPropertyValue -LiteralPath $launcher -Name CommandLine)
            $runAs = [string](Get-ItemPropertyValue -LiteralPath $launcher -Name RunAs)
            [int]$recovery = Get-ItemPropertyValue -LiteralPath $launcher -Name Recovery
            [int]$broadcast = Get-ItemPropertyValue `
                -LiteralPath "HKLM:\SOFTWARE\WOW6432Node\WinFsp" `
                -Name MountBroadcastDriveChange
            Write-Output ("COMMAND={0}" -f $command)
            Assert-Condition ($command -match "(?i)(?:^|\s)--ro(?:\s|$)") "The ext4 launcher is not read-only."
            Assert-Condition ($runAs -eq "LocalSystem") "The ext4 launcher is not global to Windows sessions."
            Assert-Condition ($recovery -eq 1) "WinFsp mount recovery is disabled."
            Assert-Condition ($broadcast -eq 1) "WinFsp drive notifications are disabled."

            $setupProcesses = @(
                Get-CimInstance Win32_Process -ErrorAction Stop |
                    Where-Object {
                        [string]$_.Name -match '(?i)^ext4-win-driver.*setup\.exe$' -or
                        [string]$_.ExecutablePath -match '(?i)\\ext4-win-driver[^\\]*setup\.exe$'
                    }
            )
            $setupProcesses | Format-List ProcessId, Name, ExecutablePath, CommandLine
            Assert-Condition ($setupProcesses.Count -eq 0) `
                "The ext4 installer is still running and may display maintenance UI."

            $runOncePath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
            $runOnce = Get-ItemProperty -LiteralPath $runOncePath -ErrorAction SilentlyContinue
            $bundleRegistrations = @(
                Get-ItemProperty `
                    -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" `
                    -ErrorAction SilentlyContinue |
                    Where-Object {
                        $displayName = $_.PSObject.Properties["DisplayName"]
                        $bundleCachePath = $_.PSObject.Properties["BundleCachePath"]
                        $null -ne $displayName -and
                        [string]$displayName.Value -eq "ext4-win-driver" -and
                        $null -ne $bundleCachePath -and
                        -not [string]::IsNullOrWhiteSpace([string]$bundleCachePath.Value)
                    }
            )
            $resumeEntries = @(
                foreach ($registration in $bundleRegistrations) {
                    $bundleCode = [string]$registration.PSChildName
                    if ($null -eq $runOnce) { continue }
                    $resumeProperty = $runOnce.PSObject.Properties[$bundleCode]
                    if ($null -ne $resumeProperty) {
                        [pscustomobject]@{
                            BundleCode = $bundleCode
                            Command = [string]$resumeProperty.Value
                        }
                    }
                }
            )
            $resumeEntries | Format-List BundleCode, Command
            Assert-Condition ($resumeEntries.Count -eq 0) `
                "The ext4 installer has a pending RunOnce resume that can display maintenance UI."
        }
        "ext4_readonly_mount" {
            $drive = Get-LinuxDrive -LinuxUsername ([string]$config.linux_username)
            $driveRoot = $drive
            $identity = Get-ExpectedLinuxMountIdentity
            $expectedExecutable = "$env:ProgramFiles\ext4-win-driver\ext4.exe"
            $processes = @(Get-CimInstance Win32_Process -Filter "Name='ext4.exe'")
            Write-Output ("LINUX_DRIVE={0}" -f $drive)
            $processes | Format-List ProcessId, ExecutablePath, CommandLine
            Assert-Condition ($processes.Count -ge 1) "No ext4 mount process is running."
            $writableProcesses = @($processes | Where-Object {
                $_.CommandLine -notmatch "(?i)(?:^|\s)--ro(?:\s|$)"
            })
            Assert-Condition ($writableProcesses.Count -eq 0) `
                "At least one active ext4 mount is not read-only."
            $processIdentityResults = @($processes | ForEach-Object {
                $commandLine = [string]$_.CommandLine
                $commandLineTokens = @(Get-CommandLineTokens -CommandLine $commandLine)
                $executableMatches = [string]$_.ExecutablePath -ieq $expectedExecutable
                $diskMatches = Test-CommandLineToken `
                    -Tokens $commandLineTokens `
                    -Value "\\.\PhysicalDrive$($identity.DiskNumber)"
                $driveMatches = Test-CommandLineOptionValue `
                    -Tokens $commandLineTokens `
                    -Option "--drive" `
                    -Value $driveRoot
                $partitionMatches = Test-CommandLineOptionValue `
                    -Tokens $commandLineTokens `
                    -Option "--part" `
                    -Value ([string]$identity.PartitionNumber)
                $readOnlyMatches = Test-CommandLineToken -Tokens $commandLineTokens -Value "--ro"
                [pscustomobject]@{
                    Process = $_
                    ProcessId = $_.ProcessId
                    ExecutableMatches = $executableMatches
                    DiskMatches = $diskMatches
                    DriveMatches = $driveMatches
                    PartitionMatches = $partitionMatches
                    ReadOnlyMatches = $readOnlyMatches
                    ExpectedDisk = "\\.\PhysicalDrive$($identity.DiskNumber)"
                    ExpectedDrive = $driveRoot
                    ExpectedPartition = [string]$identity.PartitionNumber
                    Tokens = $commandLineTokens -join " | "
                }
            })
            $processIdentityResults |
                Select-Object `
                    ProcessId, `
                    ExecutableMatches, `
                    DiskMatches, `
                    DriveMatches, `
                    PartitionMatches, `
                    ReadOnlyMatches, `
                    ExpectedDisk, `
                    ExpectedDrive, `
                    ExpectedPartition, `
                    Tokens |
                Format-List
            $ownedProcesses = @($processIdentityResults | Where-Object {
                $_.ExecutableMatches -and
                $_.DiskMatches -and
                $_.DriveMatches -and
                $_.PartitionMatches -and
                $_.ReadOnlyMatches
            })
            Assert-Condition ($ownedProcesses.Count -eq 1) `
                "The active ext4 mount is not uniquely tied to the planned disk and partition."
            $mountStatusPath = Join-Path $env:ProgramData "Libertix\WindowsShare\mount-status.json"
            Assert-Condition (Test-Path -LiteralPath $mountStatusPath -PathType Leaf) `
                "The durable ext4 mount status is missing."
            $mountStatus = Get-Content -LiteralPath $mountStatusPath -Raw -Encoding UTF8 |
                ConvertFrom-Json -ErrorAction Stop
            Assert-Condition (
                [int]$mountStatus.schemaVersion -eq 1 -and
                [int]$mountStatus.diskNumber -eq [int]$identity.DiskNumber -and
                [int]$mountStatus.partitionNumber -eq [int]$identity.PartitionNumber -and
                [int64]$mountStatus.partitionOffset -eq [int64]$identity.PartitionOffset -and
                [int64]$mountStatus.partitionSize -eq [int64]$identity.PartitionSize -and
                [string]$mountStatus.drive -eq $driveRoot -and
                [bool]$mountStatus.readOnly -and
                [int]$mountStatus.processId -gt 0
            ) "The durable ext4 mount status does not describe the active planned mount."
        }
        "linux_home" {
            $drive = Get-LinuxDrive -LinuxUsername ([string]$config.linux_username)
            $linuxHomePath = Join-Path $drive "home\$($config.linux_username)"
            Write-Output ("LINUX_HOME={0}" -f $linuxHomePath)
            Assert-Condition (Test-Path -LiteralPath $linuxHomePath -PathType Container) "The Linux home directory is not readable from Windows."
        }
        "linux_home_hash" {
            Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$config.linux_sha256)) "The Linux source hash is unavailable."
            $drive = Get-LinuxDrive -LinuxUsername ([string]$config.linux_username)
            $path = Join-Path $drive "home\$($config.linux_username)\$($config.linux_relative_path)"
            $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            Write-Output ("PATH={0}" -f $path)
            Write-Output ("SHA256={0}" -f $actual)
            Assert-Condition ($actual -eq [string]$config.linux_sha256) "The Linux-home file hash differs between Linux and Windows."
        }
        "ext4_write_denied" {
            $drive = Get-LinuxDrive -LinuxUsername ([string]$config.linux_username)
            $probe = Join-Path $drive (".libertix-write-probe-{0}" -f [Guid]::NewGuid().ToString("N"))
            $accepted = $false
            try {
                Set-Content -LiteralPath $probe -Value "write must fail" -ErrorAction Stop
                $accepted = $true
            } catch {
                Write-Output ("WRITE_REFUSAL={0}" -f $_.Exception.Message)
            } finally {
                if ($accepted) {
                    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
                }
            }
            Assert-Condition (-not $accepted) "The Linux volume accepted a Windows write."
        }
        "explorer_shortcut" {
            $shortcuts = @(Get-ChildItem -Path "C:\Users\*\Links\Linux_*_read-only.lnk" -File -ErrorAction SilentlyContinue)
            $shortcuts | Format-Table FullName, Length, LastWriteTime -AutoSize
            Assert-Condition ($shortcuts.Count -ge 1) "No Linux read-only Explorer shortcut exists."
            $drive = Get-LinuxDrive -LinuxUsername ([string]$config.linux_username)
            $expectedTarget = Join-Path $drive "home\$($config.linux_username)"
            $shell = New-Object -ComObject WScript.Shell
            foreach ($shortcutPath in $shortcuts) {
                $shortcut = $shell.CreateShortcut([string]$shortcutPath.FullName)
                Assert-Condition ([string]$shortcut.TargetPath -eq $expectedTarget) `
                    "A Linux Explorer shortcut targets another path."
            }
        }
        "explorer_integration" {
            $session = Get-LibertixRecoverySession `
                -ExpectedFirmware ([string]$config.expected_firmware)
            $resultPath = Join-Path $session.Root "post-install-verification.json"
            $savedResult = Read-JsonFileWithRetry -LiteralPath $resultPath
            $checks = @($savedResult.checks | Where-Object {
                [string]$_.name -eq "explorer-integration"
            })
            Assert-Condition ($checks.Count -eq 1) `
                "Explorer integration was not verified in the interactive user session."
            Assert-Condition ([bool]$checks[0].passed) `
                "Explorer Home/Quick Access integration failed: $($checks[0].detail)"
        }
        "post_install_result_ui" {
            $session = Get-LibertixRecoverySession `
                -ExpectedFirmware ([string]$config.expected_firmware)
            $expectedFirmware = [string]$config.expected_firmware
            $deadline = [DateTime]::UtcNow.AddMinutes(2)
            do {
                $uiProcesses = @(
                    Get-PostInstallResultUiProcesses `
                        -Session $session `
                        -ExpectedFirmware $expectedFirmware
                )
            if ($uiProcesses.Count -eq 1) { break }
                if ([DateTime]::UtcNow -ge $deadline) {
                    throw "The interactive Windows post-install result window is not running."
                }
                Start-Sleep -Seconds 2
            } while ($true)
            $uiProcesses | Format-List ProcessId, SessionId, CommandLine
            Write-Output ("POST_INSTALL_RESULT_UI_PROCESS_ID={0}" -f `
                [int]$uiProcesses[0].ProcessId)
        }
        "post_install_result_ui_dismissed" {
            $session = Get-LibertixRecoverySession `
                -ExpectedFirmware ([string]$config.expected_firmware)
            $expectedFirmware = [string]$config.expected_firmware
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            do {
                $uiProcesses = @(
                    Get-PostInstallResultUiProcesses `
                        -Session $session `
                        -ExpectedFirmware $expectedFirmware
                )
                $promptTasks = @(Get-LibertixRecoveryTasks | Where-Object {
                    $_.TaskName -match "Prompt"
                })
                if ($uiProcesses.Count -eq 0 -and $promptTasks.Count -eq 0) {
                    break
                }
                if ([DateTime]::UtcNow -ge $deadline) {
                    throw "The Windows post-install result window or its prompt task is still active."
                }
                Start-Sleep -Seconds 1
            } while ($true)
            Write-Output "POST_INSTALL_RESULT_UI_DISMISSED=True"
        }
        "sharing_tasks" {
            $mountTasks = @(Get-ScheduledTask -TaskName "LibertixLinuxReadOnly" -ErrorAction SilentlyContinue)
            $pinTasks = @(Get-ScheduledTask -TaskName "LibertixLinuxReadOnlyPin_*" -ErrorAction SilentlyContinue)
            $mountTasks | Format-Table TaskName, State -AutoSize
            $pinTasks | Format-Table TaskName, State -AutoSize
            Assert-Condition ($mountTasks.Count -eq 1) "The Linux read-only mount task is missing or duplicated."
            Assert-Condition ($mountTasks[0].State -ne "Disabled") "The Linux read-only mount task is disabled."
            Assert-Condition ($pinTasks.Count -ge 1) "No Linux Explorer shortcut task exists."
            Assert-Condition (@($pinTasks | Where-Object { $_.State -eq "Disabled" }).Count -eq 0) "A Linux Explorer shortcut task is disabled."
        }
        "cross_os_hash" {
            Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$config.windows_sha256)) "The Linux-side Windows-file hash is unavailable."
            $path = Join-Path "C:\" ([string]$config.windows_relative_path)
            $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            Write-Output ("PATH={0}" -f $path)
            Write-Output ("SHA256={0}" -f $actual)
            Assert-Condition ($actual -eq [string]$config.windows_sha256) "The 100 MiB shared-file hash differs between Linux and Windows."
        }
        "dism_check_health" {
            Invoke-NativeCheck -FilePath "dism.exe" -Arguments @("/Online", "/Cleanup-Image", "/CheckHealth")
        }
        "sfc_verify_only" {
            Invoke-NativeCheck -FilePath "sfc.exe" -Arguments @("/verifyonly")
        }
        "chkdsk_scan" {
            Invoke-NativeCheck -FilePath "chkdsk.exe" -Arguments @("C:", "/scan")
        }
        default {
            throw "Unknown post-install Windows check: $check"
        }
    }
    Write-Output ("CHECK={0}" -f $check)
    Write-Output "RESULT=OK"
    exit 0
} catch {
    Write-Error ("CHECK={0} ERROR={1}" -f $check, $_.Exception.Message)
    Write-Error $_.ScriptStackTrace
    exit 1
}
