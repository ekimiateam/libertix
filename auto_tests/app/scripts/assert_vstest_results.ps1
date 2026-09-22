param(
    [Parameter(Mandatory = $true)]
    [string]$TestResultPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# A successful runner exit alone does not prove that any tests were executed.
[xml]$report = Get-Content -LiteralPath $TestResultPath -Raw -ErrorAction Stop
$namespaces = New-Object Xml.XmlNamespaceManager($report.NameTable)
$namespaces.AddNamespace('t', 'http://microsoft.com/schemas/VisualStudio/TeamTest/2010')
$counters = $report.SelectSingleNode('/t:TestRun/t:ResultSummary/t:Counters', $namespaces)
$results = @($report.SelectNodes('/t:TestRun/t:Results/t:UnitTestResult', $namespaces))
if ($null -eq $counters) {
    throw "VSTest result counters are missing: $TestResultPath"
}
$total = [int]$counters.total
$passed = [int]$counters.passed
$executed = [int]$counters.executed
if ($total -le 0 -or $passed -ne $total -or $executed -ne $total -or
    $results.Count -ne $total -or @($results | Where-Object outcome -ne 'Passed').Count -ne 0) {
    throw "Incomplete or failed C# tests: total=$total, executed=$executed, passed=$passed; report=$TestResultPath"
}
Write-Output "VSTEST_TESTS=$passed/$total"
