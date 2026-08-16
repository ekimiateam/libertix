Set-StrictMode -Version Latest

$script:InstallationPolicy = $null

function Get-LibertixInstallationPolicy {
    if ($null -ne $script:InstallationPolicy) {
        return $script:InstallationPolicy
    }

    $policyPath = [IO.Path]::GetFullPath((Join-Path `
        $PSScriptRoot `
        "..\config\Libertix.InstallationPolicy.json"))
    if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
        throw "Libertix installation policy is missing: $policyPath"
    }

    $policy = Get-Content -LiteralPath $policyPath -Raw -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop
    if (
        [int]$policy.schemaVersion -ne 1 -or
        $null -eq $policy.storage -or
        $null -eq $policy.memory -or
        $null -eq $policy.download -or
        $null -eq $policy.volumeLabels -or
        $null -eq $policy.account
    ) {
        throw "Libertix installation policy is incomplete or unsupported."
    }

    $storage = $policy.storage
    $memory = $policy.memory
    $account = $policy.account
    $volumeLabels = $policy.volumeLabels
    $reservedUsernames = @($account.reservedUsernames)
    $normalizedReservedUsernames = @(
        $reservedUsernames | ForEach-Object { ([string]$_).ToLowerInvariant() }
    )
    [int64]$alignmentBytes = [int64]$storage.partitionAlignmentBytes
    $allVolumeLabels = @(
        [string]$volumeLabels.installationMedia
        [string]$volumeLabels.staging
        @($volumeLabels.legacyStagingForRecovery | ForEach-Object { [string]$_ })
    )
    if (
        [int]$storage.minimumFinalSizeGiB -le 0 -or
        [int]$storage.targetWindowsFreeSpaceGiB -le 0 -or
        [int]$storage.windowsFreeSpaceToleranceGiB -lt 0 -or
        [int]$storage.windowsFreeSpaceToleranceGiB -ge `
            [int]$storage.targetWindowsFreeSpaceGiB -or
        [int]$storage.windowsFreeSpaceRetryWindowGiB -lt 0 -or
        [int]$storage.preflightShrinkSafetyGiB -lt 0 -or
        [int]$storage.maximumDirectFat32SizeGiB -lt `
            [int]$storage.minimumFinalSizeGiB -or
        [int]$storage.stagingSizeGiB -le 0 -or
        [int]$storage.stagingSizeGiB -gt `
            [int]$storage.maximumDirectFat32SizeGiB -or
        $alignmentBytes -le 0 -or
        ($alignmentBytes -band ($alignmentBytes - 1)) -ne 0 -or
        [double]$storage.recommendedLinuxFractionOfFreeSpace -le 0 -or
        [double]$storage.recommendedLinuxFractionOfFreeSpace -gt 1 -or
        [int]$storage.maximumRecommendedLinuxSizeGiB -lt `
            [int]$storage.minimumFinalSizeGiB -or
        [int]$memory.liveMinimumMiB -le 0 -or
        [int]$memory.windowsMinimumMiB -lt [int]$memory.liveMinimumMiB -or
        [int]$memory.lowMemoryThresholdMiB -le [int]$memory.windowsMinimumMiB -or
        [int]$policy.download.aria2MaximumConnections -le 0 -or
        [int]$policy.download.aria2MaximumConnections -gt 16 -or
        [int]$policy.download.maximumAttempts -le 0 -or
        [int]$policy.download.maximumAttempts -gt 20 -or
        [int]$policy.download.retryBaseDelaySeconds -le 0 -or
        [int]$policy.download.retryBaseDelaySeconds -gt 300 -or
        @($allVolumeLabels | Where-Object { $_ -cnotmatch '^[A-Z0-9]{1,11}$' }).Count -ne 0 -or
        @($allVolumeLabels | Sort-Object -Unique).Count -ne $allVolumeLabels.Count -or
        [string]::IsNullOrWhiteSpace([string]$account.reservedUsernamesSource) -or
        $reservedUsernames.Count -eq 0 -or
        @($reservedUsernames | Where-Object {
                [string]$_ -cnotmatch '^[A-Za-z](?:[A-Za-z0-9-]{0,30}[A-Za-z0-9])?$'
            }).Count -ne 0 -or
        @($normalizedReservedUsernames | Sort-Object -Unique).Count -ne `
            $normalizedReservedUsernames.Count
    ) {
        throw "Libertix installation policy contains invalid values."
    }

    $script:InstallationPolicy = $policy
    return $script:InstallationPolicy
}

Export-ModuleMember -Function "Get-LibertixInstallationPolicy"
