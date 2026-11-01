BeforeAll {
    $path = Join-Path (Split-Path -Parent $PSScriptRoot) "auto_tests/app/scripts/focus_post_install_result.ps1"
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { throw $errors[0] }
    $source = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
        $node.Value -match 'public static class LibertixTestKeyboard'
    }, $true)
    Add-Type -TypeDefinition $source.Value -ErrorAction Stop
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
}

Describe "Interactive keyboard evidence reads the identified window thread" {
    It "resolves a real window keyboard and restores the worker thread keyboard" {
        $form = New-Object Windows.Forms.Form
        $getter = [LibertixTestKeyboard].GetMethod('GetKeyboardLayout',
            [Reflection.BindingFlags]'NonPublic,Static')
        try {
            $handle = $form.Handle
            $before = $getter.Invoke($null, @([uint32]0))
            $identifier = [LibertixTestKeyboard]::Read($handle, $PID)
            $identifier | Should -Match '^[0-9A-Fa-f]{8}$'
            $getter.Invoke($null, @([uint32]0)) | Should -Be $before
        } finally {
            $form.Dispose()
        }
    }

    It "rejects a window belonging to another process than the claimed target" {
        $form = New-Object Windows.Forms.Form
        try {
            { [LibertixTestKeyboard]::Read($form.Handle, 0) } | Should -Throw '*changed owner*'
            { [LibertixTestKeyboard]::Read([IntPtr]::Zero, $PID) } | Should -Throw '*changed owner*'
        } finally {
            $form.Dispose()
        }
    }
}
