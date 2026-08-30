#requires -Version 5.1

param([Parameter(Mandatory = $true)][string]$ConfigPath)

$ErrorActionPreference = "Stop"

function Set-RegistryDwordValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Value
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force |
        Out-Null
    if ([int](Get-ItemPropertyValue -LiteralPath $Path -Name $Name) -ne $Value) {
        throw "Registry fixture value was not persisted: $Path\$Name"
    }
}

function Set-RegistryStringValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -PropertyType String -Value $Value -Force |
        Out-Null
    if ([string](Get-ItemPropertyValue -LiteralPath $Path -Name $Name) -cne $Value) {
        throw "Registry fixture value was not persisted: $Path\$Name"
    }
}

function Set-PowerValue {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("AC", "DC")][string]$Source,
        [Parameter(Mandatory = $true)][string]$Subgroup,
        [Parameter(Mandatory = $true)][string]$Setting,
        [Parameter(Mandatory = $true)][uint32]$Value
    )

    $switch = if ($Source -eq "AC") { "/SETACVALUEINDEX" } else { "/SETDCVALUEINDEX" }
    & "$env:SystemRoot\System32\powercfg.exe" `
        $switch SCHEME_CURRENT $Subgroup $Setting ([string]$Value) | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Power preference fixture failed for $Source $Setting with rc=$LASTEXITCODE."
    }
}

$null = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop |
    Sort-Object CreationDate -Descending |
    Select-Object -First 1
$owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwnerSid -ErrorAction Stop
$sid = [string]$owner.Sid
if ([string]::IsNullOrWhiteSpace($sid)) {
    throw "The interactive Windows user SID could not be resolved."
}

$fixtureRoot = Join-Path $env:ProgramData "Libertix\Automation\preference-fixture"
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
$wallpaperPath = Join-Path $fixtureRoot "wallpaper.png"
$accountImagePath = Join-Path $fixtureRoot "account-image.png"
$wallpaperBase64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFElEQVR4nGP4z8DAwMDAxMDAwAAAHgIB8xW9xQAAAABJRU5ErkJggg=="
$accountImageBase64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nWQAAAAASUVORK5CYII="
[IO.File]::WriteAllBytes($wallpaperPath, [Convert]::FromBase64String($wallpaperBase64))
[IO.File]::WriteAllBytes($accountImagePath, [Convert]::FromBase64String($accountImageBase64))

$desktop = "Registry::HKEY_USERS\$sid\Control Panel\Desktop"
$theme = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
$touchpad = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\PrecisionTouchPad"
$keyboard = "Registry::HKEY_USERS\$sid\Control Panel\Keyboard"
Set-RegistryStringValue -Path $desktop -Name WallPaper -Value $wallpaperPath
Set-RegistryStringValue -Path $desktop -Name ScreenSaveActive -Value "1"
Set-RegistryStringValue -Path $desktop -Name ScreenSaverIsSecure -Value "1"
Set-RegistryStringValue -Path $desktop -Name ScreenSaveTimeOut -Value "420"
Set-RegistryDwordValue -Path $theme -Name AppsUseLightTheme -Value 0
Set-RegistryDwordValue -Path $touchpad -Name ScrollDirection -Value 1
Set-RegistryDwordValue -Path $touchpad -Name TapsEnabled -Value 1
Set-RegistryStringValue -Path $keyboard -Name KeyboardDelay -Value "1"
Set-RegistryStringValue -Path $keyboard -Name KeyboardSpeed -Value "31"

$accountPicture =
    "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\AccountPicture\Users\$sid"
Set-RegistryStringValue -Path $accountPicture -Name Image1080 -Value $accountImagePath

$videoSubgroup = "7516b95f-f776-4464-8c53-06167f40cc99"
$videoIdle = "3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e"
$sleepSubgroup = "238c9fa8-0aad-41ed-83f4-97be242c8f20"
$standbyIdle = "29f6c1db-86da-48c5-9fdb-f2b67b1f44da"
$buttonSubgroup = "4f971e89-eebd-4455-a8de-9e59040e7347"
$lidCloseAction = "5ca83367-6e45-459f-a27b-476b1d01c936"
$noSubgroup = "fea3413e-7e05-4911-9a71-700331f1c294"
$consoleLock = "0e796bdb-100d-47d6-a2d5-f7d2daa51f51"
Set-PowerValue -Source AC -Subgroup $videoSubgroup -Setting $videoIdle -Value 900
Set-PowerValue -Source DC -Subgroup $videoSubgroup -Setting $videoIdle -Value 300
Set-PowerValue -Source AC -Subgroup $sleepSubgroup -Setting $standbyIdle -Value 1800
Set-PowerValue -Source DC -Subgroup $sleepSubgroup -Setting $standbyIdle -Value 600
Set-PowerValue -Source AC -Subgroup $buttonSubgroup -Setting $lidCloseAction -Value 0
Set-PowerValue -Source DC -Subgroup $buttonSubgroup -Setting $lidCloseAction -Value 1
Set-PowerValue -Source AC -Subgroup $noSubgroup -Setting $consoleLock -Value 1
Set-PowerValue -Source DC -Subgroup $noSubgroup -Setting $consoleLock -Value 1
& "$env:SystemRoot\System32\powercfg.exe" /SETACTIVE SCHEME_CURRENT | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "The active power scheme could not be refreshed."
}

Write-Output "PREFERENCE_FIXTURE_READY=True"
Write-Output "WALLPAPER_SHA256=$((Get-FileHash -LiteralPath $wallpaperPath -Algorithm SHA256).Hash.ToLowerInvariant())"
Write-Output "ACCOUNT_IMAGE_SHA256=$((Get-FileHash -LiteralPath $accountImagePath -Algorithm SHA256).Hash.ToLowerInvariant())"
