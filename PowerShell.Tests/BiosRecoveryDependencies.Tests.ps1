BeforeAll {
    $repository = Split-Path -Parent $PSScriptRoot
    $source = Get-Content (Join-Path $repository 'Pages/ApplyChanges.Windows.cs') -Raw
    $start = $source.IndexOf('private async Task<bool> InstallWindowsRecoveryGuardAsync')
    $end = $source.IndexOf('private async Task<double> QueryShrinkSpaceAsync', $start)
    $method = $source.Substring($start, $end - $start)
    $moduleNames = @([regex]::Matches($method, '"(Libertix\.[A-Za-z.]+\.psm1)"') |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $moduleSource = Join-Path $repository 'Scripts/modules'

    function Invoke-IsolatedRecoveryImport {
        param([string]$Root)
        $session = [powershell]::Create()
        try {
            $null = $session.AddScript({
                param($Root)
                $ErrorActionPreference = 'Stop'
                Import-Module (Join-Path $Root 'Libertix.PostInstallVerification.psm1') -Force
                Import-Module (Join-Path $Root 'Libertix.Rollback.psm1') -Force
                Import-Module (Join-Path $Root 'Libertix.Process.psm1') -Force
                $null = Get-Command Invoke-LibertixPostInstallVerification -ErrorAction Stop
                $null = Get-Command Restore-LibertixSystemDriveInitialSize -ErrorAction Stop
                & (Get-Module Libertix.PostInstallVerification) {
                    $null = Get-Command Assert-LibertixDiskMatchesPlan -ErrorAction Stop
                }
                'RECOVERY_IMPORT_OK'
            }).AddArgument($Root)
            $output = $session.Invoke()
            if ($session.HadErrors) { throw [string]$session.Streams.Error[0] }
            $output
        } finally {
            $session.Dispose()
        }
    }
}

Describe 'UEFI preparation module scope' {
    It 'retains the storage commands after importing the full executor dependency list' {
        $session = [powershell]::Create()
        try {
            $null = $session.AddScript({
                param($Root)
                $ErrorActionPreference = 'Stop'
                $tokens = $null
                $errors = $null
                $ast = [Management.Automation.Language.Parser]::ParseFile(
                    (Join-Path $Root 'Scripts/libertix-uefi-install.ps1'), [ref]$tokens, [ref]$errors)
                $assignment = $ast.Find({
                    param($node)
                    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                        $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                        $node.Left.VariablePath.UserPath -eq 'requiredModules'
                }, $true)
                . ([scriptblock]::Create($assignment.Extent.Text))
                foreach ($name in $requiredModules) {
                    Import-Module (Join-Path $Root "Scripts/modules/$name") -Force
                }
                foreach ($command in @('Get-LibertixVerifiedInstallationTarget',
                    'Get-LibertixNtfsVolumeSerial', 'Get-LibertixTargetVolumeEncryptionSnapshot',
                    'Restore-LibertixSourceVolumeInitialSize', 'Publish-LibertixFileAtomic')) {
                    $null = Get-Command $command -ErrorAction Stop
                }
                'UEFI_IMPORT_OK'
            }).AddArgument($repository)
            $result = $session.Invoke()
            if ($session.HadErrors) { throw [string]$session.Streams.Error[0] }
            @($result) | Should -Contain 'UEFI_IMPORT_OK'
        } finally {
            $session.Dispose()
        }
    }
}

Describe 'BIOS recovery payload module dependencies' {
    It 'loads verification from only the modules copied by the Windows preparation' {
        $root = Join-Path $TestDrive 'complete'
        New-Item -ItemType Directory -Path $root | Out-Null
        $moduleNames | Should -Contain 'Libertix.Rollback.psm1'
        $moduleNames | Should -Contain 'Libertix.StorageTargets.psm1'
        foreach ($name in $moduleNames) {
            Copy-Item -LiteralPath (Join-Path $moduleSource $name) -Destination $root
        }
        @(Invoke-IsolatedRecoveryImport -Root $root) | Should -Contain 'RECOVERY_IMPORT_OK'
    }

    It 'reproduces the missing dependency failure without loading modules from the source tree' {
        $root = Join-Path $TestDrive 'missing-dependency'
        New-Item -ItemType Directory -Path $root | Out-Null
        foreach ($name in $moduleNames) {
            if ($name -ne 'Libertix.Rollback.psm1') {
                Copy-Item -LiteralPath (Join-Path $moduleSource $name) -Destination $root
            }
        }
        { Invoke-IsolatedRecoveryImport -Root $root } | Should -Throw '*Libertix.Rollback.psm1*'
    }
}
