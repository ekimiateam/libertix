BeforeAll {
    Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.InstallationPlan.psm1" -Force
    Import-Module "$PSScriptRoot/../Scripts/modules/Libertix.InstallationState.psm1" -Force

    function New-ValidInstallationPlan {
        return @'
{
  "schemaVersion": 1,
  "planId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "createdAtUtc": "2026-07-15T12:00:00Z",
  "firmware": "uefi",
  "distribution": {
    "name": "Linux Mint",
    "installerIsoFileName": "mint.iso",
    "installerIsoUrl": "https://example.test/mint.iso",
    "installerIsoWindowsPath": "C:\\mint.iso",
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
        { Complete-LibertixInstallation -Path $script:StatePath } |
            Should -Throw "*all required steps*"
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
