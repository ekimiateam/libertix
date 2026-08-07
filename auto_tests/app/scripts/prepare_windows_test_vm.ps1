#requires -Version 5.1

param([Parameter(Mandatory = $true)][string]$ConfigPath)

$ErrorActionPreference = "Stop"
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$target = [DateTimeOffset]::Parse(
    [string]$config.utc_now,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::RoundtripKind
)
$before = [DateTimeOffset]::Now
$beforeSkew = [math]::Abs(($before - $target).TotalSeconds)

# Restored test snapshots keep their historical RTC value. Correct only a
# material skew so HTTPS validation exercises the server certificate rather
# than an obsolete snapshot date.
if ($beforeSkew -gt 120) {
    Set-Date -Date $target.LocalDateTime | Out-Null
}

$after = [DateTimeOffset]::Now
$afterSkew = [math]::Abs(($after - $target).TotalSeconds)
if ($afterSkew -gt 300) {
    throw "Windows test VM clock remains $([math]::Round($afterSkew)) seconds from the controller."
}

Write-Output "UTC_NOW=$($after.UtcDateTime.ToString('o'))"
Write-Output "CLOCK_SKEW_SECONDS=$([math]::Round($afterSkew))"
