BeforeAll {
    $tokens = $null; $errors = $null
    $path = Join-Path $PSScriptRoot "../Scripts/libertix-uefi-recovery-agent.ps1"
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    $guard = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -eq '[string]$state.Phase -eq "FallbackProcessStateUnknown"'
    }, $true))
    if ($guard.Count -ne 1) { throw "Expected exactly one recovery process-state guard." }
    $script:GuardCode = [scriptblock]::Create($guard[0].Extent.Text)
}

Describe "Recovery process-state interlock" {
    It "blocks every recovery action without changing an unknown state" {
        $state = [pscustomobject]@{ Phase = "FallbackProcessStateUnknown" }
        { & $script:GuardCode } | Should -Throw '*previous process tree was not proven stopped*'
        $state.Phase | Should -Be "FallbackProcessStateUnknown"
    }

    It "allows a known recovery phase" {
        $state = [pscustomobject]@{ Phase = "FallbackPrompted" }
        { & $script:GuardCode } | Should -Not -Throw
    }
}
