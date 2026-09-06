BeforeAll {
    $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot "../auto_tests/app/clients/ssh.py") -Raw
    $match = [regex]::Match($source, '(?s)function Read-NativeOutputText \{\{.*?(?=\r?\n\$payload =)')
    if (-not $match.Success) { throw "SSH output reader was not found." }
    . ([scriptblock]::Create($match.Value.Replace('{{', '{').Replace('}}', '}')))
    function ConvertFrom-NativeOutputBytes {
        param([byte[]]$Bytes)
        return [Text.Encoding]::UTF8.GetString($Bytes)
    }
    if (-not ('LibertixSshDrainFixture' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Threading;
public static class LibertixSshDrainFixture {
    public static Thread FinishOutput(FileStream stream) {
        var worker = new Thread(() => {
            try {
                Thread.Sleep(150);
                byte[] bytes = Encoding.UTF8.GetBytes("final output");
                stream.Write(bytes, 0, bytes.Length);
            } finally { stream.Dispose(); }
        });
        worker.IsBackground = true;
        worker.Start();
        return worker;
    }
}
'@
    }
}

Describe "SSH output drain after native process exit" {
    It "waits for the writer to close and retains its final output" {
        $path = Join-Path $TestDrive "delayed.out"
        $stream = [IO.File]::Open($path, 'Create', 'Write', 'Read')
        $worker = [LibertixSshDrainFixture]::FinishOutput($stream)
        try {
            $result = Read-NativeOutputText -LiteralPath $path `
                -DrainClock ([Diagnostics.Stopwatch]::StartNew()) -DrainTimeoutMilliseconds 3000
            $result | Should -Be "final output"
        } finally {
            $worker.Join(5000) | Out-Null
        }
    }

    It "fails within the deadline when the writer never releases the file" {
        $path = Join-Path $TestDrive "locked.out"
        $stream = [IO.File]::Open($path, 'Create', 'Write', 'Read')
        $clock = [Diagnostics.Stopwatch]::StartNew()
        try {
            { Read-NativeOutputText -LiteralPath $path -DrainClock $clock -DrainTimeoutMilliseconds 100 } |
                Should -Throw '*SSH output drain timed out*'
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 3
        } finally {
            $stream.Dispose()
        }
    }

    It "uses the already consumed shared deadline for the second stream" {
        $path = Join-Path $TestDrive "stderr.out"
        $stream = [IO.File]::Open($path, 'Create', 'Write', 'Read')
        try {
            { Read-NativeOutputText -LiteralPath $path `
                -DrainClock ([Diagnostics.Stopwatch]::StartNew()) -DrainTimeoutMilliseconds 0 } |
                Should -Throw '*SSH output drain timed out*'
        } finally {
            $stream.Dispose()
        }
    }
}
