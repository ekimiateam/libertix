BeforeAll {
    $path = Join-Path $PSScriptRoot "../auto_tests/app/scripts/configure_windows_preference_fixture.ps1"
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
    $functions = $ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -in @("New-PreferenceFixtureImages", "Set-PreferenceFixtureImageAccess")
    }, $true)
    foreach ($function in $functions) { . ([scriptblock]::Create($function.Extent.Text)) }
}

Describe "Preference migration image fixture" {
    It "grants image read access to the actual user without changing parent or unrelated ACLs" {
        $wallpaper = Join-Path $TestDrive "public-wallpaper.jpg"
        $account = Join-Path $TestDrive "public-account.png"
        $unrelated = Join-Path $TestDrive "private-state.json"
        [IO.File]::WriteAllText($unrelated, "{}")
        New-PreferenceFixtureImages -WallpaperPath $wallpaper -AccountImagePath $account
        $parentBefore = (Get-Acl $TestDrive).Sddl
        $unrelatedBefore = (Get-Acl $unrelated).Sddl
        $sid = "S-1-5-21-123456789-234567890-345678901-1001"
        Set-PreferenceFixtureImageAccess -Paths @($wallpaper, $account) -UserSid $sid
        Set-PreferenceFixtureImageAccess -Paths @($wallpaper, $account) -UserSid $sid
        foreach ($path in @($wallpaper, $account)) {
            $rules = @((Get-Acl $path).GetAccessRules($true, $false,
                [Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -eq $sid })
            $rules.Count | Should -Be 1
            ($rules[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::Read) |
                Should -Be ([Security.AccessControl.FileSystemRights]::Read)
            ($rules[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write) | Should -Be 0
        }
        (Get-Acl $TestDrive).Sddl | Should -Be $parentBefore
        (Get-Acl $unrelated).Sddl | Should -Be $unrelatedBefore
    }

    It "creates decodable colored images rather than a black or malformed placeholder" {
        $wallpaper = Join-Path $TestDrive "wallpaper.jpg"
        $account = Join-Path $TestDrive "account.png"
        New-PreferenceFixtureImages -WallpaperPath $wallpaper -AccountImagePath $account
        foreach ($path in @($wallpaper, $account)) {
            $image = [Drawing.Bitmap]::new($path)
            try {
                $image.Width | Should -Be 1280
                $image.Height | Should -Be 720
                $image.GetPixel(100, 100).B | Should -BeGreaterThan 150
                $image.GetPixel(1040, 160).R | Should -BeGreaterThan 200
                $image.GetPixel(100, 100).ToArgb() |
                    Should -Not -Be ($image.GetPixel(1040, 160).ToArgb())
            }
            finally { $image.Dispose() }
        }
    }
}
