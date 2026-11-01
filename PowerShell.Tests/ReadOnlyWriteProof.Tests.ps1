BeforeDiscovery {
    $cases = foreach ($source in @(
        'Scripts/libertix-configure-windows-share.ps1',
        'Scripts/modules/Libertix.PostInstallVerification.psm1',
        'auto_tests/app/scripts/post_install_windows_check.ps1'
    )) {
        foreach ($code in @(19, 5, 1117)) {
            @{ Source = $source; NativeCode = $code }
        }
    }
    $readCases = @(
        @{ Source = 'Scripts/libertix-configure-windows-share.ps1' },
        @{ Source = 'Scripts/modules/Libertix.PostInstallVerification.psm1' }
    )
}

BeforeAll {
    function Write-ShareLog { param($Message) }
    function Assert-Condition {
        param([bool]$Condition, [string]$Message)
        if (-not $Condition) { throw $Message }
    }
    function Get-WriteProbeBlock {
        param([string]$Source)
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot "../$Source"), [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw ($errors | Out-String) }
        $blocks = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.TryStatementAst] -and
            $node.Body.Statements.Count -gt 0 -and
            $node.Body.Statements[0].Extent.Text -match '^Set-Content -LiteralPath \$(?:writeProbe|probe) '
        }, $true))
        if ($blocks.Count -ne 1) { throw 'The write-proof block is missing or ambiguous.' }
        return [scriptblock]::Create($blocks[0].Extent.Text)
    }
    function Get-ReadableFileFunction {
        param([string]$Source)
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot "../$Source"), [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw ($errors | Out-String) }
        $functions = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Test-LibertixFileHasReadableContent'
        }, $true))
        if ($functions.Count -ne 1) { throw 'The asynchronous read helper is missing or ambiguous.' }
        return [scriptblock]::Create($functions[0].Extent.Text)
    }
}

Describe 'Read-only write proof classifies the real filesystem error' {
    BeforeEach {
        Mock Remove-Item {}
        Mock Set-Content {
            throw [IO.IOException]::new('Synthetic filesystem refusal', $script:probeHresult)
        }
    }

    It '<Source> accepts only write protection, not native error <NativeCode>' -ForEach $cases {
        $script:probeHresult = [int]0x80070000 -bor [int]$NativeCode
        $probe = $writeProbe = Join-Path $TestDrive 'not-written'
        $accepted = $writeAccepted = $writeSucceeded = $false
        $block = Get-WriteProbeBlock -Source $Source
        if ($NativeCode -eq 19) {
            { & $block } | Should -Not -Throw
        } else {
            { & $block } | Should -Throw
        }
        Should -Invoke Set-Content -Times 1 -Exactly
        Should -Invoke Remove-Item -Times 0
    }
}

Describe 'Read-only mount readability uses an asynchronous file handle' {
    It '<Source> reads content without a synchronous File helper' -ForEach $readCases {
        $definition = Get-ReadableFileFunction -Source $Source
        $definition.ToString() | Should -Match 'FileStream'
        $definition.ToString() | Should -Match 'ReadAsync'
        $definition.ToString() | Should -Not -Match 'ReadAllText'
        . $definition
        $contentPath = Join-Path $TestDrive 'content.txt'
        $emptyPath = Join-Path $TestDrive 'empty.txt'
        [IO.File]::WriteAllText($contentPath, 'x')
        [IO.File]::WriteAllBytes($emptyPath, [byte[]]@())
        Test-LibertixFileHasReadableContent -Path $contentPath | Should -BeTrue
        Test-LibertixFileHasReadableContent -Path $emptyPath | Should -BeFalse
    }
}
