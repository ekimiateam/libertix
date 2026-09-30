# Runs one cmd.exe payload for SSHClient.run with a hard timeout on Windows.
# Python fills in the payload and timeout markers below before sending it.
# The native exit status is captured separately so PowerShell cannot replace it with
# the status of the output-drain commands.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$utf8NoBom = New-Object Text.UTF8Encoding($false)
$strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

# Native tools such as sfc.exe write UTF-16 without a BOM when redirected, while others
# use the OEM code page; decode each case explicitly instead of trusting one encoding.
function ConvertFrom-NativeOutputBytes {
    param([byte[]]$Bytes)

    if ($null -eq $Bytes -or $Bytes.Length -eq 0) {
        return ''
    }

    if ($Bytes.Length -ge 4 -and
        $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE -and
        $Bytes[2] -eq 0x00 -and $Bytes[3] -eq 0x00) {
        return [Text.Encoding]::UTF32.GetString($Bytes, 4, $Bytes.Length - 4)
    }

    if ($Bytes.Length -ge 4 -and
        $Bytes[0] -eq 0x00 -and $Bytes[1] -eq 0x00 -and
        $Bytes[2] -eq 0xFE -and $Bytes[3] -eq 0xFF) {
        $utf32BigEndian = New-Object Text.UTF32Encoding($true, $false, $true)
        return $utf32BigEndian.GetString($Bytes, 4, $Bytes.Length - 4)
    }

    if ($Bytes.Length -ge 3 -and
        $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return $utf8NoBom.GetString($Bytes, 3, $Bytes.Length - 3)
    }

    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return [Text.Encoding]::Unicode.GetString($Bytes, 2, $Bytes.Length - 2)
    }

    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        return [Text.Encoding]::BigEndianUnicode.GetString($Bytes, 2, $Bytes.Length - 2)
    }

    $sampleLength = [Math]::Min($Bytes.Length, 4096)
    $pairCount = [Math]::Floor($sampleLength / 2)
    if ($pairCount -gt 0) {
        $evenNulls = 0
        $oddNulls = 0
        for ($index = 0; $index -lt ($pairCount * 2); $index += 2) {
            if ($Bytes[$index] -eq 0) { $evenNulls++ }
            if ($Bytes[$index + 1] -eq 0) { $oddNulls++ }
        }
        $nullThreshold = [Math]::Max(2, [Math]::Floor($pairCount / 4))
        if ($oddNulls -ge $nullThreshold -and $oddNulls -gt ($evenNulls * 2)) {
            return [Text.Encoding]::Unicode.GetString($Bytes)
        }
        if ($evenNulls -ge $nullThreshold -and $evenNulls -gt ($oddNulls * 2)) {
            return [Text.Encoding]::BigEndianUnicode.GetString($Bytes)
        }
    }

    # Native tools without a BOM may still emit OEM-encoded output.
    try {
        return $strictUtf8.GetString($Bytes)
    } catch [Text.DecoderFallbackException] {
        $oemCodePage = [Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
        return [Text.Encoding]::GetEncoding($oemCodePage).GetString($Bytes)
    }
}

function Read-NativeOutputText {
    param(
        [string]$LiteralPath,
        [Diagnostics.Stopwatch]$DrainClock,
        [int]$DrainTimeoutMilliseconds = 10000
    )

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        return ''
    }

    # Timed WaitForExit does not wait for Start-Process output handlers to close files.
    while ($true) {
        try {
            return ConvertFrom-NativeOutputBytes ([IO.File]::ReadAllBytes($LiteralPath))
        } catch [IO.IOException] {
            $nativeError = $_.Exception.HResult -band 0xFFFF
            if ($nativeError -notin @(32, 33)) { throw }
            if ($DrainClock.ElapsedMilliseconds -ge $DrainTimeoutMilliseconds) {
                throw "SSH output drain timed out: $LiteralPath remained locked."
            }

            Start-Sleep -Milliseconds 25
        }
    }
}

$payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PAYLOAD_BASE64__'))
$timeoutMilliseconds = [int]'__TIMEOUT_MILLISECONDS__'
$root = Join-Path $env:TEMP ('libertix-ssh-' + [Guid]::NewGuid().ToString('N'))
$commandPath = $root + '.cmd'
$stdoutPath = $root + '.out'
$stderrPath = $root + '.err'
$statusPath = $root + '.status'
$exitCode = 1
try {
    $commandText = (
        "@echo off`r`n" +
        "chcp 65001 >nul`r`n" +
        $payload +
        "`r`necho %ERRORLEVEL% > `"$statusPath`"`r`n"
    )
    [IO.File]::WriteAllText($commandPath, $commandText, [Text.Encoding]::Default)

    $startArguments = @{
        FilePath = $env:ComSpec
        ArgumentList = @('/d', '/s', '/c', ('"' + $commandPath + '"'))
        PassThru = $true
        WindowStyle = 'Hidden'
        RedirectStandardOutput = $stdoutPath
        RedirectStandardError = $stderrPath
    }
    $process = Start-Process @startArguments
    if (-not $process.WaitForExit($timeoutMilliseconds)) {
        $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
        & $taskkill /PID $process.Id /T /F 2>&1 | Out-Null
        $taskkillExitCode = $LASTEXITCODE
        $process.WaitForExit(10000) | Out-Null
        if ($taskkillExitCode -ne 0 -or -not $process.HasExited) {
            $exitCode = 125
        } else {
            $exitCode = 124
        }
    } else {
        $reportedExitCode = 0
        $statusText = if (Test-Path -LiteralPath $statusPath) {
            (Get-Content -LiteralPath $statusPath -Raw).Trim()
        } else {
            ''
        }
        if (-not [int]::TryParse($statusText, [ref]$reportedExitCode)) {
            $exitCode = 126
        } else {
            $exitCode = $reportedExitCode
        }
    }
    $outputDrainClock = [Diagnostics.Stopwatch]::StartNew()
    if (Test-Path -LiteralPath $stdoutPath) {
        [Console]::Out.Write((Read-NativeOutputText -LiteralPath $stdoutPath `
            -DrainClock $outputDrainClock))
    }
    if (Test-Path -LiteralPath $stderrPath) {
        [Console]::Error.Write((Read-NativeOutputText -LiteralPath $stderrPath `
            -DrainClock $outputDrainClock))
    }
} finally {
    $temporaryPaths = @($commandPath, $stdoutPath, $stderrPath, $statusPath)
    Remove-Item -LiteralPath $temporaryPaths -Force -ErrorAction SilentlyContinue
}
exit $exitCode
