Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot "Libertix.AtomicFile.psm1") -Force -ErrorAction Stop

$policyModulePath = Join-Path $PSScriptRoot "Libertix.InstallationPolicy.psm1"
Import-Module -Name $policyModulePath -Force -ErrorAction Stop
$script:InstallationPolicy = Get-LibertixInstallationPolicy
$script:BytesPerGiB = 1GB
$script:InstallationPlanPropertySets = [ordered]@{
    root = @(
        "schemaVersion", "planId", "createdAtUtc", "firmware", "distribution",
        "locale", "account", "disk", "features", "runtime", "development"
    )
    distribution = @(
        "id", "name", "osReleaseId", "grubDisplayName", "grubIcon",
        "secureBootMicrosoftAuthorities",
        "installerIsoFileName", "installerIsoUrl", "installerIsoWindowsPath",
        "installerIsoSha256", "liveIsoUrl", "liveIsoSha256"
    )
    locale = @(
        "languageCode", "systemLanguage", "keyboardLayout", "keyboardVariant",
        "keyboardModel", "timezone"
    )
    account = @("username", "passwordHashWindowsPath", "computerName")
    disk = @(
        "number", "uniqueId", "partitionTableId", "sizeBytes", "logicalSectorSizeBytes", "partitionStyle",
        "systemDrive", "windows", "boot", "recovery", "installer"
    )
    partition = @("number", "offsetBytes", "sizeBytes")
    installer = @(
        "number", "offsetBytes", "finalOffsetBytes", "resizeMode",
        "finalSizeBytes", "stagingSizeBytes"
    )
    features = @(
        "shareWindowsFilesInLinux", "shareLinuxFilesInWindows",
        "windowsProfilesJsonBase64"
    )
    runtime = @(
        "windowsBitLockerState",
        "lowMemoryMode", "bootStrategy", "secureBootEnabled", "trustedMicrosoftUefiAuthorities",
        "recoveryRootWindows", "recoveryRunId"
    )
    development = @(
        "enableSsh", "staticIpv4Address", "staticIpv4PrefixLength",
        "staticIpv4Gateway", "dnsServers"
    )
}

function Assert-LibertixExactPlanProperties {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$PropertySet
    )

    $allowed = @($script:InstallationPlanPropertySets[$PropertySet])
    if ($allowed.Count -eq 0) {
        throw "Unknown installation plan property set: $PropertySet."
    }
    $propertyNames = if ($Object -is [Collections.IDictionary]) {
        @($Object.Keys)
    } else {
        @($Object.PSObject.Properties.Name)
    }
    $unexpected = @($propertyNames | Where-Object { $_ -notin $allowed })
    if ($unexpected.Count -gt 0) {
        throw "Installation plan $Path contains unsupported field '$($unexpected[0])'."
    }
}

function Test-LibertixPlanProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) {
        return $false
    }
    if ($Object -is [Collections.IDictionary]) {
        return $Object.Contains($Name)
    }
    return $Object.PSObject.Properties.Name -contains $Name
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

function Assert-LibertixMicrosoftUefiAuthorities {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AllowEmpty
    )

    if ($null -eq $Value) {
        throw "Installation plan field $Path must be an array."
    }
    $values = @($Value)
    if (-not $AllowEmpty -and $values.Count -eq 0) {
        throw "Installation plan field $Path must contain at least one authority."
    }
    $normalized = @($values | ForEach-Object { [string]$_ })
    if (@($normalized | Where-Object { $_ -notin @("2011", "2023") }).Count -gt 0) {
        throw "Installation plan field $Path may contain only 2011 and 2023."
    }
    if (@($normalized | Select-Object -Unique).Count -ne $normalized.Count) {
        throw "Installation plan field $Path must not contain duplicates."
    }
    return $normalized
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
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int64]$LogicalSectorSizeBytes
    )

    Assert-LibertixExactPlanProperties `
        -Object $Partition `
        -Path $Path `
        -PropertySet "partition"

    $number = Assert-LibertixPlanProperty -Object $Partition -Name "number" -Path "$Path.number"
    $offset = Assert-LibertixPlanProperty -Object $Partition -Name "offsetBytes" -Path "$Path.offsetBytes"
    $size = Assert-LibertixPlanProperty -Object $Partition -Name "sizeBytes" -Path "$Path.sizeBytes"

    Assert-LibertixPositiveInteger -Value $number -Path "$Path.number"
    Assert-LibertixPositiveInteger -Value $offset -Path "$Path.offsetBytes"
    Assert-LibertixPositiveInteger -Value $size -Path "$Path.sizeBytes"
    if (
        [int64]$offset % $LogicalSectorSizeBytes -ne 0 -or
        [int64]$size % $LogicalSectorSizeBytes -ne 0
    ) {
        throw "Installation plan $Path geometry must align to disk.logicalSectorSizeBytes."
    }
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

function ConvertTo-LibertixIpv4Integer {
    param([Parameter(Mandatory = $true)][System.Net.IPAddress]$Address)

    $octets = $Address.GetAddressBytes()
    return [uint64](
        ([uint64]$octets[0] * 16777216) +
        ([uint64]$octets[1] * 65536) +
        ([uint64]$octets[2] * 256) +
        [uint64]$octets[3]
    )
}

function Test-LibertixIpv4ConfigurationAddress {
    param([Parameter(Mandatory = $true)][System.Net.IPAddress]$Address)

    $octets = $Address.GetAddressBytes()
    return (
        $octets[0] -ne 0 -and
        $octets[0] -ne 127 -and
        -not ($octets[0] -eq 169 -and $octets[1] -eq 254) -and
        $octets[0] -lt 224
    )
}

function Assert-LibertixDevelopmentNetwork {
    param([Parameter(Mandatory = $true)][object]$Development)

    Assert-LibertixExactPlanProperties `
        -Object $Development `
        -Path "development" `
        -PropertySet "development"

    $staticAddress = [string](Assert-LibertixPlanProperty `
        -Object $Development `
        -Name "staticIpv4Address" `
        -Path "development.staticIpv4Address")
    $gateway = [string](Assert-LibertixPlanProperty `
        -Object $Development `
        -Name "staticIpv4Gateway" `
        -Path "development.staticIpv4Gateway")
    [System.Net.IPAddress]$parsedAddress = $null
    [System.Net.IPAddress]$parsedGateway = $null
    if (
        -not [System.Net.IPAddress]::TryParse($staticAddress, [ref]$parsedAddress) -or
        $parsedAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork
    ) {
        throw "Installation plan development.staticIpv4Address must be IPv4."
    }
    if (-not (Test-LibertixIpv4ConfigurationAddress -Address $parsedAddress)) {
        throw "Installation plan development.staticIpv4Address is not a configurable unicast address."
    }
    if (
        -not [System.Net.IPAddress]::TryParse($gateway, [ref]$parsedGateway) -or
        $parsedGateway.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork
    ) {
        throw "Installation plan development.staticIpv4Gateway must be IPv4."
    }
    if (-not (Test-LibertixIpv4ConfigurationAddress -Address $parsedGateway)) {
        throw "Installation plan development.staticIpv4Gateway is not a configurable unicast address."
    }

    $prefixLength = [int](Assert-LibertixPlanProperty `
        -Object $Development `
        -Name "staticIpv4PrefixLength" `
        -Path "development.staticIpv4PrefixLength")
    if ($prefixLength -lt 1 -or $prefixLength -gt 30) {
        throw "Installation plan development.staticIpv4PrefixLength must be between 1 and 30."
    }

    [uint64]$hostCount = [math]::Pow(2, 32 - $prefixLength)
    [uint64]$addressValue = ConvertTo-LibertixIpv4Integer -Address $parsedAddress
    [uint64]$gatewayValue = ConvertTo-LibertixIpv4Integer -Address $parsedGateway
    [uint64]$network = [math]::Floor($addressValue / $hostCount) * $hostCount
    [uint64]$broadcast = $network + $hostCount - 1
    if ($addressValue -eq $network -or $addressValue -eq $broadcast) {
        throw "Installation plan development.staticIpv4Address must be a usable host address."
    }
    if (
        $gatewayValue -le $network -or $gatewayValue -ge $broadcast -or
        $gatewayValue -eq $addressValue
    ) {
        throw "Installation plan development.staticIpv4Gateway must be a different usable address in the same subnet."
    }

    $dnsServers = @(Assert-LibertixPlanProperty `
        -Object $Development `
        -Name "dnsServers" `
        -Path "development.dnsServers")
    if ($dnsServers.Count -lt 1) {
        throw "Installation plan development.dnsServers must contain at least one IPv4 address."
    }
    $uniqueDns = @{}
    foreach ($dnsServer in $dnsServers) {
        [System.Net.IPAddress]$parsedDns = $null
        if (
            -not [System.Net.IPAddress]::TryParse([string]$dnsServer, [ref]$parsedDns) -or
            $parsedDns.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork
        ) {
            throw "Installation plan development.dnsServers must contain only IPv4 addresses."
        }
        if ($uniqueDns.ContainsKey($parsedDns.ToString())) {
            throw "Installation plan development.dnsServers must not contain duplicates."
        }
        $uniqueDns[$parsedDns.ToString()] = $true
    }
}

function Assert-LibertixInstallationPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Plan)

    Assert-LibertixExactPlanProperties -Object $Plan -Path "root" -PropertySet "root"

    $schemaVersion = Assert-LibertixPlanProperty -Object $Plan -Name "schemaVersion" -Path "schemaVersion"
    if ([int]$schemaVersion -ne 3) {
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
    Assert-LibertixExactPlanProperties `
        -Object $distribution `
        -Path "distribution" `
        -PropertySet "distribution"
    foreach ($name in @(
        "id", "name", "osReleaseId", "grubDisplayName", "grubIcon",
        "installerIsoFileName", "installerIsoUrl", "installerIsoWindowsPath", "liveIsoUrl"
    )) {
        $value = [string](Assert-LibertixPlanProperty `
            -Object $distribution `
            -Name $name `
            -Path "distribution.$name")
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "Installation plan field distribution.$name cannot be empty."
        }
    }
    foreach ($name in @("id", "osReleaseId", "grubIcon")) {
        if ([string]$distribution.$name -notmatch '^[a-z0-9](?:[a-z0-9._-]{0,62}[a-z0-9])?$') {
            throw "Installation plan field distribution.$name must be a safe lowercase identifier."
        }
    }
    if ([string]$distribution.grubDisplayName -notmatch '^[A-Za-z0-9][A-Za-z0-9 ._()+-]{0,79}$') {
        throw "Installation plan field distribution.grubDisplayName contains unsupported GRUB label characters."
    }
    $null = Assert-LibertixMicrosoftUefiAuthorities `
        -Value (Assert-LibertixPlanProperty `
            -Object $distribution `
            -Name "secureBootMicrosoftAuthorities" `
            -Path "distribution.secureBootMicrosoftAuthorities") `
        -Path "distribution.secureBootMicrosoftAuthorities"
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
    Assert-LibertixExactPlanProperties -Object $locale -Path "locale" -PropertySet "locale"
    $languageCode = [string](Assert-LibertixPlanProperty -Object $locale -Name "languageCode" -Path "locale.languageCode")
    if ($languageCode -notin @("en", "fr", "es", "ko")) {
        throw "Installation plan field locale.languageCode must be one of: en, fr, es, ko."
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
    if ([string]$locale.timezone -notmatch '^[A-Za-z0-9._+-]+(?:/[A-Za-z0-9._+-]+)+$') {
        throw "Installation plan field locale.timezone is not a safe IANA timezone name."
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
    Assert-LibertixExactPlanProperties -Object $account -Path "account" -PropertySet "account"
    $username = [string](Assert-LibertixPlanProperty -Object $account -Name "username" -Path "account.username")
    $passwordHashWindowsPath = [string](Assert-LibertixPlanProperty -Object $account -Name "passwordHashWindowsPath" -Path "account.passwordHashWindowsPath")
    $computerName = [string](Assert-LibertixPlanProperty -Object $account -Name "computerName" -Path "account.computerName")
    if ($username -notmatch '^[a-z](?:[a-z0-9-]{0,30}[a-z0-9])?$') {
        throw "Installation plan account.username is invalid."
    }
    if (@($script:InstallationPolicy.account.reservedUsernames) -icontains $username) {
        throw "Installation plan account.username is reserved by the operating system."
    }
    if ($passwordHashWindowsPath -notmatch '^[A-Za-z]:\\' -or $passwordHashWindowsPath -match '(^|\\)\.\.(\\|$)') {
        throw "Installation plan account.passwordHashWindowsPath must be an absolute safe Windows path."
    }
    if ($computerName -notmatch '^[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$') {
        throw "Installation plan account.computerName is not a valid Linux hostname."
    }

    $disk = Assert-LibertixPlanProperty -Object $Plan -Name "disk" -Path "disk"
    Assert-LibertixExactPlanProperties -Object $disk -Path "disk" -PropertySet "disk"
    $diskNumber = Assert-LibertixPlanProperty -Object $disk -Name "number" -Path "disk.number"
    [int]$parsedDiskNumber = -1
    if (-not [int]::TryParse([string]$diskNumber, [ref]$parsedDiskNumber) -or $parsedDiskNumber -lt 0) {
        throw "Installation plan disk.number cannot be negative."
    }
    foreach ($name in @("uniqueId", "partitionTableId", "systemDrive")) {
        $value = [string](Assert-LibertixPlanProperty -Object $disk -Name $name -Path "disk.$name")
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "Installation plan field disk.$name cannot be empty."
        }
    }
    if ([string]$disk.systemDrive -notmatch '^[A-Z]:$') {
        throw "Installation plan disk.systemDrive must be an uppercase Windows drive such as C:."
    }
    $diskSize = Assert-LibertixPlanProperty -Object $disk -Name "sizeBytes" -Path "disk.sizeBytes"
    $logicalSectorSize = Assert-LibertixPlanProperty `
        -Object $disk `
        -Name "logicalSectorSizeBytes" `
        -Path "disk.logicalSectorSizeBytes"
    Assert-LibertixPositiveInteger -Value $diskSize -Path "disk.sizeBytes"
    Assert-LibertixPositiveInteger -Value $logicalSectorSize -Path "disk.logicalSectorSizeBytes"
    if ([int64]$logicalSectorSize -notin @(512, 4096)) {
        throw "Installation plan disk.logicalSectorSizeBytes must be either 512 or 4096."
    }
    if ([int64]$diskSize % [int64]$logicalSectorSize -ne 0) {
        throw "Installation plan disk.sizeBytes must align to disk.logicalSectorSizeBytes."
    }

    $partitionStyle = [string](Assert-LibertixPlanProperty -Object $disk -Name "partitionStyle" -Path "disk.partitionStyle")
    $expectedStyle = if ($firmware -eq "bios") { "MBR" } else { "GPT" }
    if ($partitionStyle -ne $expectedStyle) {
        throw "Installation plan firmware '$firmware' requires partitionStyle '$expectedStyle'."
    }
    $partitionTablePattern = if ($firmware -eq "bios") {
        '^mbr:[0-9a-f]{8}$'
    } else {
        '^gpt:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    }
    if ([string]$disk.partitionTableId -notmatch $partitionTablePattern) {
        throw "Installation plan disk.partitionTableId is not canonical for firmware '$firmware'."
    }

    foreach ($name in @("windows", "boot", "recovery")) {
        $partition = Assert-LibertixPlanProperty -Object $disk -Name $name -Path "disk.$name"
        Assert-LibertixPartitionIdentity `
            -Partition $partition `
            -Path "disk.$name" `
            -LogicalSectorSizeBytes ([int64]$logicalSectorSize)
    }

    $fixedPartitionNames = @("windows", "boot", "recovery")
    $fixedExtents = @{}
    foreach ($name in $fixedPartitionNames) {
        $partition = $disk.$name
        [int64]$partitionOffset = [int64]$partition.offsetBytes
        [int64]$partitionSize = [int64]$partition.sizeBytes
        if (
            $partitionSize -gt [int64]$diskSize -or
            $partitionOffset -gt [int64]$diskSize - $partitionSize
        ) {
            throw "Installation plan disk.$name must fit within disk.sizeBytes."
        }
        $fixedExtents[$name] = @(
            $partitionOffset,
            [int64]($partitionOffset + $partitionSize)
        )
    }
    foreach ($pair in @(
        @("windows", "boot"),
        @("windows", "recovery"),
        @("boot", "recovery")
    )) {
        $left = $fixedExtents[$pair[0]]
        $right = $fixedExtents[$pair[1]]
        if ($left[0] -lt $right[1] -and $right[0] -lt $left[1]) {
            throw "Installation plan disk.$($pair[0]) and disk.$($pair[1]) overlap."
        }
    }
    [int64]$windowsEnd = $fixedExtents["windows"][1]
    [int64]$recoveryOffset = $fixedExtents["recovery"][0]
    if ($windowsEnd -gt $recoveryOffset) {
        throw "Installation plan disk.recovery must follow the original Windows partition."
    }

    $installer = Assert-LibertixPlanProperty -Object $disk -Name "installer" -Path "disk.installer"
    Assert-LibertixExactPlanProperties `
        -Object $installer `
        -Path "disk.installer" `
        -PropertySet "installer"
    $installerNumber = Assert-LibertixPlanProperty -Object $installer -Name "number" -Path "disk.installer.number"
    $installerOffset = Assert-LibertixPlanProperty -Object $installer -Name "offsetBytes" -Path "disk.installer.offsetBytes"
    if (($null -eq $installerNumber) -ne ($null -eq $installerOffset)) {
        throw "Installation plan installer number and offsetBytes must both be set or both be null."
    }
    if ($null -ne $installerNumber) {
        Assert-LibertixPositiveInteger -Value $installerNumber -Path "disk.installer.number"
        Assert-LibertixPositiveInteger -Value $installerOffset -Path "disk.installer.offsetBytes"
        if ([int64]$installerOffset % [int64]$logicalSectorSize -ne 0) {
            throw "Installation plan disk.installer.offsetBytes must align to disk.logicalSectorSizeBytes."
        }
    }
    $finalSize = Assert-LibertixPlanProperty -Object $installer -Name "finalSizeBytes" -Path "disk.installer.finalSizeBytes"
    $stagingSize = Assert-LibertixPlanProperty -Object $installer -Name "stagingSizeBytes" -Path "disk.installer.stagingSizeBytes"
    $finalOffset = Assert-LibertixPlanProperty -Object $installer -Name "finalOffsetBytes" -Path "disk.installer.finalOffsetBytes"
    $resizeMode = Assert-LibertixPlanProperty -Object $installer -Name "resizeMode" -Path "disk.installer.resizeMode"
    Assert-LibertixPositiveInteger -Value $finalSize -Path "disk.installer.finalSizeBytes"
    Assert-LibertixPositiveInteger -Value $stagingSize -Path "disk.installer.stagingSizeBytes"
    Assert-LibertixPositiveInteger -Value $finalOffset -Path "disk.installer.finalOffsetBytes"
    if ($resizeMode -notin @("windows-online", "live-offline")) {
        throw "Installation plan resizeMode must be windows-online or live-offline."
    }
    if (
        [int64]$finalSize % $script:BytesPerGiB -ne 0 -or
        [int64]$stagingSize % $script:BytesPerGiB -ne 0
    ) {
        throw "Installation plan installer sizes must be whole numbers of GiB."
    }
    [int64]$finalSizeGiB = [int64]$finalSize / $script:BytesPerGiB
    if ($finalSizeGiB -lt [int]$script:InstallationPolicy.storage.minimumFinalSizeGiB) {
        throw "Installation plan finalSizeBytes must be at least $($script:InstallationPolicy.storage.minimumFinalSizeGiB) GiB."
    }
    [int64]$expectedStagingSizeGiB = [Math]::Min(
        $finalSizeGiB,
        [int]$script:InstallationPolicy.storage.stagingSizeGiB
    )
    if ([int64]$stagingSize -ne $expectedStagingSizeGiB * $script:BytesPerGiB) {
        throw "Installation plan stagingSizeBytes does not match the shared FAT32 staging policy."
    }
    [int64]$alignmentBytes =
        [int64]$script:InstallationPolicy.storage.partitionAlignmentBytes
    [int64]$alignmentPadding = $windowsEnd % $alignmentBytes
    if ([int64]$finalSize -gt $windowsEnd - $alignmentPadding) {
        throw "Installation plan finalSizeBytes exceeds the original Windows extent."
    }
    [int64]$expectedFinalOffset = `
        $windowsEnd - $alignmentPadding - [int64]$finalSize
    if ([int64]$finalOffset -ne $expectedFinalOffset) {
        throw "Installation plan finalOffsetBytes does not match the aligned final geometry."
    }
    if (
        [int64]$finalSize -gt $recoveryOffset -or
        [int64]$finalOffset -gt $recoveryOffset - [int64]$finalSize
    ) {
        throw "Installation plan final installer extent would overlap Recovery."
    }
    if ($null -ne $installerOffset) {
        [int64]$expectedObservedOffset = if ($resizeMode -eq "live-offline") {
            $windowsEnd - $alignmentPadding - [int64]$stagingSize
        } else {
            $expectedFinalOffset
        }
        [int64]$primaryMbrOffset = $expectedObservedOffset - $alignmentBytes
        $offsetMatches = (
            [int64]$installerOffset -eq $expectedObservedOffset -or
            ($partitionStyle -eq "MBR" -and [int64]$installerOffset -eq $primaryMbrOffset)
        )
        if (-not $offsetMatches) {
            throw "Installation plan installer offset does not match the selected Windows shrink geometry."
        }
    }

    $features = Assert-LibertixPlanProperty -Object $Plan -Name "features" -Path "features"
    Assert-LibertixExactPlanProperties `
        -Object $features `
        -Path "features" `
        -PropertySet "features"
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
    Assert-LibertixExactPlanProperties `
        -Object $runtime `
        -Path "runtime" `
        -PropertySet "runtime"
    $windowsBitLockerState = [string](Assert-LibertixPlanProperty `
        -Object $runtime `
        -Name "windowsBitLockerState" `
        -Path "runtime.windowsBitLockerState")
    $safeBitLockerState = $windowsBitLockerState -cin @(
        "FullyDecrypted",
        "NotEncryptable"
    )
    $pendingUefiDecryption = (
        $firmware -eq "uefi" -and
        $windowsBitLockerState -ceq "EncryptedOrProtected"
    )
    if (-not $safeBitLockerState -and -not $pendingUefiDecryption) {
        throw "Installation plan field runtime.windowsBitLockerState is invalid for the selected firmware."
    }
    $lowMemoryMode = Assert-LibertixPlanProperty -Object $runtime -Name "lowMemoryMode" -Path "runtime.lowMemoryMode"
    if ($lowMemoryMode -isnot [bool]) {
        throw "Installation plan field runtime.lowMemoryMode must be a boolean."
    }
    $bootStrategy = [string](Assert-LibertixPlanProperty -Object $runtime -Name "bootStrategy" -Path "runtime.bootStrategy")
    $secureBootEnabled = Assert-LibertixPlanProperty `
        -Object $runtime `
        -Name "secureBootEnabled" `
        -Path "runtime.secureBootEnabled"
    if ($secureBootEnabled -isnot [bool]) {
        throw "Installation plan field runtime.secureBootEnabled must be a boolean."
    }
    $allowedStrategies = if ($firmware -eq "bios") {
        @("bios-grub4dos")
    } else {
        @("uefi-boot-next", "uefi-firmware-boot-order")
    }
    if ($bootStrategy -notin $allowedStrategies) {
        throw "Installation plan bootStrategy '$bootStrategy' is incompatible with firmware '$firmware'."
    }
    $trustedMicrosoftUefiAuthorities = @(Assert-LibertixMicrosoftUefiAuthorities `
        -Value (Assert-LibertixPlanProperty `
            -Object $runtime `
            -Name "trustedMicrosoftUefiAuthorities" `
            -Path "runtime.trustedMicrosoftUefiAuthorities") `
        -Path "runtime.trustedMicrosoftUefiAuthorities" `
        -AllowEmpty)
    if ($firmware -eq "bios" -and $trustedMicrosoftUefiAuthorities.Count -ne 0) {
        throw "A BIOS installation plan must not contain trusted Microsoft UEFI authorities."
    }
    if ($firmware -eq "bios" -and $secureBootEnabled) {
        throw "A BIOS installation plan must not enable Secure Boot."
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
    if (
        $hasRecoveryRoot -and
        (
            [string]$recoveryRoot -notmatch '^[A-Za-z]:\\' -or
            [string]$recoveryRoot -match '(^|\\)\.\.(\\|$)'
        )
    ) {
        throw "Installation plan runtime.recoveryRootWindows must be an absolute safe Windows path."
    }
    if ($hasRecoveryRunId -and [string]$recoveryRunId -notmatch '^[0-9a-f]{32}$') {
        throw "Installation plan recoveryRunId must contain 32 lowercase hexadecimal characters."
    }

    $windowsPaths = [ordered]@{
        "distribution.installerIsoWindowsPath" = [string]$distribution.installerIsoWindowsPath
        "account.passwordHashWindowsPath" = $passwordHashWindowsPath
    }
    if ($hasRecoveryRoot) {
        $windowsPaths["runtime.recoveryRootWindows"] = [string]$recoveryRoot
    }
    foreach ($entry in $windowsPaths.GetEnumerator()) {
        if ($entry.Value.Substring(0, 2).ToUpperInvariant() -ne ([string]$disk.systemDrive)) {
            throw "Installation plan $($entry.Key) must be located on disk.systemDrive."
        }
    }
    $expectedInstallerIsoPath = Join-Path `
        ([string]$disk.systemDrive) `
        "ProgramData\Libertix\Downloads\$([string]$Plan.planId)\$([string]$distribution.installerIsoFileName)"
    if (
        [IO.Path]::GetFullPath([string]$distribution.installerIsoWindowsPath) -ne
        [IO.Path]::GetFullPath($expectedInstallerIsoPath)
    ) {
        throw (
            "Installation plan distribution.installerIsoWindowsPath must use " +
            "the plan-owned ProgramData download directory."
        )
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
        Assert-LibertixDevelopmentNetwork -Development $development
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

        Publish-LibertixFileAtomic `
            -TemporaryPath $temporaryPath `
            -DestinationPath $fullPath `
            -BackupPath $backupPath
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
