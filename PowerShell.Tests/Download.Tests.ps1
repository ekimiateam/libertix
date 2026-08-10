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
}
