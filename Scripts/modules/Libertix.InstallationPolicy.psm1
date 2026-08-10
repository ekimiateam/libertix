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
        $null -eq $policy.download
    ) {
        throw "Libertix installation policy is incomplete or unsupported."
    }

    $storage = $policy.storage
    $memory = $policy.memory
    [int64]$alignmentBytes = [int64]$storage.partitionAlignmentBytes
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
        [int]$storage.largeInstallationStagingSizeGiB -le 0 -or
        [int]$storage.largeInstallationStagingSizeGiB -gt `
            [int]$storage.maximumDirectFat32SizeGiB -or
        $alignmentBytes -le 0 -or
        ($alignmentBytes -band ($alignmentBytes - 1)) -ne 0 -or
        [int]$memory.liveMinimumMiB -le 0 -or
        [int]$memory.windowsMinimumMiB -lt [int]$memory.liveMinimumMiB -or
        [int]$memory.lowMemoryThresholdMiB -le [int]$memory.windowsMinimumMiB -or
        [int]$policy.download.aria2MaximumConnections -le 0 -or
        [int]$policy.download.aria2MaximumConnections -gt 16
    ) {
        throw "Libertix installation policy contains invalid values."
    }

    $script:InstallationPolicy = $policy
    return $script:InstallationPolicy
}

Export-ModuleMember -Function "Get-LibertixInstallationPolicy"
