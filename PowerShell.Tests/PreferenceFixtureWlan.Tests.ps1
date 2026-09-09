BeforeAll {
    $path = Join-Path $PSScriptRoot '../auto_tests/app/scripts/configure_windows_preference_fixture.ps1'
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw 'The preference fixture did not parse.' }
    $function = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Start-PreferenceFixtureWlan'
    }, $false)
    . ([scriptblock]::Create($function.Extent.Text))
}

Describe 'Preference fixture WLAN readiness' {
    BeforeEach {
        $script:service = [pscustomobject]@{ Status = 'Stopped'; Waited = $false }
        $script:service | Add-Member ScriptMethod WaitForStatus {
            param($status, $timeout)
            if ($status -ne 'Running' -or $timeout.TotalSeconds -ne 20) {
                throw 'Unexpected service wait contract.'
            }
            $this.Waited = $true
        }
        Mock Get-Service { $script:service }
        Mock Start-Service { $script:service.Status = 'Running' }
    }

    It 'starts only WLAN and checks readiness with a bounded wait' {
        Start-PreferenceFixtureWlan
        $script:service.Waited | Should -BeTrue
        Should -Invoke Start-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'WlanSvc' }
        Should -Invoke Get-Service -Times 2 -Exactly -ParameterFilter { $Name -eq 'WlanSvc' }
    }

    It 'does not restart an already running service' {
        $script:service.Status = 'Running'
        Start-PreferenceFixtureWlan
        $script:service.Waited | Should -BeFalse
        Should -Invoke Start-Service -Times 0 -Exactly
    }

    It 'does not report readiness when the service stops again' {
        Mock Start-Service { }
        { Start-PreferenceFixtureWlan } | Should -Throw '*requires a running WLAN*'
    }

    It 'propagates a disabled or failed service instead of hiding missing Wi-Fi evidence' {
        Mock Start-Service { throw 'SERVICE_DISABLED' }
        { Start-PreferenceFixtureWlan } | Should -Throw '*SERVICE_DISABLED*'
        $script:service.Waited | Should -BeFalse
    }

    It 'propagates the bounded wait timeout' {
        $script:service | Add-Member ScriptMethod WaitForStatus { throw 'WAIT_TIMEOUT' } -Force
        { Start-PreferenceFixtureWlan } | Should -Throw '*WAIT_TIMEOUT*'
    }
}
