#Requires -Version 5.1
<#
.SYNOPSIS
    Installs applicable Windows updates and resumes automatically after restarts.
.DESCRIPTION
    Runs on Windows 10/11 and Windows Server, using the configured Windows Update/WSUS source.
    The background worker runs as SYSTEM from a protected Scheduled Task.
    Stop is cooperative: it never terminates an update installation mid-operation.
.EXAMPLE
    .\MSP-WindowsUpdate.ps1 -Action Start
.EXAMPLE
    .\MSP-WindowsUpdate.ps1 -Action Start -NoMonitor
.EXAMPLE
    .\MSP-WindowsUpdate.ps1 -Action Status
.EXAMPLE
    .\MSP-WindowsUpdate.ps1 -Action Stop
.EXAMPLE
    .\MSP-WindowsUpdate.ps1 -Action Start -AllowServerReboot -NoMonitor
#>
[CmdletBinding()]
param(
    [ValidateSet('Start', 'Worker', 'Status', 'Monitor', 'Stop')]
    [string]$Action = 'Start',
    [ValidateRange(1, 20)]
    [int]$MaxReboots = 8,
    [ValidateRange(1, 10)]
    [int]$MaxAttempts = 3,
    [switch]$IncludeDrivers = $true,
    [switch]$IncludeOptional = $true,
    [switch]$ExcludeDrivers,
    [switch]$ExcludeOptional,
    [ValidateRange(1, 1440)]
    [int]$OperationTimeoutMinutes = 180,
    [ValidateRange(15, 3600)]
    [int]$RebootDelaySeconds = 90,
    [switch]$IncludeFeatureUpgrades,
    [ValidateSet('Ask', 'Allow', 'Skip')]
    [string]$Windows11Upgrade = 'Ask',
    [switch]$AllowServerReboot,
    [switch]$NoMonitor,
    [ValidatePattern('^[a-f0-9]{32}$')]
    [string]$MonitorRunId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TaskName = 'MSP-WindowsUpdate'
$script:MonitorTaskName = 'MSP-WindowsUpdate-Monitor'
$script:Root = Join-Path $env:ProgramData 'MSPTools\WindowsUpdate'
$script:WorkerPath = Join-Path $script:Root 'MSP-WindowsUpdate.ps1'
$script:StatePath = Join-Path $script:Root 'state.json'
$script:BackupPath = Join-Path $script:Root 'state.json.bak'
$script:StopPath = Join-Path $script:Root 'stop.request'
$script:LogPath = Join-Path $script:Root 'activity.log'
$script:ControlLockPath = Join-Path $script:Root 'control.lock'
$script:WorkerLockPath = Join-Path $script:Root 'worker.lock'
$script:NotificationPath = Join-Path $script:Root 'completion-notified'
$script:TerminalStates = @('Completed', 'CompletedWithErrors', 'Blocked', 'Stopped')

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run Windows PowerShell as Administrator.'
    }
}

function Get-SupportedPlatform {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $type = [int]$os.ProductType
    if ($type -notin @(1, 2, 3)) {
        throw 'Unable to determine whether Windows is a client or server OS.'
    }
    $version = [version]$os.Version
    if ($type -eq 1 -and $version -lt [version]'10.0') {
        throw 'Windows 10 or later is required for clients.'
    }
    if ($type -ne 1) {
        if ($version -lt [version]'10.0.17763') {
            throw 'Windows Server 2019 or later with Desktop Experience is required.'
        }
        $installation = Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name InstallationType
        if ($installation -eq 'Server Core') {
            throw 'Server Core is not supported. Windows Server with Desktop Experience is required.'
        }
        if ($installation -ne 'Server') {
            throw ('Unsupported or unrecognized server installation type: ' + $installation)
        }
    }
    # ProductType identifies servers without relying on localized edition names.
    return [pscustomobject]@{
        IsServer = ($type -ne 1)
        IsWindows10 = ($type -eq 1 -and $version.Major -eq 10 -and $version.Build -lt 22000)
        IsWindows11 = ($type -eq 1 -and $version.Major -eq 10 -and $version.Build -ge 22000)
        Caption  = [string]$os.Caption
        Version  = [string]$os.Version
    }
}

function Get-Windows11UpgradeChoice {
    param([object]$Platform, [string]$Choice)
    if (-not $Platform.IsWindows10) {
        if ($Choice -eq 'Allow') {
            throw '-Windows11Upgrade Allow is only available when starting on Windows 10.'
        }
        return $false
    }
    if ($Choice -eq 'Allow') { return $true }
    if ($Choice -eq 'Skip') { return $false }
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        throw 'Unattended start on Windows 10 requires -Windows11Upgrade Allow or Skip.'
    }
    Write-Host 'Windows 11 verra installato solo se offerto dalla sorgente Windows Update configurata.'
    Write-Host 'La scelta autorizza il cambio di sistema operativo e i riavvii; non modifica requisiti o policy.'
    while ($true) {
        try { $answer = Read-Host 'Esegui anche aggiornamento a Windows 11? [s/N]' }
        catch { throw 'Cannot read the initial choice. Specify -Windows11Upgrade Allow or Skip.' }
        switch ($answer.Trim().ToLowerInvariant()) {
            's'  { return $true }
            'si' { return $true }
            'n'  { return $false }
            'no' { return $false }
            ''   { return $false }
            default { Write-Host 'Rispondere s oppure n.' }
        }
    }
}

function Initialize-Windows11UpgradeState {
    param([object]$State)
    # Existing runs must never acquire permission for an OS upgrade implicitly.
    if ($null -eq $State.PSObject.Properties['Windows11UpgradeRequested']) {
        $State | Add-Member -NotePropertyName Windows11UpgradeRequested -NotePropertyValue $false
        $State | Add-Member -NotePropertyName Windows11UpgradeOffered -NotePropertyValue $false
        $State | Add-Member -NotePropertyName Windows11UpgradeStatus -NotePropertyValue 'NotRequested'
    }
}

function Initialize-RuntimeState {
    param([object]$State)
    Initialize-Windows11UpgradeState $State
    $defaults = @{
        OperationTimeoutMinutes=180; RebootDelaySeconds=90; RebootCommitted=$false
        ActiveOperation=''; OperationBootId=''; ProgressPercent=-1; MonitorEnabled=$false
    }
    foreach ($name in $defaults.Keys) {
        if ($null -eq $State.PSObject.Properties[$name]) {
            $State | Add-Member -NotePropertyName $name -NotePropertyValue $defaults[$name]
        }
    }
}

function Enter-FileLock {
    param([string]$Path, [int]$TimeoutSeconds = 5)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        try { return [IO.File]::Open($Path, 'OpenOrCreate', 'ReadWrite', 'None') }
        catch [IO.IOException] {
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                throw "Another operation holds $Path. Retry after it finishes."
            }
            Start-Sleep -Milliseconds 100
        }
    } while ($true)
}

function Initialize-WuaCallback {
    if ('MSPWindowsUpdate.Callback' -as [type]) { return }
    # WUA accepts an Automation callback with DISPID 0. No PowerShell runs on COM threads.
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
namespace MSPWindowsUpdate {
    [ComVisible(true), ClassInterface(ClassInterfaceType.AutoDispatch)]
    public sealed class Callback {
        [DispId(0)] public void Invoke(object job, object args) { }
    }
}
'@
}

function Wait-WuaJob {
    param([object]$State, [object]$Job, [string]$Operation, [object]$Updates, [int]$AbortGraceSeconds = 300)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $abortAt = $null
    $timedOut = $false
    $blocked = $false
    $lastMessage = ''
    while (-not $Job.IsCompleted) {
        $stopRequested = Test-Path -LiteralPath $script:StopPath
        $deadline = [DateTime]::Parse([string]$State.StartedUtc).ToUniversalTime().AddDays(7)
        if ($clock.Elapsed.TotalMinutes -ge $State.OperationTimeoutMinutes -or [DateTime]::UtcNow -ge $deadline) {
            $timedOut = $true
        }
        if ($null -eq $abortAt -and ($timedOut -or ($stopRequested -and $Operation -ne 'Install'))) {
            $abortAt = $clock.Elapsed.TotalSeconds
            try { $Job.RequestAbort() }
            catch { Write-Log ('WUA cancellation request failed: ' + $_.Exception.Message) 'ERROR' }
        }
        if ($null -ne $abortAt -and ($clock.Elapsed.TotalSeconds - $abortAt) -ge $AbortGraceSeconds -and -not $blocked) {
            $blocked = $true
            $timedOut = $true
            $State.Status = 'Blocked'
            Remove-TaskSafely
        }
        $message = "$Operation in progress."
        $State.ProgressPercent = -1
        if ($Operation -ne 'Scan') {
            $progress = $Job.GetProgress()
            $State.ProgressPercent = [int]$progress.PercentComplete
            $index = [int]$progress.CurrentUpdateIndex
            $message = "$Operation $($State.ProgressPercent)%"
            if ($null -ne $Updates -and $index -ge 0 -and $index -lt $Updates.Count) {
                $message += ': ' + [string]$Updates.Item($index).Title
            }
        }
        if ($blocked) {
            $message = 'WUA did not finish cancellation within 5 minutes. Operation may still be active; no further updates or automatic restarts. Operator attention required.'
        } elseif ($timedOut) {
            $message = "$Operation timed out; waiting for WUA to finish cooperative cancellation."
        } elseif ($stopRequested) {
            $message = "$Operation`: stop requested; waiting for the current operation to finish."
        }
        $State.Phase = $(if ($blocked) { 'OperationStillRunning' } elseif ($null -ne $abortAt) { 'Cancelling' } else { $Operation })
        $State.Message = $message
        Save-State $State
        if ($message -ne $lastMessage) { Write-Log $message; $lastMessage = $message }
        Start-Sleep -Seconds 3
    }
    return $timedOut
}

function Invoke-WuaOperation {
    param([object]$State, [object]$Agent, [ValidateSet('Scan','Download','Install')][string]$Operation, [object]$Updates)
    Initialize-WuaCallback
    $callback = New-Object MSPWindowsUpdate.Callback
    $State.ActiveOperation = $Operation
    $State.OperationBootId = Get-BootId
    $State.ProgressPercent = -1
    Save-State $State
    $job = $null
    try {
        switch ($Operation) {
            'Scan' { $job = $Agent.BeginSearch('IsInstalled=0 and IsHidden=0', $callback, $null) }
            'Download' { $job = $Agent.BeginDownload($callback, $callback, $null) }
            'Install' { $job = $Agent.BeginInstall($callback, $callback, $null) }
        }
        $timedOut = Wait-WuaJob $State $job $Operation $Updates
        switch ($Operation) {
            'Scan' { $result = $Agent.EndSearch($job) }
            'Download' { $result = $Agent.EndDownload($job) }
            'Install' { $result = $Agent.EndInstall($job) }
        }
        return [pscustomobject]@{ Result=$result; TimedOut=$timedOut }
    } finally {
        # Never wait in CleanUp on an incomplete job or clear its recovery marker.
        if ($null -ne $job -and $job.IsCompleted) {
            $State.ActiveOperation = ''
            $State.ProgressPercent = -1
            Save-State $State
            $job.CleanUp()
        }
        [GC]::KeepAlive($callback)
    }
}

function Test-UwfEnabled {
    try {
        $uwf = @(Get-CimInstance -Namespace 'root/standardcimv2/embedded' -ClassName UWF_Filter -ErrorAction Stop)
    } catch {
        # StatusCode is numeric; NativeErrorCode exposes the locale-independent enum.
        if ($_.Exception -is [Microsoft.Management.Infrastructure.CimException] -and
            $_.Exception.NativeErrorCode -in @(
                [Microsoft.Management.Infrastructure.NativeErrorCode]::InvalidNamespace,
                [Microsoft.Management.Infrastructure.NativeErrorCode]::InvalidClass
            )) {
            return $false
        }
        throw ('Unable to determine Unified Write Filter status: ' + $_.Exception.Message)
    }
    return (@($uwf | Where-Object { [bool]$_.CurrentEnabled }).Count -gt 0)
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, ($Message -replace '[\r\n]+', ' ')
    [IO.File]::AppendAllText($script:LogPath, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

function Save-State {
    param([object]$State)
    $State.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    $json = ConvertTo-Json -InputObject $State -Depth 8
    $temp = Join-Path $script:Root ('state.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($temp, $json, [Text.UTF8Encoding]::new($false))
    try {
        if ([IO.File]::Exists($script:StatePath)) {
            # File.Replace preserves a recovery copy if the machine crashes mid-write.
            [IO.File]::Replace($temp, $script:StatePath, $script:BackupPath)
        } else {
            [IO.File]::Move($temp, $script:StatePath)
        }
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

function Read-JsonState {
    param([string]$Path)
    # FileShare.Delete permits atomic state replacement while a monitor reads it.
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8)
        try { return ($reader.ReadToEnd() | ConvertFrom-Json) }
        finally { $reader.Dispose() }
    } finally {
        $stream.Dispose()
    }
}

function Get-State {
    if (-not (Test-Path -LiteralPath $script:StatePath)) { return $null }
    try {
        return (Read-JsonState $script:StatePath)
    } catch {
        if (Test-Path -LiteralPath $script:BackupPath) {
            Write-Warning 'Main state is unreadable; using the previous valid state.'
            return (Read-JsonState $script:BackupPath)
        }
        throw
    }
}

function Set-Phase {
    param([object]$State, [string]$Phase, [string]$Message)
    $State.Phase = $Phase
    $State.Message = $Message
    Save-State $State
    Write-Log $Message
}

function Get-BootId {
    # LastBootUpTime changes after each reboot, unlike a persistent run identifier.
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    return $os.LastBootUpTime.ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
}

function Format-HResult {
    param([long]$Value)
    return ('0x{0:X8}' -f ([uint32]($Value -band [long]4294967295)))
}

function Get-Failure {
    param([object]$State, [string]$Id)
    return @($State.Failures | Where-Object { $_.Id -eq $Id } | Select-Object -First 1) | Select-Object -First 1
}

function Add-Failure {
    param([object]$State, [string]$Id, [string]$Title, [string]$Stage, [string]$Reason)
    $old = Get-Failure $State $Id
    if ($null -eq $old) {
        $record = [pscustomobject]@{
            Id = $Id; Title = $Title; Stage = $Stage; Reason = $Reason
            Attempts = 1; Resolved = $false
        }
        $State.Failures = @($State.Failures) + @($record)
    } else {
        $old.Attempts = [int]$old.Attempts + 1
        $old.Stage = $Stage
        $old.Reason = $Reason
        $old.Resolved = $false
    }
    Save-State $State
    Write-Log ("{0}: {1}: {2}" -f $Stage, $Title, $Reason) 'ERROR'
}

function Resolve-Failure {
    param([object]$State, [string]$Id)
    $old = Get-Failure $State $Id
    if ($null -ne $old) { $old.Resolved = $true }
}

function Add-Skipped {
    param([object]$State, [string]$Id, [string]$Title, [string]$Reason)
    if (-not @($State.Skipped | Where-Object { $_.Id -eq $Id }).Count) {
        $State.Skipped = @($State.Skipped) + @([pscustomobject]@{ Id=$Id; Title=$Title; Reason=$Reason })
        Save-State $State
    }
}

function Test-UpdateRebootPending {
    $systemInfo = New-Object -ComObject 'Microsoft.Update.SystemInfo'
    if ([bool]$systemInfo.RebootRequired) { return $true }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        return $true
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        return $true
    }
    return $false
}

function Remove-TaskSafely {
    param([string]$Name = $script:TaskName)
    try {
        $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
        if ($null -ne $task) {
            Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction Stop
        }
    } catch {
        Write-Log ('Task cleanup failed: ' + $_.Exception.Message) 'WARN'
    }
}

function Finish-Run {
    param([object]$State, [string]$Status, [string]$Message)
    $State.Status = $Status
    Set-Phase $State $Status $Message
    Remove-TaskSafely
}

function Test-StopRequested {
    param([object]$State)
    if (Test-Path -LiteralPath $script:StopPath) {
        Finish-Run $State 'Stopped' 'Stopped by operator. No further restarts will be requested.'
        return $true
    }
    return $false
}

function Invoke-SystemRestart {
    & "$env:SystemRoot\System32\shutdown.exe" /r /t 0 /f /d p:2:17 /c 'MSP Windows Update: restart to continue installing updates.' | Out-Null
    return $LASTEXITCODE
}

function Schedule-Reboot {
    param([object]$State, [string]$Reason)
    if (Test-StopRequested $State) { return }
    if ([bool]$State.IsServer -and -not [bool]$State.AllowServerReboot) {
        Finish-Run $State 'Blocked' 'Windows Server requires explicit permission for automatic reboot.'
        return
    }
    if ([int]$State.Reboots -ge [int]$State.MaxReboots) {
        Finish-Run $State 'Blocked' ('Maximum number of reboots reached (' + $State.MaxReboots + ').')
        return
    }
    $State.Status = 'WaitingForReboot'
    $State.RebootCommitted = $false
    $State.RebootBootId = Get-BootId
    $State.RebootRequestedUtc = [DateTime]::UtcNow.ToString('o')
    $countdown = [Diagnostics.Stopwatch]::StartNew()
    $lastSeconds = -1
    while ($countdown.Elapsed.TotalSeconds -lt $State.RebootDelaySeconds) {
        if (Test-StopRequested $State) { return }
        $remaining = [int][Math]::Ceiling($State.RebootDelaySeconds - $countdown.Elapsed.TotalSeconds)
        if ($remaining -ne $lastSeconds -and ($remaining % 5 -eq 0 -or $lastSeconds -eq -1)) {
            Set-Phase $State 'RestartCountdown' ("Restart in $remaining seconds. Save your work. $Reason")
            $lastSeconds = $remaining
        }
        Start-Sleep -Milliseconds 250
    }
    # Stop and the final reboot decision share this lock. Only this worker writes state.
    $control = Enter-FileLock $script:ControlLockPath
    try {
        if (Test-StopRequested $State) { return }
        $State.Reboots = [int]$State.Reboots + 1
        $State.RebootCommitted = $true
        $State.RebootRequestedUtc = [DateTime]::UtcNow.ToString('o')
        Set-Phase $State 'Restart' ("Reboot $($State.Reboots)/$($State.MaxReboots) committed: $Reason")
        $exitCode = Invoke-SystemRestart
        if ($exitCode -ne 0) {
            $State.RebootCommitted = $false
            Finish-Run $State 'Blocked' ("Windows refused the reboot (exit code $exitCode).")
        }
    } finally {
        $control.Dispose()
    }
}

function Get-UpdateId {
    param([object]$Update)
    return ([string]$Update.Identity.UpdateID + ':' + [string]$Update.Identity.RevisionNumber)
}

function Test-FeatureUpgrade {
    param([object]$Update)
    # Microsoft Update's 'Upgrades' classification GUID is language-independent.
    foreach ($cat in $Update.Categories) {
        if ([string]$cat.CategoryID -eq '3689bdc8-b205-4af4-8d4a-a63924c5e9d5') {
            return $true
        }
    }
    return $false
}

function Get-Candidates {
    param([object]$State, [object]$SearchResult, [object]$Platform)
    $regular = [Collections.Generic.List[object]]::new()
    $exclusive = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $SearchResult.Updates.Count; $index++) {
        $update = $SearchResult.Updates.Item($index)
        $id = Get-UpdateId $update
        $title = [string]$update.Title
        if ([int]$update.Type -eq 2 -and -not [bool]$State.IncludeDrivers) {
            Add-Skipped $State $id $title 'Driver excluded by operator'
            continue
        }
        if ([bool]$update.IsBeta) {
            Add-Skipped $State $id $title 'Beta update excluded'
            continue
        }
        $isFeatureUpgrade = Test-FeatureUpgrade $update
        # WUA exposes no target-OS-version property. Require both the classification
        # and an explicit Windows 11 product name; unrecognized upgrades stay excluded.
        $isWindows11Upgrade = $isFeatureUpgrade -and ($title -match '\bWindows\s+11\b')
        $allowWindows11Upgrade = $false
        if ($Platform.IsWindows10 -and $isFeatureUpgrade) {
            if ($isWindows11Upgrade) {
                if (-not [bool]$State.Windows11UpgradeRequested) {
                    Add-Skipped $State $id $title 'Windows 11 upgrade not authorized'
                    continue
                }
                $State.Windows11UpgradeOffered = $true
                $State.Windows11UpgradeStatus = 'Offered'
                $allowWindows11Upgrade = $true
            } elseif (-not ($title -match '\bWindows\s+10\b')) {
                Add-Skipped $State $id $title 'Unable to identify target Windows version safely'
                continue
            }
        }
        if ($isFeatureUpgrade -and -not $allowWindows11Upgrade -and -not [bool]$State.IncludeFeatureUpgrades) {
            Add-Skipped $State $id $title 'Feature upgrade excluded by default'
            continue
        }
        if (-not [bool]$State.IncludeOptional -and -not $allowWindows11Upgrade) {
            # BrowseOnly is the documented WUA flag for optional updates.
            try {
                if ([bool]$update.BrowseOnly) {
                    Add-Skipped $State $id $title 'Optional update excluded'
                    continue
                }
            } catch {
                Add-Skipped $State $id $title 'Unable to classify optional update safely'
                continue
            }
        }
        if ([bool]$update.InstallationBehavior.CanRequestUserInput) {
            Add-Skipped $State $id $title 'Update may require interactive input'
            continue
        }
        $previous = Get-Failure $State $id
        if ($null -ne $previous -and [int]$previous.Attempts -ge [int]$State.MaxAttempts) {
            continue
        }
        if ([int]$update.InstallationBehavior.Impact -eq 2) {
            $exclusive.Add($update)
        } else {
            $regular.Add($update)
        }
    }
    if ($exclusive.Count -gt 0) {
        # Exclusive updates cannot share an installation batch with other updates.
        return @($exclusive[0])
    }
    return @($regular.ToArray())
}

function Install-Batch {
    param([object]$State, [object]$Session, [object[]]$Candidates)
    $downloadCollection = New-Object -ComObject 'Microsoft.Update.UpdateColl'
    foreach ($update in $Candidates) {
        $id = Get-UpdateId $update
        try {
            if (-not [bool]$update.EulaAccepted) { $update.AcceptEula() }
            [void]$downloadCollection.Add($update)
        } catch {
            Add-Failure $State $id ([string]$update.Title) 'EULA' $_.Exception.Message
        }
    }
    if ($downloadCollection.Count -eq 0) { return $false }

    Set-Phase $State 'Download' ("Downloading $($downloadCollection.Count) update(s).")
    $downloader = $Session.CreateUpdateDownloader()
    $downloader.Updates = $downloadCollection
    $operation = Invoke-WuaOperation $State $downloader 'Download' $downloadCollection
    if ($operation.TimedOut) {
        Finish-Run $State 'Blocked' 'Download timed out. WUA operation has ended; inspect the log before starting another run.'
        return $false
    }
    if (Test-StopRequested $State) { return $false }
    $downloadResult = $operation.Result
    $installCollection = New-Object -ComObject 'Microsoft.Update.UpdateColl'
    for ($i = 0; $i -lt $downloadCollection.Count; $i++) {
        $update = $downloadCollection.Item($i)
        $id = Get-UpdateId $update
        $result = $downloadResult.GetUpdateResult($i)
        if ([bool]$update.IsDownloaded) {
            [void]$installCollection.Add($update)
        } else {
            Add-Failure $State $id ([string]$update.Title) 'Download' ("Result=$($result.ResultCode); HRESULT=$(Format-HResult $result.HResult)")
        }
    }
    if ($installCollection.Count -eq 0) { return $false }
    if (Test-StopRequested $State) { return $false }

    Set-Phase $State 'Install' ("Installing $($installCollection.Count) update(s).")
    $installer = $Session.CreateUpdateInstaller()
    $installer.Updates = $installCollection
    $installer.AllowSourcePrompts = $false
    $installer.ForceQuiet = $true
    if ($installer.IsBusy) { throw 'Another Windows Update installation is active; retry later.' }
    if ([bool]$installer.RebootRequiredBeforeInstallation) {
        Schedule-Reboot $State 'Reboot is required before the next installation batch.'
        return $false
    }
    $operation = Invoke-WuaOperation $State $installer 'Install' $installCollection
    $installResult = $operation.Result
    $anySucceeded = $false
    for ($i = 0; $i -lt $installCollection.Count; $i++) {
        $update = $installCollection.Item($i)
        $id = Get-UpdateId $update
        $result = $installResult.GetUpdateResult($i)
        $title = [string]$update.Title
        if ([int]$result.ResultCode -eq 2) {
            $anySucceeded = $true
            $State.Installed = @($State.Installed) + @([pscustomobject]@{
                Id=$id; Title=$title; InstalledUtc=[DateTime]::UtcNow.ToString('o')
            })
            Resolve-Failure $State $id
            Write-Log ("Installed: $title")
        } else {
            Add-Failure $State $id $title 'Install' ("Result=$($result.ResultCode); HRESULT=$(Format-HResult $result.HResult)")
        }
    }
    Save-State $State
    if ($operation.TimedOut) {
        Finish-Run $State 'Blocked' 'Installation exceeded its timeout. WUA operation has ended; results recorded. Check whether a restart is pending.'
        return $false
    }
    if (Test-StopRequested $State) { return $false }
    if ([bool]$installResult.RebootRequired -or (Test-UpdateRebootPending)) {
        Schedule-Reboot $State 'Windows Update requires a reboot.'
    }
    return $anySucceeded
}

function Invoke-WorkerCore {
    $state = Get-State
    if ($null -eq $state) { throw 'State file is missing.' }
    Initialize-RuntimeState $state
    if ($state.Status -in $script:TerminalStates) { return }
    try {
        $bootId = Get-BootId
        if ($state.ActiveOperation) {
            if ($state.OperationBootId -eq $bootId) {
                Finish-Run $state 'Blocked' 'Previous WUA operation ended unexpectedly; its outcome is unknown. No new operation will start on this boot.'
                return
            }
            $state.ActiveOperation = ''
            $state.ProgressPercent = -1
            Write-Log 'Reboot detected after an interrupted WUA operation; checking actual update state.' 'WARN'
        }
        if (-not $state.RebootCommitted -and (Test-StopRequested $state)) { return }
        if ($state.Status -eq 'WaitingForReboot') {
            if ($bootId -eq [string]$state.RebootBootId) {
                # Report an aborted/missed restart instead of waiting forever.
                $elapsed = ([DateTime]::UtcNow - [DateTime]::Parse([string]$state.RebootRequestedUtc).ToUniversalTime()).TotalMinutes
                if ($elapsed -gt 15) {
                    Finish-Run $state 'Blocked' 'Requested restart did not occur within 15 minutes.'
                }
                return
            }
            $state.Status = 'Running'
            $state.RebootCommitted = $false
            $state.ConsecutiveErrors = 0
            Set-Phase $state 'Resume' 'System rebooted; resuming Windows Update.'
            if (Test-StopRequested $state) { return }
            Start-Sleep -Seconds 30
        }
        if (Test-StopRequested $state) { return }
        $platform = Get-SupportedPlatform
        if ([bool]$state.Windows11UpgradeRequested -and $platform.IsWindows11) {
            $state.Windows11UpgradeStatus = 'Completed'
        }
        if ([DateTime]::Parse([string]$state.StartedUtc).ToUniversalTime() -lt [DateTime]::UtcNow.AddDays(-7)) {
            Finish-Run $state 'Blocked' 'Seven-day maintenance deadline exceeded.'
            return
        }
        if (Test-UwfEnabled) {
            Finish-Run $state 'Blocked' 'Unified Write Filter is active. Use Windows UWF servicing mode instead.'
            return
        }
        for ($pass = 1; $pass -le 30; $pass++) {
            if ([DateTime]::UtcNow -ge [DateTime]::Parse([string]$state.StartedUtc).ToUniversalTime().AddDays(7)) {
                Finish-Run $state 'Blocked' 'Seven-day maintenance deadline exceeded.'
                return
            }
            if (Test-StopRequested $state) { return }
            if (Test-UpdateRebootPending) {
                Schedule-Reboot $state 'A Windows Update reboot is pending.'
                return
            }
            $state.Scans = [int]$state.Scans + 1
            Set-Phase $state 'Scan' ("Scanning for updates (scan $($state.Scans)).")
            $session = New-Object -ComObject 'Microsoft.Update.Session'
            $session.ClientApplicationID = 'MSP-WindowsUpdate/1.0'
            $searcher = $session.CreateUpdateSearcher()
            $searcher.Online = $true
            # Default service selection respects Windows Update / Microsoft Update / WSUS policy.
            $operation = Invoke-WuaOperation $state $searcher 'Scan'
            if ($operation.TimedOut) {
                Finish-Run $state 'Blocked' 'Search timed out. WUA operation has ended; inspect the log before starting another run.'
                return
            }
            if (Test-StopRequested $state) { return }
            $searchResult = $operation.Result
            if ([int]$searchResult.ResultCode -ne 2) {
                throw ("Search returned ResultCode=$($searchResult.ResultCode)")
            }
            $candidates = @(Get-Candidates $state $searchResult $platform)
            if ($candidates.Count -eq 0) {
                $state.EmptyScans = [int]$state.EmptyScans + 1
                if ($state.EmptyScans -lt 2) {
                    Set-Phase $state 'Verify' 'No installable updates; performing a second scan.'
                    Start-Sleep -Seconds 20
                    continue
                }
                $openFailures = @($state.Failures | Where-Object { -not $_.Resolved })
                $skippedAttention = @($state.Skipped | Where-Object {
                    $_.Reason -eq 'Update may require interactive input' -or
                    $_.Reason -eq 'Unable to classify optional update safely' -or
                    $_.Reason -eq 'Unable to identify target Windows version safely'
                })
                if ([bool]$state.Windows11UpgradeRequested -and -not $platform.IsWindows11) {
                    if ([bool]$state.Windows11UpgradeOffered) {
                        $state.Windows11UpgradeStatus = 'NotCompleted'
                        $upgradeMessage = 'Windows 11 upgrade was offered but the system is still Windows 10.'
                    } else {
                        $state.Windows11UpgradeStatus = 'NotOffered'
                        $upgradeMessage = 'No identifiable Windows 11 upgrade was offered by the configured update source.'
                    }
                    Finish-Run $state 'CompletedWithErrors' ("$upgradeMessage No more eligible updates; failures=$($openFailures.Count), requires-attention=$($skippedAttention.Count).")
                } elseif ($openFailures.Count -gt 0 -or $skippedAttention.Count -gt 0) {
                    Finish-Run $state 'CompletedWithErrors' ("No more eligible updates; failures=$($openFailures.Count), requires-attention=$($skippedAttention.Count).")
                } else {
                    Finish-Run $state 'Completed' 'Two scans found no further eligible updates in the configured source.'
                }
                return
            }
            $state.EmptyScans = 0
            Save-State $state
            Write-Log ("Found $($searchResult.Updates.Count) update(s); processing $($candidates.Count).")
            $progress = Install-Batch $state $session $candidates
            if ($state.Status -ne 'Running') { return }
            if (-not $progress) {
                Set-Phase $state 'Retry' 'No installations succeeded; retrying on the next scheduled run.'
                return
            }
            $state.ConsecutiveErrors = 0
            Save-State $state
            Start-Sleep -Seconds 15
        }
        Finish-Run $state 'Blocked' 'Exceeded 30 update passes without converging.'
    } catch {
        $message = $_.Exception.Message
        $state.ConsecutiveErrors = [int]$state.ConsecutiveErrors + 1
        $state.LastError = $message
        Write-Log ("Worker error $($state.ConsecutiveErrors)/$($state.MaxAttempts): $message") 'ERROR'
        if ($state.RebootCommitted -and $state.Status -eq 'WaitingForReboot') {
            Finish-Run $state 'Blocked' ("Restart outcome cannot be confirmed: $message. Stop cannot be confirmed on this boot.")
        } elseif ($state.ActiveOperation -or $state.Status -eq 'Blocked') {
            Finish-Run $state 'Blocked' ("WUA outcome cannot be confirmed: $message. No further updates or restarts will be started.")
        } elseif (Test-StopRequested $state) {
            return
        } elseif ([int]$state.ConsecutiveErrors -ge [int]$state.MaxAttempts) {
            Finish-Run $state 'Blocked' ("Repeated Windows Update error: $message")
        } else {
            Set-Phase $state 'Retry' 'Temporary error; retry scheduled in 15 minutes.'
        }
    }
}

function Invoke-Worker {
    Assert-Administrator
    try { $workerLock = Enter-FileLock $script:WorkerLockPath -TimeoutSeconds 0 }
    catch { return }
    try { Invoke-WorkerCore }
    finally { $workerLock.Dispose() }
}

function Initialize-Directory {
    [void](New-Item -ItemType Directory -Path $script:Root -Force)
    # Remove inherited writable permissions so unprivileged users cannot replace SYSTEM code.
    & "$env:SystemRoot\System32\icacls.exe" $script:Root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to secure the state and script directory.' }
}

function Invoke-Start {
    Assert-Administrator
    $platform = Get-SupportedPlatform
    if (Test-UwfEnabled) {
        throw 'Unified Write Filter is active. Use Windows UWF servicing mode before applying updates.'
    }
    if ($platform.IsServer -and -not $AllowServerReboot) {
        throw 'Windows Server requires -AllowServerReboot to authorize unattended restarts.'
    }
    if (-not $PSCommandPath -or -not (Test-Path -LiteralPath $PSCommandPath)) {
        throw 'Start requires a local .ps1 file. Download it before running.'
    }
    Initialize-WuaCallback
    if (-not $NoMonitor) {
        if (-not [Environment]::UserInteractive -or [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {
            throw 'An interactive desktop is required for the monitor. Use -NoMonitor for unattended deployment.'
        }
        Add-Type -AssemblyName System.Windows.Forms
    }
    Initialize-Directory
    $startupLock = Enter-FileLock $script:WorkerLockPath -TimeoutSeconds 0
    $control = $null
    try {
        $previous = Get-State
        if ($null -ne $previous) {
            Initialize-RuntimeState $previous
            if ($previous.ActiveOperation -and $previous.OperationBootId -eq (Get-BootId)) {
                throw 'A previous WUA operation has an unknown outcome on this boot. Resolve it before starting another run.'
            }
            if ($previous.RebootCommitted -and $previous.RebootBootId -eq (Get-BootId)) {
                throw 'A restart has already been committed on this boot. A new run cannot start until its outcome is resolved.'
            }
        }
        if ($null -ne $previous -and $previous.Status -notin $script:TerminalStates) {
            Write-Host 'An update run is already active:'
            Show-Status
            return
        }
        $upgradeRequested = Get-Windows11UpgradeChoice $platform $Windows11Upgrade
        $control = Enter-FileLock $script:ControlLockPath
        Remove-TaskSafely
        Remove-TaskSafely $script:MonitorTaskName
        if (Test-Path -LiteralPath $script:NotificationPath) { Remove-Item -LiteralPath $script:NotificationPath -Force }
        if (Test-Path -LiteralPath $script:StopPath) { Remove-Item -LiteralPath $script:StopPath -Force }
        if ([IO.Path]::GetFullPath($PSCommandPath) -ne [IO.Path]::GetFullPath($script:WorkerPath)) {
            Copy-Item -LiteralPath $PSCommandPath -Destination $script:WorkerPath -Force
        }
        $state = [pscustomobject]@{
            Version=4; RunId=[Guid]::NewGuid().ToString('N'); Status='Running'
            Phase='Queued'; Message='Queued for installation'; UpdatedUtc=''
            StartedUtc=[DateTime]::UtcNow.ToString('o'); Scans=0; EmptyScans=0
            Reboots=0; RebootBootId=''; RebootRequestedUtc=''; ConsecutiveErrors=0; LastError=''
            MaxReboots=$MaxReboots; MaxAttempts=$MaxAttempts
            IncludeDrivers=([bool]$IncludeDrivers -and -not $ExcludeDrivers)
            IncludeOptional=([bool]$IncludeOptional -and -not $ExcludeOptional)
            OperationTimeoutMinutes=$OperationTimeoutMinutes; RebootDelaySeconds=$RebootDelaySeconds
            RebootCommitted=$false; ActiveOperation=''; OperationBootId=''; ProgressPercent=-1
            MonitorEnabled=(-not $NoMonitor)
            IncludeFeatureUpgrades=[bool]$IncludeFeatureUpgrades
            Windows11UpgradeRequested=$upgradeRequested
            Windows11UpgradeOffered=$false
            Windows11UpgradeStatus=$(if ($upgradeRequested) { 'Requested' } else { 'NotRequested' })
            IsServer=[bool]$platform.IsServer
            AllowServerReboot=[bool]$AllowServerReboot
            PlatformCaption=[string]$platform.Caption
            PlatformVersion=[string]$platform.Version
            Installed=@(); Skipped=@(); Failures=@()
        }
        Save-State $state
        Write-Log ("Windows 11 upgrade requested: $upgradeRequested")
        Write-Log ("Started $($state.RunId); platform=$($state.PlatformCaption) $($state.PlatformVersion); server=$($state.IsServer); drivers=$($state.IncludeDrivers); optional=$($state.IncludeOptional); upgrades=$($state.IncludeFeatureUpgrades)")

        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = '-NoProfile -NonInteractive -MTA -ExecutionPolicy Bypass -File "{0}" -Action Worker' -f $script:WorkerPath
        $taskAction = New-ScheduledTaskAction -Execute $psExe -Argument $arguments
        $startupTrigger = New-ScheduledTaskTrigger -AtStartup
        $retryTrigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) `
            -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Days 365)
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        try {
            $monitorArguments = $null
            if (-not $NoMonitor) { $monitorArguments = Register-MonitorTask $state $psExe }
            Register-ScheduledTask -TaskName $script:TaskName -Action $taskAction `
                -Trigger @($startupTrigger, $retryTrigger) -Principal $principal -Settings $settings -Force | Out-Null
        } catch {
            $state.Status = 'Blocked'
            Set-Phase $state 'Blocked' ('Failed to create or start the scheduled task: ' + $_.Exception.Message)
            Remove-TaskSafely
            Remove-TaskSafely $script:MonitorTaskName
            throw
        }
    } finally {
        if ($null -ne $control) { $control.Dispose() }
        $startupLock.Dispose()
    }
    Start-ScheduledTask -TaskName $script:TaskName
    Write-Host ('Started. Logs: ' + $script:LogPath)
    if ($monitorArguments) {
        Start-Process -FilePath $psExe -ArgumentList $monitorArguments -WindowStyle Hidden | Out-Null
    }
}

function Show-Status {
    $state = Get-State
    if ($null -eq $state) {
        Write-Host 'No MSP Windows Update run found.'
        return
    }
    Initialize-RuntimeState $state
    $openFailures = @($state.Failures | Where-Object { -not $_.Resolved })
    [pscustomobject]@{
        Status=$state.Status; Phase=$state.Phase; Detail=$state.Message
        Scans=$state.Scans; Reboots=$state.Reboots
        Installed=@($state.Installed).Count
        Failures=$openFailures.Count
        Skipped=@($state.Skipped).Count
        Windows11Upgrade=$state.Windows11UpgradeStatus
        ActiveOperation=$state.ActiveOperation; ProgressPercent=$state.ProgressPercent
        StartedUtc=$state.StartedUtc; UpdatedUtc=$state.UpdatedUtc
        Log=$script:LogPath
    } | Format-List | Out-Host
}

function Invoke-Stop {
    Assert-Administrator
    $control = Enter-FileLock $script:ControlLockPath
    try {
        $state = Get-State
        if ($null -eq $state) { throw 'No active run found.' }
        Initialize-RuntimeState $state
        if ($MonitorRunId -and $state.RunId -ne $MonitorRunId) { throw 'This monitor belongs to an older run.' }
        if ($state.Status -in $script:TerminalStates) {
            if ($state.ActiveOperation) {
                Write-Warning 'The run is blocked, but a WUA operation may still be active. No further updates or restarts will be started.'
            } else { Write-Host ('Already finished: ' + $state.Status) }
            return
        }
        [IO.File]::WriteAllText($script:StopPath, [DateTime]::UtcNow.ToString('o'))
        if ($state.RebootCommitted) {
            Write-Warning 'The restart has already been committed and cannot be cancelled. Stop will be applied on the next boot.'
        } else {
            Write-Host 'Stop requested. The worker will stop before the next operation or restart; an active installation may finish first.'
        }
    } finally { $control.Dispose() }
    # Wake an idle worker; the task and file lock prevent concurrent execution.
    $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if ($null -ne $task) {
        Start-ScheduledTask -TaskName $script:TaskName
    } else {
        Write-Warning 'The worker task is missing. Stop is recorded, but worker termination cannot be confirmed.'
    }
}

function Register-MonitorTask {
    param([object]$State, [string]$PowerShellExe)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $arguments = '-NoProfile -NonInteractive -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Action Monitor -MonitorRunId {1}' -f $script:WorkerPath, $State.RunId
    $action = New-ScheduledTaskAction -Execute $PowerShellExe -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $sid
    $principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances Parallel -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $script:MonitorTaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    return $arguments
}

function Play-CompletionSound {
    [System.Media.SystemSounds]::Asterisk.Play()
}

function Send-CompletionSound {
    param([object]$State)
    if ($State.Status -ne 'Completed' -or $State.ActiveOperation) { return }
    $control = Enter-FileLock $script:ControlLockPath
    try {
        $current = Get-State
        if ($current.RunId -ne $State.RunId -or $current.Status -ne 'Completed') { return }
        $marker = [IO.File]::Open($script:NotificationPath, 'CreateNew', 'Write', 'None')
        $marker.Dispose()
    } catch [IO.IOException] { return }
    finally { $control.Dispose() }
    # Sound belongs to the interactive session and depends on its audio settings.
    try { Play-CompletionSound }
    catch { Write-Warning ('Completion sound unavailable: ' + $_.Exception.Message) }
}

function Invoke-Monitor {
    Assert-Administrator
    if (-not [Environment]::UserInteractive -or [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {
        throw 'Monitor requires an interactive desktop. Use -Action Status in unattended sessions.'
    }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $initial = Get-State
    if ($null -eq $initial) { throw 'No update run found.' }
    $runId = $initial.RunId
    if ($MonitorRunId -and $MonitorRunId -ne $runId) { return }
    $script:MonitorRunId = $runId
    $mutex = [Threading.Mutex]::new($false, ('Local\MSP-WindowsUpdate-Monitor-' + $runId))
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { return }
        $form = [Windows.Forms.Form]::new()
        $form.Text = 'DaScript - Windows Update'
        $form.ClientSize = [Drawing.Size]::new(850, 570)
        $form.MinimumSize = [Drawing.Size]::new(700, 500)
        $form.StartPosition = 'CenterScreen'
        $form.Font = [Drawing.Font]::new('Segoe UI', 10)
        $heading = [Windows.Forms.Label]::new()
        $heading.SetBounds(20, 15, 810, 40)
        $heading.Font = [Drawing.Font]::new('Segoe UI', 16, [Drawing.FontStyle]::Bold)
        $heading.Anchor = 'Top, Left, Right'
        $detail = [Windows.Forms.Label]::new()
        $detail.SetBounds(20, 60, 810, 110)
        $detail.Anchor = 'Top, Left, Right'
        $bar = [Windows.Forms.ProgressBar]::new()
        $bar.SetBounds(20, 175, 810, 20)
        $bar.Anchor = 'Top, Left, Right'
        $log = [Windows.Forms.TextBox]::new()
        $log.SetBounds(20, 210, 810, 295)
        $log.Multiline = $true
        $log.ReadOnly = $true
        $log.ScrollBars = 'Both'
        $log.WordWrap = $false
        $log.Anchor = 'Top, Bottom, Left, Right'
        $stop = [Windows.Forms.Button]::new()
        $stop.Text = 'Arresta'
        $stop.SetBounds(20, 520, 130, 32)
        $stop.Anchor = 'Bottom, Left'
        $close = [Windows.Forms.Button]::new()
        $close.Text = 'Chiudi finestra'
        $close.SetBounds(670, 520, 160, 32)
        $close.Anchor = 'Bottom, Right'
        $form.Controls.AddRange(@($heading, $detail, $bar, $log, $stop, $close))
        $timer = [Windows.Forms.Timer]::new()
        $timer.Interval = 3000
        $refresh = {
        try {
            $state = Get-State
            if ($null -eq $state -or $state.RunId -ne $runId) { $form.Close(); return }
            Initialize-RuntimeState $state
            $finished = $state.Status -in $script:TerminalStates -and -not $state.ActiveOperation
            $heading.ForeColor = [Drawing.Color]::DarkBlue
            switch ($state.Status) {
                'Completed' { $heading.Text = 'Aggiornamenti completati'; $heading.ForeColor = [Drawing.Color]::DarkGreen }
                'CompletedWithErrors' { $heading.Text = 'Operazione conclusa con problemi'; $heading.ForeColor = [Drawing.Color]::DarkOrange }
                'Blocked' { $heading.Text = 'Operazione bloccata - intervento necessario'; $heading.ForeColor = [Drawing.Color]::Firebrick }
                'Stopped' { $heading.Text = 'Arrestato su richiesta' }
                'WaitingForReboot' { $heading.Text = 'Riavvio per proseguire gli aggiornamenti' }
                default { $heading.Text = 'Aggiornamenti in corso' }
            }
            $failures = @($state.Failures | Where-Object { -not $_.Resolved }).Count
            $detail.Text = "$($state.Message)`r`nInstallati: $(@($state.Installed).Count)   Errori: $failures   Esclusi: $(@($state.Skipped).Count)   Riavvii: $($state.Reboots)`r`nWindows 11: $($state.Windows11UpgradeStatus)   Fase: $($state.Phase)`r`nChiudere questa finestra non interrompe il lavoro. Log: $script:LogPath"
            if ($finished -or $state.Status -eq 'Blocked' -or $state.ProgressPercent -ge 0) {
                $bar.Style = 'Continuous'
                $bar.Value = $(if ($state.Status -eq 'Completed') { 100 } else { [Math]::Max(0, [Math]::Min(100, $state.ProgressPercent)) })
            } else { $bar.Style = 'Marquee' }
            $stop.Enabled = -not ($state.Status -in $script:TerminalStates) -and -not $state.RebootCommitted -and -not (Test-Path -LiteralPath $script:StopPath)
            $text = @(Get-Content -LiteralPath $script:LogPath -Tail 60 -ErrorAction Stop) -join "`r`n"
            if ($finished) {
                $text += "`r`n`r`nESCLUSIONI:`r`n" + (($state.Skipped | ForEach-Object { "$($_.Title): $($_.Reason)" }) -join "`r`n")
                $text += "`r`n`r`nERRORI APERTI:`r`n" + (($state.Failures | Where-Object { -not $_.Resolved } | ForEach-Object { "$($_.Title): $($_.Reason)" }) -join "`r`n")
            }
            if ($log.Text -ne $text) { $log.Text = $text; $log.SelectionStart = $log.TextLength; $log.ScrollToCaret() }
            Send-CompletionSound $state
        } catch { $heading.Text = 'Impossibile leggere lo stato'; $detail.Text = $_.Exception.Message }
        }
        $timer.add_Tick($refresh)
        $form.add_Shown({ & $refresh; $timer.Start() })
        $stop.add_Click({
            try {
                $current = Get-State
                if ($current.RunId -ne $runId) { $form.Close(); return }
                Invoke-Stop
                & $refresh
            } catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Arresto') }
        })
        $close.add_Click({ $form.Close() })
        $form.add_FormClosed({
            $timer.Stop()
            # Keep the logon task until the terminal result has been acknowledged.
            $control = $null
            try {
                $control = Enter-FileLock $script:ControlLockPath
                $current = Get-State
                Initialize-RuntimeState $current
                if ($current.RunId -eq $runId -and $current.Status -in $script:TerminalStates -and -not $current.ActiveOperation) {
                    Remove-TaskSafely $script:MonitorTaskName
                }
            } catch { Write-Warning $_.Exception.Message }
            finally { if ($null -ne $control) { $control.Dispose() } }
        })
        try { [void]$form.ShowDialog() }
        finally { $timer.Dispose(); $form.Dispose() }
    } finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

switch ($Action) {
    'Start'   { Invoke-Start }
    'Worker'  { Invoke-Worker }
    'Status'  { Show-Status }
    'Monitor' { Invoke-Monitor }
    'Stop'    { Invoke-Stop }
}
