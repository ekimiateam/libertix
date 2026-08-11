BeforeAll {
    $stagingPath = Join-Path $PSScriptRoot "../Scripts/uefi/Libertix.Uefi.Staging.ps1"
    . $stagingPath
}

Describe "UEFI BootOrder normalization" {
    It "preserves an empty BootOrder as an empty UInt16 array" {
        [uint16[]]$result = ConvertTo-LibertixBootOrderArray -Order @()

        $result.GetType().FullName | Should -Be "System.UInt16[]"
        $result.Count | Should -Be 0
    }

    It "preserves a one-entry BootOrder as a one-element UInt16 array" {
        [uint16[]]$result = ConvertTo-LibertixBootOrderArray -Order ([uint16]7)

        $result.GetType().FullName | Should -Be "System.UInt16[]"
        $result.Count | Should -Be 1
        $result[0] | Should -Be 7
    }

    It "preserves the order and type of multiple BootOrder entries" {
        [uint16[]]$result = ConvertTo-LibertixBootOrderArray -Order @(3, 9, 12)

        $result.GetType().FullName | Should -Be "System.UInt16[]"
        $result.Count | Should -Be 3
        $result | Should -Be @(3, 9, 12)
    }
}
