#requires -Version 5.1

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$scriptCases = @(
    Get-ChildItem -LiteralPath (Join-Path $repositoryRoot "auto_tests\app\scripts") `
        -Filter "*.ps1" `
        -File |
        ForEach-Object {
            @{
                Name = $_.Name
                Path = $_.FullName
            }
        }
)

Describe "Auto-test PowerShell syntax" {
    It "parses <Name> with Windows PowerShell 5.1 syntax" -TestCases $scriptCases {
        param($Name, $Path)

        $tokens = $null
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile(
            $Path,
            [ref]$tokens,
            [ref]$errors
        )
        @($errors).Count | Should -Be 0
    }
}
