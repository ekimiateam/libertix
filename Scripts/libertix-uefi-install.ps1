#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ConfigPath = "",
    [string]$InstallationPlanPath = "",
    [string]$ExecutionStatePath = "",
    [switch]$Force = $false,
    [switch]$Revert = $false,
    [switch]$RestoreWindowsSettings = $false,
    [string]$ExpectedRecoveryRunId = "",
    [string]$FilepoolBaseUrl = "",
    [string]$Aria2ExePath = "",
    [ValidateRange(0, 16)]
    [int]$Aria2Connections = 0,
    [ValidateSet("BootNext", "FirmwareBootOrder")]
    [string]$BootStrategy = "BootNext",
    [switch]$ReusePreparedInstaller = $false,
    [switch]$PreserveConfig = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$bootStrategyWasSpecified = $PSBoundParameters.ContainsKey("BootStrategy")

$policyModulePath = Join-Path $PSScriptRoot "modules\Libertix.InstallationPolicy.psm1"
if (-not (Test-Path -LiteralPath $policyModulePath -PathType Leaf)) {
    throw "Libertix PowerShell module is missing: $policyModulePath"
}
Import-Module -Name $policyModulePath -Force -ErrorAction Stop
$installationPolicy = Get-LibertixInstallationPolicy

$requiredModules = @(
    "Libertix.InstallationPlan.psm1",
    "Libertix.InstallationState.psm1",
    "Libertix.StorageGeometry.psm1",
    "Libertix.Process.psm1",
    "Libertix.Firmware.psm1",
    "Libertix.Download.psm1",
    "Libertix.TemporaryArtifacts.psm1",
    "Libertix.Transaction.psm1",
    "Libertix.Rollback.psm1",
    # Import this last so dot-sourced UEFI components see its exported command.
    "Libertix.AtomicFile.psm1"
)
foreach ($moduleName in $requiredModules) {
    $modulePath = Join-Path $PSScriptRoot "modules\$moduleName"
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Libertix PowerShell module is missing: $modulePath"
    }
    Import-Module -Name $modulePath -Force -ErrorAction Stop
}

if ($Aria2Connections -eq 0) {
    $Aria2Connections = [int]$installationPolicy.download.aria2MaximumConnections
}

# Dot-sourced components intentionally share this script's transaction scope.
# They define functions only; all execution still starts in the orchestrator
# below after configuration and the installation plan have been validated.
$requiredComponents = @(
    "Libertix.Uefi.Execution.ps1",
    "Libertix.Uefi.Firmware.ps1",
    "Libertix.Uefi.Storage.ps1",
    "Libertix.Uefi.Downloads.ps1",
    "Libertix.Uefi.Transaction.ps1",
    "Libertix.Uefi.Staging.ps1"
)
foreach ($componentName in $requiredComponents) {
    $componentPath = Join-Path $PSScriptRoot "uefi\$componentName"
    if (-not (Test-Path -LiteralPath $componentPath -PathType Leaf)) {
        throw "Libertix UEFI component is missing: $componentPath"
    }
    . $componentPath
}

if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
    try {
        $config = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($config.PSObject.Properties.Name -contains "InstallationPlanPath") {
            $InstallationPlanPath = [string]$config.InstallationPlanPath
        }
        if ($config.PSObject.Properties.Name -contains "ExecutionStatePath") {
            $ExecutionStatePath = [string]$config.ExecutionStatePath
        }
        $FilepoolBaseUrl = [string]$config.FilepoolBaseUrl
        $Aria2ExePath = [string]$config.Aria2ExePath
        $Aria2Connections = [int]$config.Aria2Connections
        if (-not $bootStrategyWasSpecified -and $config.PSObject.Properties.Name -contains "BootStrategy") {
            $BootStrategy = [string]$config.BootStrategy
        }
    } finally {
        if (-not $PreserveConfig) {
            Remove-Item -LiteralPath $ConfigPath -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($Aria2Connections -lt 1 -or $Aria2Connections -gt 16) {
    throw "Aria2Connections must be between 1 and 16."
}

$installationPlan = $null
$RecoveryRunId = ""
if (-not [string]::IsNullOrWhiteSpace($InstallationPlanPath)) {
    $installationPlan = Read-LibertixInstallationPlan -Path $InstallationPlanPath
    if ([string]$installationPlan.firmware -ne "uefi") {
        throw "The UEFI installer requires an installation plan with firmware='uefi'."
    }

    [int64]$finalSizeBytes = [int64]$installationPlan.disk.installer.finalSizeBytes
    if (($finalSizeBytes % 1GB) -ne 0) {
        throw "Installation plan finalSizeBytes must be an exact number of GiB."
    }
    $InstallerPartitionSizeGB = [int]($finalSizeBytes / 1GB)
    $RecoveryRoot = [string]$installationPlan.runtime.recoveryRootWindows
    $RecoveryRunId = [string]$installationPlan.runtime.recoveryRunId
    $LowMemoryMode = [bool]$installationPlan.runtime.lowMemoryMode
    $ShareWindowsFilesInLinux = [bool]$installationPlan.features.shareWindowsFilesInLinux
    if (-not $bootStrategyWasSpecified) {
        $BootStrategy = switch ([string]$installationPlan.runtime.bootStrategy) {
            "uefi-boot-next" { "BootNext" }
            "uefi-firmware-boot-order" { "FirmwareBootOrder" }
            default { throw "Unsupported plan boot strategy: $($installationPlan.runtime.bootStrategy)" }
        }
    }

    if ([string]::IsNullOrWhiteSpace($ExecutionStatePath)) {
        throw "ExecutionStatePath is required when InstallationPlanPath is supplied."
    }
    $executionState = Read-LibertixExecutionState -Path $ExecutionStatePath
    if ([string]$executionState.planId -ne [string]$installationPlan.planId) {
        throw "Installation plan and execution state planId values do not match."
    }
}

if (-not $Revert -and -not $RestoreWindowsSettings -and $null -eq $installationPlan) {
    throw "InstallationPlanPath is required for every UEFI preparation workflow."
}

$SystemDrive = if ($installationPlan) {
    [string]$installationPlan.disk.systemDrive
} else {
    [string]$env:SystemDrive
}
if ($SystemDrive -notmatch "^[A-Za-z]:$") {
    throw "Invalid Windows system drive: $SystemDrive"
}
$SystemDrive = $SystemDrive.ToUpperInvariant()
$SystemDriveLetter = $SystemDrive.TrimEnd(":")

# A rollback only consumes the transaction state stored on disk. It must remain
# available even when no download configuration is supplied by the caller.
if (-not $Revert -and -not $RestoreWindowsSettings) {
    $parsedFilepoolUri = $null
    if (
        [string]::IsNullOrWhiteSpace($FilepoolBaseUrl) -or
        -not [Uri]::TryCreate($FilepoolBaseUrl, [UriKind]::Absolute, [ref]$parsedFilepoolUri) -or
        $parsedFilepoolUri.Scheme -notin @("http", "https")
    ) {
        throw "FilepoolBaseUrl is required and must be an absolute HTTP(S) URL supplied by Libertix."
    }
    $FilepoolBaseUrl = $FilepoolBaseUrl.TrimEnd("/")
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12


# Download hashes and names are shared with the WPF path so an artifact update
# cannot silently reach only one firmware workflow.
$artifactCatalogPath = Join-Path $PSScriptRoot "config\Libertix.Artifacts.json"
$artifactCatalog = Get-Content -LiteralPath $artifactCatalogPath -Raw -ErrorAction Stop |
    ConvertFrom-Json -ErrorAction Stop
$Aria2ZipName = [string]$artifactCatalog.aria2.archiveFileName
$downloadUrls = $null
if (-not $Revert -and -not $RestoreWindowsSettings) {
    $downloadUrls = New-LibertixDownloadUrls `
        -FilepoolBaseUrl $FilepoolBaseUrl `
        -Aria2ZipName $Aria2ZipName
}
$InstallerIsoUrl = if ($installationPlan) { [string]$installationPlan.distribution.liveIsoUrl } else { "" }
$InstallerIsoName = "libertix-installer-uefi.iso"
$InstallerIsoSha256 = if ($installationPlan) { [string]$installationPlan.distribution.liveIsoSha256 } else { "" }
$DistributionIsoUrl = if ($installationPlan) { [string]$installationPlan.distribution.installerIsoUrl } else { "" }
$DistributionIsoPath = if ($installationPlan) { [string]$installationPlan.distribution.installerIsoWindowsPath } else { "" }
$DistributionIsoSha256 = if ($installationPlan) { [string]$installationPlan.distribution.installerIsoSha256 } else { "" }
$Aria2ZipUrl = if ($downloadUrls) { $downloadUrls.Aria2Zip } else { "" }
$Aria2ZipSha256 = [string]$artifactCatalog.aria2.archiveSha256
$Aria2ExeSha256 = [string]$artifactCatalog.aria2.executableSha256
$Aria2CacheDir = "$SystemDrive\LibertixTools\aria2"
$Aria2DownloadDir = "$SystemDrive\LibertixTools\downloads"
$LowMemoryIsoPath = "$SystemDrive\libertix-live.iso"

$InstallerLetter = Get-LibertixFreeDriveLetter
$EspLetter = Get-LibertixFreeDriveLetter -ExcludedLetters @($InstallerLetter)
$InstallerLabel = "LIBERTIXEFI"
$firmwareOwnerRunId = if ($RecoveryRunId -match '^[0-9a-f]{32}$') {
    $RecoveryRunId
} elseif ($ExpectedRecoveryRunId -match '^[0-9a-f]{32}$') {
    $ExpectedRecoveryRunId
} else {
    ""
}
$InstallerBootDescription = if ($firmwareOwnerRunId) {
    "Libertix UEFI Installer $firmwareOwnerRunId"
} else {
    "Libertix UEFI Installer"
}
if (-not $RecoveryRunId -and $firmwareOwnerRunId) {
    $RecoveryRunId = $firmwareOwnerRunId
}
$InstallerEspDirectory = "EFI\LibertixInstaller"
$InstallerEspOwnershipFile = ".libertix-owner"
$TransactionStatePath = "$SystemDrive\LibertixTools\uefi-transaction.json"

if ($BootStrategy -notin @("BootNext", "FirmwareBootOrder")) {
    throw "Unsupported UEFI boot strategy: $BootStrategy"
}

if (-not (Test-Administrator)) {
    Write-Log "Run this script as Administrator." "Red"
    exit 1
}

if ($Revert -and $RestoreWindowsSettings) {
    throw "Revert and RestoreWindowsSettings are mutually exclusive."
}

if ($Revert) {
    Assert-LibertixTransactionRecoveryRunId -ExpectedRecoveryRunId $ExpectedRecoveryRunId
    Start-LibertixTrackedRollback
    Invoke-Revert
    Complete-LibertixTrackedRollback
    exit 0
}

if ($RestoreWindowsSettings) {
    Assert-LibertixTransactionRecoveryRunId -ExpectedRecoveryRunId $ExpectedRecoveryRunId
    Restore-LibertixTransactionWindowsSettings
    exit 0
}

# Diagnostic only. The BootNext fallback deliberately re-enters this script
# without -Force while its own firmware entry still exists, so reporting the
# existing entry must never interrupt the workflow.
if (-not $Force) {
    $already = Invoke-BcdeditCommand -Arguments @("/enum", "firmware") |
        Select-String -Pattern "Libertix UEFI Installer"
    if ($already) {
        Write-Log "Libertix UEFI entry already exists and will be reused or replaced." "Yellow"
    }
}

try {
    if ($ReusePreparedInstaller) {
        if ($BootStrategy -ne "FirmwareBootOrder") {
            throw "Prepared installer reuse is only valid with FirmwareBootOrder."
        }
        $info = Get-ReusablePreparedInstallerPartition
        $drive = $info["Drive"]
        Assert-PreparedInstallerManifest -InstallerDrive $drive
        if ($installationPlan) {
            $installationPlan.runtime.bootStrategy = "uefi-firmware-boot-order"
            Write-LibertixInstallationPlanAtomic -Path $InstallationPlanPath -Plan $installationPlan
        }
        Start-LibertixTrackedStep -Step "windows.temporary-boot-prepared"
        Set-LibertixUefiBootEntry `
            -InstallerDrive $drive `
            -InstallerDiskNumber ([int]$info["DiskNumber"]) `
            -InstallerPartitionNumber ([int]$info["PartitionNumber"]) `
            -ReusePreparedInstaller
        Complete-LibertixTrackedStep -Step "windows.temporary-boot-prepared"
        Publish-LibertixInstallationContext -PartitionDrive $drive
        # The fallback changes the published plan after validating the original
        # media. Refresh the manifest so another guarded retry validates the
        # exact plan that is now present on the staging volume.
        Save-PreparedInstallerManifest -InstallerDrive $drive
        Dismount-Letter -Letter ($drive.TrimEnd(":"))
        Write-Log "FALLBACK_REUSED_PREPARED_INSTALLER=true" "Green"
        Write-Log "Preparation complete; waiting for the user interface to confirm restart." "Cyan"
        exit 0
    }

    Assert-LibertixPlanMatchesCurrentStorage
    Test-LibertixSecureBootCompatibility
    Set-WindowsVolumeReadableFromLinux
    Start-LibertixTrackedStep -Step "windows.artifacts-verified"
    Write-LibertixProgress -Stage "installer-iso-download" -Percent 30
    Set-DistributionIsoOnWindows
    Write-LibertixProgress -Stage "installer-iso-ready" -Percent 45
    Complete-LibertixTrackedStep -Step "windows.artifacts-verified"

    Write-LibertixProgress -Stage "staging-partition" -Percent 52
    $info = New-OrReuseInstallerPartition -SizeGB $InstallerPartitionSizeGB
    $drive = $info["Drive"]
    $installerDiskNumber = [int]$info["DiskNumber"]
    $installerPartitionNumber = [int]$info["PartitionNumber"]

    Start-LibertixTrackedStep -Step "windows.live-media-prepared"
    Install-LibertixIsoToPartition -PartitionDrive $drive
    Publish-LibertixInstallationContext -PartitionDrive $drive
    Complete-LibertixTrackedStep -Step "windows.live-media-prepared"

    Start-LibertixTrackedStep -Step "windows.temporary-boot-prepared"
    Write-LibertixProgress -Stage "temporary-boot" -Percent 90
    Set-LibertixUefiBootEntry `
        -InstallerDrive $drive `
        -InstallerDiskNumber $installerDiskNumber `
        -InstallerPartitionNumber $installerPartitionNumber
    Save-PreparedInstallerManifest -InstallerDrive $drive
    Complete-LibertixTrackedStep -Step "windows.temporary-boot-prepared"
    Publish-LibertixInstallationContext -PartitionDrive $drive

    Dismount-Letter -Letter ($drive.TrimEnd(":"))

    Write-Host ""
    Write-LibertixProgress -Stage "complete" -Percent 100
    Write-Log "Complete. Next boot should start Libertix UEFI installer once." "Green"
    Write-Host ""
    Write-Host "First boot: signed shim/GRUB should start the Libertix live installer." `
        -ForegroundColor Yellow

    Write-Log "Preparation complete; waiting for the user interface to confirm restart." "Cyan"
    exit 0
} catch {
    $preparationError = $_
    Write-Log $preparationError.Exception.Message "Red"
    Write-ExceptionDiagnostics -ErrorRecord $preparationError
    Write-Log "Error during preparation; running automatic revert..." "Yellow"
    try {
        Set-LibertixTrackedFailure `
            -Code "UEFI_PREPARATION_FAILED" `
            -Message $preparationError.Exception.Message
        Start-LibertixTrackedRollback
    } catch {
        Write-Log "Execution-state failure tracking failed: $($_.Exception.Message)" "Yellow"
    }
    try {
        Invoke-Revert
        Complete-LibertixTrackedRollback
    } catch {
        $revertError = $_
        Write-Log "Automatic revert failed: $($revertError.Exception.Message)" "Red"
        Write-ExceptionDiagnostics -ErrorRecord $revertError
        Write-Log "Tip: you can run with -Revert to restore Windows boot." "Yellow"
    }
    exit 1
}
