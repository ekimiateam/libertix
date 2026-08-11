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
