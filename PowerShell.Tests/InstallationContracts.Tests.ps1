BeforeAll {
    Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.AtomicFile.psm1" -Force
    Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.InstallationPlan.psm1" -Force
    Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.InstallationState.psm1" -Force

    function New-ValidInstallationPlan {
        return @'
{
  "schemaVersion": 2,
  "planId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "createdAtUtc": "2026-07-15T12:00:00Z",
  "firmware": "uefi",
  "distribution": {
    "id": "mint",
    "name": "Linux Mint",
    "osReleaseId": "linuxmint",
    "grubDisplayName": "Linux Mint 22.3 Cinnamon",
    "grubIcon": "linuxmint",
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
    "passwordHashWindowsPath": "C:\\ProgramData\\Libertix\\account-secret.env",
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
    "lowMemoryMode": false,
    "bootStrategy": "uefi-boot-next",
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
            param($Path, $ReadyPath)
            $stream = [IO.File]::Open(
                $Path,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::None
            )
            try {
                [IO.File]::WriteAllText($ReadyPath, "ready")
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

    It "rejects Windows paths on another drive" {
        $plan = New-ValidInstallationPlan
        $plan.account.passwordHashWindowsPath = "D:\ProgramData\Libertix\account-secret.env"
        { Assert-LibertixInstallationPlan -Plan $plan } |
            Should -Throw "*must be located on disk.systemDrive*"
    }

    It "accepts consistent Windows paths on a non-C system drive" {
        $plan = New-ValidInstallationPlan
        $plan.disk.systemDrive = "D:"
        $plan.distribution.installerIsoWindowsPath = `
            "D:\ProgramData\Libertix\Downloads\aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\mint.iso"
        $plan.account.passwordHashWindowsPath = "D:\ProgramData\Libertix\account-secret.env"
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
