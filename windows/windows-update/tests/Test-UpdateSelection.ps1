#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Load only selection functions; never execute the script's Start/Worker entry points.
$source = Join-Path $PSScriptRoot '..\MSP-WindowsUpdate.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$names = @('Get-SupportedPlatform', 'Get-Windows11UpgradeChoice', 'Initialize-Windows11UpgradeState',
    'Get-UpdateId', 'Test-FeatureUpgrade', 'Get-Candidates', 'Add-Skipped', 'Get-Failure')
foreach ($node in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($node.Name -in $names) { . ([scriptblock]::Create($node.Extent.Text)) }
}

# Substitute only OS reads and persistence. Updates below are synthetic WUA metadata.
function Get-CimInstance { param($ClassName) return $script:testOS }
function Get-ItemPropertyValue { param($LiteralPath, $Name) return $script:installationType }
function Save-State { param($State) }
$script:checks = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Assert-Throws {
    param([scriptblock]$Operation, [string]$Expected)
    try { & $Operation | Out-Null }
    catch {
        Assert-True ($_.Exception.Message -like $Expected) ('Unexpected error: ' + $_.Exception.Message)
        return
    }
    throw ('Expected rejection: ' + $Expected)
}

$script:testOS = [pscustomobject]@{ProductType=1; Version='10.0.19045'; Caption='Localized client name'}
$win10 = Get-SupportedPlatform
Assert-True ($win10.IsWindows10 -and -not $win10.IsWindows11) 'Windows 10 detection failed.'
$script:testOS.Version = '10.0.22000'
$win11 = Get-SupportedPlatform
Assert-True ($win11.IsWindows11 -and -not $win11.IsWindows10) 'Windows 11 detection failed.'
$script:testOS.ProductType = 3
$script:installationType = 'Server'
foreach ($version in @('10.0.17763', '10.0.20348', '10.0.26100')) {
    $script:testOS.Version = $version
    $server = Get-SupportedPlatform
    Assert-True ($server.IsServer -and -not $server.IsWindows10 -and -not $server.IsWindows11) 'Server detection failed.'
}
$script:installationType = 'Server Core'
Assert-Throws { Get-SupportedPlatform } '*Server Core is not supported*'
$script:installationType = ''
Assert-Throws { Get-SupportedPlatform } '*unrecognized server installation type*'
$script:installationType = 'Server'
$script:testOS.Version = '10.0.14393'
Assert-Throws { Get-SupportedPlatform } '*Server 2019*'
Assert-True (Get-Windows11UpgradeChoice $win10 'Allow') 'Explicit upgrade consent was lost.'
Assert-True (-not (Get-Windows11UpgradeChoice $win10 'Skip')) 'Skip authorized an upgrade.'
Assert-True (-not (Get-Windows11UpgradeChoice $win11 'Ask')) 'Windows 11 must not prompt.'
Assert-True (-not (Get-Windows11UpgradeChoice $server 'Ask')) 'Server must not prompt.'
Assert-Throws { Get-Windows11UpgradeChoice $win11 'Allow' } '*only available*'
Assert-Throws { Get-Windows11UpgradeChoice $server 'Allow' } '*only available*'

function New-TestState {
    $state = [pscustomobject]@{
        IncludeDrivers=$false; IncludeOptional=$false; IncludeFeatureUpgrades=$false
        MaxAttempts=3; Failures=@(); Skipped=@()
    }
    Initialize-Windows11UpgradeState $state
    return $state
}
function New-TestUpdate {
    param([string]$Title, [bool]$Upgrade = $true)
    return [pscustomobject]@{
        Identity=[pscustomobject]@{UpdateID=$Title; RevisionNumber=1}
        Title=$Title; Type=1; IsBeta=$false; BrowseOnly=$true
        Categories=@($(if ($Upgrade) { [pscustomobject]@{CategoryID='3689bdc8-b205-4af4-8d4a-a63924c5e9d5'} }))
        InstallationBehavior=[pscustomobject]@{CanRequestUserInput=$false; Impact=0}
    }
}
function Select-TestUpdate {
    param($State, $Update, $Platform = $win10)
    $collection = [pscustomobject]@{Entry=$Update; Count=1}
    $collection | Add-Member -MemberType ScriptMethod -Name Item -Value { param($index) return $this.Entry }
    return @(Get-Candidates $State ([pscustomobject]@{Updates=$collection}) $Platform)
}

$state = New-TestState
Assert-True (-not $state.Windows11UpgradeRequested) 'Legacy state acquired upgrade consent.'
$state.IncludeFeatureUpgrades = $true
$state.IncludeOptional = $true
$upgrade = New-TestUpdate 'Windows 11, version 25H2'
Assert-True (@(Select-TestUpdate $state $upgrade).Count -eq 0) 'General upgrade flags bypassed Windows 11 consent.'
$state = New-TestState
$state.Windows11UpgradeRequested = $true
Assert-True (@(Select-TestUpdate $state $upgrade).Count -eq 1) 'An authorized optional Windows 11 upgrade was excluded.'
Assert-True ($state.Windows11UpgradeOffered -and $state.Windows11UpgradeStatus -eq 'Offered') 'Offer status was not recorded.'
$state = $state | ConvertTo-Json -Depth 8 | ConvertFrom-Json
Initialize-Windows11UpgradeState $state
Assert-True $state.Windows11UpgradeRequested 'Persisted consent was lost on resume.'
Assert-True (@(Select-TestUpdate $state (New-TestUpdate 'Windows 10, version 22H2')).Count -eq 0) 'Windows 11 consent enabled unrelated feature upgrades.'
Assert-True (@(Select-TestUpdate $state (New-TestUpdate 'Cumulative Update for Windows 11' $false)).Count -eq 0) 'Product name alone bypassed optional filtering.'
$state.IncludeFeatureUpgrades = $true
$state.IncludeOptional = $true
Assert-True (@(Select-TestUpdate $state (New-TestUpdate 'Unrecognized OS upgrade')).Count -eq 0) 'An unidentified target OS was allowed.'
$upgrade.IsBeta = $true
Assert-True (@(Select-TestUpdate $state $upgrade).Count -eq 0) 'Upgrade consent enabled beta content.'
$upgrade.IsBeta = $false
$upgrade.InstallationBehavior.CanRequestUserInput = $true
Assert-True (@(Select-TestUpdate $state $upgrade).Count -eq 0) 'Upgrade consent enabled interactive installation.'
$upgrade.InstallationBehavior.CanRequestUserInput = $false
$state.IncludeFeatureUpgrades = $false
Assert-True (@(Select-TestUpdate $state $upgrade $win11).Count -eq 0) 'Windows 10 consent enabled later Windows 11 feature upgrades.'
$state = New-TestState
$state.IncludeDrivers = $true
$state.IncludeOptional = $true
$driver = New-TestUpdate 'OEM Firmware' $false
$driver.Type = 2
Assert-True (@(Select-TestUpdate $state $driver).Count -eq 1) 'Optional firmware driver was excluded.'
$state.IncludeDrivers = $false
Assert-True (@(Select-TestUpdate $state $driver).Count -eq 0) 'Explicit driver exclusion was ignored.'
foreach ($name in @('IncludeDrivers', 'IncludeOptional')) {
    $parameter = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $name }
    Assert-True ($parameter.DefaultValue.Extent.Text -eq '$true') ("Default $name must include updates.")
}
Write-Output ("PASS: $script:checks checks (synthetic selection/platform cases; no updates or system changes).")
