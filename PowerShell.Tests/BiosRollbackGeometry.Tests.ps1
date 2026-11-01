BeforeAll {
    $path = Join-Path $PSScriptRoot "..\Scripts\libertix-recovery-guard.ps1"
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    $function = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Test-RecoveryRawPartitionGeometry"
    }, $true)
    . ([scriptblock]::Create($function.Extent.Text))
}

Describe "BIOS rollback raw partition geometry" {
    It "accepts the grown ext4 partition without a Windows Volume at size <Size>" -TestCases @(
        @{ Size = 20GB }
        @{ Size = 20GB - 1MB }
    ) {
        param($Size)
        Test-RecoveryRawPartitionGeometry -Partition @{ Offset = 80GB; Size = $Size } `
            -FinalOffset 80GB -FinalSize 20GB -StagingSize 8GB -Alignment 1MB |
            Should -BeTrue
    }

    It "preserves rollback before filesystem creation" {
        Test-RecoveryRawPartitionGeometry -Partition @{ Offset = 92GB; Size = 8GB } `
            -FinalOffset 80GB -FinalSize 20GB -StagingSize 8GB -Alignment 1MB |
            Should -BeTrue
    }

    It "rejects an unowned final extent at offset <Offset> and size <Size>" -TestCases @(
        @{ Offset = 80GB + 1MB; Size = 20GB }
        @{ Offset = 80GB; Size = 20GB + 1MB }
        @{ Offset = 80GB; Size = 20GB - 2MB }
        @{ Offset = 80GB; Size = 10GB }
    ) {
        param($Offset, $Size)
        Test-RecoveryRawPartitionGeometry -Partition @{ Offset = $Offset; Size = $Size } `
            -FinalOffset 80GB -FinalSize 20GB -StagingSize 8GB -Alignment 1MB |
            Should -BeFalse
    }
}
