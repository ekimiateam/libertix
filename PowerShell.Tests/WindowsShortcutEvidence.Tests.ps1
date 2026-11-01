BeforeAll {
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        "$PSScriptRoot/../auto_tests/app/scripts/post_install_windows_check.ps1", [ref]$null, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    foreach ($name in @('Assert-Condition', 'Get-RegisteredLinuxShortcuts')) {
        $functionAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }
}

Describe 'Independent shortcut evidence for relocated profiles' {
    BeforeEach {
        Mock Get-CimInstance {
            [pscustomobject]@{ SID = 'S-1-5-21-1-2-3-1001'; LocalPath = 'D:\People\Alice[1]'; Special = $false }
        }
        Mock Test-Path { $true }
        Mock Get-Item { [pscustomobject]@{ FullName = $LiteralPath } }
    }

    It 'checks the actual registered profile instead of C Users' {
        $shortcuts = @(Get-RegisteredLinuxShortcuts -LinuxUsername 'test')
        $shortcuts.Count | Should -Be 1
        $shortcuts[0].FullName | Should -BeExactly 'D:\People\Alice[1]\Links\Linux_test_read-only.lnk'
    }

    It 'fails when a relocated profile lacks its shortcut' {
        Mock Test-Path { $PathType -ne 'Leaf' }
        { Get-RegisteredLinuxShortcuts -LinuxUsername 'test' } | Should -Throw '*missing*'
    }

    It 'never accepts a shortcut for a different Linux account' {
        Mock Test-Path { ([string]$LiteralPath) -notlike '*Linux_test_read-only.lnk' }
        { Get-RegisteredLinuxShortcuts -LinuxUsername 'test' } | Should -Throw '*missing*'
    }

    It 'does not query profile directories for an unsafe Linux account' {
        { Get-RegisteredLinuxShortcuts -LinuxUsername '..\test' } | Should -Throw '*Invalid*'
        Should -Invoke Get-CimInstance -Times 0
    }
}
