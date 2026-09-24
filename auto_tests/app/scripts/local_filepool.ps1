param([Parameter(Mandatory = $true)][string]$ConfigPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$directory = [IO.Path]::GetFullPath([string]$config.directory)
if ([IO.Path]::GetFileName($directory) -ne 'filepool') {
    throw 'Expected the adjacent filepool directory'
}
if ($config.mode -eq 'prepare') {
    if (Test-Path -LiteralPath $directory) { throw 'The test filepool directory already exists' }
    New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null
    return
}
if ($config.mode -ne 'verify') { throw 'Unknown local filepool operation' }
$processId = [int]$config.process_id
$root = Join-Path ([IO.Path]::GetPathRoot($env:SystemRoot)) 'LibertixInstallLogs\Windows'
$logs = @(Get-ChildItem -LiteralPath $root -Filter "libertix-exe-*-pid$processId.log" -File)
if ($logs.Count -ne 1) { throw 'Expected exactly one log for the current Libertix process' }
$text = Get-Content -LiteralPath $logs[0].FullName -Raw
foreach ($proof in @(
    "Local filepool selected: $directory",
    "LOCAL_FILEPOOL_ONLINE_VERIFIED=$directory",
    'Copying distribution ISO from the selected local filepool...',
    'Copying Libertix UEFI ISO from the selected local filepool...',
    'UEFI installation preparation completed successfully.'
)) {
    if (-not $text.Contains($proof)) { throw "Missing local filepool evidence: $proof" }
}
Write-Output 'LOCAL_FILEPOOL_USED=True'
Write-Output ("SOURCE_LOG=" + $logs[0].FullName)
