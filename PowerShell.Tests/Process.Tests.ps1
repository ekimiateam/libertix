$modulePath = Join-Path $PSScriptRoot "..\Scripts\modules\Libertix.Process.psm1"
Import-Module -Name $modulePath -Force

Describe "Libertix native process output" {
    It "delivers stdout lines while the process is still running" {
        $markerPath = Join-Path $TestDrive "callback.received"
        $childPath = Join-Path $TestDrive "streaming-child.ps1"
        @'
param([Parameter(Mandatory = $true)][string]$MarkerPath)
Write-Output "progress=25%"
$deadline = [DateTime]::UtcNow.AddSeconds(5)
while (-not (Test-Path -LiteralPath $MarkerPath) -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 50
}
if (-not (Test-Path -LiteralPath $MarkerPath)) {
    exit 9
}
Write-Output "progress=100%"
'@ | Set-Content -LiteralPath $childPath -Encoding UTF8

        $received = [Collections.Generic.List[string]]::new()
        $onOutput = {
            param([string]$Line)
            $received.Add($Line)
            if ($Line -eq "progress=25%") {
                Set-Content -LiteralPath $markerPath -Value "received" -NoNewline
            }
        }
        $arguments = @(
            "-NoProfile",
            "-NonInteractive",
            "-File",
            (ConvertTo-LibertixNativeArgument -Value $childPath),
            (ConvertTo-LibertixNativeArgument -Value $markerPath)
        ) -join " "

        $result = Invoke-LibertixNativeProcess `
            -FilePath "powershell.exe" `
            -Arguments $arguments `
            -TimeoutSeconds 30 `
            -OnStandardOutputLine $onOutput

        $result.ExitCode | Should -Be 0
        $received | Should -Be @("progress=25%", "progress=100%")
        $result.StandardOutput | Should -Match "progress=25%"
        $result.StandardOutput | Should -Match "progress=100%"
    }
}
