BeforeAll {
    Import-Module `
        "$PSScriptRoot/../Scripts/modules/Libertix.BootGuardian.psm1" `
        -Force
}

Describe "Boot guardian installation contract" {
    It "hashes UEFI load-option bytes without relying on a temporary file" {
        InModuleScope Libertix.BootGuardian {
            $bytes = [Text.Encoding]::ASCII.GetBytes("boot-entry")
            Get-LibertixBootGuardianByteHash -Bytes $bytes |
                Should -Be "d774f351c08e20a74d3bbce90faa29d682ba7b85de4a0a2e906756691f323341"
        }
    }

    It "publishes configuration JSON atomically and can replace it" {
        InModuleScope Libertix.BootGuardian -Parameters @{ Root = $TestDrive } {
            param($Root)

            $path = Join-Path $Root "guardian\config.json"
            Write-LibertixBootGuardianJsonAtomic `
                -Path $path `
                -Value ([ordered]@{ version = 1; mode = "first" })
            Write-LibertixBootGuardianJsonAtomic `
                -Path $path `
                -Value ([ordered]@{ version = 1; mode = "second" })

            $value = Get-Content -LiteralPath $path -Raw -Encoding UTF8 |
                ConvertFrom-Json
            $value.mode | Should -Be "second"
            @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -Force).Count |
                Should -Be 1
        }
    }

    It "captures native exit codes explicitly under strict module scope" {
        InModuleScope Libertix.BootGuardian {
            Mock Start-Process {
                [pscustomobject]@{ ExitCode = 37 }
            }

            Invoke-LibertixBootGuardianCommand `
                -Executable "C:\ProgramData\Libertix\BootGuardian\guardian.exe" `
                -Argument "--repair-now" |
                Should -Be 37
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq "C:\ProgramData\Libertix\BootGuardian\guardian.exe" -and
                $ArgumentList -eq "--repair-now" -and
                $Wait -and
                $PassThru -and
                $WindowStyle -eq "Hidden"
            }
        }
    }

    It "accepts only an exact ESP ownership marker for the current run" {
        InModuleScope Libertix.BootGuardian -Parameters @{ Root = $TestDrive } {
            param($Root)

            $runId = "0123456789abcdef0123456789abcdef"
            $espRoot = Join-Path $Root "esp"
            $marker = Join-Path $espRoot "EFI\Libertix\.libertix-owner"
            New-Item -ItemType Directory -Path (Split-Path -Parent $marker) -Force |
                Out-Null
            @(
                $runId
                "0007"
                "1"
                "11111111-2222-3333-4444-555555555555"
                "\EFI\Libertix\shimx64.efi"
            ) | Set-Content -LiteralPath $marker -Encoding UTF8
            $state = [pscustomobject]@{ RunId = $runId }
            $partition = [pscustomobject]@{
                PartitionNumber = 1
                Guid = "11111111-2222-3333-4444-555555555555"
            }

            $owner = Get-LibertixBootGuardianOwnerMarker `
                -State $state `
                -EspPartition $partition `
                -EspRoot $espRoot
            $owner.BootNumber | Should -Be 7

            (Get-Content -LiteralPath $marker -Raw).Replace($runId, ("f" * 32)) |
                Set-Content -LiteralPath $marker -Encoding UTF8 -NoNewline
            {
                Get-LibertixBootGuardianOwnerMarker `
                    -State $state `
                    -EspPartition $partition `
                    -EspRoot $espRoot
            } | Should -Throw "*ownership marker is invalid*"
        }
    }
}
