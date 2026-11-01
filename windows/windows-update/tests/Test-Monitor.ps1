#Requires -Version 5.1
[CmdletBinding()]
param([switch]$Preview)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Run this test with powershell.exe -STA.' }
$tokens = $null
$errors = $null
$source = Join-Path $PSScriptRoot '..\MSP-WindowsUpdate.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
# Load definitions only. Never execute Start, Worker, WUA, shutdown or real task operations.
foreach ($node in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($node.Extent.Text))
}
function Assert-Administrator { }
function Play-CompletionSound { }
function Invoke-Stop { [IO.File]::WriteAllText($script:StopPath, 'synthetic cooperative request') }
$script:checks = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
$testBase = Join-Path ([IO.Path]::GetTempPath()) ('DaScript-monitor-tests-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testBase)
$script:Root = $testBase
$script:StatePath = Join-Path $testBase 'state.json'
$script:BackupPath = Join-Path $testBase 'state.json.bak'
$script:LogPath = Join-Path $testBase 'activity.log'
$script:StopPath = Join-Path $testBase 'stop.request'
$script:NotificationPath = Join-Path $testBase 'completion-notified'
$script:ResultReadPath = Join-Path $testBase 'result-read'
$script:ControlLockName = 'Local\DaScript-monitor-test-' + [Guid]::NewGuid().ToString('N')
$script:TaskName = 'Unused-monitor-test'
$script:MonitorRunId = ''
$script:TerminalStates = @('Completed','CompletedWithExclusions','CompletedWithErrors','Blocked','Stopped')
$state = [pscustomobject]@{
    RunId=[Guid]::NewGuid().ToString('N'); Status='Running'; Phase='Install'
    Message='Install 42%: Aggiornamento cumulativo per Windows - anteprima con dati sintetici'
    UpdatedUtc=[DateTime]::UtcNow.ToString('o'); Scans=2; Reboots=1
    Installed=@([pscustomobject]@{Title='Synthetic update'})
    Failures=@(); Skipped=@()
}
Initialize-RuntimeState $state
$state.ProgressPercent = 42
$state.ActiveOperation = 'Install'
$window = $null
$reader = $null
try {
    $sampleLog = @'
2026-01-01 10:00:00 [INFO] PREVIEW: dati sintetici, nessuna operazione sul sistema.
2026-01-01 10:00:01 [INFO] Queued for installation.
2026-01-01 10:00:02 [INFO] Scanning for updates (scan 1).
2026-01-01 10:00:03 [INFO] Found 1 update(s); processing 1.
2026-01-01 10:00:04 [INFO] Download 100%: Synthetic update
2026-01-01 10:00:05 [INFO] Installed: Synthetic update
2026-01-01 10:00:06 [INFO] Synthetic reboot and resume; no restart executed.
2026-01-01 10:00:07 [INFO] Scanning for updates (scan 2).
2026-01-01 10:00:08 [INFO] Found 1 update(s); processing 1.
2026-01-01 10:00:09 [INFO] Download 100%: Aggiornamento cumulativo di prova
2026-01-01 10:00:10 [INFO] Installing 1 update(s).
2026-01-01 10:00:11 [INFO] Install 0%: Aggiornamento cumulativo di prova
2026-01-01 10:00:12 [INFO] Install 21%: Aggiornamento cumulativo di prova
2026-01-01 10:00:13 [INFO] Install 42%: Aggiornamento cumulativo di prova
'@
    [IO.File]::WriteAllText($script:LogPath, $sampleLog + "`r`n", [Text.Encoding]::UTF8)
    Save-State $state
    $window = New-MonitorWindow
    Assert-True ($window -is [Windows.Window]) 'XAML did not produce a WPF Window.'
    Assert-True ($window.WindowStyle -eq 'None' -and $null -ne [Windows.Shell.WindowChrome]::GetWindowChrome($window)) 'Terminal chrome lost native move/resize support.'
    $signal = $window.FindName('LogoHost')
    $logo = $window.FindName('LogoPath').Data
    Assert-True ($logo.IsFrozen -and $logo.Bounds.Width -eq 1180 -and $logo.Bounds.Height -eq 964) 'Embedded vector logo is missing or invalid.'
    $snapshot = [pscustomobject]@{State=$state; Log='Synthetic log'; StopRequested=$false}
    Update-MonitorView $window $snapshot
    $index = $signal.Tag.Index
    Update-MonitorAnimation $window
    Assert-True ($signal.Tag.Index -eq $index+1 -and $window.FindName('NoiseText').Text.Length -gt 0) 'Terminal animation did not advance.'
    $signal.Tag.Random = [Random]::new(1234)
    $lightPosition = $signal.Tag.LightY
    Update-MonitorAnimation $window
    Assert-True ($window.FindName('LogoGlow').Opacity -eq 0.20) 'Logo illumination is disabled.'
    Assert-True ($signal.Parent -eq $window.FindName('AmbientField') -and $null -eq $window.FindName('LogoFragments')) 'Logo is not an intact terminal background.'
    Assert-True ($signal.Tag.LightY -gt $lightPosition -and $window.FindName('LogoPath').RenderTransform.Value.IsIdentity) 'Logo illumination moved or distorted the silhouette.'
    $index = $signal.Tag.Index
    $window.WindowState = 'Minimized'
    Update-MonitorAnimation $window
    Assert-True ($signal.Tag.Index -eq $index -and $window.FindName('LogoGlow').Opacity -eq 0) 'Minimized window kept animating.'
    $window.WindowState = 'Normal'
    Update-MonitorAnimation $window
    Assert-True ($signal.Tag.Index -eq $index+1) 'Restored window did not resume animation.'
    Assert-True ($window.FindName('LogText').Text -eq 'Synthetic log' -and $window.FindName('Progress').Value -eq 42) 'Decorative glitch changed operational content.'
    $snapshot.Log = (1..20 | ForEach-Object { "Synthetic line $_" }) -join "`r`n"
    Update-MonitorView $window $snapshot
    Assert-True ($window.FindName('LogText').Tag.Visible -gt 0 -and $window.FindName('LogText').Tag.Visible -lt 20) 'Log did not reveal progressively.'
    for ($i=0; $i -lt 25; $i++) { Update-MonitorAnimation $window }
    Assert-True ($window.FindName('LogText').Text -ceq $snapshot.Log) 'Progressive reveal lost or fabricated log lines.'
    $snapshot.Log = (4..23 | ForEach-Object { "Synthetic line $_" }) -join "`r`n"
    Update-MonitorView $window $snapshot
    Assert-True ($window.FindName('LogText').Tag.Visible -ge 17) 'Rolling log replayed previously displayed lines.'
    for ($i=0; $i -lt 10; $i++) { Update-MonitorAnimation $window }
    Assert-True ($window.FindName('LogText').Text -ceq $snapshot.Log) 'Rolling log duplicated or dropped lines.'
    $snapshot.Log += "`r`n[ERROR] Synthetic urgent failure"
    Update-MonitorView $window $snapshot
    Assert-True ($window.FindName('LogText').Text -ceq $snapshot.Log) 'Error log was delayed by animation.'
    $snapshot.Log = 'Synthetic log'
    Update-MonitorView $window $snapshot
    Assert-True ($null -eq $window.FindName('AsciiLogo') -and $null -eq $window.FindName('SignalImage')) 'Obsolete branding or globe is still present.'
    Assert-True ($window.FindName('Progress').Value -eq 42 -and $window.FindName('ProgressText').Text -eq '42%') 'Determinate WUA progress was lost.'
    Assert-True $window.FindName('StopButton').IsEnabled 'Stop should be available during installation.'
    Assert-True ($window.FindName('InstalledCount').Text -eq '1') 'Installed counter is incorrect.'
    foreach ($percent in @(-1, 101)) {
        $state.ProgressPercent = $percent
        Update-MonitorView $window $snapshot
        Assert-True ($window.FindName('Progress').Value -eq 0 -and $window.FindName('ProgressText').Text -eq '--') 'Unknown/invalid progress became a fabricated percentage.'
    }
    $state.ProgressPercent = 42
    foreach ($phase in @('Queued','Scan','Verify','Resume','Retry','Cancelling','OperationStillRunning','FuturePhase')) {
        $state.Phase = $phase
        Update-MonitorView $window $snapshot
        Assert-True ($window.FindName('PhaseText').Text -ne '' -and $window.FindName('ProgressText').Text -eq '--') "Phase $phase displayed a stale percentage."
        $index = $signal.Tag.Index
        Update-MonitorAnimation $window
        Assert-True ($signal.Tag.Index -eq $index+1) "Phase $phase stopped terminal animation."
    }
    $state.Status = 'WaitingForReboot'
    $state.Phase = 'RestartCountdown'
    $state.Message = 'Restart in 75 seconds. Save your work.'
    Update-MonitorView $window $snapshot
    Assert-True ($window.FindName('ProgressText').Text -eq '75s') 'Worker countdown is missing.'
    $state.RebootCommitted = $true
    $state.Phase = 'Restart'
    Update-MonitorView $window $snapshot
    Assert-True (-not $window.FindName('StopButton').IsEnabled -and $window.FindName('ProgressText').Text -eq '--') 'Committed restart permits stop or retains an obsolete countdown.'
    $state.RebootCommitted = $false
    $snapshot.StopRequested = $true
    Update-MonitorView $window $snapshot
    Assert-True (-not $window.FindName('StopButton').IsEnabled -and $window.FindName('NoticeText').Text -like 'Stop richiesto*') 'Stop request was not represented as pending.'
    $snapshot.StopRequested = $false
    $state.ActiveOperation = ''
    foreach ($status in $script:TerminalStates) {
        $state.Status = $status
        $state.Phase = $status
        Update-MonitorView $window $snapshot
        Assert-True (-not $window.FindName('StopButton').IsEnabled -and $window.FindName('ProgressText').Text -eq '--') "Terminal status $status fabricated progress or enabled stop."
        $index = $signal.Tag.Index
        Update-MonitorAnimation $window
        Assert-True ($signal.Tag.Index -eq $index+1) "Terminal status $status stopped decorative animation."
        Assert-True ($window.FindName('LogoGlow').Opacity -eq 0.20 -and $window.FindName('ProgressText').Text -eq '--') "Terminal status $status lost illumination or fabricated progress."
    }
    $state.Status = 'Blocked'
    $state.ActiveOperation = 'Install'
    Update-MonitorView $window $snapshot
    Assert-True ($window.FindName('NoticeText').Text -like '*potrebbe essere ancora attiva*') 'Blocked active WUA operation was presented as finished.'
    $state.CleanupError = 'Synthetic cleanup error'
    Update-MonitorView $window $snapshot
    Assert-True ($window.FindName('NoticeText').Text -like 'Pulizia incompleta:*') 'Cleanup error was hidden.'
    $state.CleanupError = ''
    $state.ActiveOperation = ''
    $state.Status = 'CompletedWithErrors'
    $state.Phase = 'CompletedWithErrors'
    $state.Failures = @([pscustomobject]@{Title='Synthetic failure'; Reason='Synthetic reason'; Resolved=$false})
    $state.Skipped = @([pscustomobject]@{Title='Synthetic exclusion'; Reason='Requires interactive input'})
    Save-State $state
    $reader = New-MonitorReader
    [void]$reader.AddCommand('Get-MonitorSnapshot').AddParameter('RunId',$state.RunId)
    $guard = Enter-RunLock $script:ControlLockName
    try {
        $pending = $reader.BeginInvoke()
        Assert-True (-not $pending.AsyncWaitHandle.WaitOne(200)) 'Snapshot bypassed the control lock.'
        $window.FindName('NoticeText').Text = 'UI remains available while the reader waits.'
        Assert-True ($window.FindName('NoticeText').Text -like 'UI remains*') 'Background lock blocked access to UI controls.'
    } finally { Exit-RunLock $guard }
    Assert-True ($pending.AsyncWaitHandle.WaitOne(10000)) 'Background snapshot timed out.'
    $result = @($reader.EndInvoke($pending))
    if ($reader.HadErrors) { throw ($reader.Streams.Error | Out-String) }
    $result = $result[-1]
    Assert-True ($result.Finished -and $result.Log -like '*Synthetic failure: Synthetic reason*' -and $result.Log -like '*Synthetic exclusion*') 'Final snapshot omitted outcome details.'
    Assert-True (-not [IO.File]::Exists($script:ResultReadPath)) 'Result acknowledged before UI consumption.'
    Update-MonitorView $window $result
    Assert-True ($window.FindName('LogText').Text -ceq $result.Log) 'Final result was acknowledged before the complete log was displayed.'
    Assert-True ($window.FindName('FailureCount').Text -eq '1') 'Open failure counter is incorrect.'
    $reader.Commands.Clear()
    [void]$reader.AddCommand('Get-MonitorSnapshot').AddParameter('RunId',$state.RunId).AddParameter('AcknowledgeFinal',$true)
    $null = $reader.Invoke()
    if ($reader.HadErrors) { throw ($reader.Streams.Error | Out-String) }
    Assert-True ([IO.File]::ReadAllText($script:ResultReadPath) -eq $state.RunId) 'Consumed final result was not acknowledged.'
    $reader.Commands.Clear()
    [void]$reader.AddCommand('Get-MonitorSnapshot').AddParameter('RunId',([Guid]::NewGuid().ToString('N')))
    $other = @($reader.Invoke())[-1]
    Assert-True ($null -eq $other.State -and -not $other.Cleaned) 'A different run leaked into the monitor.'
    $state.Status = 'Running'
    $state.Phase = 'Install'
    $state.ActiveOperation = 'Install'
    $state.Message = 'Install 42%: Aggiornamento cumulativo per Windows - anteprima con dati sintetici'
    $state.ProgressPercent = 42
    $state.Failures = @()
    $state.Skipped = @()
    Save-State $state
    $reader.Commands.Clear()
    [void]$reader.AddCommand('Get-MonitorSnapshot').AddParameter('RunId',$state.RunId).AddParameter('RequestStop',$true)
    $stopped = @($reader.Invoke())[-1]
    if ($reader.HadErrors) { throw ($reader.Streams.Error | Out-String) }
    Assert-True ($stopped.StopRequested -and (Get-State).Status -eq 'Running') 'UI stop changed worker state.'
    [IO.File]::Delete($script:StopPath)
    $reader.Dispose()
    $reader = $null
    $window.Close()
    $window = $null
    Write-Output "PASS: $script:checks WPF checks (PowerShell $($PSVersionTable.PSVersion), native XAML/controls, synthetic states and background I/O; no updates or restarts)."
    if ($Preview) { Invoke-Monitor }
} finally {
    if ($null -ne $window) { $window.Close() }
    if ($null -ne $reader) { $reader.Dispose() }
    $resolved = [IO.Path]::GetFullPath($testBase)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -like 'DaScript-monitor-tests-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
