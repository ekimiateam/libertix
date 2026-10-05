Set-StrictMode -Version Latest

$script:AtomicPublishAttempts = 8
$script:AtomicPublishRetryDelayMilliseconds = 100
$script:TransientPublishErrorCodes = @(
    5,    # ERROR_ACCESS_DENIED
    32,   # ERROR_SHARING_VIOLATION
    33,   # ERROR_LOCK_VIOLATION
    1175, # ERROR_UNABLE_TO_REMOVE_REPLACED
    1176, # ERROR_UNABLE_TO_MOVE_REPLACEMENT
    1177  # ERROR_UNABLE_TO_MOVE_REPLACEMENT_2
)

# Compiled only when a lock outlasts every retry, so normal writes pay nothing.
$script:FileLockReportSource = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace Libertix
{
    // Asks the Windows Restart Manager which processes currently hold a file open.
    public static class FileLockReport
    {
        private const int ErrorMoreData = 234;
        private const int SessionKeyLength = 32;
        private const int MaxAppNameLength = 255;
        private const int MaxServiceNameLength = 63;

        [StructLayout(LayoutKind.Sequential)]
        private struct RmUniqueProcess
        {
            public int ProcessId;
            public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct RmProcessInfo
        {
            public RmUniqueProcess Process;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = MaxAppNameLength + 1)]
            public string AppName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = MaxServiceNameLength + 1)]
            public string ServiceShortName;
            public int ApplicationType;
            public uint AppStatus;
            public uint SessionId;
            [MarshalAs(UnmanagedType.Bool)]
            public bool Restartable;
        }

        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        private static extern int RmStartSession(
            out uint sessionHandle, int sessionFlags, StringBuilder sessionKey);

        [DllImport("rstrtmgr.dll")]
        private static extern int RmEndSession(uint sessionHandle);

        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        private static extern int RmRegisterResources(
            uint sessionHandle, uint fileCount, string[] fileNames,
            uint applicationCount, IntPtr applications,
            uint serviceCount, string[] serviceNames);

        [DllImport("rstrtmgr.dll")]
        private static extern int RmGetList(
            uint sessionHandle, out uint processInfoNeeded, ref uint processInfoCount,
            [In, Out] RmProcessInfo[] processInfo, out uint rebootReasons);

        public static string[] Describe(string path)
        {
            uint session;
            int result = RmStartSession(out session, 0, new StringBuilder(SessionKeyLength + 1));
            if (result != 0)
                throw new Win32Exception(result);
            try
            {
                result = RmRegisterResources(session, 1, new[] { path }, 0, IntPtr.Zero, 0, null);
                if (result != 0)
                    throw new Win32Exception(result);

                uint needed;
                uint count = 0;
                uint rebootReasons;
                RmProcessInfo[] processes = null;
                result = RmGetList(session, out needed, ref count, processes, out rebootReasons);
                // The holder list can grow between the size query and the read.
                while (result == ErrorMoreData)
                {
                    processes = new RmProcessInfo[needed];
                    count = needed;
                    result = RmGetList(session, out needed, ref count, processes, out rebootReasons);
                }
                if (result != 0)
                    throw new Win32Exception(result);

                var holders = new List<string>();
                for (int index = 0; index < count; index++)
                {
                    RmProcessInfo holder = processes[index];
                    holders.Add(string.Format(
                        "pid={0} image={1} app={2} service={3} session={4}",
                        holder.Process.ProcessId,
                        GetImageName(holder.Process.ProcessId),
                        holder.AppName,
                        holder.ServiceShortName,
                        holder.SessionId));
                }
                return holders.ToArray();
            }
            finally
            {
                RmEndSession(session);
            }
        }

        private static string GetImageName(int processId)
        {
            try
            {
                using (Process process = Process.GetProcessById(processId))
                    return process.ProcessName;
            }
            catch (ArgumentException)
            {
                return "exited";
            }
        }
    }
}
'@

function Get-LibertixFileLockReport {
    # Returns a one-line description for error messages and never throws, so the
    # diagnostic cannot replace the failure that is being reported.
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        if (-not ('Libertix.FileLockReport' -as [type])) {
            Add-Type -TypeDefinition $script:FileLockReportSource -ErrorAction Stop
        }
        $holders = @([Libertix.FileLockReport]::Describe([IO.Path]::GetFullPath($Path)))
        if ($holders.Count -eq 0) {
            return "no process reported by Restart Manager"
        }
        return $holders -join "; "
    } catch {
        return "holder lookup failed: $($_.Exception.Message)"
    }
}

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

    $clock = [Diagnostics.Stopwatch]::StartNew()
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
            if (-not (Test-LibertixTransientAtomicPublishFailure -Exception $_.Exception)) {
                throw
            }
            if ($attempt -ge $script:AtomicPublishAttempts) {
                # Keep the original error as the inner exception and name the processes
                # still holding the file, so a recurring lock can be traced to its owner.
                $message = (
                    "Atomic publication of '{0}' still failed after {1} attempts over {2} ms: " +
                    "{3} Destination holders: {4}. Temporary file holders: {5}."
                ) -f @(
                    $destinationFullPath,
                    $attempt,
                    $clock.ElapsedMilliseconds,
                    $_.Exception.Message,
                    (Get-LibertixFileLockReport -Path $destinationFullPath),
                    (Get-LibertixFileLockReport -Path $temporaryFullPath)
                )
                throw [IO.IOException]::new($message, $_.Exception)
            }
            # Antivirus and indexers can briefly lock a JSON document after a
            # reader closes it. Replaying the same-directory rename is atomic.
            Start-Sleep -Milliseconds ($script:AtomicPublishRetryDelayMilliseconds * $attempt)
        }
    }
}

Export-ModuleMember -Function Publish-LibertixFileAtomic, Get-LibertixFileLockReport
