param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Result {
    param([string]$Name, [string]$Value)
    Write-Output ("{0}={1}" -f $Name, $Value)
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$exe = [string]$config.executable
$mode = [string]$config.mode

if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw "Libertix.exe local est introuvable"
}

if ($mode -eq "prepare") {
    # Le service SSH Windows lance sinon les processus dans une session non visible.
    # On repère donc la vraie session graphique via explorer.exe de l'utilisateur admin.
    $interactive = Get-Process explorer -IncludeUserName |
        Where-Object { $_.UserName -like ("*\" + $config.username) } |
        Select-Object -First 1

    if (-not $interactive) {
        throw "Aucune session graphique admin active"
    }

    Get-Process -Name "Libertix", "LinuxGate" -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $interactive.SessionId } |
        Stop-Process -Force

    # Libertix demande l'élévation dans son manifeste. Pour la validation visuelle
    # de l'écran d'accueil, on force temporairement RUNASINVOKER sur cette copie
    # locale. La clé est supprimée dans le mode verify.
    $layers = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers"
    New-Item $layers -Force | Out-Null
    New-ItemProperty $layers -Name $exe -Value "RUNASINVOKER" -PropertyType String -Force |
        Out-Null

    # Le lancement vraiment interactif est fait par VNC côté Python : on crée ici
    # seulement le raccourci temporaire sur le bureau de la session admin.
    $desktop = [Environment]::GetFolderPath("Desktop")
    $shortcut = Join-Path $desktop "Libertix.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($shortcut)
    $link.TargetPath = $exe
    $link.WorkingDirectory = Split-Path $exe
    $link.Save()

    Write-Result -Name "SESSION_ID" -Value $interactive.SessionId
    exit 0
}

if ($mode -eq "verify") {
    $sessionId = [int]$config.session_id
    $desktop = [Environment]::GetFolderPath("Desktop")
    $shortcut = Join-Path $desktop "Libertix.lnk"
    $layers = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers"

    try {
        $deadline = (Get-Date).AddSeconds(20)
        do {
            Start-Sleep -Milliseconds 500
            $process = Get-Process -Name "Libertix", "LinuxGate" -ErrorAction SilentlyContinue |
                Where-Object { $_.SessionId -eq $sessionId } |
                Sort-Object StartTime -Descending |
                Select-Object -First 1
        } while ((-not $process) -and ((Get-Date) -lt $deadline))

        if (-not $process) {
            throw "Libertix/LinuxGate ne démarre pas dans la session graphique"
        }

        # MainWindowHandle vaut parfois 0 même quand la fenêtre est visible via VNC.
        # La preuve fiable de l'écran est donc la capture VNC + validation LLM.
        Write-Result -Name "PID" -Value $process.Id
        Write-Result -Name "SESSION_ID" -Value $process.SessionId
        Write-Result -Name "WINDOW_HANDLE" -Value $process.MainWindowHandle
        exit 0
    }
    finally {
        Remove-Item -LiteralPath $shortcut -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty $layers -Name $exe -ErrorAction SilentlyContinue
    }
}

throw ("Mode launch inconnu: " + $mode)
