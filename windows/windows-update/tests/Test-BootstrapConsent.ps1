#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tokens = $null
$errors = $null
$source = Join-Path $PSScriptRoot '..\bootstrap.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }

# Execute only the consent block; no elevation, downloads, worker or updates.
$consentNode = @($ast.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.IfStatementAst] -and
    $_.Clauses[0].Item1.Extent.Text -eq '-not $AllowServerReboot'
})
if ($consentNode.Count -ne 1) { throw 'Bootstrap consent block not found.' }
$consent = [scriptblock]::Create($consentNode[0].Extent.Text)
$script:checks = 0
$script:productType = 1
$script:providerFailure = $false
$script:promptFailure = $false
$script:answer = ''
$script:promptCount = 0
$script:queryCount = 0
function Get-CimInstance {
    param($ClassName, $ErrorAction)
    $script:queryCount++
    if ($script:providerFailure) { throw 'CIM unavailable' }
    [pscustomobject]@{ProductType=$script:productType}
}
function Read-Host {
    param($Prompt)
    $script:promptCount++
    if ($script:promptFailure) { throw 'Host cannot read input' }
    $script:answer
}
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Invoke-Consent {
    param([switch]$AllowServerReboot)
    . $consent
    [bool]$AllowServerReboot
}
function Assert-Rejected {
    param([string]$Expected)
    $message = ''
    try { $null = Invoke-Consent }
    catch { $message = $_.Exception.Message }
    Assert-True ($message -like $Expected) "Unexpected consent result: $message"
}

Assert-True (-not (Invoke-Consent)) 'A client received server restart consent.'
Assert-True ($script:promptCount -eq 0) 'A client was prompted.'
$script:providerFailure = $true
$queriesBefore = $script:queryCount
Assert-True (Invoke-Consent -AllowServerReboot) 'Explicit consent was lost.'
Assert-True ($script:queryCount -eq $queriesBefore -and $script:promptCount -eq 0) 'Explicit consent queried or prompted again.'
Assert-Rejected 'CIM unavailable'
$script:providerFailure = $false
foreach ($value in @($null, 0, 4)) {
    $script:productType = $value
    Assert-Rejected 'Unable to determine*'
}

$canPrompt = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and
    [Diagnostics.Process]::GetCurrentProcess().SessionId -ne 0
foreach ($value in @(2, 3)) {
    $script:productType = $value
    if ($canPrompt) {
        foreach ($reply in @('', 'n', 'no', 'yes', 'invalid')) {
            $script:answer = $reply
            Assert-Rejected 'Server restarts were not authorized*'
        }
        foreach ($reply in @('s', 'S', ' s ')) {
            $script:answer = $reply
            Assert-True (Invoke-Consent) 'Affirmative consent was not passed on.'
        }
        $script:promptFailure = $true
        Assert-Rejected 'Cannot read the initial choice*'
        $script:promptFailure = $false
    } else {
        $promptsBefore = $script:promptCount
        Assert-Rejected 'Unattended start on Windows Server requires*'
        Assert-True ($script:promptCount -eq $promptsBefore) 'Unattended startup attempted to prompt.'
    }
}
Write-Output ("PASS: $script:checks bootstrap consent checks; synthetic CIM/input, native session checks. Prompt cases: $canPrompt. No system changes.")
