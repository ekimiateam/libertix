Set-StrictMode -Version Latest

$script:AtomicPublishAttempts = 8
$script:TransientPublishErrorCodes = @(
    5,    # ERROR_ACCESS_DENIED
    32,   # ERROR_SHARING_VIOLATION
    33,   # ERROR_LOCK_VIOLATION
    1175, # ERROR_UNABLE_TO_REMOVE_REPLACED
    1176, # ERROR_UNABLE_TO_MOVE_REPLACEMENT
    1177  # ERROR_UNABLE_TO_MOVE_REPLACEMENT_2
)

function Test-LibertixTransientAtomicPublishFailure {
    param([Parameter(Mandatory = $true)][Exception]$Exception)

    $candidate = $Exception
    while ($null -ne $candidate) {
        if ($candidate -is [IO.IOException] -or $candidate -is [UnauthorizedAccessException]) {
            $win32Code = $candidate.HResult -band 0xFFFF
            return $win32Code -in $script:TransientPublishErrorCodes
        }
        $candidate = $candidate.InnerException
    }
    return $false
}

function Publish-LibertixFileAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TemporaryPath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][string]$BackupPath
    )

    $temporaryFullPath = [IO.Path]::GetFullPath($TemporaryPath)
    $destinationFullPath = [IO.Path]::GetFullPath($DestinationPath)
    $backupFullPath = [IO.Path]::GetFullPath($BackupPath)
    $destinationDirectory = [IO.Path]::GetDirectoryName($destinationFullPath)
    if (
        [IO.Path]::GetDirectoryName($temporaryFullPath) -ne $destinationDirectory -or
        [IO.Path]::GetDirectoryName($backupFullPath) -ne $destinationDirectory
    ) {
        throw "Atomic publication paths must share the destination directory."
    }
    if (-not [IO.File]::Exists($temporaryFullPath)) {
        throw "Atomic publication temporary file does not exist: $temporaryFullPath"
    }

    for ($attempt = 1; $attempt -le $script:AtomicPublishAttempts; $attempt++) {
        try {
            if ([IO.File]::Exists($destinationFullPath)) {
                # Windows PowerShell 5.1 can bind a null backup path incorrectly
                # on .NET Framework. A same-directory backup keeps Replace atomic.
                [IO.File]::Replace($temporaryFullPath, $destinationFullPath, $backupFullPath)
            } else {
                [IO.File]::Move($temporaryFullPath, $destinationFullPath)
            }
            return
        } catch {
            if (
                $attempt -ge $script:AtomicPublishAttempts -or
                -not (Test-LibertixTransientAtomicPublishFailure -Exception $_.Exception)
            ) {
                throw
            }
            # Antivirus and indexers can briefly lock a JSON document after a
            # reader closes it. Replaying the same-directory rename is atomic.
            Start-Sleep -Milliseconds (25 * $attempt)
        }
    }
}

Export-ModuleMember -Function Publish-LibertixFileAtomic
