BeforeAll {
    Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.InstallationPlan.psm1" -Force
    Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.InstallationState.psm1" -Force
    Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.AtomicFile.psm1" -Force

    function New-ValidInstallationPlan {
        return @'
{
  "schemaVersion": 3,
  "planId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "createdAtUtc": "2026-07-15T12:00:00Z",
  "firmware": "uefi",
  "distribution": {
    "id": "mint",
    "name": "Linux Mint",
    "osReleaseId": "linuxmint",
    "grubDisplayName": "Linux Mint 22.3 Cinnamon",
    "grubIcon": "linuxmint",
    "secureBootMicrosoftAuthorities": ["2011"],
    "installerIsoFileName": "mint.iso",
    "installerIsoUrl": "https://example.test/mint.iso",
    "installerIsoWindowsPath": "C:\\ProgramData\\Libertix\\Downloads\\aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\mint.iso",
    "installerIsoSha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "liveIsoUrl": "https://example.test/libertix.iso",
    "liveIsoSha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  },
  "locale": {
    "languageCode": "en",
    "systemLanguage": "en_US.UTF-8",
    "keyboardLayout": "us",
    "keyboardVariant": "",
    "keyboardModel": "pc105",
    "timezone": "Etc/UTC"
  },
  "account": {
    "username": "oem",
    "passwordHashWindowsPath": "C:\\ProgramData\\Libertix\\Recovery\\account-secret.env",
    "computerName": "libertix-test"
  },
  "disk": {
    "number": 0,
    "uniqueId": "disk-0",
    "partitionTableId": "gpt:12345678-1234-1234-1234-123456789abc",
    "sizeBytes": 274877906944,
    "logicalSectorSizeBytes": 512,
    "partitionStyle": "GPT",
    "systemDrive": "C:",
    "windows": {"number": 2, "offsetBytes": 1073741824, "sizeBytes": 214748364800},
    "boot": {"number": 1, "offsetBytes": 1048576, "sizeBytes": 104857600},
    "recovery": {"number": 3, "offsetBytes": 257698037760, "sizeBytes": 1073741824},
    "installer": {
      "number": 4,
      "offsetBytes": 172872433664,
      "finalOffsetBytes": 172872433664,
      "resizeMode": "windows-online",
      "finalSizeBytes": 42949672960,
      "stagingSizeBytes": 8589934592
    }
  },
  "features": {
    "shareWindowsFilesInLinux": true,
    "shareLinuxFilesInWindows": true,
    "windowsProfilesJsonBase64": "W10="
  },
  "runtime": {
    "windowsBitLockerState": "FullyDecrypted",
    "lowMemoryMode": false,
    "bootStrategy": "uefi-boot-next",
    "secureBootEnabled": true,
    "trustedMicrosoftUefiAuthorities": ["2011"],
    "recoveryRootWindows": "C:\\ProgramData\\Libertix\\Recovery",
    "recoveryRunId": "dddddddddddddddddddddddddddddddd"
  }
}

'@ | ConvertFrom-Json
    }
}

Describe "Atomic file publication" {
    It "replaces a complete document without temporary residue" {
        $destination = Join-Path $TestDrive "atomic.json"
        $temporary = Join-Path $TestDrive ".atomic.json.tmp"
        $backup = Join-Path $TestDrive ".atomic.json.bak"
        Set-Content -LiteralPath $destination -Value '{"revision":1}' -NoNewline
        Set-Content -LiteralPath $temporary -Value '{"revision":2}' -NoNewline

        Publish-LibertixFileAtomic `
            -TemporaryPath $temporary `
            -DestinationPath $destination `
            -BackupPath $backup

        Get-Content -LiteralPath $destination -Raw | Should -Be '{"revision":2}'
        Test-Path -LiteralPath $temporary | Should -BeFalse
        Test-Path -LiteralPath $backup | Should -BeTrue
    }

    It "retries while another Windows process briefly locks the destination" {
        $destination = Join-Path $TestDrive "locked.json"
        $temporary = Join-Path $TestDrive ".locked.json.tmp"
        $backup = Join-Path $TestDrive ".locked.json.bak"
        $ready = Join-Path $TestDrive ".locked.ready"
        Set-Content -LiteralPath $destination -Value '{"revision":1}' -NoNewline
        Set-Content -LiteralPath $temporary -Value '{"revision":2}' -NoNewline
        $lockJob = Start-Job -ArgumentList $destination, $ready -ScriptBlock {
            $path = $args[0]
            $readyPath = $args[1]
            $stream = [IO.File]::Open(
                $path,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::None
            )
            try {
                [IO.File]::WriteAllText($readyPath, "ready")
                Start-Sleep -Milliseconds 150
            } finally {
                $stream.Dispose()
            }
        }
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            while (-not (Test-Path -LiteralPath $ready) -and [DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 25
            }
            Test-Path -LiteralPath $ready | Should -BeTrue

            Publish-LibertixFileAtomic `
                -TemporaryPath $temporary `
                -DestinationPath $destination `
                -BackupPath $backup

            Get-Content -LiteralPath $destination -Raw | Should -Be '{"revision":2}'
        } finally {
            Wait-Job -Job $lockJob -Timeout 10 | Out-Null
            Remove-Job -Job $lockJob -Force
        }
    }
}

Describe "Installation plan contract" {
    It "accepts a complete valid plan" {
        $plan = New-ValidInstallationPlan
        { Assert-LibertixInstallationPlan -Plan $plan } | Should -Not -Throw
    }

    It "accepts the staging geometry selected for live offline resize" {
        $plan = New-ValidInstallationPlan
        $plan.disk.installer.resizeMode = "live-offline"
        $plan.disk.installer.offsetBytes = 207232172032
        { Assert-LibertixInstallationPlan -Plan $plan } | Should -Not -Throw
    }

    It "rejects an offline resize whose staging offset uses the final extent" {
        $plan = New-ValidInstallationPlan
        $plan.disk.installer.resizeMode = "live-offline"
        { Assert-LibertixInstallationPlan -Plan $plan } |
            Should -Throw "*selected Windows shrink geometry*"
    }

    It "accepts a UEFI plan while verified decryption is still pending" {
        $plan = New-ValidInstallationPlan
        $plan.runtime.windowsBitLockerState = "EncryptedOrProtected"
        { Assert-LibertixInstallationPlan -Plan $plan } | Should -Not -Throw
    }

    It "rejects pending BitLocker decryption in a BIOS plan" {
        $plan = New-ValidInstallationPlan
        $plan.firmware = "bios"
        $plan.disk.partitionStyle = "MBR"
        $plan.disk.partitionTableId = "mbr:12345678"
        $plan.runtime.bootStrategy = "bios-grub4dos"
        $plan.runtime.secureBootEnabled = $false
        $plan.runtime.trustedMicrosoftUefiAuthorities = @()
        $plan.runtime.windowsBitLockerState = "EncryptedOrProtected"
        { Assert-LibertixInstallationPlan -Plan $plan } |
            Should -Throw "*windowsBitLockerState is invalid*"
    }

    It "rejects an unknown Windows BitLocker state" {
        $plan = New-ValidInstallationPlan
        $plan.runtime.windowsBitLockerState = "FullyEncrypted"
        { Assert-LibertixInstallationPlan -Plan $plan } |
            Should -Throw "*windowsBitLockerState is invalid*"
    }

    It "rejects an unknown root property" {
        $plan = New-ValidInstallationPlan
        $plan | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
        { Assert-LibertixInstallationPlan -Plan $plan } |
            Should -Throw "*contains unsupported field 'unexpected'*"
    }

    It "rejects an unknown nested property" {
        $plan = New-ValidInstallationPlan
        $plan.disk | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
        { Assert-LibertixInstallationPlan -Plan $plan } |
            Should -Throw "*contains unsupported field 'unexpected'*"
    }

    It "rejects an unknown distribution Secure Boot authority" {
        $plan = New-ValidInstallationPlan
        $plan.distribution.secureBootMicrosoftAuthorities = @("2040")
        { Assert-LibertixInstallationPlan -Plan $plan } |
            Should -Throw "*secureBootMicrosoftAuthorities may contain only 2011 and 2023*"
    }

    It "rejects a Debian or Ubuntu reserved Linux username" {
        $plan = New-ValidInstallationPlan
        $plan.account.username = "admin"
        { Assert-LibertixInstallationPlan -Plan $plan } |
            Should -Throw "*account.username is reserved by the operating system*"
    }

    It "rejects trusted UEFI authorities in a BIOS plan" {
        $plan = New-ValidInstallationPlan
        $plan.firmware = "bios"
        $plan.disk.partitionStyle = "MBR"
        $plan.disk.partitionTableId = "mbr:12345678"
        $plan.runtime.bootStrategy = "bios-grub4dos"
        $plan.runtime.secureBootEnabled = $false
        { Assert-LibertixInstallationPlan -Plan $plan } |
            Should -Throw "*BIOS installation plan must not contain trusted Microsoft UEFI authorities*"
    }

    It "rejects Windows paths on another drive" {
        $plan = New-ValidInstallationPlan
        $plan.account.passwordHashWindowsPath = "D:\ProgramData\Libertix\account-secret.env"
        { Assert-LibertixInstallationPlan -Plan $plan } |
            Should -Throw "*must be located on disk.systemDrive*"
    }

    It "rejects mixed-separator traversal in recovery paths" {
        $plan = New-ValidInstallationPlan
        $plan.distribution.installerIsoWindowsPath = `
            "C:\ProgramData\Libertix\Downloads\aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\safe/../mint.iso"
        { Assert-LibertixInstallationPlan -Plan $plan } |
            Should -Throw "*absolute safe Windows path*"

        $plan = New-ValidInstallationPlan
        $plan.account.passwordHashWindowsPath = `
            "C:\ProgramData\Libertix\Recovery\safe/../../account-secret.env"
        { Assert-LibertixInstallationPlan -Plan $plan } |
            Should -Throw "*absolute safe Windows path*"

        $plan = New-ValidInstallationPlan
        $plan.runtime.recoveryRootWindows = `
            "C:\ProgramData\Libertix\Recovery\safe/../escaped"
        $plan.account.passwordHashWindowsPath = `
            "C:\ProgramData\Libertix\Recovery\safe/../escaped\account-secret.env"
        { Assert-LibertixInstallationPlan -Plan $plan } |
            Should -Throw "*absolute safe Windows path*"
    }

    It "requires the account secret under the recovery root" {
        $plan = New-ValidInstallationPlan
        $plan.account.passwordHashWindowsPath = `
            "C:\ProgramData\Libertix\Other\account-secret.env"
        { Assert-LibertixInstallationPlan -Plan $plan } |
            Should -Throw "*under runtime.recoveryRootWindows*"
    }

    It "accepts consistent Windows paths on a non-C system drive" {
        $plan = New-ValidInstallationPlan
        $plan.disk.systemDrive = "D:"
        $plan.distribution.installerIsoWindowsPath = `
            "D:\ProgramData\Libertix\Downloads\aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\mint.iso"
        $plan.account.passwordHashWindowsPath = "D:\ProgramData\Libertix\Recovery\account-secret.env"
        $plan.runtime.recoveryRootWindows = "D:\ProgramData\Libertix\Recovery"
        { Assert-LibertixInstallationPlan -Plan $plan } | Should -Not -Throw
    }
}

Describe "Installation state ordering" {
    BeforeEach {
        $script:StatePath = Join-Path $TestDrive "installation-state.json"
        $null = New-LibertixExecutionState `
            -Path $script:StatePath `
            -PlanId "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }

    It "rejects a step outside the ordered prefix" {
        { Start-LibertixExecutionStep `
                -Path $script:StatePath `
                -Step "live.preflight-verified" } |
            Should -Throw "*out of order*"
    }

    It "rejects successful completion before every required step" {
        $null = Start-LibertixExecutionStep `
            -Path $script:StatePath `
            -Step "windows.preflight-verified"
        $null = Complete-LibertixExecutionStep `
            -Path $script:StatePath `
            -Step "windows.preflight-verified"
        { Complete-LibertixInstallation -Path $script:StatePath } |
            Should -Throw "*final target verification*"
    }

    It "rejects forged incomplete terminal states" {
        $succeeded = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
        $succeeded.status = "succeeded"
        $succeeded.phase = "complete"
        $succeeded.completedSteps = @("windows.preflight-verified")
        { Assert-LibertixExecutionState -State $succeeded } |
            Should -Throw "*every installation step*"

        $rolledBack = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
        $rolledBack.status = "rolled-back"
        $rolledBack.phase = "complete"
        $rolledBack.completedSteps = @(
            "windows.preflight-verified",
            "windows.artifacts-verified",
            "windows.recovery-armed"
        )
        $rolledBack.failure = [pscustomobject]@{
            code = "failure"
            message = "failure"
            component = "windows"
        }
        { Assert-LibertixExecutionState -State $rolledBack } |
            Should -Throw "*every applicable compensation*"
    }

    It "allows an explicit rollback after successful installation" {
        $state = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
        $state.status = "succeeded"
        $state.phase = "complete"
        $state.completedSteps = @(
            "windows.preflight-verified",
            "windows.artifacts-verified",
            "windows.recovery-armed",
            "windows.system-volume-shrunk",
            "windows.installer-partition-created",
            "windows.live-media-prepared",
            "windows.temporary-boot-prepared",
            "live.preflight-verified",
            "live.installer-partition-expanded",
            "live.target-filesystem-created",
            "live.distribution-extracted",
            "target.system-configured",
            "target.bootloader-installed",
            "target.installation-verified"
        )
        $state | ConvertTo-Json -Depth 8 | Set-Content `
            -LiteralPath $script:StatePath `
            -Encoding UTF8

        $rolledBack = Start-LibertixRollback -Path $script:StatePath

        $rolledBack.status | Should -Be "rollback-running"
        $rolledBack.phase | Should -Be "rollback"
    }

    It "completes a post-install rollback after every applicable compensation" {
        $state = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
        $state.status = "succeeded"
        $state.phase = "complete"
        $state.completedSteps = @(
            "windows.preflight-verified",
            "windows.artifacts-verified",
            "windows.recovery-armed",
            "windows.system-volume-shrunk",
            "windows.installer-partition-created",
            "windows.live-media-prepared",
            "windows.temporary-boot-prepared",
            "live.preflight-verified",
            "live.installer-partition-expanded",
            "live.target-filesystem-created",
            "live.distribution-extracted",
            "target.system-configured",
            "target.bootloader-installed",
            "target.installation-verified"
        )
        $state | ConvertTo-Json -Depth 8 | Set-Content `
            -LiteralPath $script:StatePath `
            -Encoding UTF8

        $null = Start-LibertixRollback -Path $script:StatePath
        foreach ($step in @(
            "windows.recovery-armed",
            "windows.system-volume-shrunk",
            "windows.installer-partition-created",
            "windows.live-media-prepared",
            "windows.temporary-boot-prepared",
            "live.installer-partition-expanded",
            "live.target-filesystem-created",
            "live.distribution-extracted",
            "target.system-configured",
            "target.bootloader-installed"
        )) {
            $null = Complete-LibertixCompensation -Path $script:StatePath -Step $step
        }

        $rolledBack = Complete-LibertixRollback -Path $script:StatePath

        $rolledBack.status | Should -Be "rolled-back"
        $rolledBack.compensatedSteps.Count | Should -Be 10
    }

    It "rejects an unknown persisted state property" {
        $state = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
        $state | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
        { Assert-LibertixExecutionState -State $state } |
            Should -Throw "*contains unsupported field 'unexpected'*"
    }

    It "validates progress in a newly created ordered state" {
        $orderedState = New-LibertixExecutionState `
            -Path (Join-Path $TestDrive "ordered-state.json") `
            -PlanId "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        $orderedState.progress.overallPercent = 101
        { Assert-LibertixExecutionState -State $orderedState } |
            Should -Throw "*overall progress is invalid*"
    }
}
