Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.StorageGeometry.psm1" -Force

Describe "Windows free-space stabilization" {
    InModuleScope Libertix.StorageGeometry {
        It "waits for a small transient deficit without lowering the accepted floor" {
            $script:measurements = @([int64](27.75GB), [int64](28.25GB))
            $script:measurementIndex = 0
            Mock Get-Volume {
                $value = $script:measurements[
                    [Math]::Min($script:measurementIndex, $script:measurements.Count - 1)
                ]
                $script:measurementIndex++
                [pscustomobject]@{ SizeRemaining = $value }
            }
            Mock Start-Sleep {}

            $budget = Wait-LibertixWindowsFreeSpaceBudget `
                -DriveLetter C `
                -AllocationBytes ([int64](20GB)) `
                -TimeoutSeconds 60

            $budget.Accepted | Should -BeTrue
            $budget.AcceptedFloorBytes | Should -Be ([int64](28GB))
            Should -Invoke Start-Sleep -Times 1 -Exactly
        }

        It "accepts bounded managed-file growth while keeping the ten GiB target" {
            $budget = Get-LibertixWindowsFreeSpaceBudget `
                -AvailableBytes ([int64](28.75GB)) `
                -AllocationBytes ([int64](20GB))

            $budget.Accepted | Should -BeTrue
            $budget.WithinTolerance | Should -BeTrue
            $budget.RequiredBytes | Should -Be ([int64](30GB))
            $budget.AcceptedFloorBytes | Should -Be ([int64](28GB))
        }

        It "counts only a verified transaction artifact as reclaimable capacity" {
            $budget = Get-LibertixWindowsFreeSpaceBudget `
                -AvailableBytes ([int64](27.75GB)) `
                -AllocationBytes ([int64](20GB)) `
                -ReclaimableArtifactBytes ([int64](3.5GB))

            $budget.Accepted | Should -BeTrue
            $budget.AvailableBytes | Should -Be ([int64](27.75GB))
            $budget.ReclaimableArtifactBytes | Should -Be ([int64](3.5GB))
            $budget.EffectiveAvailableBytes | Should -Be ([int64](31.25GB))
            $budget.RequiredBytes | Should -Be ([int64](30GB))
        }

        It "rejects a material deficit immediately" {
            Mock Get-Volume { [pscustomobject]@{ SizeRemaining = [int64](25GB) } }
            Mock Start-Sleep {}

            $budget = Wait-LibertixWindowsFreeSpaceBudget `
                -DriveLetter C `
                -AllocationBytes ([int64](20GB)) `
                -TimeoutSeconds 60

            $budget.Accepted | Should -BeFalse
            $budget.AcceptedFloorBytes | Should -Be ([int64](28GB))
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }
    }
}

Describe "Temporary drive-letter allocation" {
    InModuleScope Libertix.StorageGeometry {
        It "prefers Z and falls back without reusing an occupied letter" {
            Mock Get-Volume {
                @(
                    [pscustomobject]@{ DriveLetter = "Z" },
                    [pscustomobject]@{ DriveLetter = "C" }
                )
            }
            Mock Get-PSDrive { @() }
            Mock Test-Path { $false }

            Get-LibertixFreeDriveLetter | Should -Be "Y"
            Get-LibertixFreeDriveLetter -ExcludedLetters @("Y") | Should -Be "X"
        }
    }
}
