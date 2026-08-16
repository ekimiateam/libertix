BeforeDiscovery {
    Import-Module `
        "$PSScriptRoot/../Scripts/modules/Libertix.PostInstallVerification.psm1" `
        -Force
}

BeforeAll {
    Import-Module `
        "$PSScriptRoot/../Scripts/modules/Libertix.PostInstallVerification.psm1" `
        -Force
}

Describe "Post-install Linux boot evidence" {
    BeforeEach {
        $script:Plan = [pscustomobject]@{
            planId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            createdAtUtc = "2026-08-11T10:00:00Z"
            firmware = "uefi"
            distribution = [pscustomobject]@{
                id = "zorin"
                osReleaseId = "zorin"
            }
            runtime = [pscustomobject]@{
                recoveryRunId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            }
            account = [pscustomobject]@{
                username = "test"
            }
            disk = [pscustomobject]@{
                installer = [pscustomobject]@{
                    offsetBytes = 107374182400
                    finalOffsetBytes = 107374182400
                    finalSizeBytes = 42949672960
                    resizeMode = "windows-online"
                }
            }
        }
        $script:Evidence = [pscustomobject]@{
            schemaVersion = 1
            planId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            recoveryRunId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            observedAtUtc = "2026-08-11T10:15:00Z"
            bootId = "11111111-2222-3333-4444-555555555555"
            firmware = "uefi"
            distribution = [pscustomobject]@{
                id = "zorin"
                osReleaseId = "zorin"
            }
            root = [pscustomobject]@{
                filesystem = "ext4"
                offsetBytes = 107374182400
                sizeBytes = 42949672960
                plannedSizeBytes = 42949672960
                alignmentToleranceBytes = 1048576
                uuid = "11111111-2222-3333-4444-555555555555"
            }
            system = [pscustomobject]@{
                rootReadWrite = $true
                fstabRootUuid = "11111111-2222-3333-4444-555555555555"
                machineIdSha256 = "c" * 64
                username = "test"
                sudoMember = $true
                passwordActive = $true
                dpkgAuditClean = $true
                failedSystemdUnits = 0
            }
            grub = [pscustomobject]@{
                syntaxValid = $true
                requiredEntriesPresent = $true
                configSha256 = "b" * 64
                runningKernel = "6.8.0-test"
                bootChain = [pscustomobject]@{
                    verified = $true
                    type = "uefi-boot-current"
                    bootNumber = "0007"
                    entry = [pscustomobject]@{
                        description = "Libertix"
                        partitionNumber = 1
                        partitionGuid = "11111111-2222-3333-4444-555555555555"
                        loaderPath = "\EFI\Libertix\shimx64.efi"
                    }
                }
            }
        }
    }

    It "accepts evidence tied to UEFI BootCurrent" {
        {
            Assert-LibertixLinuxBootEvidence `
                -Evidence $script:Evidence `
                -Plan $script:Plan `
                -AlignmentBytes 1048576
        } | Should -Not -Throw
    }

    It "rejects evidence from a direct Windows boot" {
        $script:Evidence.grub.bootChain.entry.description = "Windows Boot Manager"
        $script:Evidence.grub.bootChain.entry.loaderPath = "\EFI\Microsoft\Boot\bootmgfw.efi"
        {
            Assert-LibertixLinuxBootEvidence `
                -Evidence $script:Evidence `
                -Plan $script:Plan `
                -AlignmentBytes 1048576
        } | Should -Throw "*firmware selected Libertix*"
    }

    It "accepts the Windows firmware path only with the complete verified fallback proof" {
        $script:Evidence.grub.bootChain.type = "uefi-preferred-windows-path"
        $script:Evidence.grub.bootChain.entry.description = "Windows Boot Manager"
        $script:Evidence.grub.bootChain.entry.loaderPath = "\EFI\Microsoft\Boot\bootmgfw.efi"
        $script:Evidence.grub.bootChain | Add-Member -NotePropertyName preferredPath -NotePropertyValue (
            [pscustomobject]@{
                manifestPath = "/boot/efi/EFI/Libertix/preferred-boot-path.json"
                manifestSha256 = "d" * 64
                secureBootEvidencePath = "/boot/efi/EFI/Libertix/secure-boot-chain.json"
                verifiedHashes = [pscustomobject]@{
                    "bootmgfw.efi" = "1" * 64
                    "grubx64.efi" = "2" * 64
                    "mmx64.efi" = "3" * 64
                    "grub.cfg" = "4" * 64
                    "bootmgfw.libertix-windows.efi" = "5" * 64
                }
            }
        )

        {
            Assert-LibertixLinuxBootEvidence `
                -Evidence $script:Evidence `
                -Plan $script:Plan `
                -AlignmentBytes 1048576
        } | Should -Not -Throw
    }

    It "rejects an incomplete preferred Windows path proof" {
        $script:Evidence.grub.bootChain.type = "uefi-preferred-windows-path"
        $script:Evidence.grub.bootChain.entry.description = "Windows Boot Manager"
        $script:Evidence.grub.bootChain.entry.loaderPath = "\EFI\Microsoft\Boot\bootmgfw.efi"
        $script:Evidence.grub.bootChain | Add-Member -NotePropertyName preferredPath -NotePropertyValue (
            [pscustomobject]@{
                manifestPath = "/boot/efi/EFI/Libertix/preferred-boot-path.json"
                manifestSha256 = "d" * 64
                secureBootEvidencePath = "/boot/efi/EFI/Libertix/secure-boot-chain.json"
                verifiedHashes = [pscustomobject]@{
                    "bootmgfw.efi" = "1" * 64
                }
            }
        )

        {
            Assert-LibertixLinuxBootEvidence `
                -Evidence $script:Evidence `
                -Plan $script:Plan `
                -AlignmentBytes 1048576
        } | Should -Throw "*verified hash for 'grubx64.efi'*"
    }

    It "rejects legacy UEFI evidence without boot-entry identity clearly" {
        $script:Evidence.grub.bootChain.PSObject.Properties.Remove("entry")
        {
            Assert-LibertixLinuxBootEvidence `
                -Evidence $script:Evidence `
                -Plan $script:Plan `
                -AlignmentBytes 1048576
        } | Should -Throw "*missing boot-chain field 'entry'*"
    }

    It "rejects evidence from an unhealthy installed system" {
        $script:Evidence.system.dpkgAuditClean = $false
        {
            Assert-LibertixLinuxBootEvidence `
                -Evidence $script:Evidence `
                -Plan $script:Plan `
                -AlignmentBytes 1048576
        } | Should -Throw "*healthy installed system*"
    }
}

Describe "Permanent recovery archive" {
    It "requires the UEFI transaction document" {
        $root = Join-Path $TestDrive "recovery"
        New-Item -ItemType Directory -Path $root | Out-Null
        foreach ($relativePath in @(
            "installation-plan.json",
            "installation-state.json",
            "installed-linux-boot.json",
            "payload\Scripts\modules\Libertix.InstallationState.psm1",
            "payload\Scripts\modules\Libertix.PostInstallVerification.psm1",
            "payload\Scripts\libertix-uefi-recovery-agent.ps1",
            "payload\Scripts\libertix-post-install-result.ps1",
            "payload\Resources\Images\icon.ico"
        )) {
            $path = Join-Path $root $relativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            New-Item -ItemType File -Path $path -Force | Out-Null
        }
        $plan = [pscustomobject]@{ firmware = "uefi" }

        { Test-LibertixRecoveryArchive -Plan $plan -RecoveryRoot $root } |
            Should -Throw "*uefi-transaction.json*"

        New-Item -ItemType File -Path (Join-Path $root "uefi-transaction.json") | Out-Null
        Test-LibertixRecoveryArchive -Plan $plan -RecoveryRoot $root |
            Should -Be "rollback archive retained"
    }
}

Describe "Concurrent Explorer shortcut verification" {
    InModuleScope Libertix.PostInstallVerification {
        It "retries while the interactive pin task replaces the shortcut" {
            $script:ShortcutReadCount = 0
            $shell = [pscustomobject]@{}
            $shell | Add-Member -MemberType ScriptMethod -Name CreateShortcut -Value {
                param([string]$Path)
                $script:ShortcutReadCount++
                [pscustomobject]@{
                    TargetPath = if ($script:ShortcutReadCount -eq 1) {
                        ""
                    } else {
                        "l:\home\test\"
                    }
                }
            }

            Test-LibertixShortcutTargetWithRetry `
                -Shell $shell `
                -ShortcutPath "C:\Users\test\Links\Linux_test_read-only.lnk" `
                -ExpectedTarget "L:\home\test" `
                -TimeoutMilliseconds 1000 |
                Should -BeTrue
            $script:ShortcutReadCount | Should -BeGreaterThan 1
        }
    }
}

Describe "Scheduled task principal identity" {
    InModuleScope Libertix.PostInstallVerification {
        It "uses the invariant SID from task XML instead of a localized account name" {
            Mock Export-ScheduledTask {
                @'
<?xml version="1.0" encoding="UTF-16"?>
<Task><Principals><Principal><UserId>S-1-5-18</UserId></Principal></Principals></Task>
'@
            }

            Get-LibertixScheduledTaskPrincipalSid -TaskName "LibertixLinuxReadOnly" |
                Should -Be "S-1-5-18"
        }
    }
}

Describe "Durable post-install checkpoints" {
    InModuleScope Libertix.PostInstallVerification {
        It "keeps successful final persistence outside the primary verification catch" {
            $definition = ${function:Invoke-LibertixPostInstallVerification}.ToString()
            $catchBody = ($definition -split [regex]::Escape('} catch {'), 2)[1]
            $catchBody = ($catchBody -split [regex]::Escape('throw $primaryError'), 2)[0]
            $successBody = ($definition -split [regex]::Escape('throw $primaryError'), 2)[1]

            $catchBody | Should -Match 'Outcome "failed"'
            $catchBody | Should -Match 'startup task will retry'
            $successBody | Should -Match 'Outcome "succeeded"'
            $successBody | Should -Match 'Post-install verification completed successfully'
        }

        It "records and resumes an interrupted verification attempt" {
            $result = [pscustomobject]@{
                updatedAtUtc = "2026-08-11T10:00:00Z"
                attempts = @(
                    [pscustomobject]@{
                        attemptId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                        processId = 10
                        startedAtUtc = "2026-08-11T10:00:00Z"
                        completedAtUtc = $null
                        outcome = "running"
                    }
                )
                activeAttemptId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                interruptionCount = 0
            }
            $messages = [Collections.Generic.List[string]]::new()
            $writeLog = { param($Message) $messages.Add([string]$Message) }
            Mock Write-LibertixPostInstallResult

            $attemptId = Start-LibertixPostInstallAttempt `
                -Result $result `
                -ResultPath (Join-Path $TestDrive "result.json") `
                -WriteLog $writeLog

            $attemptId | Should -Match "^[0-9a-f]{32}$"
            $result.interruptionCount | Should -Be 1
            @($result.attempts).Count | Should -Be 2
            $result.attempts[0].outcome | Should -Be "interrupted"
            $result.attempts[1].outcome | Should -Be "running"
            $messages[0] | Should -Match "interrupted attempt"
            Should -Invoke Write-LibertixPostInstallResult -Times 1
        }

        It "persists the terminal outcome on the active attempt" {
            $result = [pscustomobject]@{
                activeAttemptId = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
                attempts = @(
                    [pscustomobject]@{
                        attemptId = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
                        completedAtUtc = $null
                        outcome = "running"
                    }
                )
            }

            Complete-LibertixPostInstallAttempt `
                -Result $result `
                -AttemptId $result.activeAttemptId `
                -Outcome "succeeded"

            $result.activeAttemptId | Should -BeNullOrEmpty
            $result.attempts[0].outcome | Should -Be "succeeded"
            $result.attempts[0].completedAtUtc | Should -Not -BeNullOrEmpty
        }

        It "does not rerun a check already persisted as successful" {
            $result = [pscustomobject]@{
                updatedAtUtc = "2026-08-11T10:00:00Z"
                checks = @(
                    [pscustomobject]@{
                        name = "installed-linux-boot"
                        passed = $true
                        detail = "OK"
                    }
                )
            }
            $messages = [Collections.Generic.List[string]]::new()
            $writeLog = { param($Message) $messages.Add([string]$Message) }
            Mock Write-LibertixPostInstallResult

            {
                Add-LibertixPostInstallCheck `
                    -Result $result `
                    -ResultPath (Join-Path $TestDrive "result.json") `
                    -Name "installed-linux-boot" `
                    -Test { throw "must not run" } `
                    -WriteLog $writeLog
            } | Should -Not -Throw

            $result.checks.Count | Should -Be 1
            $messages[0] | Should -Match "resumed from durable result"
            Should -Invoke Write-LibertixPostInstallResult -Times 0
        }

        It "replaces a failed checkpoint when its retry succeeds" {
            $result = [pscustomobject]@{
                updatedAtUtc = "2026-08-11T10:00:00Z"
                checks = @(
                    [pscustomobject]@{
                        name = "windows-health"
                        passed = $false
                        detail = "interrupted"
                    }
                )
            }
            $writeLog = { param($Message) }
            Mock Write-LibertixPostInstallResult

            Add-LibertixPostInstallCheck `
                -Result $result `
                -ResultPath (Join-Path $TestDrive "result.json") `
                -Name "windows-health" `
                -Test { "healthy" } `
                -WriteLog $writeLog

            $result.checks.Count | Should -Be 1
            $result.checks[0].passed | Should -BeTrue
            $result.checks[0].detail | Should -Be "healthy"
            Should -Invoke Write-LibertixPostInstallResult -Times 1
        }
    }
}

Describe "Waiting for the first installed Linux boot" {
    It "persists a resumable non-terminal state without inventing a failed check" {
        $root = Join-Path $TestDrive "waiting-recovery"
        New-Item -ItemType Directory -Path $root | Out-Null
        @{
            planId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            firmware = "uefi"
        } | ConvertTo-Json | Set-Content `
            -LiteralPath (Join-Path $root "installation-plan.json") `
            -Encoding UTF8

        $result = Set-LibertixPostInstallWaitingForLinux `
            -RecoveryRoot $root `
            -LogPath (Join-Path $root "recovery.log")

        $result.status | Should -Be "waiting-linux-boot"
        $result.waitingFor | Should -Be "installed-linux-boot.json"
        @($result.checks).Count | Should -Be 0
        $persisted = Get-Content `
            -LiteralPath (Join-Path $root "post-install-verification.json") `
            -Raw `
            -Encoding UTF8 | ConvertFrom-Json
        $persisted.status | Should -Be "waiting-linux-boot"
    }

    It "does not overwrite a terminal result" {
        $root = Join-Path $TestDrive "terminal-recovery"
        New-Item -ItemType Directory -Path $root | Out-Null
        @{
            planId = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            firmware = "bios"
        } | ConvertTo-Json | Set-Content `
            -LiteralPath (Join-Path $root "installation-plan.json") `
            -Encoding UTF8
        @{
            schemaVersion = 1
            planId = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            firmware = "bios"
            status = "succeeded"
            checks = @()
        } | ConvertTo-Json | Set-Content `
            -LiteralPath (Join-Path $root "post-install-verification.json") `
            -Encoding UTF8

        $result = Set-LibertixPostInstallWaitingForLinux `
            -RecoveryRoot $root `
            -LogPath (Join-Path $root "recovery.log")

        $result.status | Should -Be "succeeded"
    }

    It "turns a resumed waiting state into a durable controller failure" {
        $root = Join-Path $TestDrive "failed-recovery"
        New-Item -ItemType Directory -Path $root | Out-Null
        @{
            planId = "cccccccccccccccccccccccccccccccc"
            firmware = "uefi"
        } | ConvertTo-Json | Set-Content `
            -LiteralPath (Join-Path $root "installation-plan.json") `
            -Encoding UTF8
        $null = Set-LibertixPostInstallWaitingForLinux `
            -RecoveryRoot $root `
            -LogPath (Join-Path $root "recovery.log")

        $result = Set-LibertixPostInstallFailure `
            -RecoveryRoot $root `
            -LogPath (Join-Path $root "recovery.log") `
            -CheckName "post-install-controller" `
            -ErrorMessage "share finalization failed"

        $result.status | Should -Be "failed"
        $result.rollbackAvailable | Should -BeTrue
        @($result.checks).Count | Should -Be 1
        $result.checks[0].name | Should -Be "post-install-controller"
        $result.checks[0].passed | Should -BeFalse
        $result.checks[0].detail | Should -Be "share finalization failed"
    }

    It "rejects a persisted waiting result owned by another plan" {
        $root = Join-Path $TestDrive "foreign-waiting-recovery"
        New-Item -ItemType Directory -Path $root | Out-Null
        @{
            planId = "dddddddddddddddddddddddddddddddd"
            firmware = "bios"
        } | ConvertTo-Json | Set-Content `
            -LiteralPath (Join-Path $root "installation-plan.json") `
            -Encoding UTF8
        @{
            schemaVersion = 1
            planId = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
            firmware = "bios"
            status = "waiting-linux-boot"
            checks = @()
        } | ConvertTo-Json | Set-Content `
            -LiteralPath (Join-Path $root "post-install-verification.json") `
            -Encoding UTF8

        {
            Set-LibertixPostInstallWaitingForLinux `
                -RecoveryRoot $root `
                -LogPath (Join-Path $root "recovery.log")
        } | Should -Throw "*belongs to another contract*"
    }
}

Describe "Windows filesystem repair after offline NTFS resize" {
    InModuleScope Libertix.PostInstallVerification {
        BeforeEach {
            $script:RepairRoot = Join-Path $TestDrive "filesystem-repair"
            New-Item -ItemType Directory -Path $script:RepairRoot -Force | Out-Null
            $script:RepairPlan = [pscustomobject]@{
                planId = "ffffffffffffffffffffffffffffffff"
                firmware = "bios"
                disk = [pscustomobject]@{
                    systemDrive = "C:"
                    installer = [pscustomobject]@{
                        resizeMode = "live-offline"
                    }
                }
            }
            Mock Read-LibertixJsonObject { $script:RepairPlan }
            Mock Get-LibertixWindowsBootIdentity { "2026-08-15T10:00:00.0000000Z" }
            Mock Write-LibertixPostInstallResult
            Mock Set-LibertixPostInstallWaitingForWindowsRepair
            Mock Register-LibertixWindowsBootVolumeCheck
        }

        It "does nothing for the normal Windows online resize path" {
            $script:RepairPlan.disk.installer.resizeMode = "windows-online"

            $result = Invoke-LibertixWindowsFilesystemRepairIfRequired `
                -RecoveryRoot $script:RepairRoot `
                -LogPath (Join-Path $script:RepairRoot "recovery.log") `
                -WriteLog { param($Message) }

            $result.Required | Should -BeFalse
            $result.RestartRequired | Should -BeFalse
            Should -Invoke Register-LibertixWindowsBootVolumeCheck -Times 0
        }

        It "schedules and persists a bounded boot-time repair for an unhealthy volume" {
            Mock Get-LibertixWindowsVolumeHealth {
                [pscustomobject]@{
                    IsHealthy = $false
                    Detail = "drive=C: filesystem=NTFS health=Warning operational=Scan Needed"
                }
            }

            $result = Invoke-LibertixWindowsFilesystemRepairIfRequired `
                -RecoveryRoot $script:RepairRoot `
                -LogPath (Join-Path $script:RepairRoot "recovery.log") `
                -WriteLog { param($Message) }

            $result.Required | Should -BeTrue
            $result.RestartRequired | Should -BeTrue
            $result.AttemptCount | Should -Be 1
            Should -Invoke Register-LibertixWindowsBootVolumeCheck -Times 1 `
                -ParameterFilter { $SystemDrive -eq "C:" }
            Should -Invoke Set-LibertixPostInstallWaitingForWindowsRepair -Times 1
            Should -Invoke Write-LibertixPostInstallResult -Times 1 `
                -ParameterFilter { $Path -like "*windows-filesystem-repair.json" }
        }

        It "continues verification as soon as Windows reports the volume healthy" {
            Mock Get-LibertixWindowsVolumeHealth {
                [pscustomobject]@{
                    IsHealthy = $true
                    Detail = "drive=C: filesystem=NTFS health=Healthy operational=OK"
                }
            }

            $result = Invoke-LibertixWindowsFilesystemRepairIfRequired `
                -RecoveryRoot $script:RepairRoot `
                -LogPath (Join-Path $script:RepairRoot "recovery.log") `
                -WriteLog { param($Message) }

            $result.RestartRequired | Should -BeFalse
            Should -Invoke Register-LibertixWindowsBootVolumeCheck -Times 0
            Should -Invoke Write-LibertixPostInstallResult -Times 1 `
                -ParameterFilter { $Path -like "*windows-filesystem-repair.json" }
        }
    }
}
