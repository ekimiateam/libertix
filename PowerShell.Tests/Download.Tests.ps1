BeforeAll {
    . "$PSScriptRoot/../Scripts/uefi/Libertix.Uefi.Downloads.ps1"
}

Describe "aria2 download arguments" {
    It "pins a root-volume download to the dedicated staging directory" {
        $script:Aria2Connections = 4
        $arguments = New-Aria2DownloadArguments `
            -Url "https://example.test/mint.iso" `
            -DownloadDir "C:\LibertixTools\downloads" `
            -DestinationName "mint.iso"

        $arguments | Should -Contain "--dir=C:\LibertixTools\downloads"
        $arguments | Should -Contain "--out=mint.iso"
        $arguments[-1] | Should -Be "https://example.test/mint.iso"
    }

    It "uses one non-resumable connection when the server cannot honor ranges" {
        $arguments = New-Aria2DownloadArguments `
            -Url "https://example.test/live.iso" `
            -DownloadDir "C:\LibertixTools\downloads" `
            -DestinationName "live.iso" `
            -Connections 1 `
            -ContinueDownload $false

        $arguments | Should -Contain "--continue=false"
        $arguments | Should -Contain "--max-connection-per-server=1"
        $arguments | Should -Contain "--split=1"
    }

    It "accepts only an exact one-byte partial response as range support" {
        Test-ExactSingleByteContentRange 206 "bytes 0-0/524288000" | Should -BeTrue
        Test-ExactSingleByteContentRange 200 "" | Should -BeFalse
        Test-ExactSingleByteContentRange 206 "bytes 0-524287999/524288000" |
            Should -BeFalse
    }

    It "retains a partial download when the range probe cannot reach the server" {
        $script:Aria2Connections = 4
        Mock Get-Aria2Exe { "C:\fake\aria2c.exe" }
        Mock Get-HttpByteRangeSupport { "unknown" }
        $destination = Join-Path $TestDrive "partial.iso"
        [IO.File]::WriteAllBytes($destination, [byte[]](1, 2, 3, 4))

        {
            Start-Aria2Download `
                -Url "https://example.test/live.iso" `
                -Destination $destination `
                -MaxBytes 1GB
        } | Should -Throw "*partial download is retained*"

        [Convert]::ToBase64String([IO.File]::ReadAllBytes($destination)) |
            Should -Be "AQIDBA=="
    }

    It "extracts the percentage from an aria2 progress summary" {
        Get-Aria2DownloadPercent `
            -Line "[#094339 1.4GiB/3.6GiB(38%) CN:5 DL:2.4MiB ETA:15m50s]" |
            Should -Be 38
    }

    It "ignores aria2 output without a valid percentage" {
        Get-Aria2DownloadPercent -Line "Download Results:" | Should -BeNullOrEmpty
        Get-Aria2DownloadPercent -Line "[#094339 3.6GiB/3.6GiB(101%)]" |
            Should -BeNullOrEmpty
    }
}
