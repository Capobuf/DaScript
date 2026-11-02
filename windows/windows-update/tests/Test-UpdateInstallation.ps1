#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Load only the tested functions; never execute Start/Worker or create real WUA objects.
$source = Join-Path $PSScriptRoot '..\WindowsUpdate.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$names = @('Get-Candidates','Get-UpdateId','Test-FeatureUpgrade','Add-Skipped',
    'Install-Batch','Invoke-WuaOperation','Wait-WuaJob','Format-HResult',
    'Get-Failure','Add-Failure','Resolve-Failure','Reset-WuaProgress')
foreach ($node in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($node.Name -in $names) { . ([scriptblock]::Create($node.Extent.Text)) }
}
$script:checks = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Save-State { param($State) }
function Set-Phase { param($State, $Phase, $Message) }
function Get-BootId { return 'event12:1:100' }
function Initialize-WuaCallback { }
function Test-StopRequested { param($State) return $false }
function Test-UpdateRebootPending { return $false }
function Schedule-Reboot { throw 'Unexpected reboot request.' }
function Write-Log {
    param($Message, $Level='INFO')
    $script:log.Add([pscustomobject]@{Message=$Message; Level=$Level})
}
function New-Object {
    param([string]$TypeName, [string]$ComObject)
    if ($ComObject -eq 'Microsoft.Update.UpdateColl') { return ,([Collections.ArrayList]::new()) }
    if ($TypeName -eq 'DaScript.WindowsUpdate.Callback') { return [pscustomobject]@{} }
    throw 'Unexpected object creation in test.'
}
function New-TestUpdate {
    param([string]$Title, [bool]$CanRequestUserInput, [int]$ResultCode=2, [long]$HResult=0)
    $update = [pscustomobject]@{
        Title=$Title; Identity=[pscustomobject]@{UpdateID=$Title; RevisionNumber=1}
        Type=2; IsBeta=$false; Categories=@(); BrowseOnly=$true
        InstallationBehavior=[pscustomobject]@{CanRequestUserInput=$CanRequestUserInput; Impact=0}
        EulaAccepted=$false; IsDownloaded=$false
        TestResult=[pscustomobject]@{ResultCode=$ResultCode; HResult=$HResult}
    }
    $update | Add-Member ScriptMethod AcceptEula { $this.EulaAccepted=$true }
    return $update
}
function New-TestState {
    $script:log = [Collections.Generic.List[object]]::new()
    $script:downloaded = @()
    $script:attempted = @()
    return [pscustomobject]@{
        IncludeDrivers=$true; IncludeOptional=$true; IncludeFeatureUpgrades=$false
        MaxAttempts=3; Failures=@(); Skipped=@(); Installed=@()
        ActiveOperation=''; OperationBootId=''; OperationStartedUtc=''; OperationProcessId=0; ProgressPercent=-1
    }
}

$script:job = [pscustomobject]@{IsCompleted=$true; Cleanups=0}
$script:job | Add-Member ScriptMethod CleanUp { $this.Cleanups++ }
$script:downloader = [pscustomobject]@{Updates=$null}
$script:downloader | Add-Member ScriptMethod BeginDownload {
    param($progress, $callback, $context)
    $script:downloaded = @($this.Updates)
    return $script:job
}
$script:downloader | Add-Member ScriptMethod EndDownload {
    param($job)
    foreach ($update in $this.Updates) { $update.IsDownloaded=$true }
    $result = [pscustomobject]@{}
    $result | Add-Member ScriptMethod GetUpdateResult { param($index) return [pscustomobject]@{ResultCode=2; HResult=0} }
    return $result
}
$script:installer = [pscustomobject]@{
    Updates=$null; AllowSourcePrompts=$true; ForceQuiet=$false; IsBusy=$false; RebootRequiredBeforeInstallation=$false
}
$script:installer | Add-Member ScriptMethod BeginInstall {
    param($progress, $callback, $context)
    Assert-True ($this.ForceQuiet -and -not $this.AllowSourcePrompts) 'Unattended installation enabled prompts.'
    $script:attempted = @($this.Updates)
    return $script:job
}
$script:installer | Add-Member ScriptMethod EndInstall {
    param($job)
    # The aggregate result deliberately succeeds: individual results must still be inspected.
    $result = [pscustomobject]@{ResultCode=2; RebootRequired=$false; Entries=@($this.Updates)}
    $result | Add-Member ScriptMethod GetUpdateResult { param($index) return $this.Entries[$index].TestResult }
    return $result
}
$session = [pscustomobject]@{}
$session | Add-Member ScriptMethod CreateUpdateDownloader { return $script:downloader }
$session | Add-Member ScriptMethod CreateUpdateInstaller { return $script:installer }
$platform = [pscustomobject]@{IsWindows10=$false}

$state = New-TestState
$driver = New-TestUpdate 'Realtek Semiconductor Corp. Driver Update (1030.52.1216.2025)' $true
$regular = New-TestUpdate 'Ordinary update' $false
$search = [pscustomobject]@{Updates=[Collections.ArrayList]@($driver, $regular)}
$candidates = @(Get-Candidates $state $search $platform)
$succeeded = Install-Batch $state $session $candidates
Assert-True ($script:downloaded.Count -eq 2 -and $script:downloaded[0] -eq $driver) 'Flagged update did not reach download.'
Assert-True ($script:attempted.Count -eq 2 -and $script:attempted[0] -eq $driver) 'Flagged update did not reach BeginInstall.'
Assert-True ($driver.EulaAccepted -and $driver.IsDownloaded) 'Flagged update bypassed normal preparation.'
Assert-True ($succeeded -and $state.Installed.Count -eq 2 -and $state.Failures.Count -eq 0 -and $state.Skipped.Count -eq 0) 'Successful flagged update was not completed normally.'
$notice = @($script:log | Where-Object { $_.Message -like 'Update may require interactive input*' })
Assert-True ($notice.Count -eq 1 -and $notice[0].Level -eq 'INFO') 'Possible interaction was not purely informational.'
Assert-True (-not $state.ActiveOperation -and $script:job.Cleanups -eq 2) 'Asynchronous operations were not finalized.'

$cases = @(
    @{Code=4; HR=0x8024200A; Diagnostic='*WU_E_UH_CANREQUIREINPUT: Manual intervention required*'}
    @{Code=4; HR=0x80240020; Diagnostic='*WU_E_NO_INTERACTIVE_USER: Manual intervention required*'}
    @{Code=4; HR=0x80242004; Diagnostic='*WU_E_UH_DOESNOTSUPPORTACTION:*operator review required*'}
)
foreach ($code in @(0,1,3,4,5)) {
    $cases += @{Code=$code; HR=0x80004005; Diagnostic='Result=*; HRESULT=0x80004005'}
}
foreach ($case in $cases) {
    $state = New-TestState
    $failed = New-TestUpdate 'Flagged failure' $true $case.Code $case.HR
    $other = New-TestUpdate 'Successful companion' $false
    $search.Updates = [Collections.ArrayList]@($failed, $other)
    $succeeded = Install-Batch $state $session @(Get-Candidates $state $search $platform)
    Assert-True ($script:attempted.Count -eq 2 -and $script:attempted[1] -eq $other) 'One failing update prevented another installation attempt.'
    Assert-True ($succeeded -and $state.Installed.Count -eq 1 -and $state.Installed[0].Title -eq $other.Title) 'Aggregate success hid an individual failure.'
    Assert-True ($state.Failures.Count -eq 1 -and $state.Skipped.Count -eq 0) 'Actual failure was lost or marked as an exclusion.'
    $failure = $state.Failures[0]
    Assert-True ($failure.Reason -like $case.Diagnostic -and $failure.Reason.Contains("Result=$($case.Code); HRESULT=$(Format-HResult $case.HR)")) 'Actual result or diagnostic was lost.'
    if ($case.HR -eq 0x80004005) {
        Assert-True ($failure.Reason -notlike '*Manual intervention*') 'Metadata falsely classified a generic failure as an interaction requirement.'
    }
    Assert-True ($failure.Stage -eq 'Install' -and $failure.Attempts -eq 1 -and -not $failure.Resolved) 'Existing failure bookkeeping changed.'
    $failed.TestResult = [pscustomobject]@{ResultCode=2; HResult=0}
    Assert-True (Install-Batch $state $session @($failed)) 'A successful retry was not recognized.'
    Assert-True ($failure.Resolved -and $state.Installed.Count -eq 2) 'A successful retry left its previous failure open.'
}

$state = New-TestState
$failed = New-TestUpdate 'Only failed update' $true 4 0x8024200A
Assert-True (-not (Install-Batch $state $session @($failed))) 'A failed-only batch claimed progress.'
Assert-True ($state.Installed.Count -eq 0 -and $state.Failures.Count -eq 1) 'A failed-only batch recorded an installation.'
Write-Output ("PASS: $script:checks installation checks (synthetic WUA objects/results; no updates or system changes).")
