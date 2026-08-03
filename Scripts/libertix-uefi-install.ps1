#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ConfigPath = "",
    [string]$InstallationPlanPath = "",
    [string]$ExecutionStatePath = "",
    [switch]$Force = $false,
    [switch]$Revert = $false,
    [switch]$SkipInstaller = $false,
    [int]$InstallerPartitionSizeGB = 20,
    [string]$FilepoolBaseUrl = "",
    [string]$Aria2ExePath = "",
    [ValidateRange(1, 5)]
    [int]$Aria2Connections = 5,
    [string]$LinuxUsername = "",
    [string]$LinuxPasswordHash = "",
    [string]$LinuxComputerName = "",
    [ValidateSet("en", "fr", "es", "ja")]
    [string]$LanguageCode = "en",
    [string]$SystemLang = "en_US.UTF-8",
    [string]$KeyboardLayout = "us",
    [string]$KeyboardModel = "pc105",
    [string]$Timezone = "UTC",
    [ValidateSet("BootNext", "FirmwareBootOrder")]
    [string]$BootStrategy = "BootNext",
    [switch]$ReusePreparedInstaller = $false,
    [string]$RecoveryRoot = "",
    [string]$RecoveryRunId = "",
    [bool]$LowMemoryMode = $false,
    [bool]$ShareWindowsFilesInLinux = $true,
    [bool]$ShareLinuxFilesInWindows = $true,
    [string]$WindowsProfilesJsonBase64 = "W10=",
    [switch]$PreserveConfig = $false,
    [switch]$InsecureTls = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$bootStrategyWasSpecified = $PSBoundParameters.ContainsKey("BootStrategy")

$requiredModules = @(
    "Libertix.InstallationPlan.psm1",
    "Libertix.InstallationState.psm1",
    "Libertix.Process.psm1",
    "Libertix.Firmware.psm1",
    "Libertix.Download.psm1",
    "Libertix.Transaction.psm1",
    "Libertix.Rollback.psm1"
)
foreach ($moduleName in $requiredModules) {
    $modulePath = Join-Path $PSScriptRoot "modules\$moduleName"
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Libertix PowerShell module is missing: $modulePath"
    }
    Import-Module -Name $modulePath -Force -ErrorAction Stop
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
        if ($config.PSObject.Properties.Name -contains "InstallerPartitionSizeGB") {
            $InstallerPartitionSizeGB = [int]$config.InstallerPartitionSizeGB
        }
        $FilepoolBaseUrl = [string]$config.FilepoolBaseUrl
        $Aria2ExePath = [string]$config.Aria2ExePath
        $Aria2Connections = [int]$config.Aria2Connections
        # Account and locale values moved into InstallationPlan. Keep these
        # guarded reads only for legacy recovery configs that still carry them.
        if ($config.PSObject.Properties.Name -contains "LinuxUsername") {
            $LinuxUsername = [string]$config.LinuxUsername
        }
        if ($config.PSObject.Properties.Name -contains "LinuxPasswordHash") {
            $LinuxPasswordHash = [string]$config.LinuxPasswordHash
        }
        if ($config.PSObject.Properties.Name -contains "LinuxComputerName") {
            $LinuxComputerName = [string]$config.LinuxComputerName
        }
        if ($config.PSObject.Properties.Name -contains "LanguageCode") {
            $LanguageCode = [string]$config.LanguageCode
        }
        if ($config.PSObject.Properties.Name -contains "SystemLang") {
            $SystemLang = [string]$config.SystemLang
        }
        if ($config.PSObject.Properties.Name -contains "KeyboardLayout") {
            $KeyboardLayout = [string]$config.KeyboardLayout
        }
        if ($config.PSObject.Properties.Name -contains "KeyboardModel") {
            $KeyboardModel = [string]$config.KeyboardModel
        }
        if ($config.PSObject.Properties.Name -contains "Timezone") {
            $Timezone = [string]$config.Timezone
        }
        if (-not $bootStrategyWasSpecified -and $config.PSObject.Properties.Name -contains "BootStrategy") {
            $BootStrategy = [string]$config.BootStrategy
        }
        if ($config.PSObject.Properties.Name -contains "RecoveryRoot") {
            $RecoveryRoot = [string]$config.RecoveryRoot
        }
        if ($config.PSObject.Properties.Name -contains "RecoveryRunId") {
            $RecoveryRunId = [string]$config.RecoveryRunId
        }
        if ($config.PSObject.Properties.Name -contains "LowMemoryMode") {
            $LowMemoryMode = [bool]$config.LowMemoryMode
        }
        if ($config.PSObject.Properties.Name -contains "ShareWindowsFilesInLinux") {
            $ShareWindowsFilesInLinux = [bool]$config.ShareWindowsFilesInLinux
        }
        if ($config.PSObject.Properties.Name -contains "ShareLinuxFilesInWindows") {
            $ShareLinuxFilesInWindows = [bool]$config.ShareLinuxFilesInWindows
        }
        if ($config.PSObject.Properties.Name -contains "WindowsProfilesJsonBase64") {
            $WindowsProfilesJsonBase64 = [string]$config.WindowsProfilesJsonBase64
        }
    } finally {
        if (-not $PreserveConfig) {
            Remove-Item -LiteralPath $ConfigPath -Force -ErrorAction SilentlyContinue
        }
    }
}

# New callers pass a validated plan. Legacy command-line parameters remain as
# a compatibility boundary for recovery tools and direct script diagnostics.
$installationPlan = $null
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
    $LinuxUsername = [string]$installationPlan.account.username
    $LinuxPasswordHash = [string]$installationPlan.account.passwordHash
    $LinuxComputerName = [string]$installationPlan.account.computerName
    $LanguageCode = [string]$installationPlan.locale.languageCode
    $SystemLang = [string]$installationPlan.locale.systemLanguage
    $KeyboardLayout = [string]$installationPlan.locale.keyboardLayout
    $KeyboardModel = [string]$installationPlan.locale.keyboardModel
    $Timezone = [string]$installationPlan.locale.timezone
    $RecoveryRoot = [string]$installationPlan.runtime.recoveryRootWindows
    $RecoveryRunId = [string]$installationPlan.runtime.recoveryRunId
    $LowMemoryMode = [bool]$installationPlan.runtime.lowMemoryMode
    $ShareWindowsFilesInLinux = [bool]$installationPlan.features.shareWindowsFilesInLinux
    $ShareLinuxFilesInWindows = [bool]$installationPlan.features.shareLinuxFilesInWindows
    $WindowsProfilesJsonBase64 = [string]$installationPlan.features.windowsProfilesJsonBase64
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

# A rollback only consumes the transaction state stored on disk. It must remain
# available even when no download configuration is supplied by the caller.
if (-not $Revert) {
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

# Networking defaults
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($InsecureTls) {
    try {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) {
        return true;
    }
}
"@
    } catch {}

    [System.Net.ServicePointManager]::CertificatePolicy =
        New-Object TrustAllCertsPolicy

    if (
        -not (
            [System.Management.Automation.PSTypeName]`
                "ServerCertificateValidationCallback"
        ).Type
    ) {
        $certCallback = @"
using System;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public class ServerCertificateValidationCallback {
    public static void Ignore() {
        ServicePointManager.ServerCertificateValidationCallback +=
            delegate(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors sslPolicyErrors) { return true; };
    }
}
"@
        try { Add-Type $certCallback } catch {}
    }

    try { [ServerCertificateValidationCallback]::Ignore() } catch {}
}

# Downloads
$Aria2ZipName = "aria2-64.zip"
$downloadUrls = $null
if (-not $Revert) {
    $downloadUrls = New-LibertixDownloadUrls `
        -FilepoolBaseUrl $FilepoolBaseUrl `
        -Aria2ZipName $Aria2ZipName
}
$InstallerIsoUrl = if ($installationPlan) {
    [string]$installationPlan.distribution.liveIsoUrl
} elseif ($downloadUrls) { $downloadUrls.InstallerIso } else { "" }
$InstallerIsoName = "libertix-installer-uefi.iso"
$InstallerIsoSha256 = if ($installationPlan) {
    [string]$installationPlan.distribution.liveIsoSha256
} else { "3a6db211fcd2d9b437c5c906a3c508203bd1636bb27e40904e9891079f054a97" }
$MintIsoUrl = if ($installationPlan) {
    [string]$installationPlan.distribution.installerIsoUrl
} elseif ($downloadUrls) { $downloadUrls.MintIso } else { "" }
$MintIsoPath = if ($installationPlan) {
    [string]$installationPlan.distribution.installerIsoWindowsPath
} else { "$env:SystemDrive\mint.iso" }
$MintIsoSha256 = if ($installationPlan) {
    [string]$installationPlan.distribution.installerIsoSha256
} else { "a081ab202cfda17f6924128dbd2de8b63518ac0531bcfe3f1a1b88097c459bd4" }
$Aria2ZipUrl = if ($downloadUrls) { $downloadUrls.Aria2Zip } else { "" }
$Aria2ZipSha256 = "67d015301eef0b612191212d564c5bb0a14b5b9c4796b76454276a4d28d9b288"
$Aria2ExeSha256 = "be2099c214f63a3cb4954b09a0becd6e2e34660b886d4c898d260febfe9d70c2"
$Aria2CacheDir = "$env:SystemDrive\LibertixTools\aria2"
$Aria2DownloadDir = "$env:SystemDrive\LibertixTools\downloads"
$LowMemoryIsoPath = "$env:SystemDrive\libertix-live.iso"

# Defaults
$EspLetter = "Y"
$InstallerLetter = "X"
$InstallerLabel = "LIBERTIXEFI"
$InstallerBootDescription = "Libertix UEFI Installer"
$InstallerEspDirectory = "EFI\LibertixInstaller"
$TransactionStatePath = "$env:SystemDrive\LibertixTools\uefi-transaction.json"

if ($BootStrategy -notin @("BootNext", "FirmwareBootOrder")) {
    throw "Unsupported UEFI boot strategy: $BootStrategy"
}

if (-not (Test-Administrator)) {
    Write-Log "Run this script as Administrator." "Red"
    exit 1
}

if ($Revert) {
    Invoke-Revert
    exit 0
}

if (-not $Force) {
    $already = Invoke-BcdeditCommand -Arguments @("/enum", "firmware") |
        Select-String -Pattern "Libertix UEFI Installer"
    if ($already) {
        Write-Log "Libertix UEFI entry detected. Use -Force to recreate." "Yellow"
    }
}

try {
    if ($ReusePreparedInstaller) {
        if ($BootStrategy -ne "FirmwareBootOrder") {
            throw "Prepared installer reuse is only valid with FirmwareBootOrder."
        }
        Test-LibertixLiveConfig
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
        Dismount-Letter -Letter ($drive.TrimEnd(":"))
        Write-Log "FALLBACK_REUSED_PREPARED_INSTALLER=true" "Green"
        Write-Log "Preparation complete; waiting for the user interface to confirm restart." "Cyan"
        exit 0
    }

    Test-LibertixLiveConfig
    Assert-LibertixPlanMatchesCurrentStorage
    Test-LibertixSecureBootCompatibility
    Ensure-WindowsVolumeReadableFromLinux
    Start-LibertixTrackedStep -Step "windows.artifacts-verified"
    Ensure-MintIsoOnWindows
    Complete-LibertixTrackedStep -Step "windows.artifacts-verified"

    if ($SkipInstaller) {
        Write-Log "Done (installer partition skipped)." "Green"
        exit 0
    }

    $info = New-OrReuseInstallerPartition -SizeGB $InstallerPartitionSizeGB
    $drive = $info["Drive"]
    $installerDiskNumber = [int]$info["DiskNumber"]
    $installerPartitionNumber = [int]$info["PartitionNumber"]

    Start-LibertixTrackedStep -Step "windows.live-media-prepared"
    Install-LibertixIsoToPartition -PartitionDrive $drive
    Write-LibertixLiveConfig -PartitionDrive $drive
    Complete-LibertixTrackedStep -Step "windows.live-media-prepared"

    Start-LibertixTrackedStep -Step "windows.temporary-boot-prepared"
    Set-LibertixUefiBootEntry `
        -InstallerDrive $drive `
        -InstallerDiskNumber $installerDiskNumber `
        -InstallerPartitionNumber $installerPartitionNumber
    Save-PreparedInstallerManifest -InstallerDrive $drive
    Complete-LibertixTrackedStep -Step "windows.temporary-boot-prepared"
    Publish-LibertixInstallationContext -PartitionDrive $drive

    Dismount-Letter -Letter ($drive.TrimEnd(":"))

    Write-Host ""
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
