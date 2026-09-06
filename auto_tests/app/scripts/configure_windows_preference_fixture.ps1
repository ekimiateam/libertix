#requires -Version 5.1

param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [switch]$ApplyWallpaper,
    [string]$WallpaperPath,
    [string]$ResultPath
)

$ErrorActionPreference = "Stop"

if ($ApplyWallpaper) {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WallpaperFixtureNative {
    [ComImport, Guid("B92B56A9-8B55-4E14-9A89-0199BBB6F93B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDesktopWallpaper {
        void SetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitor, [MarshalAs(UnmanagedType.LPWStr)] string path);
        [return: MarshalAs(UnmanagedType.LPWStr)] string GetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitor);
        [return: MarshalAs(UnmanagedType.LPWStr)] string GetMonitorDevicePathAt(uint index);
        uint GetMonitorDevicePathCount();
        void GetMonitorRECT([MarshalAs(UnmanagedType.LPWStr)] string monitor, IntPtr rectangle);
        void SetBackgroundColor(uint color);
        uint GetBackgroundColor();
        void SetPosition(uint position);
        uint GetPosition();
        void SetSlideshow(IntPtr items);
        IntPtr GetSlideshow();
        void SetSlideshowOptions(uint options, uint interval);
        void GetSlideshowOptions(out uint options, out uint interval);
        void AdvanceSlideshow([MarshalAs(UnmanagedType.LPWStr)] string monitor, uint direction);
        uint GetStatus();
        void Enable([MarshalAs(UnmanagedType.Bool)] bool enabled);
    }

    public static void Apply(string path) {
        if (System.Diagnostics.Process.GetCurrentProcess().SessionId == 0)
            throw new InvalidOperationException("Wallpaper must be applied in an interactive session.");
        if (!System.IO.File.Exists(path))
            throw new InvalidOperationException("Wallpaper file is not accessible in the interactive session: " + path);
        var desktop = (IDesktopWallpaper)Activator.CreateInstance(Type.GetTypeFromCLSID(
            new Guid("C2CF3110-460E-4FC1-B9D0-8A1C0C9CC4BD")));
        string stage = "select image";
        try {
            desktop.SetWallpaper(null, path);
            stage = "enable rendering";
            desktop.Enable(true);
            stage = "set position";
            desktop.SetPosition(4);
            stage = "verify selection";
            if (!String.Equals(desktop.GetWallpaper(null), path, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("The desktop wallpaper API did not select the fixture.");
            stage = "verify rendering status";
            uint status = desktop.GetStatus();
            if ((status & 1) == 0 || (status & 4) != 0)
                throw new InvalidOperationException("Desktop wallpaper rendering is disabled.");
        }
        catch (Exception error) { throw new InvalidOperationException("Wallpaper " + stage + " (" + path + "): " + error.Message, error); }
        finally { Marshal.FinalReleaseComObject(desktop); }
    }
}
'@
        [WallpaperFixtureNative]::Apply($WallpaperPath)
        if ((Get-ItemPropertyValue 'HKCU:\Control Panel\Desktop' -Name WallPaper) -ine $WallpaperPath) {
            throw "The interactive Windows wallpaper selection did not persist."
        }
        [IO.File]::WriteAllText($ResultPath, "OK")
        exit 0
    }
    catch {
        [IO.File]::WriteAllText($ResultPath, "ERROR: " + $_.Exception.Message)
        exit 1
    }
}

function Set-InteractiveFixtureWallpaper {
    param([string]$Path, [string]$UserSid, [string]$FixtureRoot)

    # SSH has no interactive desktop. Notify Explorer from the actual user's session.
    $id = [Guid]::NewGuid().ToString("N")
    $taskName = "LibertixWallpaperFixture_$id"
    $resultPath = Join-Path $FixtureRoot "$id.result"
    $arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -ConfigPath ignored -ApplyWallpaper -WallpaperPath "{1}" -ResultPath "{2}"' -f $PSCommandPath, $Path, $resultPath
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $arguments
    $principal = New-ScheduledTaskPrincipal -UserId $UserSid -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds 45)
    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings | Out-Null
        Start-ScheduledTask -TaskName $taskName
        $deadline = [Diagnostics.Stopwatch]::StartNew()
        do {
            Start-Sleep -Milliseconds 200
            $state = (Get-ScheduledTask -TaskName $taskName -ErrorAction Stop).State
            if ((Test-Path -LiteralPath $resultPath) -and $state -ne "Running") { break }
        } while ($deadline.Elapsed.TotalSeconds -lt 50)
        if (-not (Test-Path -LiteralPath $resultPath) -or
            (Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8) -ne "OK" -or $state -eq "Running") {
            $diagnostic = if (Test-Path -LiteralPath $resultPath) {
                Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8
            } else { "No worker result before the deadline." }
            throw "The interactive wallpaper fixture failed: $diagnostic"
        }
    }
    finally {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($null -ne $task) {
            if ($task.State -eq "Running") { Stop-ScheduledTask -TaskName $taskName }
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }
        if (Test-Path -LiteralPath $resultPath) { Remove-Item -LiteralPath $resultPath -Force }
    }
}

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

function Set-PreferenceFixtureImageAccess {
    param([string[]]$Paths, [string]$UserSid)

    # Explorer is not elevated. Keep the containing automation payload administrator-only.
    $identity = [Security.Principal.SecurityIdentifier]::new($UserSid)
    foreach ($imagePath in $Paths) {
        $acl = Get-Acl -LiteralPath $imagePath
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $identity, [Security.AccessControl.FileSystemRights]::Read,
            [Security.AccessControl.AccessControlType]::Allow)
        $acl.SetAccessRule($rule)
        Set-Acl -LiteralPath $imagePath -AclObject $acl
    }
}

function New-PreferenceFixtureImages {
    param([string]$WallpaperPath, [string]$AccountImagePath)

    Add-Type -AssemblyName System.Drawing
    $bitmap = New-Object Drawing.Bitmap 1280, 720
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([Drawing.Color]::CornflowerBlue)
        $graphics.FillRectangle([Drawing.Brushes]::SeaGreen, 0, 480, 1280, 240)
        $graphics.FillEllipse([Drawing.Brushes]::Gold, 960, 80, 160, 160)
        $graphics.FillRectangle([Drawing.Brushes]::White, 80, 560, 320, 40)
        $bitmap.Save($WallpaperPath, [Drawing.Imaging.ImageFormat]::Jpeg)
        $bitmap.Save($AccountImagePath, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
    foreach ($imagePath in @($WallpaperPath, $AccountImagePath)) {
        $decoded = [Drawing.Bitmap]::new($imagePath)
        try {
            if ($decoded.Width -ne 1280 -or $decoded.Height -ne 720 -or
                $decoded.GetPixel(100, 100).B -lt 150 -or
                $decoded.GetPixel(1040, 160).R -lt 200) {
                throw "The preference fixture image did not decode with the expected colors."
            }
        }
        finally { $decoded.Dispose() }
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
$wallpaperPath = Join-Path $fixtureRoot "wallpaper.jpg"
$accountImagePath = Join-Path $fixtureRoot "account-image.png"
New-PreferenceFixtureImages -WallpaperPath $wallpaperPath -AccountImagePath $accountImagePath

Set-PreferenceFixtureImageAccess -Paths @($wallpaperPath, $accountImagePath) -UserSid $sid

$desktop = "Registry::HKEY_USERS\$sid\Control Panel\Desktop"
$theme = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
$touchpad = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\PrecisionTouchPad"
$keyboard = "Registry::HKEY_USERS\$sid\Control Panel\Keyboard"
Set-RegistryStringValue -Path $desktop -Name WallPaper -Value $wallpaperPath
Set-RegistryStringValue -Path $desktop -Name WallpaperStyle -Value "10"
Set-RegistryDwordValue -Path "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers" -Name BackgroundType -Value 0
Set-RegistryDwordValue -Path "Registry::HKEY_USERS\$sid\Software\Policies\Microsoft\Windows\CloudContent" -Name DisableSpotlightCollectionOnDesktop -Value 1
Set-InteractiveFixtureWallpaper -Path $wallpaperPath -UserSid $sid -FixtureRoot $fixtureRoot
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
