[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StatePath,
    [Parameter(Mandatory = $true)][string]$RecoveryScriptPath,
    [Parameter(Mandatory = $true)][ValidateSet("bios", "uefi")][string]$Firmware,
    [Parameter(Mandatory = $true)][string]$PromptTaskName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop |
        ConvertFrom-Json -ErrorAction Stop
}

function Write-JsonFileAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $directory = Split-Path -Parent $Path
    $temporary = Join-Path $directory ".$([IO.Path]::GetFileName($Path)).$([Guid]::NewGuid().ToString('N')).tmp"
    $backup = Join-Path $directory ".$([IO.Path]::GetFileName($Path)).$([Guid]::NewGuid().ToString('N')).bak"
    try {
        $encoding = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText(
            $temporary,
            (($Value | ConvertTo-Json -Depth 8) + "`n"),
            $encoding
        )
        if ([IO.File]::Exists($Path)) {
            [IO.File]::Replace($temporary, $Path, $backup)
        } else {
            [IO.File]::Move($temporary, $Path)
        }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
    }
}

function Remove-PromptTask {
    Unregister-ScheduledTask `
        -TaskName $PromptTaskName `
        -Confirm:$false `
        -ErrorAction SilentlyContinue
}

function Add-InteractiveShareCheck {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][string]$Detail
    )

    $Result.checks = @($Result.checks | Where-Object { [string]$_.name -ne $Name }) + @(
        [pscustomobject][ordered]@{
            name = $Name
            passed = $Passed
            detail = $Detail
            checkedAtUtc = [DateTime]::UtcNow.ToString("o")
        }
    )
}

function Complete-InteractiveWindowsShareVerification {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)]$Plan
    )

    if (
        [string]$Result.status -ne "succeeded" -or
        -not [bool]$Plan.features.shareLinuxFilesInWindows
    ) {
        return
    }
    $shareRoot = Join-Path $env:ProgramData "Libertix\WindowsShare"
    $configPath = Join-Path $shareRoot "config.json"
    $shareScript = Join-Path $shareRoot "mount-linux-readonly.ps1"
    try {
        if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
            throw "Windows read-only Linux sharing configuration is missing."
        }
        if (-not (Test-Path -LiteralPath $shareScript -PathType Leaf)) {
            throw "Windows read-only Linux sharing script is missing."
        }
        $shareArguments = (
            '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -Pin'
        ) -f $shareScript, $configPath
        $process = Start-Process `
            -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -ArgumentList $shareArguments `
            -Wait `
            -PassThru `
            -WindowStyle Hidden
        if ($process.ExitCode -ne 0) {
            throw "Explorer integration verification failed with rc=$($process.ExitCode)."
        }
        Add-InteractiveShareCheck `
            -Result $Result `
            -Name "explorer-integration" `
            -Passed $true `
            -Detail "Linux read-only shortcut is accessible in Explorer Home/Quick Access."
        Write-JsonFileAtomic -Path $StatePath -Value $Result
    } catch {
        Add-InteractiveShareCheck `
            -Result $Result `
            -Name "explorer-integration" `
            -Passed $false `
            -Detail $_.Exception.Message
        $Result.status = "failed"
        $Result.error = $_.Exception.Message
        $Result.rollbackAvailable = $true
        Write-JsonFileAtomic -Path $StatePath -Value $Result
    }
}

if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
    exit 0
}
$result = Read-JsonFile -Path $StatePath
if ([string]$result.status -notin @("succeeded", "failed", "rolled-back")) {
    $recoveryRoot = Split-Path -Parent $StatePath
    $linuxEvidencePath = Join-Path $recoveryRoot "installed-linux-boot.json"
    if (-not (Test-Path -LiteralPath $linuxEvidencePath -PathType Leaf)) {
        exit 0
    }

    # At logon the interactive trigger can run a few seconds before the SYSTEM
    # startup verifier. Once Linux evidence exists, keep this instance alive so
    # the result cannot be lost merely because the two tasks raced each other.
    $deadline = [DateTime]::UtcNow.AddMinutes(15)
    do {
        Start-Sleep -Seconds 2
        if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
            $result = Read-JsonFile -Path $StatePath
        }
    } while (
        [string]$result.status -notin @("succeeded", "failed", "rolled-back") -and
        [DateTime]::UtcNow -lt $deadline
    )
    if ([string]$result.status -notin @("succeeded", "failed", "rolled-back")) {
        exit 0
    }
}

$recoveryRoot = Split-Path -Parent $StatePath
$plan = Read-JsonFile -Path (Join-Path $recoveryRoot "installation-plan.json")
Complete-InteractiveWindowsShareVerification `
    -Result $result `
    -Plan $plan
$language = [string]$plan.locale.languageCode
$translationsPath = @(
    (Join-Path $PSScriptRoot "config\Libertix.Translations.json"),
    (Join-Path (Split-Path -Parent $PSScriptRoot) "Resources\Libertix.Translations.json")
) | Where-Object {
    Test-Path -LiteralPath $_ -PathType Leaf
} | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($translationsPath)) {
    throw "Libertix translation catalogue is missing."
}
$translations = Read-JsonFile -Path $translationsPath
if ($language -notin @("en", "fr", "es")) {
    $language = "en"
}
$text = $translations.languages.$language.postInstall

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$window = New-Object Windows.Window
$window.Title = if ([string]$result.status -eq "succeeded") {
    [string]$text.successTitle
} else {
    [string]$text.failureTitle
}
$window.Width = 820
$window.Height = 610
$window.MinWidth = 720
$window.MinHeight = 520
$window.WindowStartupLocation = "CenterScreen"
$window.Background = [Windows.Media.Brushes]::White
$window.Topmost = $true

$root = New-Object Windows.Controls.Grid
$root.Margin = New-Object Windows.Thickness(28)
$root.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = "Auto" }))
$root.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = "Auto" }))
$root.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = "*" }))
$root.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = "Auto" }))

$title = New-Object Windows.Controls.TextBlock
$title.Text = $window.Title
$title.FontSize = 28
$title.FontWeight = "SemiBold"
$title.TextWrapping = "Wrap"
$title.Margin = New-Object Windows.Thickness(0, 0, 0, 18)
[Windows.Controls.Grid]::SetRow($title, 0)
$root.Children.Add($title) | Out-Null

$message = New-Object Windows.Controls.TextBlock
$message.Text = if ([string]$result.status -eq "succeeded") {
    [string]$text.successMessage
} else {
    [string]$text.failureMessage
}
$message.FontSize = 16
$message.TextWrapping = "Wrap"
$message.Margin = New-Object Windows.Thickness(0, 0, 0, 18)
[Windows.Controls.Grid]::SetRow($message, 1)
$root.Children.Add($message) | Out-Null

$details = New-Object Windows.Controls.TextBox
$details.IsReadOnly = $true
$details.AcceptsReturn = $true
$details.TextWrapping = "Wrap"
$details.VerticalScrollBarVisibility = "Auto"
$details.FontFamily = New-Object Windows.Media.FontFamily("Consolas")
$details.FontSize = 13
$detailLines = @(
    "$($text.details):",
    "$($text.statusLabel): $($result.status)",
    "$($text.planLabel): $($result.planId)",
    "$($text.logLabel): $($result.logPath)"
)
foreach ($check in @($result.checks)) {
    $checkLabel = if ($check.passed) {
        [string]$text.checkPassedLabel
    } else {
        [string]$text.checkFailedLabel
    }
    $detailLines += "[$checkLabel] $($check.name): $($check.detail)"
}
if (-not [string]::IsNullOrWhiteSpace([string]$result.error)) {
    $detailLines += "$($text.errorLabel): $($result.error)"
}
$details.Text = $detailLines -join [Environment]::NewLine
[Windows.Controls.Grid]::SetRow($details, 2)
$root.Children.Add($details) | Out-Null

$buttons = New-Object Windows.Controls.StackPanel
$buttons.Orientation = "Horizontal"
$buttons.HorizontalAlignment = "Right"
$buttons.Margin = New-Object Windows.Thickness(0, 18, 0, 0)
[Windows.Controls.Grid]::SetRow($buttons, 3)

$closeButton = New-Object Windows.Controls.Button
$closeButton.Content = [string]$text.close
$closeButton.MinWidth = 150
$closeButton.Height = 46
$closeButton.Padding = New-Object Windows.Thickness(18, 8, 18, 8)
$closeButton.IsDefault = $true
$closeButton.SetValue(
    [Windows.Automation.AutomationProperties]::AutomationIdProperty,
    "LibertixPostInstallCloseButton"
)
$closeButton.Add_Click({ $window.Close() })

if ([string]$result.status -eq "failed" -and [bool]$result.rollbackAvailable) {
    $rollbackButton = New-Object Windows.Controls.Button
    $rollbackButton.Content = [string]$text.rollback
    $rollbackButton.MinWidth = 190
    $rollbackButton.Height = 46
    $rollbackButton.Margin = New-Object Windows.Thickness(0, 0, 12, 0)
    $rollbackButton.Padding = New-Object Windows.Thickness(18, 8, 18, 8)
    $rollbackButton.Add_Click({
        $answer = [Windows.MessageBox]::Show(
            [string]$text.rollbackConfirmMessage,
            [string]$text.rollbackConfirmTitle,
            [Windows.MessageBoxButton]::YesNo,
            [Windows.MessageBoxImage]::Warning
        )
        if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }
        $rollbackButton.IsEnabled = $false
        $closeButton.IsEnabled = $false
        $message.Text = [string]$text.rollbackRunning
        $arguments = if ($Firmware -eq "uefi") {
            @(
                "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $RecoveryScriptPath,
                "-StatePath", (Join-Path $recoveryRoot "state.json"), "-Action", "Cancel"
            )
        } else {
            @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $RecoveryScriptPath, "-Action", "Revert")
        }
        $process = Start-Process `
            -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -ArgumentList $arguments `
            -Wait `
            -PassThru `
            -WindowStyle Hidden
        if ($process.ExitCode -eq 0) {
            $result.status = "rolled-back"
            $result.rollbackAvailable = $false
            $result.updatedAtUtc = [DateTime]::UtcNow.ToString("o")
            $result | Add-Member `
                -NotePropertyName rolledBackAtUtc `
                -NotePropertyValue ([DateTime]::UtcNow.ToString("o")) `
                -Force
            Write-JsonFileAtomic -Path $StatePath -Value $result
            $message.Text = [string]$text.rollbackComplete
            $rollbackButton.Visibility = "Collapsed"
            $closeButton.IsEnabled = $true
        } else {
            $message.Text = "$($text.rollbackFailed) rc=$($process.ExitCode)"
            $rollbackButton.IsEnabled = $true
            $closeButton.IsEnabled = $true
        }
    })
    $buttons.Children.Add($rollbackButton) | Out-Null
}
$buttons.Children.Add($closeButton) | Out-Null
$root.Children.Add($buttons) | Out-Null
$window.Content = $root
$window.Add_ContentRendered({
    $null = $window.Activate()
    $null = $closeButton.Focus()
})
try {
    $null = $window.ShowDialog()
} finally {
    Remove-PromptTask
}
