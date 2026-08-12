$modulePath = Join-Path `
    $PSScriptRoot `
    "..\Scripts\modules\Libertix.TemporaryArtifacts.psm1"
Import-Module -Name $modulePath -Force

Describe "Libertix temporary artifact ownership" {
    BeforeEach {
        & subst.exe T: $TestDrive
        if ($LASTEXITCODE -ne 0) {
            throw "Could not map the Pester test directory to T:."
        }
    }

    AfterEach {
        & subst.exe T: /D
    }

    It "resolves transaction downloads under the plan-owned ProgramData directory" {
        $planId = "a" * 32
        Get-LibertixTransactionDownloadRoot -SystemDrive "T:" -PlanId $planId |
            Should -Be ([IO.Path]::GetFullPath(
                "T:\ProgramData\Libertix\Downloads\$planId"
            ))
    }

    It "removes only the selected transaction download directory" {
        $planId = "a" * 32
        $otherPlanId = "b" * 32
        $owned = "T:\ProgramData\Libertix\Downloads\$planId"
        $other = "T:\ProgramData\Libertix\Downloads\$otherPlanId"
        New-Item -ItemType Directory -Path $owned, $other -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $owned "linux.iso") -Value "owned"
        Set-Content -LiteralPath (Join-Path $other "linux.iso") -Value "other"

        Remove-LibertixTransactionDownloads -SystemDrive "T:" -PlanId $planId

        Test-Path -LiteralPath $owned | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $other "linux.iso") | Should -BeTrue
    }

    It "removes known UEFI tools but preserves an unknown file" {
        $toolRoot = "T:\LibertixTools"
        New-Item -ItemType Directory -Path (Join-Path $toolRoot "aria2") -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $toolRoot "uefi-transaction.json") -Value "{}"
        Set-Content -LiteralPath (Join-Path $toolRoot "keep.txt") -Value "unknown"

        Remove-LibertixUefiToolArtifacts -SystemDrive "T:"

        Test-Path -LiteralPath (Join-Path $toolRoot "aria2") | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $toolRoot "uefi-transaction.json") |
            Should -BeFalse
        Test-Path -LiteralPath (Join-Path $toolRoot "keep.txt") | Should -BeTrue
    }

    It "can remove helper tools while preserving the active transaction owner" {
        $toolRoot = "T:\LibertixTools"
        New-Item -ItemType Directory -Path (Join-Path $toolRoot "aria2") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $toolRoot "downloads") -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $toolRoot "uefi-transaction.json") -Value "{}"

        Remove-LibertixUefiToolArtifacts `
            -SystemDrive "T:" `
            -PreserveTransactionState

        Test-Path -LiteralPath (Join-Path $toolRoot "aria2") | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $toolRoot "downloads") | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $toolRoot "uefi-transaction.json") |
            Should -BeTrue
    }
}
