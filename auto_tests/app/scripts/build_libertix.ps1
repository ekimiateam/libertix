param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Python parses only NAME=VALUE lines. Other output remains human-readable
# diagnostic context and must not imitate that protocol.
function Write-Result {
    param([string]$Name, [string]$Value)
    Write-Output ("{0}={1}" -f $Name, $Value)
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)]
        [string]$FailureMessage
    )

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $FilePath @Arguments 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }

    if ($code -ne 0) {
        throw ("{0}, code={1}; sortie={2}" -f $FailureMessage, $code, ($output -join " | "))
    }

    return $output
}

function Find-VisualStudioMSBuild {
    # This legacy .NET Framework WPF project requires the Visual Studio MSBuild.
    # The .NET SDK and Framework-directory MSBuild cannot resolve its toolchain.
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
        $found = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild `
            -find "MSBuild\**\Bin\MSBuild.exe" 2>$null | Select-Object -First 1
        if ($found) {
            return $found
        }
    }

    $cmd = Get-Command MSBuild.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    $candidates = @(
        "C:\Program Files\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe",
        "C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe",
        "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\MSBuild\Current\Bin\MSBuild.exe",
        "C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\MSBuild\Current\Bin\MSBuild.exe"
    )

    return $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}

function Find-VisualStudioTestRunner {
    # Use the runner from the same Visual Studio installation as MSBuild so
    # classic .NET Framework tests do not depend on a separately installed SDK.
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
        $installationPath = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild `
            -property installationPath 2>$null | Select-Object -First 1
        if ($installationPath) {
            $candidate = Join-Path $installationPath `
                "Common7\IDE\CommonExtensions\Microsoft\TestWindow\vstest.console.exe"
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return $candidate
            }
        }
    }

    $cmd = Get-Command vstest.console.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    # Build hosts intentionally stay minimal. The test project pins the full
    # runner in NuGet, keeping this validation reproducible and disposable.
    $packageRunner = Get-ChildItem `
        -LiteralPath (Join-Path $env:NUGET_PACKAGES "microsoft.testplatform") `
        -Filter "vstest.console.exe" `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "tools\\net462\\" } |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if ($packageRunner) {
        return $packageRunner.FullName
    }

    return $null
}

function Copy-WithRobocopy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Destination,
        [string[]]$ExtraArgs = @()
    )

    $args = @(
        $Source,
        $Destination,
        "/E",
        "/R:3",
        "/W:2",
        "/COPY:DAT",
        "/DCOPY:DAT",
        "/NFL",
        "/NDL",
        "/NJH",
        "/NJS",
        "/NP"
    ) + $ExtraArgs

    $output = & robocopy.exe @args
    $code = $LASTEXITCODE
    if ($code -gt 7) {
        throw ("Robocopy failed, code={0}; output={1}" -f $code, ($output -join " | "))
    }
}

function Get-FreeDriveLetter {
    $used = @{}
    Get-PSDrive -PSProvider FileSystem | ForEach-Object { $used[$_.Name.ToUpperInvariant()] = $true }
    Get-SmbMapping -ErrorAction SilentlyContinue | ForEach-Object {
        $driveMatch = [regex]::Match([string]$_.LocalPath, "^([A-Z]):$")
        if ($driveMatch.Success) {
            $used[$driveMatch.Groups[1].Value.ToUpperInvariant()] = $true
        }
    }

    foreach ($letter in @("Y", "X", "W", "V", "U", "T", "S", "R", "Q", "P")) {
        if (-not $used.ContainsKey($letter)) {
            return ($letter + ":")
        }
    }

    throw "No free drive letter is available to mount the Samba share"
}

function Convert-SharePathToMappedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Share,
        [Parameter(Mandatory = $true)]
        [string]$Drive
    )

    $normalizedShare = $Share.TrimEnd("\")
    if (-not $Path.StartsWith($normalizedShare, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("Chemin hors partage Samba: " + $Path)
    }

    $suffix = $Path.Substring($normalizedShare.Length).TrimStart("\")
    if ($suffix) {
        return (Join-Path ($Drive + "\") $suffix)
    }
    return ($Drive + "\")
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$mapped = $false
$mappedDrive = $null
$temp = Join-Path $env:TEMP ("Libertix-build-" + [guid]::NewGuid().ToString("N"))
$srcLocal = Join-Path $temp "source"
$releaseStaging = $null
$releaseBackup = $null

# Keep the NuGet cache inside the disposable build directory so the shared
# build host retains no package state from an automation run.
$env:NUGET_PACKAGES = Join-Path $temp "nuget-packages"

try {
    $sourcePath = $config.source
    $releasePath = $config.release

    # Preserve any working user share configuration. Create only a temporary
    # mapping when the UNC path is not already accessible.
    if (-not (Test-Path -LiteralPath $config.share)) {
        Get-SmbMapping -ErrorAction SilentlyContinue |
            Where-Object { $_.RemotePath -eq $config.share -and $_.LocalPath } |
            Remove-SmbMapping -Force -UpdateProfile -ErrorAction SilentlyContinue

        $mappedDrive = Get-FreeDriveLetter
        New-SmbMapping `
            -LocalPath $mappedDrive `
            -RemotePath $config.share `
            -UserName $config.samba_username `
            -Password $config.samba_password `
            -Persistent $false |
            Out-Null
        $mapped = $true

        $sourcePath = Convert-SharePathToMappedPath `
            -Path $config.source `
            -Share $config.share `
            -Drive $mappedDrive
        $releasePath = Convert-SharePathToMappedPath `
            -Path $config.release `
            -Share $config.share `
            -Drive $mappedDrive
    }

    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
        throw ("Libertix source was not found on Samba: " + $sourcePath)
    }

    New-Item -ItemType Directory -Path $srcLocal -Force | Out-Null

    # Build a local disposable copy because compiling on Samba causes file-lock
    # races and would leave intermediate artifacts in the source tree.
    Copy-WithRobocopy -Source $sourcePath -Destination $srcLocal -ExtraArgs @("/XD", ".git", "bin", "obj")

    $solution = Join-Path $srcLocal "Libertix.sln"
    if (-not (Test-Path -LiteralPath $solution -PathType Leaf)) {
        throw "Libertix.sln is missing from the temporary copy"
    }

    $msbuild = Find-VisualStudioMSBuild
    if (-not $msbuild) {
        throw (
            "Visual Studio MSBuild was not found. This VM requires Visual Studio Build Tools " +
            "with the Microsoft.VisualStudio.Workload.ManagedDesktopBuildTools workload to build " +
            "this .NET Framework 4.8 WPF project without modifying the repository."
        )
    }

    # Build the source tree without runtime patches so stderr describes the
    # exact version that the API was asked to publish.
    Invoke-Native `
        -FilePath $msbuild `
        -Arguments @(
            $solution,
            "/restore",
            "/t:Restore;Build",
            "/p:Configuration=Release",
            "/p:Platform=Any CPU",
            "/p:RestoreProjectStyle=PackageReference",
            "/m",
            "/v:minimal",
            "/nologo"
        ) `
        -FailureMessage "Libertix compilation failed" |
        Out-Null

    $testAssembly = Join-Path $srcLocal "Libertix.Tests\bin\Release\Libertix.Tests.dll"
    if (-not (Test-Path -LiteralPath $testAssembly -PathType Leaf)) {
        throw "Libertix.Tests.dll is missing after the Release build"
    }

    $testRunner = Find-VisualStudioTestRunner
    if (-not $testRunner) {
        throw "vstest.console.exe was not found in the Visual Studio installation"
    }

    $adapterPath = Get-ChildItem `
        -LiteralPath (Join-Path $env:NUGET_PACKAGES "mstest.testadapter") `
        -Directory `
        -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName "build\net462" } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
        Select-Object -First 1

    if (-not $adapterPath) {
        throw "MSTest adapter was not found after NuGet restore"
    }

    Invoke-Native `
        -FilePath $testRunner `
        -Arguments @(
            $testAssembly,
            "/TestAdapterPath:$adapterPath",
            "/Platform:x64",
            "/Logger:console;verbosity=minimal"
        ) `
        -FailureMessage "Libertix C# tests failed" |
        Out-Null

    $exe = Get-ChildItem -LiteralPath $srcLocal -Recurse -Filter "Libertix.exe" |
        Where-Object { -not $_.PSIsContainer -and $_.FullName -match "\\bin\\Release\\" } |
        Sort-Object FullName |
        Select-Object -First 1

    if (-not $exe) {
        throw "Libertix.exe is missing after the Release build"
    }

    $releaseStaging = "$releasePath.staging-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $releaseStaging -Force | Out-Null

    $buildDir = Split-Path -Parent $exe.FullName
    Copy-WithRobocopy -Source $buildDir -Destination $releaseStaging

    $stagedExe = Join-Path $releaseStaging "Libertix.exe"
    if (-not (Test-Path -LiteralPath $stagedExe -PathType Leaf)) {
        throw "Libertix.exe is missing from Libertix-release after copying"
    }
    $finalHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $stagedExe).Hash.ToLowerInvariant()

    if (Test-Path -LiteralPath $releasePath) {
        $releaseBackup = "$releasePath.backup-$([Guid]::NewGuid().ToString('N'))"
        Move-Item -LiteralPath $releasePath -Destination $releaseBackup
    }
    try {
        Move-Item -LiteralPath $releaseStaging -Destination $releasePath
    }
    catch {
        if ($releaseBackup -and -not (Test-Path -LiteralPath $releasePath)) {
            Move-Item -LiteralPath $releaseBackup -Destination $releasePath
            $releaseBackup = $null
        }
        throw
    }
    $releaseStaging = $null
    $finalExe = Join-Path $releasePath "Libertix.exe"
    $publishedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $finalExe).Hash.ToLowerInvariant()
    if ($publishedHash -ne $finalHash) {
        throw "The Libertix.exe hash changed during publication"
    }
    if ($releaseBackup) {
        Remove-Item -LiteralPath $releaseBackup -Recurse -Force
        $releaseBackup = $null
    }

    Write-Result -Name "MSBUILD" -Value $msbuild
    Write-Result -Name "VSTEST" -Value $testRunner
    Write-Result -Name "TEMP_BUILD_DIR" -Value $temp
    Write-Result -Name "FINAL_EXE" -Value $finalExe
    Write-Result -Name "FINAL_EXE_SHA256" -Value $publishedHash
}
finally {
    # Always remove copied sources and build caches, including after a failed
    # build, because this host is also used for independent manual builds.
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($releaseStaging -and (Test-Path -LiteralPath $releaseStaging)) {
        Remove-Item -LiteralPath $releaseStaging -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($releaseBackup -and (Test-Path -LiteralPath $releaseBackup)) {
        if (Test-Path -LiteralPath $releasePath) {
            Remove-Item -LiteralPath $releasePath -Recurse -Force -ErrorAction SilentlyContinue
        }
        Move-Item -LiteralPath $releaseBackup -Destination $releasePath -ErrorAction SilentlyContinue
    }
    if ($mapped) {
        if ($mappedDrive) {
            Remove-SmbMapping -LocalPath $mappedDrive -Force -UpdateProfile -ErrorAction SilentlyContinue
        }
        else {
            Remove-SmbMapping -RemotePath $config.share -Force -UpdateProfile -ErrorAction SilentlyContinue
        }
    }
}
