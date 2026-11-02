#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tokens = $null
$errors = $null
$source = Join-Path $PSScriptRoot '..\WindowsUpdate.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('Get-BootId', 'Test-BootChanged')) {
    $node = $ast.Find({ param($n)
        $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name
    }, $false)
    if ($null -eq $node) { throw "Missing function: $name" }
    . ([scriptblock]::Create($node.Extent.Text))
}
$script:checks = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Assert-Throws {
    param([scriptblock]$Operation)
    try { & $Operation | Out-Null } catch { $script:checks++; return }
    throw 'Expected invalid or unavailable boot evidence to be rejected.'
}

# Real, read-only CIM queries; no worker, update, task or restart is invoked.
$native = Get-BootId
Assert-True ($native -match '^cimboot:[1-9]\d+$') 'Native boot identity is missing.'
Assert-True (-not (Test-BootChanged $native (Get-BootId))) 'Boot identity changed between native queries.'

function Get-WinEvent { throw 'NoMatchingEventsFound' }
$script:boot = [DateTime]::new(2026, 1, 1, 8, 0, 0, [DateTimeKind]::Utc)
$script:cimFailure = $false
function Get-CimInstance {
    param($ClassName, $Property, $ErrorAction)
    if ($script:cimFailure) { throw [UnauthorizedAccessException]::new('CIM unavailable') }
    [pscustomobject]@{LastBootUpTime=$script:boot}
}
$first = Get-BootId
Assert-True ($first -eq ('cimboot:' + $script:boot.Ticks)) 'Missing events prevented CIM boot detection.'
Assert-True (-not (Test-BootChanged $first (Get-BootId))) 'The same boot was treated as a restart.'
$script:boot = $script:boot.ToLocalTime()
Assert-True ($first -eq (Get-BootId)) 'Local and UTC representations differed.'
$script:boot = $script:boot.AddMinutes(5)
Assert-True (Test-BootChanged $first (Get-BootId)) 'A new boot time was not detected.'
$script:cimFailure = $true
Assert-Throws { Get-BootId }
$script:cimFailure = $false
foreach ($value in @($null, '', '2026-01-01', [DateTime]::MinValue)) {
    $script:boot = $value
    Assert-Throws { Get-BootId }
}
foreach ($value in @('', 'legacy-ticks', 'event12:1:100', 'cimboot:0', 'cimboot:-1',
    'cimboot:01', 'cimboot:9999999999999999999', 'cimboot:3155378976000000000')) {
    Assert-Throws { Test-BootChanged $value $first }
    Assert-Throws { Test-BootChanged $first $value }
}
Write-Output ("PASS: $script:checks boot identity checks; native read-only CIM and synthetic missing events/provider failures. No system changes.")
