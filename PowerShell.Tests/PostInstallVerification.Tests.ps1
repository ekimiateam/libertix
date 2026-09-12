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

Describe 'Installed filesystem ownership before uninstall' {
    InModuleScope Libertix.PostInstallVerification {
        BeforeEach {
            $script:header = New-Object byte[] 4096
            $script:header[1080] = 0x53; $script:header[1081] = 0xef
            for ($i = 1128; $i -lt 1144; $i++) { $script:header[$i] = 0x11 }
            Mock Read-LibertixPartitionHeader { return ,$script:header }
            Mock Read-LibertixJsonObject {
                if ($Path -like '*installation-plan.json') { return [pscustomobject]@{ planId = 'test-plan' } }
                return [pscustomobject]@{
                    planId = 'test-plan'; recoveryRunId = 'test-plan'
                    root = [pscustomobject]@{
                        filesystem = 'ext4'; uuid = '11111111-1111-1111-1111-111111111111'
                        offsetBytes = 1MB; sizeBytes = 20GB
                    }
                }
            }
            $script:partition = [pscustomobject]@{ DiskNumber = 0; Offset = 1MB; Size = 20GB }
        }
        It 'accepts the original filesystem without writing to disk' {
            { Assert-LibertixInstalledFilesystemIdentity -Partition $script:partition -RecoveryRoot 'C:\archive' } |
                Should -Not -Throw
            Should -Invoke Read-LibertixPartitionHeader -Exactly 1
        }
        It 'refuses a replacement filesystem occupying the identical extent' {
            $script:header[1128] = 0x22
            { Assert-LibertixInstalledFilesystemIdentity -Partition $script:partition -RecoveryRoot 'C:\archive' } |
                Should -Throw '*filesystem was replaced*'
        }
        It 'refuses a non-ext filesystem even with matching UUID bytes' {
            $script:header[1080] = 0
            { Assert-LibertixInstalledFilesystemIdentity -Partition $script:partition -RecoveryRoot 'C:\archive' } |
                Should -Throw '*filesystem was replaced*'
        }
        It 'refuses changed geometry before opening the disk' {
            $script:partition.Offset = 2MB
            { Assert-LibertixInstalledFilesystemIdentity -Partition $script:partition -RecoveryRoot 'C:\archive' } |
                Should -Throw '*does not match*'
            Should -Invoke Read-LibertixPartitionHeader -Exactly 0
        }
    }
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
            "payload\Libertix.BootGuardian.exe",
            "payload\Scripts\modules\Libertix.InstallationState.psm1",
            "payload\Scripts\modules\Libertix.PostInstallVerification.psm1",
            "payload\Scripts\modules\Libertix.WindowsProfiles.psm1",
            "payload\Scripts\modules\Libertix.Rollback.psm1",
            "payload\Scripts\modules\Libertix.StorageTargets.psm1",
            "payload\Scripts\modules\Libertix.PreferredBootPath.psm1",
            "payload\Scripts\modules\Libertix.BootGuardian.psm1",
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

Describe "Optional service registry properties" {
    InModuleScope Libertix.PostInstallVerification {
        It "returns an empty array when RequiredPrivileges is absent under StrictMode" {
            $registry = [pscustomobject]@{ PreshutdownTimeout = 10000 }

            $values = @(Get-LibertixObjectPropertyValues `
                    -InputObject $registry `
                    -Name "RequiredPrivileges")

            $values.Count | Should -Be 0
        }

        It "returns every configured RequiredPrivileges value" {
            $registry = [pscustomobject]@{
                RequiredPrivileges = @(
                    "SeSystemEnvironmentPrivilege",
                    "SeBackupPrivilege"
                )
            }

            $values = @(Get-LibertixObjectPropertyValues `
                    -InputObject $registry `
                    -Name "RequiredPrivileges")

            $values | Should -Be @(
                "SeSystemEnvironmentPrivilege",
                "SeBackupPrivilege"
            )
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

        It "preserves old observations but reruns them in the next attempt" {
            $path = Join-Path $TestDrive "resumed-result.json"
            $result = New-LibertixPostInstallResult -PlanId ('a' * 32) -Firmware bios -LogPath "test.log"
            $result.checks = @([pscustomobject]@{
                name = 'windows-read-only-linux-share'; passed = $true; detail = 'old mount'
            })
            $null = Start-LibertixPostInstallAttempt -Result $result -ResultPath $path -WriteLog { param($line) }
            $result.checks.Count | Should -Be 0
            $result.attempts[-1].previousChecks[0].detail | Should -Be 'old mount'
            {
                Add-LibertixPostInstallCheck -Result $result -ResultPath $path `
                    -Name 'windows-read-only-linux-share' -Test { throw 'MOUNT_DISAPPEARED' } `
                    -WriteLog { param($line) }
            } | Should -Throw '*MOUNT_DISAPPEARED*'
            $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $saved.checks[0].passed | Should -BeFalse
            $saved.attempts[-1].previousChecks[0].passed | Should -BeTrue
        }

        It "rechecks a terminal success from an earlier Windows boot" {
            $script:saved = New-LibertixPostInstallResult -PlanId ('a' * 32) -Firmware bios -LogPath 'old.log'
            $script:saved.status = 'succeeded'
            $script:saved | Add-Member -NotePropertyName windowsBootId -NotePropertyValue 'old-boot'
            $script:saved.checks = @([pscustomobject]@{ name = 'disk-geometry'; passed = $true; detail = 'old geometry' })
            Mock Get-LibertixWindowsBootIdentity { 'new-boot' }
            Mock Get-LibertixPartitionAlignmentBytes { 1MB }
            Mock Test-Path { $true }
            Mock Read-LibertixJsonObject {
                param($Description)
                if ($Description -eq 'installation plan') {
                    return [pscustomobject]@{ planId = ('a' * 32); firmware = 'bios' }
                }
                if ($Description -eq 'post-install verification result') { return $script:saved }
                return [pscustomobject]@{ present = $true }
            }
            Mock Read-LibertixExecutionState { [pscustomobject]@{ planId = ('a' * 32); status = 'succeeded'; revision = 1 } }
            Mock Assert-LibertixLinuxBootEvidence { 'valid' }
            Mock Test-LibertixDiskGeometry { throw 'DISK_CHANGED' }
            Mock Set-LibertixShutdownVerificationPriority {}
            Mock Write-LibertixPostInstallResult {}
            {
                Invoke-LibertixPostInstallVerification -RecoveryRoot $TestDrive -LogPath 'test.log' -WriteLog { param($line) }
            } | Should -Throw '*DISK_CHANGED*'
            $script:saved.status | Should -Be 'failed'
            $script:saved.windowsBootId | Should -Be 'new-boot'
            $script:saved.attempts[-1].previousChecks[0].detail | Should -Be 'old geometry'
        }

        It "keeps a terminal result idempotent within the same Windows boot" {
            $saved = New-LibertixPostInstallResult -PlanId ('a' * 32) -Firmware bios -LogPath 'old.log'
            $saved.status = 'succeeded'
            $saved | Add-Member -NotePropertyName windowsBootId -NotePropertyValue 'same-boot'
            Mock Get-LibertixWindowsBootIdentity { 'same-boot' }
            Mock Get-LibertixPartitionAlignmentBytes { 1MB }
            Mock Test-Path { $true }
            Mock Read-LibertixJsonObject {
                param($Description)
                if ($Description -eq 'installation plan') {
                    return [pscustomobject]@{ planId = ('a' * 32); firmware = 'bios' }
                }
                return $saved
            }
            Mock Start-LibertixPostInstallAttempt { throw 'MUST_NOT_RESTART' }
            $result = Invoke-LibertixPostInstallVerification -RecoveryRoot $TestDrive -LogPath 'test.log' -WriteLog { param($line) }
            $result.status | Should -Be 'succeeded'
            Should -Invoke Start-LibertixPostInstallAttempt -Times 0
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
                schemaVersion = 4
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
            Mock Get-LibertixAllocationSourceDrive { 'C:' }
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

        It 'checks and schedules repair only for the selected data volume' {
            $script:RepairPlan.schemaVersion = 5
            Mock Get-LibertixAllocationSourceDrive { 'J:' }
            Mock Get-LibertixWindowsVolumeHealth {
                [pscustomobject]@{ IsHealthy = $false; Detail = 'J: requires a consistency check' }
            }
            $result = Invoke-LibertixWindowsFilesystemRepairIfRequired `
                -RecoveryRoot $script:RepairRoot -LogPath (Join-Path $script:RepairRoot 'recovery.log') `
                -WriteLog { param($Message) }
            $result.RestartRequired | Should -BeTrue
            Should -Invoke Get-LibertixWindowsVolumeHealth -Times 1 -Exactly `
                -ParameterFilter { $SystemDrive -eq 'J:' }
            Should -Invoke Register-LibertixWindowsBootVolumeCheck -Times 1 -Exactly `
                -ParameterFilter { $SystemDrive -eq 'J:' }
            Should -Invoke Write-LibertixPostInstallResult -Times 1 -Exactly `
                -ParameterFilter { $Path -like '*windows-filesystem-repair.json' -and $Result.sourceDrive -eq 'J:' }
        }

        It 'rejects a persisted repair intended for a different volume' {
            Mock Get-LibertixAllocationSourceDrive { 'J:' }
            Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*windows-filesystem-repair.json' }
            Mock Read-LibertixJsonObject {
                [pscustomobject]@{ schemaVersion = 1; planId = $script:RepairPlan.planId; sourceDrive = 'C:' }
            } -ParameterFilter { $Path -like '*windows-filesystem-repair.json' }
            { Invoke-LibertixWindowsFilesystemRepairIfRequired `
                -RecoveryRoot $script:RepairRoot -LogPath (Join-Path $script:RepairRoot 'recovery.log') `
                -WriteLog { param($Message) } } | Should -Throw '*different source volume*'
            Should -Invoke Register-LibertixWindowsBootVolumeCheck -Times 0
        }
    }
}

Describe 'Final uninstall verification' {
    InModuleScope Libertix.PostInstallVerification {
        BeforeEach {
            $script:FinalPlan = [pscustomobject]@{
                planId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; firmware = 'bios'
                disk = [pscustomobject]@{
                    number = 0; systemDrive = 'C:'
                    windows = [pscustomobject]@{ offsetBytes = 1048576; sizeBytes = 40000000000 }
                    recovery = [pscustomobject]@{ sizeBytes = 0 }
                }
            }
            $script:FinalReport = $null
            Mock Read-LibertixJsonObject { $script:FinalPlan }
            Mock Read-LibertixExecutionState {
                [pscustomobject]@{ planId = $script:FinalPlan.planId; status = 'rolled-back'; revision = 42 }
            }
            Mock Get-LibertixPlannedLinuxDisk { $script:FinalPlan.disk }
            Mock Get-Partition { [pscustomobject]@{ Offset = 1048576; Size = 40000000000 } }
            Mock Assert-LibertixSourceVolumeIdentity { }
            Mock Get-ScheduledTask { @() }
            Mock Get-Service { @() }
            Mock Write-LibertixPostInstallResult { $script:FinalReport = $Result }
            Mock Write-LibertixPostInstallErrorDiagnostic { }
        }

        It 'rereads storage and records every final check before reporting success' {
            Assert-LibertixUninstallComplete -RecoveryRoot $TestDrive `
                -RecoveryTaskNames @('LibertixInstallRecovery') -VerifyBoot { 'boot verified' } -WriteLog { }
            $script:FinalReport.status | Should -Be 'succeeded'
            $script:FinalReport.rollbackExecutionRevision | Should -Be 42
            @($script:FinalReport.checks).Count | Should -Be 4
            @($script:FinalReport.checks | Where-Object { -not $_.passed }).Count | Should -Be 0
            Should -Invoke Get-Partition -Times 1 -Exactly
        }

        It 'does not trust the rolled-back ledger when the source size is wrong' {
            Mock Get-Partition { [pscustomobject]@{ Offset = 1048576; Size = 20000000000 } }
            { Assert-LibertixUninstallComplete -RecoveryRoot $TestDrive `
                -RecoveryTaskNames @('LibertixInstallRecovery') -VerifyBoot { } -WriteLog { } } |
                Should -Throw '*original size*'
            $script:FinalReport.status | Should -Be 'failed'
            $script:FinalReport.checks[-1].name | Should -Be 'restored-storage'
            $script:FinalReport.checks[-1].passed | Should -BeFalse
        }

        It 'keeps a failed boot verification in the permanent report' {
            { Assert-LibertixUninstallComplete -RecoveryRoot $TestDrive `
                -RecoveryTaskNames @('LibertixInstallRecovery') `
                -VerifyBoot { throw 'GRUB remains' } -WriteLog { } } | Should -Throw '*GRUB remains*'
            $script:FinalReport.status | Should -Be 'failed'
            $script:FinalReport.checks[-1].name | Should -Be 'boot-restored'
        }

        It 'rejects remaining maintenance tasks without deleting them in the verifier' {
            Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'LibertixLinuxReadOnly' } }
            { Assert-LibertixUninstallComplete -RecoveryRoot $TestDrive `
                -RecoveryTaskNames @('LibertixInstallRecovery') -VerifyBoot { } -WriteLog { } } |
                Should -Throw '*task remains*'
            $script:FinalReport.status | Should -Be 'failed'
        }
    }
}

Describe "Post-install rollback result" {
    InModuleScope Libertix.PostInstallVerification {
        BeforeEach {
            $script:RollbackPlan = [pscustomobject]@{
                planId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                firmware = "uefi"
            }
            $script:RollbackResult = [pscustomobject]@{
                schemaVersion = 1
                planId = $script:RollbackPlan.planId
                firmware = $script:RollbackPlan.firmware
                status = "succeeded"
                rollbackAvailable = $true
                updatedAtUtc = "2026-09-10T08:00:00Z"
            }
            $script:WrittenRollbackResult = $null
            Mock Test-Path { $true } -ParameterFilter {
                $LiteralPath -like "*post-install-verification.json"
            }
            Mock Read-LibertixJsonObject {
                if ($Path -like "*installation-plan.json") {
                    return $script:RollbackPlan
                }
                return $script:RollbackResult
            }
            Mock Read-LibertixExecutionState {
                [PSCustomObject]@{
                    planId = $script:RollbackPlan.planId
                    status = "rolled-back"
                    revision = 42
                }
            }
            Mock Write-LibertixPostInstallResult {
                $script:WrittenRollbackResult = $Result
            }
        }

        It "closes the durable verification result only after a proven rollback" {
            $result = Set-LibertixPostInstallRolledBack -RecoveryRoot $TestDrive

            $result.status | Should -Be "rolled-back"
            $result.rollbackAvailable | Should -BeFalse
            $result.rollbackExecutionRevision | Should -Be 42
            $result.rolledBackAtUtc | Should -Not -BeNullOrEmpty
            $result.updatedAtUtc | Should -Not -Be "2026-09-10T08:00:00Z"
            $script:WrittenRollbackResult.status | Should -Be "rolled-back"
            $script:WrittenRollbackResult.rollbackExecutionRevision | Should -Be 42
            Should -Invoke Write-LibertixPostInstallResult -Times 1 -Exactly
        }

        It "refuses to publish completion while the ledger is still successful" {
            Mock Read-LibertixExecutionState {
                [PSCustomObject]@{
                    planId = $script:RollbackPlan.planId
                    status = "succeeded"
                    revision = 41
                }
            }

            {
                Set-LibertixPostInstallRolledBack -RecoveryRoot $TestDrive
            } | Should -Throw "*before the execution ledger proves rollback*"
            Should -Invoke Write-LibertixPostInstallResult -Times 0
        }
    }
}
