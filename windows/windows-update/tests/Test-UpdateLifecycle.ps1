#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module ScheduledTasks -ErrorAction Stop
$tokens = $null
$errors = $null
$source = Join-Path $PSScriptRoot '..\MSP-WindowsUpdate.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
# Define functions only. WUA, task registration and the main entry point are never executed.
foreach ($node in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    # Route registration to a unique test sink that module autoload cannot replace.
    . ([scriptblock]::Create($node.Extent.Text.Replace('Register-ScheduledTask -TaskName', 'Register-TestScheduledTask -TaskName')))
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
    throw 'Expected an exception.'
}
# Replace external side effects; keep actual state files, locks, callbacks and control flow.
function Assert-Administrator { }
$nativeBootId = Get-BootId
Assert-True ($nativeBootId -match '^event12:\d+:\d+$') 'Native boot event did not provide an identity.'
Assert-True (-not (Test-BootChanged $nativeBootId (Get-BootId))) 'Boot identity changed between read-only queries.'
Assert-Throws { Test-BootChanged 'legacy-ticks' $nativeBootId }
$script:testBootId = 'event12:1:100'
function Get-BootId { return $script:testBootId }
function Invoke-SystemRestart { $script:restarts++; return $script:restartExit }
function Remove-TaskSafely {
    param($Name, [switch]$Strict)
    if ($script:failCleanup -and $Strict) { throw 'Synthetic task cleanup failure' }
    $script:removedTasks++
}
function Get-ScheduledTask { param($TaskName) return [pscustomobject]@{State='Ready'} }
function Start-ScheduledTask { param($TaskName) $script:taskStarts++ }
function Register-TestScheduledTask {
    param($TaskName, $Action, $Trigger, $Principal, $Settings, [switch]$Force)
    $script:taskDefinition = [pscustomobject]@{Action=$Action; Trigger=$Trigger; Principal=$Principal; Settings=$Settings}
}
function New-Object {
    [CmdletBinding()]
    param([Parameter(Position=0)][string]$TypeName, [string]$ComObject)
    if ($ComObject) { throw 'Tests must never instantiate WUA COM objects.' }
    Microsoft.PowerShell.Utility\New-Object @PSBoundParameters
}
function Play-CompletionSound { $script:sounds++ }
function Start-Sleep { param($Seconds, $Milliseconds) if ($script:sleepHook) { & $script:sleepHook } }
$testBase = Join-Path ([IO.Path]::GetTempPath()) ('DaScript-tests-' + [Guid]::NewGuid().ToString('N'))
$originalProgramData = $env:ProgramData
$script:Root = Join-Path $testBase 'MSPTools\WindowsUpdate'
[void][IO.Directory]::CreateDirectory($script:Root)
$script:StatePath = Join-Path $script:Root 'state.json'
$script:BackupPath = Join-Path $script:Root 'state.json.bak'
$script:LogPath = Join-Path $script:Root 'activity.log'
$script:StopPath = Join-Path $script:Root 'stop.request'
$script:ControlLockName = 'Local\DaScript-tests-control-' + [Guid]::NewGuid().ToString('N')
$script:WorkerLockName = 'Local\DaScript-tests-worker-' + [Guid]::NewGuid().ToString('N')
$script:NotificationPath = Join-Path $script:Root 'completion-notified'
$script:ResultReadPath = Join-Path $script:Root 'result-read'
$script:TaskName = 'Unused-test-task'
$script:MonitorTaskName = 'Unused-test-monitor'
$script:WorkerPath = $source
$script:MonitorRunId = ''
$script:TerminalStates = @('Completed','CompletedWithExclusions','CompletedWithErrors','Blocked','Stopped')
$script:restarts = 0
$script:restartExit = 0
$script:removedTasks = 0
$script:taskStarts = 0
$script:sounds = 0
$script:sleepHook = $null
$script:failCleanup = $false

function New-TestState {
    [void][IO.Directory]::CreateDirectory($script:Root)
    if ([IO.File]::Exists($script:StopPath)) { [IO.File]::Delete($script:StopPath) }
    $script:sleepHook = $null
    $state = [pscustomobject]@{
        RunId='01234567890123456789012345678901'; Status='Running'; Phase='Queued'; Message=''; UpdatedUtc=''
        StartedUtc=[DateTime]::UtcNow.ToString('o'); Reboots=0; MaxReboots=8; IsServer=$false; AllowServerReboot=$false
        RebootBootId=''; RebootRequestedUtc=''; Installed=@(); Failures=@(); Skipped=@()
        ConsecutiveErrors=0; MaxAttempts=3; LastError=''
    }
    Initialize-RuntimeState $state
    $state.RebootDelaySeconds = 0
    Save-State $state
    return $state
}
function New-TestJob {
    $job = [pscustomobject]@{IsCompleted=$false; Aborts=0; Cleaned=$false; FailProgress=$false}
    $job | Add-Member ScriptMethod RequestAbort { $this.Aborts++ }
    $job | Add-Member ScriptMethod CleanUp { if (-not $this.IsCompleted) { throw 'Unsafe cleanup' }; $this.Cleaned=$true }
    $job | Add-Member ScriptMethod GetProgress {
        if ($this.FailProgress) { throw 'Synthetic progress error' }
        return [pscustomobject]@{PercentComplete=42; CurrentUpdateIndex=0}
    }
    return $job
}
try {
    Initialize-WuaCallback
    $callback = New-Object MSPWindowsUpdate.Callback
    $dispatch = [Runtime.InteropServices.Marshal]::GetIDispatchForObject($callback)
    try { Assert-True ($dispatch -ne [IntPtr]::Zero) 'Callback has no IDispatch interface.' }
    finally { [void][Runtime.InteropServices.Marshal]::Release($dispatch) }

    $first = Enter-RunLock $script:WorkerLockName -TimeoutSeconds 0
    $otherThread = [PowerShell]::Create()
    try {
        [void]$otherThread.AddScript('param($name) $m = [Threading.Mutex]::OpenExisting($name); try { $owned = $m.WaitOne(0); if ($owned) { $m.ReleaseMutex() }; $owned } finally { $m.Dispose() }').AddArgument($script:WorkerLockName)
        $result = @($otherThread.Invoke())
        Assert-True (-not $otherThread.HadErrors -and $result.Count -eq 1 -and -not $result[0]) 'Another thread acquired the worker mutex.'
    } finally { $otherThread.Dispose(); Exit-RunLock $first }
    $second = Enter-RunLock $script:WorkerLockName -TimeoutSeconds 0
    Exit-RunLock $second
    $script:checks++

    $state = New-TestState
    [IO.File]::WriteAllText($script:StopPath, 'stop')
    Schedule-Reboot $state 'test'
    Assert-True ($state.Status -eq 'Stopped' -and $script:restarts -eq 0) 'Stop before countdown did not prevent restart.'
    $state = New-TestState
    $state.RebootDelaySeconds = 90
    $script:sleepHook = { [IO.File]::WriteAllText($script:StopPath, 'stop') }
    Schedule-Reboot $state 'test'
    Assert-True ($state.Status -eq 'Stopped' -and $script:restarts -eq 0) 'Stop during countdown did not prevent restart.'

    # Inject a stop exactly when the final decision obtains the real control mutex.
    $realEnterLock = (Get-Item Function:Enter-RunLock).ScriptBlock
    function Enter-RunLock {
        param($Name, $TimeoutSeconds=5)
        $handle = & $realEnterLock $Name $TimeoutSeconds
        [IO.File]::WriteAllText($script:StopPath, 'stop')
        return $handle
    }
    $state = New-TestState
    Schedule-Reboot $state 'test'
    Assert-True ($state.Status -eq 'Stopped' -and $script:restarts -eq 0) 'Final reboot decision ignored stop.'
    Set-Item Function:Enter-RunLock $realEnterLock

    $state = New-TestState
    Schedule-Reboot $state 'test'
    Assert-True ($state.RebootCommitted -and $state.Status -eq 'WaitingForReboot' -and $script:restarts -eq 1) 'Restart was not committed.'
    Invoke-Stop -WarningAction SilentlyContinue
    $saved = Get-State
    Assert-True ($saved.Status -eq 'WaitingForReboot' -and $saved.RebootCommitted) 'Late stop falsely reported a cancelled reboot.'
    Assert-True ([IO.File]::Exists($script:StopPath)) 'Late stop was not persisted for the next boot.'
    Invoke-WorkerCore
    Assert-True ((Get-State).Status -eq 'WaitingForReboot') 'A still-pending committed reboot was falsely reported as stopped.'
    $script:testBootId = 'event12:2:200'
    Invoke-WorkerCore
    Assert-True ((Get-State).Status -eq 'Stopped') 'Stop was not applied before any resumed update work.'
    $script:testBootId = 'event12:1:100'

    $state = New-TestState
    $script:restartExit = 5
    Schedule-Reboot $state 'test'
    Assert-True ($state.Status -eq 'Blocked' -and -not $state.RebootCommitted) 'Rejected restart was not reported.'
    $script:restartExit = 0
    $state = New-TestState
    Invoke-Stop
    Assert-True ((Get-State).Status -eq 'Running' -and $script:taskStarts -gt 0) 'Stop overwrote worker state or failed to wake the worker.'

    $state = New-TestState
    $state.ActiveOperation = 'Install'
    $state.OperationBootId = 'event12:1:100'
    Save-State $state
    Invoke-WorkerCore
    Assert-True ((Get-State).Status -eq 'Blocked') 'Uncertain installation was allowed to resume on the same boot.'

    $state = New-TestState
    $state.ActiveOperation = 'Scan'
    $state.OperationBootId = 'event12:0:50'
    Save-State $state
    [IO.File]::WriteAllText($script:StopPath, 'stop')
    Invoke-WorkerCore
    Assert-True ((Get-State).Status -eq 'Stopped' -and -not (Get-State).ActiveOperation) 'Confirmed reboot did not clear the old operation before applying stop.'
    Assert-True ((Get-Content -LiteralPath $script:LogPath -Raw) -like '*Previous Scan was not finalized*new Windows boot confirmed*') 'Recovery diagnostic omitted the interrupted operation and boot evidence.'

    $platform = [pscustomobject]@{IsWindows11=$true}
    $state = New-TestState
    $state.Skipped = @([pscustomobject]@{Title='Interactive driver'; Reason='Update may require interactive input'})
    Complete-UpdateRun $state $platform
    Assert-True ($state.Status -eq 'CompletedWithExclusions' -and $state.Message -like '*failures=0, excluded=1*') 'Exclusions were classified as errors.'
    $state.Failures = @([pscustomobject]@{Resolved=$false})
    Complete-UpdateRun $state $platform
    Assert-True ($state.Status -eq 'CompletedWithErrors') 'An actual failure was hidden by exclusions.'
    $state.Failures[0].Resolved = $true
    $state.Skipped = @()
    Complete-UpdateRun $state $platform
    Assert-True ($state.Status -eq 'Completed') 'A resolved error prevented successful completion.'
    $state.Windows11UpgradeRequested = $true
    $platform.IsWindows11 = $false
    Complete-UpdateRun $state $platform
    Assert-True ($state.Status -eq 'CompletedWithExclusions' -and $state.Windows11UpgradeStatus -eq 'NotOffered') 'An unavailable upgrade was classified as an installation failure.'
    $state.Windows11UpgradeOffered = $true
    Complete-UpdateRun $state $platform
    Assert-True ($state.Status -eq 'CompletedWithErrors' -and $state.Windows11UpgradeStatus -eq 'NotCompleted') 'An offered but incomplete upgrade was reported as completed.'

    $state = New-TestState
    $script:fakeJob = New-TestJob
    [IO.File]::WriteAllText($script:StopPath, 'stop')
    $script:sleepHook = { $script:fakeJob.IsCompleted=$true }
    $timedOut = Wait-WuaJob $state $script:fakeJob 'Install'
    Assert-True (-not $timedOut -and $script:fakeJob.Aborts -eq 0) 'Operator stop interrupted an active installation.'
    $script:fakeJob = New-TestJob
    $timedOut = Wait-WuaJob $state $script:fakeJob 'Scan'
    Assert-True (-not $timedOut -and $script:fakeJob.Aborts -eq 1) 'Scan did not request cooperative cancellation.'

    $state = New-TestState
    $state.OperationTimeoutMinutes = 0
    $script:fakeJob = New-TestJob
    $script:sleepHook = { $script:fakeJob.IsCompleted=$true }
    $timedOut = Wait-WuaJob $state $script:fakeJob 'Install'
    Assert-True ($timedOut -and $script:fakeJob.Aborts -eq 1) 'Timeout did not request WUA cancellation.'
    $script:fakeJob = New-TestJob
    $before = $script:removedTasks
    $timedOut = Wait-WuaJob $state $script:fakeJob 'Install' -AbortGraceSeconds 0
    Assert-True ($timedOut -and $state.Status -eq 'Blocked' -and $script:removedTasks -gt $before) 'Unfinished cancellation was not blocked.'

    $state = New-TestState
    $script:fakeJob = New-TestJob
    $script:fakeJob.IsCompleted = $true
    $agent = [pscustomobject]@{}
    $agent | Add-Member ScriptMethod BeginSearch { param($criteria,$callback,$context) return $script:fakeJob }
    $agent | Add-Member ScriptMethod EndSearch { param($job) return [pscustomobject]@{ResultCode=2} }
    $result = Invoke-WuaOperation $state $agent 'Scan'
    Assert-True ($result.Result.ResultCode -eq 2 -and $script:fakeJob.Cleaned -and -not $state.ActiveOperation) 'Completed asynchronous operation was not finalized.'
    $script:fakeJob = New-TestJob
    $script:fakeJob.FailProgress = $true
    $agent | Add-Member ScriptMethod BeginDownload { param($progress,$callback,$context) return $script:fakeJob }
    Assert-Throws { Invoke-WuaOperation $state $agent 'Download' }
    Assert-True ($state.ActiveOperation -eq 'Download' -and -not $script:fakeJob.Cleaned) 'Incomplete operation lost its recovery marker or performed blocking cleanup.'

    $state = New-TestState
    $state.Status = 'Completed'
    Save-State $state
    Send-CompletionSound $state
    Send-CompletionSound $state
    Assert-True ($script:sounds -eq 1) 'Success notification was not once per run.'
    [IO.File]::Delete($script:NotificationPath)
    $state.Status = 'CompletedWithErrors'
    Save-State $state
    Send-CompletionSound $state
    Assert-True ($script:sounds -eq 1) 'An error result played the success sound.'
    $state.Status = 'CompletedWithExclusions'
    Save-State $state
    Send-CompletionSound $state
    Send-CompletionSound $state
    Assert-True ($script:sounds -eq 2) 'Exclusions did not produce a single completion notification.'
    $arguments = Register-MonitorTask $state (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    Assert-True ($arguments -like '*-Action Monitor*' -and $arguments -like "*MonitorRunId $($state.RunId)*") 'Monitor action is not scoped to this run.'
    Assert-True ($script:taskDefinition.Principal.LogonType -eq 'Interactive') 'Monitor is not registered with an interactive token.'
    Assert-True ($script:taskDefinition.Principal.RunLevel -eq 'Highest') 'Monitor cannot access protected state.'
    Assert-True ($script:taskDefinition.Trigger.UserId -eq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) 'Logon trigger is not restricted to the initiating account.'

    # Limit real file deletion to this test's ProgramData substitute; task removal is a test sink.
    $env:ProgramData = $testBase
    $state = New-TestState
    $state.Status = 'CompletedWithExclusions'
    $state.ParentCreated = $true
    Save-State $state
    [IO.File]::WriteAllText((Join-Path $script:Root 'MSP-WindowsUpdate.ps1'), 'test worker')
    [IO.File]::WriteAllText($script:ResultReadPath, $state.RunId)
    $script:failCleanup = $true
    Remove-RunArtifacts $state -WarningAction SilentlyContinue
    Assert-True ([IO.File]::Exists($script:StatePath) -and (Get-State).CleanupError -like '*task cleanup failure*') 'Failed cleanup erased state or hid its error.'
    $script:failCleanup = $false
    [IO.File]::WriteAllText((Join-Path $script:Root 'unrelated.txt'), 'preserve')
    Remove-RunArtifacts $state -WarningAction SilentlyContinue
    Assert-True ([IO.File]::Exists((Join-Path $script:Root 'unrelated.txt')) -and (Get-State).CleanupError -like '*unrecognized*') 'Cleanup removed an unrelated file.'
    [IO.File]::Delete((Join-Path $script:Root 'unrelated.txt'))
    $state.ActiveOperation = 'Install'
    Save-State $state
    Remove-RunArtifacts $state
    Assert-True ([IO.File]::Exists($script:StatePath)) 'Cleanup erased an uncertain operation.'
    $state.ActiveOperation = ''
    $state.RebootCommitted = $true
    Save-State $state
    Remove-RunArtifacts $state
    Assert-True ([IO.File]::Exists($script:StatePath)) 'Cleanup erased a committed reboot.'
    $state.RebootCommitted = $false
    Save-State $state
    $workerGuard = Enter-RunLock $script:WorkerLockName
    try { Remove-RunArtifacts $state }
    finally { Exit-RunLock $workerGuard }
    Assert-True (-not (Test-Path -LiteralPath $script:Root)) 'Cleanup left runtime files behind.'
    Assert-True (-not (Test-Path -LiteralPath (Split-Path -Parent $script:Root))) 'Cleanup left its empty parent directory behind.'

    $state = New-TestState
    $state.Status = 'Completed'
    Save-State $state
    Invoke-Worker
    Assert-True (-not (Test-Path -LiteralPath $script:Root)) 'Headless terminal worker did not clean up automatically.'
    Assert-True (Test-Path -LiteralPath (Split-Path -Parent $script:Root)) 'Cleanup removed a pre-existing parent directory.'

    $state = New-TestState
    $state.Status = 'Completed'
    $state.MonitorEnabled = $true
    Save-State $state
    $script:monitorWaits = 0
    $script:sleepHook = { $script:monitorWaits++; [IO.File]::WriteAllText($script:ResultReadPath, $state.RunId) }
    Invoke-Worker
    Assert-True ($script:monitorWaits -eq 1 -and -not (Test-Path -LiteralPath $script:Root)) 'An acknowledged result did not allow automatic cleanup.'

    $state = New-TestState
    $state.Status = 'Completed'
    $state.MonitorEnabled = $true
    Save-State $state
    $script:monitorWaits = 0
    $script:sleepHook = { $script:monitorWaits++ }
    Invoke-Worker
    Assert-True ($script:monitorWaits -eq 10 -and -not (Test-Path -LiteralPath $script:Root)) 'An absent monitor prevented bounded automatic cleanup.'
    Write-Output ("PASS: $script:checks lifecycle checks (synthetic jobs; native task definitions, temporary state/locks; no updates, restarts, registered tasks or audio).")
} finally {
    $env:ProgramData = $originalProgramData
    # Delete only files created in this test's verified temporary directory.
    $resolved = [IO.Path]::GetFullPath($testBase)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -like 'DaScript-tests-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
