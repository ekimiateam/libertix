BeforeAll {
    $script:deviceBlocks = @()
    foreach ($name in @('inspect_installation_rollback_state.ps1', 'verify_installation_rollback.ps1')) {
        $path = Join-Path $PSScriptRoot "../auto_tests/app/scripts/$name"
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        if ($errors.Count -ne 0) { throw ($errors | Out-String) }
        $block = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.ForEachStatementAst] -and
                $node.Variable.VariablePath.UserPath -eq 'elementType'
        }, $true)
        if ($null -eq $block) { throw "Qualified boot device comparison missing: $name" }
        $script:deviceBlocks += [scriptblock]::Create($block.Extent.Text)
    }
}

Describe 'Rollback boot device evidence' {
    It 'retains identities of both normal loader device elements' {
        foreach ($block in $script:deviceBlocks) {
            $rawLoader = [pscustomobject]@{ Id = '{11111111-1111-1111-1111-111111111111}' }
            $loader = [pscustomobject]@{ Identity = 'original-partition'; DeviceType = 6 }
            $loader | Add-Member ScriptMethod GetElement {
                param($elementType)
                return [pscustomobject]@{ ReturnValue = $true; Element = [pscustomobject]@{
                    Device = [pscustomobject]@{ DeviceType = $this.DeviceType }
                } }
            }
            $loader | Add-Member ScriptMethod GetElementWithFlags {
                param($elementType, $flags)
                if ($flags -ne 1) { throw 'The qualified flag is required.' }
                return [pscustomobject]@{ ReturnValue = $true; Element = [pscustomobject]@{
                    Device = [pscustomobject]@{ DeviceType = $this.DeviceType; PartitionStyle = 1
                        DiskSignature = 'disk'; PartitionIdentifier = $this.Identity }
                } }
            }
            $ramdiskPartitions = @()
            . $block
            $ramdiskPartitions.Count | Should -Be 2
            $before = ConvertTo-Json -InputObject $ramdiskPartitions -Compress
            $loader.Identity = 'replacement-partition'
            $ramdiskPartitions = @()
            . $block
            (ConvertTo-Json -InputObject $ramdiskPartitions -Compress) | Should -Not -BeExactly $before
            $loader.DeviceType = 2
            { . $block } | Should -Throw '*remained unqualified*'
            $loader.DeviceType = 4
            $loader | Add-Member ScriptMethod GetElementWithFlags { throw 'Ramdisk cannot be qualified directly' } -Force
            $ramdiskPartitions = @()
            . $block
            $ramdiskPartitions.Count | Should -Be 0
        }
    }
}
