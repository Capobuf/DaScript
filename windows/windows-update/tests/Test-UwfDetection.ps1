#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tokens = $null
$errors = $null
$source = Join-Path $PSScriptRoot '..\WindowsUpdate.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$function = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-UwfEnabled'
}, $false)
. ([scriptblock]::Create($function.Extent.Text))
$script:checks = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

# Read-only queries obtain real CimException instances, including numeric StatusCode.
$missingName = 'DaScriptMissing_' + [Guid]::NewGuid().ToString('N')
$exceptions = @()
foreach ($query in @(
    @{Namespace='root/cimv2'; ClassName=$missingName; Expected=5},
    @{Namespace=('root/' + $missingName); ClassName='UWF_Filter'; Expected=3}
)) {
    try { $null = Get-CimInstance -Namespace $query.Namespace -ClassName $query.ClassName -ErrorAction Stop }
    catch {
        Assert-True ($_.Exception -is [Microsoft.Management.Infrastructure.CimException]) 'Expected a real CIM error.'
        Assert-True ($_.Exception.StatusCode -eq $query.Expected) 'Unexpected status from the read-only probe.'
        $exceptions += $_.Exception
    }
}
Assert-True ($exceptions.Count -eq 2) 'Missing-class/namespace probes did not both fail.'
$nativeResult = Test-UwfEnabled
Assert-True ($nativeResult -is [bool]) 'Native UWF detection did not return a Boolean.'
Write-Output ("Native read-only UWF check: enabled=$nativeResult")

# Test the detection function with captured real errors and synthetic provider states.
function Get-CimInstance {
    param($Namespace, $ClassName, $ErrorAction)
    if ($null -ne $script:providerError) { throw $script:providerError }
    return $script:providerInstances
}
$script:providerInstances = @()
foreach ($exception in $exceptions) {
    $script:providerError = $exception
    Assert-True (-not (Test-UwfEnabled)) 'An absent UWF provider blocked startup.'
}
$script:providerError = $null
foreach ($enabled in @($false, $true)) {
    $script:providerInstances = @([pscustomobject]@{CurrentEnabled=$enabled})
    Assert-True ((Test-UwfEnabled) -eq $enabled) 'UWF enabled state was misreported.'
}
foreach ($exception in @(
    [UnauthorizedAccessException]::new('Access denied'),
    [Microsoft.Management.Infrastructure.CimException]::new('Provider failure')
)) {
    $script:providerError = $exception
    $rejected = $false
    try { $null = Test-UwfEnabled }
    catch { $rejected = $_.Exception.Message -like 'Unable to determine Unified Write Filter status:*' }
    Assert-True $rejected 'An unrelated provider/access error was silently ignored.'
}
Write-Output ("PASS: $script:checks UWF checks; read-only CIM probes and isolated provider cases. No system changes.")
