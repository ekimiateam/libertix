Set-StrictMode -Version Latest

$script:MinimumFinalSizeGiB = 20
$script:MaximumDirectFat32SizeGiB = 31
$script:LargeInstallationStagingSizeGiB = 8
$script:BytesPerGiB = 1GB

function Test-LibertixPlanProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return $null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name
}

function Assert-LibertixPlanProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not (Test-LibertixPlanProperty -Object $Object -Name $Name)) {
        throw "Installation plan is missing $Path."
    }

    return $Object.$Name
}

function Assert-LibertixPositiveInteger {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )

    [int64]$parsed = 0
    if ($null -eq $Value -or -not [int64]::TryParse([string]$Value, [ref]$parsed) -or $parsed -le 0) {
        throw "Installation plan field $Path must be a positive integer."
    }
}

function Assert-LibertixPartitionIdentity {
    param(
        [Parameter(Mandatory = $true)][object]$Partition,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $number = Assert-LibertixPlanProperty -Object $Partition -Name "number" -Path "$Path.number"
    $offset = Assert-LibertixPlanProperty -Object $Partition -Name "offsetBytes" -Path "$Path.offsetBytes"
    $size = Assert-LibertixPlanProperty -Object $Partition -Name "sizeBytes" -Path "$Path.sizeBytes"

    Assert-LibertixPositiveInteger -Value $number -Path "$Path.number"
    Assert-LibertixPositiveInteger -Value $offset -Path "$Path.offsetBytes"
    Assert-LibertixPositiveInteger -Value $size -Path "$Path.sizeBytes"
}

function Assert-LibertixSha256 {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ([string]$Value -notmatch '^[0-9a-f]{64}$') {
        throw "Installation plan field $Path must be a lowercase SHA-256 hash."
    }
}

function Assert-LibertixInstallationPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Plan)

    $schemaVersion = Assert-LibertixPlanProperty -Object $Plan -Name "schemaVersion" -Path "schemaVersion"
    if ([int]$schemaVersion -ne 1) {
        throw "Unsupported installation plan schemaVersion: $schemaVersion."
    }

    $planId = [string](Assert-LibertixPlanProperty -Object $Plan -Name "planId" -Path "planId")
    if ($planId -notmatch '^[0-9a-f]{32}$') {
        throw "Installation plan planId must contain 32 lowercase hexadecimal characters."
    }
    $createdAtUtc = [string](Assert-LibertixPlanProperty -Object $Plan -Name "createdAtUtc" -Path "createdAtUtc")
    [DateTimeOffset]$createdAt = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($createdAtUtc, [ref]$createdAt) -or $createdAt.Offset -ne [TimeSpan]::Zero) {
        throw "Installation plan createdAtUtc must be a valid UTC date-time."
    }

    $firmware = [string](Assert-LibertixPlanProperty -Object $Plan -Name "firmware" -Path "firmware")
    if ($firmware -notin @("bios", "uefi")) {
        throw "Installation plan firmware must be 'bios' or 'uefi'."
    }

    $distribution = Assert-LibertixPlanProperty -Object $Plan -Name "distribution" -Path "distribution"
    foreach ($name in @("name", "installerIsoFileName", "installerIsoUrl", "installerIsoWindowsPath", "liveIsoUrl")) {
        $value = [string](Assert-LibertixPlanProperty `
            -Object $distribution `
            -Name $name `
            -Path "distribution.$name")
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "Installation plan field distribution.$name cannot be empty."
        }
    }
    foreach ($name in @("installerIsoUrl", "liveIsoUrl")) {
        [Uri]$uri = $null
        $value = [string]$distribution.$name
        if (
            -not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -notin @("http", "https")
        ) {
            throw "Installation plan field distribution.$name must be an absolute HTTP(S) URL."
        }
    }
    if ([string]$distribution.installerIsoFileName -match '[/\\]') {
        throw "Installation plan distribution.installerIsoFileName must be a file name, not a path."
    }
    if ([string]$distribution.installerIsoWindowsPath -notmatch '^[A-Za-z]:[\\/]') {
        throw "Installation plan distribution.installerIsoWindowsPath must be an absolute Windows drive path."
    }
    Assert-LibertixSha256 `
        -Value (Assert-LibertixPlanProperty -Object $distribution -Name "installerIsoSha256" -Path "distribution.installerIsoSha256") `
        -Path "distribution.installerIsoSha256"
    Assert-LibertixSha256 `
        -Value (Assert-LibertixPlanProperty -Object $distribution -Name "liveIsoSha256" -Path "distribution.liveIsoSha256") `
        -Path "distribution.liveIsoSha256"

    $locale = Assert-LibertixPlanProperty -Object $Plan -Name "locale" -Path "locale"
    $languageCode = [string](Assert-LibertixPlanProperty -Object $locale -Name "languageCode" -Path "locale.languageCode")
    if ($languageCode -notin @("en", "fr", "es", "ja")) {
        throw "Installation plan field locale.languageCode must be one of: en, fr, es, ja."
    }
    foreach ($name in @("systemLanguage", "keyboardLayout", "keyboardModel", "timezone")) {
        $value = [string](Assert-LibertixPlanProperty -Object $locale -Name $name -Path "locale.$name")
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "Installation plan field locale.$name cannot be empty."
        }
    }
    foreach ($name in @("keyboardLayout", "keyboardModel")) {
        if ([string]$locale.$name -notmatch '^[a-z0-9_-]+$') {
            throw "Installation plan field locale.$name is not a valid XKB name."
        }
    }
    $keyboardVariant = if (Test-LibertixPlanProperty -Object $locale -Name "keyboardVariant") {
        [string]$locale.keyboardVariant
    } else {
        ""
    }
    if ($keyboardVariant -notmatch '^[a-z0-9_-]*$') {
        throw "Installation plan field locale.keyboardVariant is not a valid XKB variant name."
    }

    $account = Assert-LibertixPlanProperty -Object $Plan -Name "account" -Path "account"
    $username = [string](Assert-LibertixPlanProperty -Object $account -Name "username" -Path "account.username")
    $passwordHash = [string](Assert-LibertixPlanProperty -Object $account -Name "passwordHash" -Path "account.passwordHash")
    $computerName = [string](Assert-LibertixPlanProperty -Object $account -Name "computerName" -Path "account.computerName")
    if ($username -notmatch '^[a-z](?:[a-z0-9-]{0,30}[a-z0-9])?$') {
        throw "Installation plan account.username is invalid."
    }
    if ($passwordHash -notmatch '^\$6\$[^\r\n\t]+$') {
        throw "Installation plan account.passwordHash must use SHA-512 crypt."
    }
    if ([string]::IsNullOrWhiteSpace($computerName) -or $computerName.Length -gt 63) {
        throw "Installation plan account.computerName must contain between 1 and 63 characters."
    }

    $disk = Assert-LibertixPlanProperty -Object $Plan -Name "disk" -Path "disk"
    $diskNumber = Assert-LibertixPlanProperty -Object $disk -Name "number" -Path "disk.number"
    [int]$parsedDiskNumber = -1
    if (-not [int]::TryParse([string]$diskNumber, [ref]$parsedDiskNumber) -or $parsedDiskNumber -lt 0) {
        throw "Installation plan disk.number cannot be negative."
    }
    foreach ($name in @("uniqueId", "systemDrive")) {
        $value = [string](Assert-LibertixPlanProperty -Object $disk -Name $name -Path "disk.$name")
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "Installation plan field disk.$name cannot be empty."
        }
    }
    if ([string]$disk.systemDrive -notmatch '^[A-Z]:$') {
        throw "Installation plan disk.systemDrive must be an uppercase Windows drive such as C:."
    }
    Assert-LibertixPositiveInteger `
        -Value (Assert-LibertixPlanProperty -Object $disk -Name "sizeBytes" -Path "disk.sizeBytes") `
        -Path "disk.sizeBytes"
    Assert-LibertixPositiveInteger `
        -Value (Assert-LibertixPlanProperty -Object $disk -Name "logicalSectorSizeBytes" -Path "disk.logicalSectorSizeBytes") `
        -Path "disk.logicalSectorSizeBytes"

    $partitionStyle = [string](Assert-LibertixPlanProperty -Object $disk -Name "partitionStyle" -Path "disk.partitionStyle")
    $expectedStyle = if ($firmware -eq "bios") { "MBR" } else { "GPT" }
    if ($partitionStyle -ne $expectedStyle) {
        throw "Installation plan firmware '$firmware' requires partitionStyle '$expectedStyle'."
    }

    foreach ($name in @("windows", "boot", "recovery")) {
        $partition = Assert-LibertixPlanProperty -Object $disk -Name $name -Path "disk.$name"
        Assert-LibertixPartitionIdentity -Partition $partition -Path "disk.$name"
    }

    $installer = Assert-LibertixPlanProperty -Object $disk -Name "installer" -Path "disk.installer"
    $installerNumber = Assert-LibertixPlanProperty -Object $installer -Name "number" -Path "disk.installer.number"
    $installerOffset = Assert-LibertixPlanProperty -Object $installer -Name "offsetBytes" -Path "disk.installer.offsetBytes"
    if (($null -eq $installerNumber) -ne ($null -eq $installerOffset)) {
        throw "Installation plan installer number and offsetBytes must both be set or both be null."
    }
    if ($null -ne $installerNumber) {
        Assert-LibertixPositiveInteger -Value $installerNumber -Path "disk.installer.number"
        Assert-LibertixPositiveInteger -Value $installerOffset -Path "disk.installer.offsetBytes"
    }
    $finalSize = Assert-LibertixPlanProperty -Object $installer -Name "finalSizeBytes" -Path "disk.installer.finalSizeBytes"
    $stagingSize = Assert-LibertixPlanProperty -Object $installer -Name "stagingSizeBytes" -Path "disk.installer.stagingSizeBytes"
    Assert-LibertixPositiveInteger -Value $finalSize -Path "disk.installer.finalSizeBytes"
    Assert-LibertixPositiveInteger -Value $stagingSize -Path "disk.installer.stagingSizeBytes"
    if (
        [int64]$finalSize % $script:BytesPerGiB -ne 0 -or
        [int64]$stagingSize % $script:BytesPerGiB -ne 0
    ) {
        throw "Installation plan installer sizes must be whole numbers of GiB."
    }
    [int64]$finalSizeGiB = [int64]$finalSize / $script:BytesPerGiB
    if ($finalSizeGiB -lt $script:MinimumFinalSizeGiB) {
        throw "Installation plan finalSizeBytes must be at least $($script:MinimumFinalSizeGiB) GiB."
    }
    [int64]$expectedStagingSizeGiB = if ($finalSizeGiB -gt $script:MaximumDirectFat32SizeGiB) {
        $script:LargeInstallationStagingSizeGiB
    } else {
        $finalSizeGiB
    }
    if ([int64]$stagingSize -ne $expectedStagingSizeGiB * $script:BytesPerGiB) {
        throw "Installation plan stagingSizeBytes does not match the shared FAT32 staging policy."
    }

    $features = Assert-LibertixPlanProperty -Object $Plan -Name "features" -Path "features"
    foreach ($name in @("shareWindowsFilesInLinux", "shareLinuxFilesInWindows")) {
        $featureValue = Assert-LibertixPlanProperty -Object $features -Name $name -Path "features.$name"
        if ($featureValue -isnot [bool]) {
            throw "Installation plan field features.$name must be a boolean."
        }
    }
    $profilesBase64 = [string](Assert-LibertixPlanProperty `
        -Object $features `
        -Name "windowsProfilesJsonBase64" `
        -Path "features.windowsProfilesJsonBase64")
    try {
        $decodedProfiles = [Convert]::FromBase64String($profilesBase64)
    } catch {
        throw "Installation plan features.windowsProfilesJsonBase64 must be valid Base64."
    }
    if ($decodedProfiles.Length -eq 0) {
        throw "Installation plan features.windowsProfilesJsonBase64 must not decode to an empty value."
    }

    $runtime = Assert-LibertixPlanProperty -Object $Plan -Name "runtime" -Path "runtime"
    $lowMemoryMode = Assert-LibertixPlanProperty -Object $runtime -Name "lowMemoryMode" -Path "runtime.lowMemoryMode"
    if ($lowMemoryMode -isnot [bool]) {
        throw "Installation plan field runtime.lowMemoryMode must be a boolean."
    }
    $bootStrategy = [string](Assert-LibertixPlanProperty -Object $runtime -Name "bootStrategy" -Path "runtime.bootStrategy")
    $allowedStrategies = if ($firmware -eq "bios") {
        @("bios-grub4dos")
    } else {
        @("uefi-boot-next", "uefi-firmware-boot-order")
    }
    if ($bootStrategy -notin $allowedStrategies) {
        throw "Installation plan bootStrategy '$bootStrategy' is incompatible with firmware '$firmware'."
    }

    $recoveryRoot = Assert-LibertixPlanProperty -Object $runtime -Name "recoveryRootWindows" -Path "runtime.recoveryRootWindows"
    $recoveryRunId = Assert-LibertixPlanProperty -Object $runtime -Name "recoveryRunId" -Path "runtime.recoveryRunId"
    $hasRecoveryRoot = $null -ne $recoveryRoot
    $hasRecoveryRunId = $null -ne $recoveryRunId
    if ($hasRecoveryRoot -ne $hasRecoveryRunId) {
        throw "Installation plan recoveryRootWindows and recoveryRunId must both be set or both be null."
    }
    if ($hasRecoveryRoot -and [string]::IsNullOrWhiteSpace([string]$recoveryRoot)) {
        throw "Installation plan recoveryRootWindows cannot be empty."
    }
    if ($hasRecoveryRunId -and [string]$recoveryRunId -notmatch '^[0-9a-f]{32}$') {
        throw "Installation plan recoveryRunId must contain 32 lowercase hexadecimal characters."
    }

    if (Test-LibertixPlanProperty -Object $Plan -Name "development") {
        $development = $Plan.development
        $enableSsh = Assert-LibertixPlanProperty `
            -Object $development `
            -Name "enableSsh" `
            -Path "development.enableSsh"
        if ($enableSsh -isnot [bool] -or -not $enableSsh) {
            throw "Installation plan development.enableSsh must be true."
        }
        $staticAddress = [string](Assert-LibertixPlanProperty `
            -Object $development `
            -Name "staticIpv4Address" `
            -Path "development.staticIpv4Address")
        [System.Net.IPAddress]$parsedAddress = $null
        if (
            -not [System.Net.IPAddress]::TryParse($staticAddress, [ref]$parsedAddress) -or
            $parsedAddress.AddressFamily -ne
                [System.Net.Sockets.AddressFamily]::InterNetwork
        ) {
            throw "Installation plan development.staticIpv4Address must be IPv4."
        }
        $octets = $parsedAddress.GetAddressBytes()
        if (
            $octets[0] -ne 192 -or $octets[1] -ne 168 -or $octets[2] -ne 1 -or
            $octets[3] -le 1 -or $octets[3] -ge 255
        ) {
            throw "Installation plan development.staticIpv4Address must be usable in 192.168.1.0/24."
        }
        $prefixLength = Assert-LibertixPlanProperty `
            -Object $development `
            -Name "staticIpv4PrefixLength" `
            -Path "development.staticIpv4PrefixLength"
        if ([int]$prefixLength -ne 24) {
            throw "Installation plan development.staticIpv4PrefixLength must be 24."
        }
        $gateway = [string](Assert-LibertixPlanProperty `
            -Object $development `
            -Name "staticIpv4Gateway" `
            -Path "development.staticIpv4Gateway")
        if ($gateway -ne "192.168.1.1") {
            throw "Installation plan development.staticIpv4Gateway must be 192.168.1.1."
        }
        $dnsServers = @(Assert-LibertixPlanProperty `
            -Object $development `
            -Name "dnsServers" `
            -Path "development.dnsServers")
        if (
            $dnsServers.Count -ne 2 -or
            [string]$dnsServers[0] -ne "8.8.8.8" -or
            [string]$dnsServers[1] -ne "1.1.1.1"
        ) {
            throw "Installation plan development.dnsServers must contain 8.8.8.8 then 1.1.1.1."
        }
    }

    return $Plan
}

function Read-LibertixInstallationPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Installation plan file does not exist: $Path"
    }

    try {
        $plan = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Installation plan is not valid JSON: $($_.Exception.Message)"
    }

    return Assert-LibertixInstallationPlan -Plan $plan
}

function Write-LibertixInstallationPlanAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Plan
    )

    # Validate before creating the temporary file so an invalid in-memory
    # mutation can never replace the last known-good plan.
    $null = Assert-LibertixInstallationPlan -Plan $Plan
    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    if ([string]::IsNullOrWhiteSpace($directory)) {
        throw "Installation plan path has no parent directory."
    }

    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporaryPath = Join-Path `
        $directory `
        ".$([IO.Path]::GetFileName($fullPath)).$([Guid]::NewGuid().ToString('N')).tmp"
    $backupPath = Join-Path `
        $directory `
        ".$([IO.Path]::GetFileName($fullPath)).$([Guid]::NewGuid().ToString('N')).bak"
    try {
        $json = $Plan | ConvertTo-Json -Depth 12
        $encoding = New-Object Text.UTF8Encoding($false)
        $stream = New-Object IO.FileStream(
            $temporaryPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough
        )
        try {
            $writer = New-Object IO.StreamWriter($stream, $encoding)
            try {
                $writer.Write($json)
                $writer.Write("`n")
                $writer.Flush()
                $stream.Flush($true)
            } finally {
                $writer.Dispose()
            }
        } finally {
            $stream.Dispose()
        }

        if ([IO.File]::Exists($fullPath)) {
            # Windows PowerShell 5.1 can bind a null backup path incorrectly
            # on .NET Framework. A same-directory backup keeps Replace atomic.
            [IO.File]::Replace($temporaryPath, $fullPath, $backupPath)
        } else {
            [IO.File]::Move($temporaryPath, $fullPath)
        }
    } finally {
        if ([IO.File]::Exists($temporaryPath)) {
            [IO.File]::Delete($temporaryPath)
        }
        if ([IO.File]::Exists($backupPath)) {
            [IO.File]::Delete($backupPath)
        }
    }
}

Export-ModuleMember -Function `
    Assert-LibertixInstallationPlan, `
    Read-LibertixInstallationPlan, `
    Write-LibertixInstallationPlanAtomic
