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
$script:testBootId = 'test-boot'
function Get-BootId { return $script:testBootId }
function Invoke-SystemRestart { $script:restarts++; return $script:restartExit }
function Remove-TaskSafely { param($Name) $script:removedTasks++ }
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
$script:Root = Join-Path ([IO.Path]::GetTempPath()) ('DaScript-tests-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($script:Root)
$script:StatePath = Join-Path $script:Root 'state.json'
$script:BackupPath = Join-Path $script:Root 'state.json.bak'
$script:LogPath = Join-Path $script:Root 'activity.log'
$script:StopPath = Join-Path $script:Root 'stop.request'
$script:ControlLockPath = Join-Path $script:Root 'control.lock'
$script:WorkerLockPath = Join-Path $script:Root 'worker.lock'
$script:NotificationPath = Join-Path $script:Root 'completion-notified'
$script:TaskName = 'Unused-test-task'
$script:MonitorTaskName = 'Unused-test-monitor'
$script:WorkerPath = $source
$script:MonitorRunId = ''
$script:TerminalStates = @('Completed','CompletedWithErrors','Blocked','Stopped')
$script:restarts = 0
$script:restartExit = 0
$script:removedTasks = 0
$script:taskStarts = 0
$script:sounds = 0
$script:sleepHook = $null

function New-TestState {
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

    $first = Enter-FileLock $script:WorkerLockPath -TimeoutSeconds 0
    try { Assert-Throws { Enter-FileLock $script:WorkerLockPath -TimeoutSeconds 0 } }
    finally { $first.Dispose() }
    $second = Enter-FileLock $script:WorkerLockPath -TimeoutSeconds 0
    $second.Dispose()
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

    # Inject a stop exactly when the final decision obtains the real control lock.
    $realEnterLock = (Get-Item Function:Enter-FileLock).ScriptBlock
    function Enter-FileLock {
        param($Path, $TimeoutSeconds=5)
        $handle = & $realEnterLock $Path $TimeoutSeconds
        [IO.File]::WriteAllText($script:StopPath, 'stop')
        return $handle
    }
    $state = New-TestState
    Schedule-Reboot $state 'test'
    Assert-True ($state.Status -eq 'Stopped' -and $script:restarts -eq 0) 'Final reboot decision ignored stop.'
    Set-Item Function:Enter-FileLock $realEnterLock

    $state = New-TestState
    Schedule-Reboot $state 'test'
    Assert-True ($state.RebootCommitted -and $state.Status -eq 'WaitingForReboot' -and $script:restarts -eq 1) 'Restart was not committed.'
    Invoke-Stop -WarningAction SilentlyContinue
    $saved = Get-State
    Assert-True ($saved.Status -eq 'WaitingForReboot' -and $saved.RebootCommitted) 'Late stop falsely reported a cancelled reboot.'
    Assert-True ([IO.File]::Exists($script:StopPath)) 'Late stop was not persisted for the next boot.'
    Invoke-WorkerCore
    Assert-True ((Get-State).Status -eq 'WaitingForReboot') 'A still-pending committed reboot was falsely reported as stopped.'
    $script:testBootId = 'next-boot'
    Invoke-WorkerCore
    Assert-True ((Get-State).Status -eq 'Stopped') 'Stop was not applied before any resumed update work.'
    $script:testBootId = 'test-boot'

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
    $state.OperationBootId = 'test-boot'
    Save-State $state
    Invoke-WorkerCore
    Assert-True ((Get-State).Status -eq 'Blocked') 'Uncertain installation was allowed to resume on the same boot.'

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
    $arguments = Register-MonitorTask $state (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    Assert-True ($arguments -like '*-Action Monitor*' -and $arguments -like "*MonitorRunId $($state.RunId)*") 'Monitor action is not scoped to this run.'
    Assert-True ($script:taskDefinition.Principal.LogonType -eq 'Interactive') 'Monitor is not registered with an interactive token.'
    Assert-True ($script:taskDefinition.Principal.RunLevel -eq 'Highest') 'Monitor cannot access protected state.'
    Assert-True ($script:taskDefinition.Trigger.UserId -eq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) 'Logon trigger is not restricted to the initiating account.'
    Write-Output ("PASS: $script:checks lifecycle checks (synthetic jobs; native task definitions, temporary state/locks; no updates, restarts, registered tasks or audio).")
} finally {
    # Delete only files created in this test's verified temporary directory.
    $resolved = [IO.Path]::GetFullPath($script:Root)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -like 'DaScript-tests-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
