BeforeAll {
    $path = Join-Path (Split-Path -Parent $PSScriptRoot) "auto_tests/app/scripts/post_install_windows_check.ps1"
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { throw $errors[0] }
    foreach ($name in @("Assert-Condition", "Assert-RecoveryLocation")) {
        $function = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        . ([scriptblock]::Create($function.Extent.Text))
    }
}

Describe "Recovery verification inspects the preserved partition without repairing it" {
    BeforeEach {
        $plan = [pscustomobject]@{ disk = [pscustomobject]@{
            uniqueId = "test-disk"
            recovery = [pscustomobject]@{ offsetBytes = 1000000; sizeBytes = 500000 }
        } }
        Mock Get-Disk { [pscustomobject]@{ UniqueId = "test-disk" } }
        Mock Get-Partition { [pscustomobject]@{ Offset = 1000000; Size = 500000 } }
    }

    It "resolves the configured partition independently of localized labels" {
        Assert-RecoveryLocation -Plan $plan -ReagentOutput 'Emplacement Windows RE : \\?\GLOBALROOT\device\harddisk0\partition4\Recovery\WindowsRE'
        Should -Invoke Get-Disk -Times 1 -Exactly -ParameterFilter { @($Number).Count -eq 1 -and $Number[0] -eq 0 }
        Should -Invoke Get-Partition -Times 1 -Exactly -ParameterFilter {
            @($DiskNumber).Count -eq 1 -and $DiskNumber[0] -eq 0 -and
            @($PartitionNumber).Count -eq 1 -and $PartitionNumber[0] -eq 4
        }
    }

    It "rejects an absent or ambiguous location" {
        { Assert-RecoveryLocation -Plan $plan -ReagentOutput 'Windows RE location:' } | Should -Throw '*no unique*'
        $line = '\\?\GLOBALROOT\device\harddisk0\partition4\Recovery\WindowsRE'
        { Assert-RecoveryLocation -Plan $plan -ReagentOutput ($line + "`n" + $line) } | Should -Throw '*no unique*'
    }

    It "rejects another disk with the same partition size" {
        Mock Get-Disk { [pscustomobject]@{ UniqueId = "another-disk" } }
        { Assert-RecoveryLocation -Plan $plan -ReagentOutput '\\?\GLOBALROOT\device\harddisk1\partition4\Recovery\WindowsRE' } |
            Should -Throw '*outside the preserved*'
    }

    It "rejects changed recovery geometry" {
        Mock Get-Partition { [pscustomobject]@{ Offset = 1000000; Size = 400000 } }
        { Assert-RecoveryLocation -Plan $plan -ReagentOutput '\\?\GLOBALROOT\device\harddisk0\partition4\Recovery\WindowsRE' } |
            Should -Throw '*outside the preserved*'
    }
}
