BeforeAll {
    $source = Join-Path $PSScriptRoot "../auto_tests/app/scripts/inject_stale_firmware_entry.ps1"
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
    $function = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Get-FirmwareFixtureScripts"
    }, $true)
    . ([scriptblock]::Create($function.Extent.Text))
    Add-Type -AssemblyName System.IO.Compression

    function New-TestFirmwareExecutable {
        param([string]$Root, [bool]$BadHash)
        [IO.Directory]::CreateDirectory($Root) | Out-Null
        $zip = Join-Path $Root "Libertix.Standalone.Payload.zip"
        $stream = [IO.File]::Create($zip)
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create)
        $records = @()
        try {
            foreach ($name in @("Scripts/modules/Libertix.Firmware.psm1", "Scripts/uefi/Libertix.Uefi.Firmware.ps1")) {
                $bytes = [Text.Encoding]::UTF8.GetBytes("function Test-Fixture { 'read-only fixture' }")
                $entry = $archive.CreateEntry($name).Open()
                try { $entry.Write($bytes, 0, $bytes.Length) } finally { $entry.Dispose() }
                $sha = [Security.Cryptography.SHA256]::Create()
                try { $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant() }
                finally { $sha.Dispose() }
                if ($BadHash) { $hash = '0' * 64 }
                $records += @{ path = $name; size = $bytes.Length; sha256 = $hash }
            }
        } finally { $archive.Dispose(); $stream.Dispose() }
        $manifest = Join-Path $Root "Libertix.Standalone.PayloadManifest.json"
        @{ schemaVersion = 1; files = $records } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifest -Encoding UTF8
        $compiler = [CodeDom.Compiler.CompilerParameters]::new()
        $compiler.GenerateExecutable = $false
        $compiler.OutputAssembly = Join-Path $Root ("Fixture" + [guid]::NewGuid().ToString('N') + ".dll")
        [void]$compiler.EmbeddedResources.Add($zip)
        [void]$compiler.EmbeddedResources.Add($manifest)
        $provider = [Microsoft.CSharp.CSharpCodeProvider]::new()
        try {
            $compiled = $provider.CompileAssemblyFromSource($compiler, "public class Fixture {}")
            if ($compiled.Errors.HasErrors) { throw ($compiled.Errors | Out-String) }
            [IO.File]::Copy($compiler.OutputAssembly, (Join-Path $Root "Libertix.exe"))
        } finally { $provider.Dispose() }
    }
}

Describe "Firmware fixture with standalone releases" {
    It "reads and verifies embedded helpers without starting the application or extracting scripts" {
        $root = Join-Path $TestDrive "valid"
        New-TestFirmwareExecutable -Root $root -BadHash $false
        $scripts = Get-FirmwareFixtureScripts -ReleaseRoot $root
        $scripts.Count | Should -Be 2
        $scripts["Scripts/modules/Libertix.Firmware.psm1"] | Should -Match "read-only fixture"
        Test-Path (Join-Path $root "Scripts") | Should -BeFalse
    }

    It "refuses a modified embedded firmware helper" {
        $root = Join-Path $TestDrive "tampered"
        New-TestFirmwareExecutable -Root $root -BadHash $true
        { Get-FirmwareFixtureScripts -ReleaseRoot $root } | Should -Throw "*hash is invalid*"
    }

    It "keeps unpacked development releases supported" {
        $root = Join-Path $TestDrive "unpacked"
        foreach ($name in @("Scripts/modules/Libertix.Firmware.psm1", "Scripts/uefi/Libertix.Uefi.Firmware.ps1")) {
            $path = Join-Path $root $name
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
            Set-Content -LiteralPath $path -Value 'function Test-Fixture {}'
        }
        (Get-FirmwareFixtureScripts -ReleaseRoot $root).Count | Should -Be 2
    }
}
