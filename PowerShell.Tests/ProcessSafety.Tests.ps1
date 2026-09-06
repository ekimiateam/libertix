BeforeAll {
    Import-Module (Join-Path $PSScriptRoot "..\Scripts\modules\Libertix.Process.psm1") -Force
    $path = Join-Path $PSScriptRoot "../Scripts/modules/Libertix.PostInstallVerification.psm1"
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    $function = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Register-LibertixWindowsBootVolumeCheck"
    }, $true)
    . ([scriptblock]::Create($function.Extent.Text))
}

Describe "Native process termination safety" {
    It "schedules CHKDSK through the bounded process helper and verifies BootExecute" {
        Mock Test-Path { $true }
        Mock Invoke-LibertixNativeCommand {
            [pscustomobject]@{ ExitCode = 0; StandardOutput = "scheduled"; StandardError = "" }
        }
        Mock Get-ItemProperty { [pscustomobject]@{ BootExecute = @('autocheck autochk /p \??\C:') } }
        Register-LibertixWindowsBootVolumeCheck -SystemDrive "C:" -WriteLog { param($line) }
        Should -Invoke Invoke-LibertixNativeCommand -Exactly -Times 1 -ParameterFilter {
            $TimeoutSeconds -eq 120 -and $ArgumentList[0] -eq "C:" -and
            $StandardInputText -eq "Y`r`nO`r`nS`r`n"
        }
    }

    It "rejects an unproved CHKDSK schedule despite exit zero" {
        Mock Test-Path { $true }
        Mock Invoke-LibertixNativeCommand {
            [pscustomobject]@{ ExitCode = 0; StandardOutput = ""; StandardError = "" }
        }
        Mock Get-ItemProperty { [pscustomobject]@{ BootExecute = @('autocheck autochk *') } }
        { Register-LibertixWindowsBootVolumeCheck -SystemDrive "C:" -WriteLog { param($line) } } |
            Should -Throw '*did not register*'
    }

    It "passes bounded stdin and closes it so the child can finish" {
        $result = Invoke-LibertixNativeCommand -FilePath "powershell.exe" `
            -ArgumentList @("-NoProfile", "-NonInteractive", "-Command", '[Console]::Write([Console]::In.ReadToEnd())') `
            -TimeoutSeconds 5 -StandardInputText "Y`r`nO`r`nS`r`n"
        @($result).Count | Should -Be 1
        $result.ExitCode | Should -Be 0
        $result.StandardOutput.Trim() | Should -Be "Y`r`nO`r`nS"
    }

    It "times out a continuously writing child" {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        {
            Invoke-LibertixNativeCommand -FilePath "powershell.exe" `
                -ArgumentList @("-NoProfile", "-NonInteractive", "-Command", 'while ($true) { [Console]::WriteLine("progress"); Start-Sleep -Milliseconds 1 }') `
                -TimeoutSeconds 1
        } | Should -Throw '*timed out*'
        $timer.Elapsed.TotalSeconds | Should -BeLessThan 5
    }

    It "bounds inherited output pipes after the parent has exited" {
        $pidFile = Join-Path $TestDrive "inherited-pipe-child.pid"
        $childCode = "[IO.File]::WriteAllText('" + $pidFile.Replace("'", "''") + "', [string]" +
            '$PID); Start-Sleep -Seconds 10'
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCode))
        $parentCode = '$i=New-Object Diagnostics.ProcessStartInfo; $i.FileName="powershell.exe"; ' +
            '$i.Arguments="-NoProfile -NonInteractive -EncodedCommand ' + $encoded + '"; ' +
            '$i.UseShellExecute=$false; $i.CreateNoWindow=$true; $null=[Diagnostics.Process]::Start($i)'
        $timer = [Diagnostics.Stopwatch]::StartNew()
        try {
            {
                Invoke-LibertixNativeCommand -FilePath "powershell.exe" `
                    -ArgumentList @("-NoProfile", "-NonInteractive", "-Command", $parentCode) `
                    -TimeoutSeconds 2
            } | Should -Throw '*exited but an inherited output stream remains open*'
            Test-Path -LiteralPath $pidFile | Should -BeTrue
            $timer.Elapsed.TotalSeconds | Should -BeLessThan 6
        } finally {
            if (Test-Path -LiteralPath $pidFile) {
                $child = Get-Process -Id ([int](Get-Content -LiteralPath $pidFile -Raw)) -ErrorAction SilentlyContinue
                if ($child) {
                    if (-not $child.HasExited) { $child.Kill(); $null = $child.WaitForExit(5000) }
                    $child.Dispose()
                }
            }
        }
    }

    It "bounds a hung taskkill helper and never reports an unproven tree as stopped" {
        $helper = Join-Path $TestDrive "hung-taskkill.exe"
        Add-Type -TypeDefinition 'public static class HungTaskKill { public static void Main() { System.Threading.Thread.Sleep(10000); } }' `
            -OutputAssembly $helper -OutputType ConsoleApplication
        $child = Start-Process powershell.exe -ArgumentList '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 10"' -WindowStyle Hidden -PassThru
        try {
            InModuleScope Libertix.Process -Parameters @{ helper = $helper; child = $child } {
                param($helper, $child)
                Mock Get-LibertixNativeSystemExecutable { $helper }
                $timer = [Diagnostics.Stopwatch]::StartNew()
                Stop-LibertixNativeProcessTree -Process $child -TimeoutSeconds 1 | Should -BeFalse
                $timer.Elapsed.TotalSeconds | Should -BeLessThan 3
            }
        } finally {
            if (-not $child.HasExited) { $child.Kill(); $null = $child.WaitForExit(5000) }
            $child.Dispose()
        }
    }

    It "propagates an unverified descendant as a blocking failure" {
        {
            Invoke-LibertixNativeCommand -FilePath "powershell.exe" `
                -ArgumentList @("-NoProfile", "-NonInteractive", "-Command", "exit 173") `
                -TimeoutSeconds 30
        } | Should -Throw "*PROCESS_TREE_NOT_STOPPED*"
    }

    It "does not treat an ordinary exit failure as an unknown process tree" {
        $result = Invoke-LibertixNativeCommand -FilePath "powershell.exe" `
            -ArgumentList @("-NoProfile", "-NonInteractive", "-Command", "exit 1") `
            -TimeoutSeconds 30
        $result.ExitCode | Should -Be 1
    }

    It "preserves stderr warnings from a successful child" {
        $result = Invoke-LibertixNativeCommand -FilePath "powershell.exe" `
            -ArgumentList @("-NoProfile", "-NonInteractive", "-Command", '[Console]::Error.WriteLine("warning"); exit 0') `
            -TimeoutSeconds 30
        $result.ExitCode | Should -Be 0
        $result.StandardError | Should -Match "warning"
    }

    It "preserves a start failure without querying an unstarted process" {
        {
            Invoke-LibertixNativeCommand -FilePath (Join-Path $TestDrive "absent.exe") `
                -TimeoutSeconds 30
        } | Should -Throw
    }

    It "stops a live child when the output callback fails" {
        $childId = [Collections.Generic.List[int]]::new()
        $callback = {
            param($Line)
            $childId.Add([int]$Line)
            throw "CALLBACK_FAILED"
        }
        {
            Invoke-LibertixNativeCommand -FilePath "powershell.exe" `
                -ArgumentList @("-NoProfile", "-NonInteractive", "-Command", 'Write-Output $PID; Start-Sleep -Seconds 20') `
                -TimeoutSeconds 30 -OnStandardOutputLine $callback
        } | Should -Throw "*CALLBACK_FAILED*"
        $childId.Count | Should -Be 1
        Get-Process -Id $childId[0] -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}
