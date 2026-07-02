param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Les seules sorties structurées attendues par Python sont les lignes NAME=VALUE.
# Tout le reste sert au diagnostic en cas d'erreur.
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
    # Pour ce projet WPF .NET Framework 4.8 ancien format, le MSBuild du .NET SDK
    # ou le vieux MSBuild C:\Windows\Microsoft.NET\Framework* ne suffit pas :
    # il faut le MSBuild installé avec Visual Studio / Build Tools Desktop.
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
        throw ("Échec robocopy, code={0}; sortie={1}" -f $code, ($output -join " | "))
    }
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$mapped = $false
$temp = Join-Path $env:TEMP ("Libertix-build-" + [guid]::NewGuid().ToString("N"))
$srcLocal = Join-Path $temp "source"

# Important pour la VM 192.168.1.138, utilisée aussi manuellement :
# le cache NuGet reste dans le dossier temporaire du build et disparaît au cleanup.
$env:NUGET_PACKAGES = Join-Path $temp "nuget-packages"

try {
    # On ne crée pas de mapping persistant. Si le partage est déjà accessible,
    # on ne touche pas à la configuration existante de l'utilisateur.
    if (-not (Test-Path -LiteralPath $config.share)) {
        Get-SmbMapping |
            Where-Object { $_.RemotePath -eq $config.share } |
            Remove-SmbMapping -Force -UpdateProfile -ErrorAction SilentlyContinue

        New-SmbMapping `
            -RemotePath $config.share `
            -UserName $config.samba_username `
            -Password $config.samba_password `
            -Persistent $false |
            Out-Null
        $mapped = $true
    }

    if (-not (Test-Path -LiteralPath $config.source -PathType Container)) {
        throw ("Source Libertix introuvable sur Samba: " + $config.source)
    }

    New-Item -ItemType Directory -Path $srcLocal -Force | Out-Null

    # Le repo original reste sur Samba. On compile uniquement une copie locale
    # temporaire pour éviter les problèmes de locks et pour pouvoir supprimer
    # tous les artefacts intermédiaires en fin de run.
    Copy-WithRobocopy -Source $config.source -Destination $srcLocal -ExtraArgs @("/XD", ".git", "bin", "obj")

    # Le repo distant peut encore contenir les anciens noms LinuxGate tant que
    # le renommage Libertix n'est pas poussé. On accepte les deux sans modifier
    # la source clonée sur Samba.
    $solution = Join-Path $srcLocal "Libertix.sln"
    if (-not (Test-Path -LiteralPath $solution -PathType Leaf)) {
        $solution = Join-Path $srcLocal "LinuxGate.sln"
    }
    if (-not (Test-Path -LiteralPath $solution -PathType Leaf)) {
        throw "Aucune solution Libertix.sln ou LinuxGate.sln trouvée dans la copie temporaire"
    }

    $msbuild = Find-VisualStudioMSBuild
    if (-not $msbuild) {
        throw (
            "MSBuild Visual Studio introuvable. Cette VM a besoin de Visual Studio Build Tools " +
            "avec le workload Microsoft.VisualStudio.Workload.ManagedDesktopBuildTools pour compiler " +
            "ce projet WPF .NET Framework 4.8 sans modifier le repo."
        )
    }

    # Build du repo tel quel : pas de patch temporaire de .cs/.csproj.
    # Si cette commande échoue, l'erreur MSBuild complète est remontée dans
    # le JSON API via stderr.
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
        -FailureMessage "Compilation Libertix échouée" |
        Out-Null

    $exe = Get-ChildItem -LiteralPath $srcLocal -Recurse -Include "Libertix.exe", "LinuxGate.exe" |
        Where-Object { -not $_.PSIsContainer -and $_.FullName -match "\\bin\\Release\\" } |
        Sort-Object FullName |
        Select-Object -First 1

    if (-not $exe) {
        throw "Aucun exécutable Libertix.exe ou LinuxGate.exe trouvé après compilation Release"
    }

    if (Test-Path -LiteralPath $config.release) {
        Remove-Item -LiteralPath $config.release -Recurse -Force
    }
    New-Item -ItemType Directory -Path $config.release -Force | Out-Null

    $buildDir = Split-Path -Parent $exe.FullName
    Copy-WithRobocopy -Source $buildDir -Destination $config.release

    if ($exe.Name -eq "LinuxGate.exe") {
        Copy-Item `
            -LiteralPath (Join-Path $config.release "LinuxGate.exe") `
            -Destination (Join-Path $config.release "Libertix.exe") `
            -Force

        $linuxGateConfig = Join-Path $config.release "LinuxGate.exe.config"
        if (Test-Path -LiteralPath $linuxGateConfig -PathType Leaf) {
            Copy-Item `
                -LiteralPath $linuxGateConfig `
                -Destination (Join-Path $config.release "Libertix.exe.config") `
                -Force
        }
    }

    $finalExe = Join-Path $config.release "Libertix.exe"
    if (-not (Test-Path -LiteralPath $finalExe -PathType Leaf)) {
        throw "Libertix.exe absent dans Libertix-release après copie"
    }

    Write-Result -Name "MSBUILD" -Value $msbuild
    Write-Result -Name "TEMP_BUILD_DIR" -Value $temp
    Write-Result -Name "FINAL_EXE" -Value $finalExe
}
finally {
    # Nettoyage systématique : source copiée, packages NuGet temporaires et
    # éventuels bin/obj de build disparaissent même en cas d'erreur.
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($mapped) {
        Remove-SmbMapping -RemotePath $config.share -Force -UpdateProfile -ErrorAction SilentlyContinue
    }
}
