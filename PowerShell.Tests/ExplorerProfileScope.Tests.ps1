BeforeAll {
    $tokens = $null; $errors = $null
    $path = Join-Path $PSScriptRoot "../Scripts/libertix-configure-windows-share.ps1"
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    $function = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Install-ExplorerShortcuts"
    }, $true)
    . ([scriptblock]::Create($function.Extent.Text))
    function Get-RealWindowsProfiles {}
    function Write-ShareLog { param($Message) }
}

Describe "Explorer shortcuts use the task user's profile" {
    BeforeEach {
        $script:profiles = @(
            [pscustomobject]@{ SID = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; LocalPath = 'C:\Users\Current' },
            [pscustomobject]@{ SID = 'S-1-5-21-1-2-3-1002'; LocalPath = 'C:\Users\Other' }
        )
        $script:shortcuts = @{}
        $script:QuickAccessNamespace = 'test namespace'
        $script:fakeShell = [pscustomobject]@{}
        $script:fakeShell | Add-Member -MemberType ScriptMethod -Name CreateShortcut -Value {
            param($path)
            if (-not $script:shortcuts.ContainsKey($path)) {
                $link = [pscustomobject]@{ TargetPath = ''; Description = '' }
                $link | Add-Member -MemberType ScriptMethod -Name Save -Value {}
                $script:shortcuts[$path] = $link
            }
            return $script:shortcuts[$path]
        }
        $script:fakeExplorer = [pscustomobject]@{}
        $script:fakeExplorer | Add-Member -MemberType ScriptMethod -Name Namespace -Value {
            param($path)
            $folder = [pscustomobject]@{}
            $folder | Add-Member -MemberType ScriptMethod -Name Items -Value {
                return @([pscustomobject]@{ Path = 'C:\Users\Current\Linux_test_read-only' })
            }
            return $folder
        }
        Mock Get-RealWindowsProfiles { $script:profiles }
        Mock New-Object { $script:fakeShell } -ParameterFilter { $ComObject -eq 'WScript.Shell' }
        Mock New-Object { $script:fakeExplorer } -ParameterFilter { $ComObject -eq 'Shell.Application' }
        Mock New-Item {}
        Mock Test-Path { $true }
        Mock Get-Item { [pscustomobject]@{ Attributes = [IO.FileAttributes]::ReparsePoint } }
        $script:config = [pscustomobject]@{ LinuxUsername = 'test'; ShortcutDescription = 'Linux read-only' }
    }

    It "does not write another user's Links directory during logon pinning" {
        Install-ExplorerShortcuts -Config $script:config -LinuxHome 'L:\home\test' -CurrentUserOnly
        @($script:shortcuts.Keys).Count | Should -Be 1
        $script:shortcuts.ContainsKey('C:\Users\Current\Links\Linux_test_read-only.lnk') | Should -BeTrue
        Should -Invoke New-Item -Times 0 -ParameterFilter { $Path -like '*Other*' }
    }

    It "retains machine-wide shortcut preparation for the mount task" {
        Install-ExplorerShortcuts -Config $script:config -LinuxHome 'L:\home\test'
        @($script:shortcuts.Keys).Count | Should -Be 2
    }

    It "rejects an ambiguous current profile before writing any shortcut" {
        $script:profiles[1].SID = $script:profiles[0].SID
        { Install-ExplorerShortcuts -Config $script:config -LinuxHome 'L:\home\test' -CurrentUserOnly } |
            Should -Throw '*missing or ambiguous*'
        @($script:shortcuts.Keys).Count | Should -Be 0
    }
}
