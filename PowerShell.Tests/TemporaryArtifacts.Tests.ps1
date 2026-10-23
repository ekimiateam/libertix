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

Describe "Libertix distribution ISO reuse" {
    BeforeEach {
        # TestDrive persists across the It blocks of one Describe, so clear the
        # previous test's downloads and recovery owners before arranging this one.
        foreach ($leftover in @("ProgramData", "LibertixInstallRecovery")) {
            Remove-Item -LiteralPath (Join-Path $TestDrive $leftover) -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
        & subst.exe T: $TestDrive
        if ($LASTEXITCODE -ne 0) {
            throw "Could not map the Pester test directory to T:."
        }
        Mock -ModuleName Libertix.TemporaryArtifacts Get-ScheduledTask { $null }
        $script:planId = "a" * 32
        $script:orphanId = "b" * 32
        $script:orphan = "T:\ProgramData\Libertix\Downloads\$orphanId\linux.iso"
        $script:destination = "T:\ProgramData\Libertix\Downloads\$planId\linux.iso"
        New-Item -ItemType Directory -Path (Split-Path -Parent $orphan) -Force | Out-Null
        Set-Content -LiteralPath $orphan -Value "verified iso" -NoNewline
        $script:hash = (Get-FileHash -LiteralPath $orphan -Algorithm SHA256).Hash
        $script:invokeReuse = {
            param([string]$Sha256 = $script:hash)
            Move-LibertixReusableDistributionIso `
                -SystemDrive "T:" `
                -PlanId $script:planId `
                -FileName "linux.iso" `
                -Sha256 $Sha256 `
                -MinimumBytes 0 `
                -MaximumBytes 1KB
        }
    }

    AfterEach {
        & subst.exe T: /D
    }

    It "moves a verified ISO out of an orphaned plan directory" {
        & $invokeReuse | Should -Be $orphan

        Test-Path -LiteralPath $destination | Should -BeTrue
        Test-Path -LiteralPath $orphan | Should -BeFalse
    }

    It "skips an unfinished aria2 download" {
        Set-Content -LiteralPath "$orphan.aria2" -Value "control"

        & $invokeReuse | Should -BeNullOrEmpty
        Test-Path -LiteralPath $orphan | Should -BeTrue
        Test-Path -LiteralPath $destination | Should -BeFalse
    }

    It "leaves an ISO whose hash does not match in place" {
        & $invokeReuse -Sha256 ("0" * 64) | Should -BeNullOrEmpty
        Test-Path -LiteralPath $orphan | Should -BeTrue
        Test-Path -LiteralPath $destination | Should -BeFalse
    }

    It "skips a plan that still has UEFI recovery state" {
        New-Item -ItemType Directory -Path "T:\ProgramData\Libertix\UefiRecovery\$orphanId" -Force |
            Out-Null

        & $invokeReuse | Should -BeNullOrEmpty
        Test-Path -LiteralPath $orphan | Should -BeTrue
        Test-Path -LiteralPath $destination | Should -BeFalse
    }

    It "skips a plan that still has a UEFI recovery task" {
        Mock -ModuleName Libertix.TemporaryArtifacts Get-ScheduledTask {
            if ($TaskName -eq "LibertixUefiRecoveryPrompt_$orphanId") { [pscustomobject]@{} }
        }

        & $invokeReuse | Should -BeNullOrEmpty
        Test-Path -LiteralPath $orphan | Should -BeTrue
        Test-Path -LiteralPath $destination | Should -BeFalse
    }

    It "respects the BIOS recovery owner and refuses an unreadable one" {
        New-Item -ItemType Directory -Path "T:\LibertixInstallRecovery" -Force | Out-Null
        & $invokeReuse | Should -BeNullOrEmpty
        Test-Path -LiteralPath $destination | Should -BeFalse

        Set-Content -LiteralPath "T:\LibertixInstallRecovery\pending.env" -Value "PLAN_ID=$orphanId"
        & $invokeReuse | Should -BeNullOrEmpty
        Test-Path -LiteralPath $destination | Should -BeFalse

        Set-Content -LiteralPath "T:\LibertixInstallRecovery\pending.env" -Value ("PLAN_ID=" + "c" * 32)
        & $invokeReuse | Should -Be $orphan
    }
}
