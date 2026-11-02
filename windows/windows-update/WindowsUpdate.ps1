#Requires -Version 5.1
<#
.SYNOPSIS
    Installs applicable Windows updates and resumes automatically after restarts.
.DESCRIPTION
    Runs on Windows 10/11 and Windows Server, using the configured Windows Update/WSUS source.
    The background worker runs as SYSTEM from a protected Scheduled Task.
    Stop is cooperative: it never terminates an update installation mid-operation.
.EXAMPLE
    .\WindowsUpdate.ps1 -Action Start
.EXAMPLE
    .\WindowsUpdate.ps1 -Action Start -NoMonitor
.EXAMPLE
    .\WindowsUpdate.ps1 -Action Status
.EXAMPLE
    .\WindowsUpdate.ps1 -Action Stop
.EXAMPLE
    .\WindowsUpdate.ps1 -Action Start -AllowServerReboot -NoMonitor
#>
[CmdletBinding()]
param(
    [ValidateSet('Start', 'Worker', 'Status', 'Monitor', 'Stop', 'Preview')]
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

$script:TaskName = 'DaScript-WindowsUpdate'
$script:MonitorTaskName = 'DaScript-WindowsUpdate-Monitor'
$script:Root = Join-Path $env:ProgramData 'DaScript\WindowsUpdate'
$script:WorkerPath = Join-Path $script:Root 'WindowsUpdate.ps1'
$script:StatePath = Join-Path $script:Root 'state.json'
$script:BackupPath = Join-Path $script:Root 'state.json.bak'
$script:StopPath = Join-Path $script:Root 'stop.request'
$script:LogNamePrefix = 'Global\DaScript-WindowsUpdate-Log-'
$script:MemoryLog = $null
$script:MemoryLogRunId = ''
$script:MemoryLogError = ''
$script:MonitorBootId = ''
$script:ControlLockName = 'Global\DaScript-WindowsUpdate-Control'
$script:WorkerLockName = 'Global\DaScript-WindowsUpdate-Worker'
$script:NotificationPath = Join-Path $script:Root 'completion-notified'
$script:ResultReadPath = Join-Path $script:Root 'result-read'
$script:TerminalStates = @('Completed', 'CompletedWithExclusions', 'CompletedWithErrors', 'Blocked', 'Stopped')

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
        OperationStartedUtc=''; OperationProcessId=0; CleanupError=''; ParentCreated=$false
        WuaProgress=$null
    }
    foreach ($name in $defaults.Keys) {
        if ($null -eq $State.PSObject.Properties[$name]) {
            $State | Add-Member -NotePropertyName $name -NotePropertyValue $defaults[$name]
        }
    }
}

function Enter-RunLock {
    param([string]$Name, [int]$TimeoutSeconds = 5)
    # Kernel objects leave no lock files and protect cleanup across Windows sessions.
    $security = [Security.AccessControl.MutexSecurity]::new()
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $security.AddAccessRule([Security.AccessControl.MutexAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'Allow'))
    }
    $created = $false
    $mutex = [Threading.Mutex]::new($false, $Name, [ref]$created, $security)
    try {
        try { $owned = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds)) }
        catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw [TimeoutException]::new("Another operation holds $Name. Retry after it finishes.") }
        return $mutex
    } catch { $mutex.Dispose(); throw }
}

function Exit-RunLock {
    param([Threading.Mutex]$Mutex)
    if ($null -ne $Mutex) {
        try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() }
    }
}

function Initialize-WuaCallback {
    if ('DaScript.WindowsUpdate.Callback' -as [type]) { return }
    # WUA accepts an Automation callback with DISPID 0. No PowerShell runs on COM threads.
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
namespace DaScript.WindowsUpdate {
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
    $lastLoggedPercent = -1
    $lastLoggedUpdatePercent = -1
    $unchangedLogged = $false
    $changeFields = @('Index','BatchPercent','UpdatePercent','DownloadPhase','TotalBytesDownloaded','CurrentUpdateBytesDownloaded')
    $observed = @{}
    if ($null -ne $State.WuaProgress) {
        foreach ($name in $changeFields) {
            if ($null -ne $State.WuaProgress.$name) { $observed[$name] = $State.WuaProgress.$name }
        }
    }
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
            try {
                $progress = $Job.GetProgress()
                if ($null -eq $progress) { throw 'WUA returned no progress object.' }
            } catch {
                if ($null -eq $State.WuaProgress) { $State.WuaProgress = New-WuaProgress }
                $State.WuaProgress.ReadError = $_.Exception.Message.Substring(0, [Math]::Min(1024, $_.Exception.Message.Length))
                Write-Log ("$Operation progress read failed: " + $_.Exception.Message) 'ERROR'
                throw
            }
            $previous = $State.WuaProgress
            $sample = Get-WuaProgressSample $progress $Updates $Operation
            $now = [DateTime]::UtcNow
            $sample.LastResponseUtc = $now.ToString('o')
            $changed = $false
            $newUpdate = $null -ne $sample.Index -and (-not $observed.ContainsKey('Index') -or $sample.Index -ne $observed.Index)
            if ($newUpdate) {
                foreach ($name in @('UpdatePercent','DownloadPhase','CurrentUpdateBytesDownloaded')) { $observed.Remove($name) }
            }
            $newPhase = $null -ne $sample.DownloadPhase -and (-not $observed.ContainsKey('DownloadPhase') -or $sample.DownloadPhase -ne $observed.DownloadPhase)
            if ($null -ne $previous) {
                $sample.ObservedUtc = $previous.ObservedUtc
                $sample.LastChangeUtc = $previous.LastChangeUtc
            }
            foreach ($name in $changeFields) {
                # Compare usable observations across missing samples, never availability itself.
                if ($null -ne $sample.$name) {
                    if ($observed.ContainsKey($name) -and $sample.$name -ne $observed[$name]) { $changed = $true }
                    $observed[$name] = $sample.$name
                }
            }
            $hasValues = $null -ne $sample.Index -or $null -ne $sample.BatchPercent -or $null -ne $sample.TotalBytesDownloaded
            if (-not $sample.ObservedUtc -and $hasValues) { $sample.ObservedUtc = $sample.LastResponseUtc }
            if ($changed) { $sample.LastChangeUtc = $sample.LastResponseUtc; $unchangedLogged = $false }
            $State.WuaProgress = $sample
            if ($null -ne $sample.BatchPercent) { $State.ProgressPercent = $sample.BatchPercent }
            if ($newUpdate) {
                $lastLoggedUpdatePercent = -1
                Write-Log ("$Operation update $($sample.Index+1)/$($sample.Count): $($sample.Title)")
            }
            if ($newPhase) { Write-Log ("Download phase: " + (Get-DownloadPhaseLabel $sample.DownloadPhase)) }
            if ($null -ne $sample.BatchPercent -and ($lastLoggedPercent -lt 0 -or [Math]::Abs($sample.BatchPercent-$lastLoggedPercent) -ge 10 -or ($sample.BatchPercent -eq 100 -and $lastLoggedPercent -ne 100))) {
                Write-Log ("$Operation WUA batch: $($sample.BatchPercent)%")
                $lastLoggedPercent = $sample.BatchPercent
            }
            if ($null -ne $sample.UpdatePercent -and ($lastLoggedUpdatePercent -lt 0 -or [Math]::Abs($sample.UpdatePercent-$lastLoggedUpdatePercent) -ge 10 -or ($sample.UpdatePercent -eq 100 -and $lastLoggedUpdatePercent -ne 100))) {
                Write-Log ("$Operation update $($sample.Index+1)/$($sample.Count): $($sample.UpdatePercent)%")
                $lastLoggedUpdatePercent = $sample.UpdatePercent
            }
            $since = if ($sample.LastChangeUtc) { $sample.LastChangeUtc } else { $sample.ObservedUtc }
            if ($since -and -not $unchangedLogged -and (Get-MonitorAgeSeconds $since $now) -ge 120) {
                Write-Log ("$Operation`: NO PROGRESS CHANGE // WINDOWS UPDATE STILL RESPONDING (120s or more).")
                $unchangedLogged = $true
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
    $callback = New-Object DaScript.WindowsUpdate.Callback
    $State.ActiveOperation = $Operation
    $State.OperationBootId = Get-BootId
    $State.OperationStartedUtc = [DateTime]::UtcNow.ToString('o')
    $State.OperationProcessId = $PID
    Reset-WuaProgress $State
    Save-State $State
    Write-Log ("$Operation operation started.")
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
            Reset-WuaProgress $State
            Save-State $State
            Write-Log ("$Operation WUA job completed; finalizing results.")
            $job.CleanUp()
        }
        [GC]::KeepAlive($callback)
    }
}

function Reset-WuaProgress {
    param([object]$State)
    $State.ProgressPercent = -1
    $State | Add-Member -NotePropertyName WuaProgress -NotePropertyValue $null -Force
}

function New-WuaProgress {
    return [pscustomobject]@{
        Index=$null; Count=0; Title=''; BatchPercent=$null; UpdatePercent=$null; DownloadPhase=$null
        TotalBytesDownloaded=$null; TotalBytesToDownload=$null
        CurrentUpdateBytesDownloaded=$null; CurrentUpdateBytesToDownload=$null
        ObservedUtc=''; LastResponseUtc=''; LastChangeUtc=''; ReadError=''
    }
}

function Get-WuaProgressNumber {
    param([object]$Progress, [string]$Name, [decimal]$Maximum=[decimal]::MaxValue)
    try {
        $raw = $Progress.$Name
        # WUA byte counters use COM DECIMAL, which may retain a fractional scale for whole bytes.
        if ($raw -is [decimal]) {
            if ($raw -ge 0 -and $raw -le $Maximum -and [decimal]::Truncate($raw) -eq $raw) { return [decimal]::Truncate($raw) }
            return $null
        }
        $value = [decimal]0
        if ($null -ne $raw -and [string]$raw -match '^\d+$' -and
            [decimal]::TryParse([string]$raw, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$value) -and $value -le $Maximum) {
            return $value
        }
    } catch { }
    return $null
}

function Get-WuaProgressSample {
    param([object]$Progress, [object]$Updates, [string]$Operation)
    $sample = New-WuaProgress
    $sample.BatchPercent = Get-WuaProgressNumber $Progress 'PercentComplete' 100
    if ($null -ne $Updates) { $sample.Count = $Updates.Count }
    $index = Get-WuaProgressNumber $Progress 'CurrentUpdateIndex' ([int]::MaxValue)
    if ($null -ne $index -and $index -lt $sample.Count) {
        $sample.Index = [int]$index
        try { $sample.Title = [string]$Updates.Item([int]$index).Title } catch { }
        $sample.UpdatePercent = Get-WuaProgressNumber $Progress 'CurrentUpdatePercentComplete' 100
    }
    if ($Operation -eq 'Download') {
        foreach ($name in @('TotalBytesDownloaded','TotalBytesToDownload')) { $sample.$name = Get-WuaProgressNumber $Progress $name }
        if ($null -ne $sample.Index) {
            foreach ($name in @('CurrentUpdateBytesDownloaded','CurrentUpdateBytesToDownload')) { $sample.$name = Get-WuaProgressNumber $Progress $name }
            $phase = Get-WuaProgressNumber $Progress 'CurrentUpdateDownloadPhase' 3
            if ($null -ne $phase -and $phase -ge 1) { $sample.DownloadPhase = [int]$phase }
        }
    }
    return $sample
}

function Get-DownloadPhaseLabel {
    param($Phase)
    switch ($Phase) { 1 { return 'INITIALIZING' }; 2 { return 'DOWNLOADING' }; 3 { return 'VERIFYING' }; default { return '--' } }
}

function Get-MonitorAgeSeconds {
    param([string]$Timestamp, [DateTime]$Now=[DateTime]::UtcNow)
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($Timestamp, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { return $null }
    $seconds = ($Now.ToUniversalTime() - $parsed.UtcDateTime).TotalSeconds
    if ($seconds -lt 0) { return $null }
    return [Math]::Floor($seconds)
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

function Close-MemoryLog {
    if ($null -ne $script:MemoryLog) { $script:MemoryLog.Dispose() }
    $script:MemoryLog = $null
    $script:MemoryLogRunId = ''
    $script:MemoryLogError = ''
}

function Initialize-MemoryLog {
    param([string]$RunId, [switch]$ReadOnly)
    if ($script:MemoryLogRunId -eq $RunId -and $null -ne $script:MemoryLog) { return }
    Close-MemoryLog
    $script:MemoryLogRunId = $RunId
    try {
        $name = $script:LogNamePrefix + $RunId
        if ($ReadOnly) {
            $script:MemoryLog = [IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting(
                $name, [IO.MemoryMappedFiles.MemoryMappedFileRights]::Read)
        } else {
            $security = [IO.MemoryMappedFiles.MemoryMappedFileSecurity]::new()
            foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
                $security.AddAccessRule([Security.AccessControl.AccessRule[IO.MemoryMappedFiles.MemoryMappedFileRights]]::new(
                    [Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'Allow'))
            }
            # A named, non-persisted mapping connects SYSTEM and the elevated monitor across sessions.
            $script:MemoryLog = [IO.MemoryMappedFiles.MemoryMappedFile]::CreateOrOpen(
                $name, 1MB, [IO.MemoryMappedFiles.MemoryMappedFileAccess]::ReadWrite,
                [IO.MemoryMappedFiles.MemoryMappedFileOptions]::None, $security, [IO.HandleInheritability]::None)
        }
    } catch [IO.FileNotFoundException] {
        $script:MemoryLogError = 'No in-memory activity log is available. Waiting for the worker; previous history may have been released.'
    } catch {
        $script:MemoryLogError = 'In-memory activity log unavailable: ' + $_.Exception.Message
        if (-not $ReadOnly) { Write-Warning $script:MemoryLogError }
    }
}

function Read-MemoryLog {
    # Callers hold the control mutex, including while writing the length-prefixed UTF-8 string.
    if ($null -eq $script:MemoryLog) { return $script:MemoryLogError }
    $stream = $script:MemoryLog.CreateViewStream(0, 0, [IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read)
    try {
        $reader = [IO.BinaryReader]::new($stream, [Text.Encoding]::UTF8)
        try { return $reader.ReadString() } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, ($Message -replace '[\r\n]+', ' ')
    if ($null -eq $script:MemoryLog) { Write-Verbose $line; return }
    # Bound the tail to 60 lines of at most 4096 characters, safely below the 1 MiB capacity.
    if ($line.Length -gt 4096) { $line = $line.Substring(0, 4080) + ' ... [truncated]' }
    $control = $null
    try {
        $control = Enter-RunLock $script:ControlLockName
        $previous = Read-MemoryLog
        $lines = @()
        if ($previous) { $lines = @($previous -split '\r?\n' | Select-Object -Last 59) }
        $text = (@($lines) + @($line)) -join "`r`n"
        $stream = $script:MemoryLog.CreateViewStream(0, 0, [IO.MemoryMappedFiles.MemoryMappedFileAccess]::Write)
        try {
            $writer = [IO.BinaryWriter]::new($stream, [Text.Encoding]::UTF8)
            try { $writer.Write([string]$text) } finally { $writer.Dispose() }
        } finally { $stream.Dispose() }
    } catch {
        # Logging must neither write a disk fallback nor interrupt an update operation.
        Write-Warning ('In-memory activity log write failed: ' + $_.Exception.Message)
    } finally { Exit-RunLock $control }
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
    # Use the OS-reported boot time; event logs can roll over during a long uptime.
    try {
        $boot = (Get-CimInstance -ClassName Win32_OperatingSystem -Property LastBootUpTime -ErrorAction Stop).LastBootUpTime
    } catch {
        throw ('Cannot read Windows boot time from CIM: ' + $_.Exception.Message)
    }
    if ($boot -isnot [DateTime] -or $boot -eq [DateTime]::MinValue) {
        throw 'CIM did not return a valid LastBootUpTime. Startup or recovery cannot continue.'
    }
    return ('cimboot:{0}' -f $boot.ToUniversalTime().Ticks)
}

function Test-BootChanged {
    param([string]$Previous, [string]$Current)
    if ($Previous -notmatch '^cimboot:[1-9]\d{0,18}$' -or $Current -notmatch '^cimboot:[1-9]\d{0,18}$') {
        throw 'Boot evidence is missing or uses an older state format. Recovery requires operator verification.'
    }
    foreach ($value in @($Previous, $Current)) {
        $ticks = 0L
        if (-not [long]::TryParse($value.Substring(8), [ref]$ticks) -or $ticks -gt [DateTime]::MaxValue.Ticks) {
            throw 'Boot evidence contains an invalid timestamp. Recovery requires operator verification.'
        }
    }
    return ($Previous -ne $Current)
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
    param([string]$Name = $script:TaskName, [switch]$Strict)
    try {
        $task = Get-ScheduledTask -TaskPath '\' -ErrorAction Stop | Where-Object { $_.TaskName -eq $Name }
        if ($null -ne $task) {
            Unregister-ScheduledTask -TaskName $Name -TaskPath '\' -Confirm:$false -ErrorAction Stop
        }
    } catch {
        if ($Strict) { throw }
        Write-Log ('Task cleanup failed: ' + $_.Exception.Message) 'WARN'
    }
}

function Finish-Run {
    param([object]$State, [string]$Status, [string]$Message)
    $State.Status = $Status
    Set-Phase $State $Status $Message
    Remove-TaskSafely
}

function Complete-UpdateRun {
    param([object]$State, [object]$Platform)
    $errors = @($State.Failures | Where-Object { -not $_.Resolved }).Count
    $excluded = @($State.Skipped).Count
    $status = if ($errors) { 'CompletedWithErrors' } elseif ($excluded) { 'CompletedWithExclusions' } else { 'Completed' }
    $message = "Two scans found no further eligible updates; failures=$errors, excluded=$excluded."
    if ($State.Windows11UpgradeRequested -and -not $Platform.IsWindows11) {
        $State.Windows11UpgradeStatus = if ($State.Windows11UpgradeOffered) { 'NotCompleted' } else { 'NotOffered' }
        $message += " Windows 11 upgrade: $($State.Windows11UpgradeStatus)."
        # An unavailable offer is not an installation failure; an unfulfilled upgrade needs attention.
        $upgradeExcluded = @($State.Skipped | Where-Object { $_.Title -match '\bWindows\s+11\b' }).Count -gt 0
        if ($State.Windows11UpgradeOffered -and -not $upgradeExcluded) { $status = 'CompletedWithErrors' }
        elseif (-not $errors) { $status = 'CompletedWithExclusions' }
    }
    Finish-Run $State $status $message
}

function Remove-RunArtifacts {
    [CmdletBinding()]
    param([object]$State)
    # Called while holding the worker mutex; Start cannot race with directory removal.
    $control = Enter-RunLock $script:ControlLockName
    try {
        $current = Get-State
        if ($null -eq $current -or $current.RunId -ne $State.RunId) { return }
        Initialize-RuntimeState $current
        if ($current.Status -notin $script:TerminalStates -or $current.ActiveOperation -or $current.RebootCommitted) { return }
        $State.CleanupError = ''
        $root = [IO.Path]::GetFullPath($script:Root).TrimEnd('\')
        $expected = [IO.Path]::GetFullPath((Join-Path $env:ProgramData 'DaScript\WindowsUpdate')).TrimEnd('\')
        if ($root -ne $expected) { throw 'Cleanup refused an unexpected runtime directory.' }
        $parent = [IO.Directory]::GetParent($root).FullName
        foreach ($path in @($parent, $root)) {
            if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Cleanup refused a redirected runtime directory.'
            }
        }
        $names = @('WindowsUpdate.ps1', 'state.json', 'state.json.bak', 'activity.log',
            'stop.request', 'completion-notified', 'result-read', 'control.lock', 'worker.lock')
        $files = @(Get-ChildItem -LiteralPath $root -Force)
        foreach ($file in $files) {
            if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
                ($file.Name -notin $names -and $file.Name -notmatch '^state\.[a-f0-9]{32}\.tmp$')) {
                throw ('Cleanup refused an unrecognized entry: ' + $file.Name)
            }
        }
        Remove-TaskSafely $script:MonitorTaskName -Strict
        Remove-TaskSafely $script:TaskName -Strict
        # Keep the recovery state until other files have been removed successfully.
        foreach ($file in $files | Where-Object { $_.Name -notin @('state.json', 'state.json.bak') }) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
        }
        foreach ($path in @($script:BackupPath, $script:StatePath)) {
            if ([IO.File]::Exists($path)) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
        }
        [IO.Directory]::Delete($root, $false)
        if ($current.ParentCreated -and @(Get-ChildItem -LiteralPath $parent -Force).Count -eq 0) {
            [IO.Directory]::Delete($parent, $false)
        }
    } catch {
        $State.CleanupError = $_.Exception.Message
        if (Test-Path -LiteralPath $script:Root) {
            Save-State $State
            Write-Log ('Cleanup incomplete: ' + $State.CleanupError) 'ERROR'
        }
        Write-Warning ('Cleanup incomplete: ' + $State.CleanupError)
    } finally { Exit-RunLock $control }
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
    & "$env:SystemRoot\System32\shutdown.exe" /r /t 0 /f /d p:2:17 /c 'DaScript Windows Update: restart to continue installing updates.' | Out-Null
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
    $control = Enter-RunLock $script:ControlLockName
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
        Exit-RunLock $control
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
    # Report exclusions from the latest successful scan, not superseded offers.
    $State.Skipped = @()
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
            if ([bool]$update.InstallationBehavior.CanRequestUserInput) {
                Write-Log ("Update may require interactive input; attempting normal unattended installation: $($update.Title)") 'INFO'
            }
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
            $hresult = Format-HResult $result.HResult
            $reason = "Result=$($result.ResultCode); HRESULT=$hresult"
            # Diagnose actual WUA results, never infer failure from CanRequestUserInput.
            switch ($hresult) {
                '0x8024200A' {
                    $reason += '; WU_E_UH_CANREQUIREINPUT: Manual intervention required. WUA could not install this update because it requires user input in the current execution context.'
                }
                '0x80240020' {
                    $reason += '; WU_E_NO_INTERACTIVE_USER: Manual intervention required. WUA could not complete installation because no interactive user is logged on.'
                }
                '0x80242004' {
                    $reason += '; WU_E_UH_DOESNOTSUPPORTACTION: WUA rejected the requested installation action. This can occur when an update does not support forced silent installation; operator review required.'
                }
            }
            Add-Failure $State $id $title 'Install' $reason
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
    Initialize-MemoryLog $state.RunId
    if ($state.Status -in $script:TerminalStates) { return }
    try {
        $bootId = Get-BootId
        Write-Log ("Worker started: PID=$PID; boot=$bootId; status=$($state.Status).")
        if ($state.ActiveOperation) {
            if (-not (Test-BootChanged $state.OperationBootId $bootId)) {
                Finish-Run $state 'Blocked' 'Previous WUA operation ended unexpectedly; its outcome is unknown. No new operation will start on this boot.'
                return
            }
            Write-Log ("Previous $($state.ActiveOperation) was not finalized (PID=$($state.OperationProcessId), started=$($state.OperationStartedUtc), boot=$($state.OperationBootId)); new Windows boot confirmed: $bootId. Checking actual update state.") 'WARN'
            $state.ActiveOperation = ''
            $state.OperationBootId = ''
            Reset-WuaProgress $state
            Save-State $state
        }
        if (-not $state.RebootCommitted -and (Test-StopRequested $state)) { return }
        if ($state.Status -eq 'WaitingForReboot') {
            if (-not (Test-BootChanged $state.RebootBootId $bootId)) {
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
            $session.ClientApplicationID = 'DaScript/WindowsUpdate'
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
                Complete-UpdateRun $state $platform
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
    try { $workerLock = Enter-RunLock $script:WorkerLockName -TimeoutSeconds 0 }
    catch [TimeoutException] { return }
    try {
        Invoke-WorkerCore
        $state = Get-State
        if ($null -ne $state) {
            Initialize-RuntimeState $state
            if ($state.Status -in $script:TerminalStates -and -not $state.ActiveOperation -and -not $state.RebootCommitted) {
                # Give an open monitor a bounded opportunity to keep the result in memory.
                if ($state.MonitorEnabled) {
                    for ($wait = 0; $wait -lt 10 -and -not (Test-Path -LiteralPath $script:ResultReadPath); $wait++) {
                        Start-Sleep -Seconds 1
                    }
                }
                Remove-RunArtifacts $state
            }
        }
    } finally { Exit-RunLock $workerLock }
}

function Initialize-Directory {
    [void](New-Item -ItemType Directory -Path $script:Root -Force)
    # Remove inherited writable permissions so unprivileged users cannot replace SYSTEM code.
    & "$env:SystemRoot\System32\icacls.exe" $script:Root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to secure the state and script directory.' }
}

function Assert-NoPreviousUpdateRuntime {
    # Identify older scheduled workers by their runtime path, without retaining old branding.
    foreach ($task in @(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop)) {
        if ($task.TaskName -in @($script:TaskName, $script:MonitorTaskName)) { continue }
        foreach ($taskAction in @($task.Actions)) {
            if ($null -eq $taskAction -or $null -eq $taskAction.PSObject.Properties['Arguments']) { continue }
            if ($taskAction.Arguments -match '(?i)\\WindowsUpdate\\[^"\r\n]+\.ps1"?\s+-Action\s+(Worker|Monitor)\b') {
                throw "Previous update task found: $($task.TaskName). Finish or stop that run with its original worker before starting this version."
            }
        }
    }
    if (Test-Path -LiteralPath $script:Root) {
        foreach ($file in @(Get-ChildItem -LiteralPath $script:Root -Filter '*.ps1' -File)) {
            if ($file.Name -ne [IO.Path]::GetFileName($script:WorkerPath)) {
                throw "Previous worker found: $($file.FullName). Resolve the previous runtime before starting this version."
            }
        }
    }
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
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    }
    $null = Get-BootId
    $startupLock = Enter-RunLock $script:WorkerLockName -TimeoutSeconds 0
    $control = $null
    $state = $null
    try {
        Assert-NoPreviousUpdateRuntime
        $parentCreated = -not (Test-Path -LiteralPath (Split-Path -Parent $script:Root))
        Initialize-Directory
        $previous = Get-State
        if ($null -ne $previous) {
            Initialize-RuntimeState $previous
            $parentCreated = $parentCreated -or $previous.ParentCreated
            if ($previous.ActiveOperation -and (-not (Test-BootChanged $previous.OperationBootId (Get-BootId)))) {
                throw 'A previous WUA operation has an unknown outcome on this boot. Resolve it before starting another run.'
            }
            if ($previous.RebootCommitted -and (-not (Test-BootChanged $previous.RebootBootId (Get-BootId)))) {
                throw 'A restart has already been committed on this boot. A new run cannot start until its outcome is resolved.'
            }
        }
        if ($null -ne $previous -and $previous.Status -notin $script:TerminalStates) {
            Write-Host 'An update run is already active:'
            Show-Status
            return
        }
        $upgradeRequested = Get-Windows11UpgradeChoice $platform $Windows11Upgrade
        $control = Enter-RunLock $script:ControlLockName
        Remove-TaskSafely
        Remove-TaskSafely $script:MonitorTaskName
        if (Test-Path -LiteralPath $script:ResultReadPath) { Remove-Item -LiteralPath $script:ResultReadPath -Force }
        if (Test-Path -LiteralPath $script:NotificationPath) { Remove-Item -LiteralPath $script:NotificationPath -Force }
        if (Test-Path -LiteralPath $script:StopPath) { Remove-Item -LiteralPath $script:StopPath -Force }
        if ([IO.Path]::GetFullPath($PSCommandPath) -ne [IO.Path]::GetFullPath($script:WorkerPath)) {
            Copy-Item -LiteralPath $PSCommandPath -Destination $script:WorkerPath -Force
        }
        $state = [pscustomobject]@{
            Version=5; RunId=[Guid]::NewGuid().ToString('N'); Status='Running'
            Phase='Queued'; Message='Queued for installation'; UpdatedUtc=''
            StartedUtc=[DateTime]::UtcNow.ToString('o'); Scans=0; EmptyScans=0
            Reboots=0; RebootBootId=''; RebootRequestedUtc=''; ConsecutiveErrors=0; LastError=''
            MaxReboots=$MaxReboots; MaxAttempts=$MaxAttempts
            IncludeDrivers=([bool]$IncludeDrivers -and -not $ExcludeDrivers)
            IncludeOptional=([bool]$IncludeOptional -and -not $ExcludeOptional)
            OperationTimeoutMinutes=$OperationTimeoutMinutes; RebootDelaySeconds=$RebootDelaySeconds
            RebootCommitted=$false; ActiveOperation=''; OperationBootId=''; ProgressPercent=-1
            MonitorEnabled=(-not $NoMonitor); ParentCreated=$parentCreated; CleanupError=''
            OperationStartedUtc=''; OperationProcessId=0
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
        Initialize-MemoryLog $state.RunId
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
    } catch {
        if ($null -ne $state) {
            $state.Status = 'Blocked'
            Set-Phase $state 'Blocked' ('Startup failed: ' + $_.Exception.Message)
            Remove-RunArtifacts $state
        }
        throw
    } finally {
        Exit-RunLock $control
        Exit-RunLock $startupLock
    }
    Start-ScheduledTask -TaskName $script:TaskName
    Write-Host 'DaScript Windows Update started. No activity logs are saved to disk; history is available only in the monitor.'
    if ($monitorArguments) {
        Start-Process -FilePath $psExe -ArgumentList $monitorArguments -WindowStyle Hidden | Out-Null
    }
}

function Show-Status {
    $state = Get-State
    if ($null -eq $state) {
        Write-Host 'No DaScript Windows Update run found.'
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
        Log='Memory only (monitor)'; CleanupError=$state.CleanupError
    } | Format-List | Out-Host
}

function Invoke-Stop {
    Assert-Administrator
    $control = Enter-RunLock $script:ControlLockName
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
    } finally { Exit-RunLock $control }
    # Wake an idle worker; the task and mutex prevent concurrent execution.
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
    if ($State.Status -notin @('Completed', 'CompletedWithExclusions') -or $State.ActiveOperation) { return }
    $control = Enter-RunLock $script:ControlLockName
    try {
        $current = Get-State
        if ($null -eq $current -or $current.RunId -ne $State.RunId -or $current.Status -notin @('Completed', 'CompletedWithExclusions')) { return }
        $marker = [IO.File]::Open($script:NotificationPath, 'CreateNew', 'Write', 'None')
        $marker.Dispose()
    } catch [IO.IOException] { return }
    finally { Exit-RunLock $control }
    # Sound belongs to the interactive session and depends on its audio settings.
    try { Play-CompletionSound }
    catch { Write-Warning ('Completion sound unavailable: ' + $_.Exception.Message) }
}

function Get-MonitorLogoGeometry {
    # Exact path from the supplied SVG, compressed only to keep the single-file payload compact.
    $encoded = @'
H4sIAAAAAAAACpS9x7Etya4kqkoqUGbJiQJ/1nqUBDVo6b85qAMRa7/Xg7vvqZUsKIjDgfj/1mX5
P/d2L9u3/7f9+8/23/Hv+d8/27/bf/8c/3f5P/d6LPu6/bfrpe2/7d8dl4///jnw0z87bjruZV9P
fX7HNXle/vOf7f8u/+d6rmXfLnnBcO17l32Lj/+z02t2vVW+OD553+eyb1s8eei/Tr3LH+/tQYOv
Z1/27fvP3h8tWZd9X+VX/p5/7rrkso6CNwyDdN3vsu/2efkyde+9l32//tuzF/IE3vX2EZO2vbj0
4NL534nJkFHTcV5lqKSvpw3VZOSkFfL0ZU/nGLb/bCOcrZTJv3Zpu/VL/1g3aRRkLZThksa+hzx8
oCX/u0dkWo4YR1uMfOOOJsrQorv+b1+nB32oPWV9j9ufddmPq4xfrG0fBxmC413246YbbYxjon0Q
ZSFcuNtuvOzumBbu/RkPyzzaoviW/dx9qcSv27KfNih1ae5xz/nKPaf2ZD6b14sXSVf4Jhr9a9kv
Wz97kQKyR7MNutxsKHSt287L9Z9ra7be6m5832W/sEXk7TKvZV9e27Jf/HWeCP8a9yhH9JE341od
fxMNsZRkYdsz57Lfaw4THipraKfdeNruOHW/+RbJVuZuvGg3yvrPV2Yf/Ool4xItCdHms8LtF1F4
SFuyBdkqkRY+X2gk/nHGK2btObEsuSn3d8naOboQaLti/qUmkXkwcxfEGPg+uk8dvJsEeGzi7Los
2/uuox2bOnbSL0nwQHDcIm55xnS1NMVTRch6L/stIpzHoMoR+ddJYmf7/UxVOCKA8kGIofuLZ3Za
D7ylYvyOZX9EUaArl62n+172x7p69W0aW9n23LrsTxtVNg5EuqWAeo/s+SkLBt/6um62sb14TeD2
6zzkHX67CHLdentbrz608pVjX/bPbtbvH786dH7L/pmQ0S0dYsAl3PPWzWz6Vdojv129HTJJxdJQ
ZY37ZN+8z7K/r/ebJEOVBz/VcbF1vmu2xmK4/XJKCV5AeB7zET9sbYJcWNgGP//95/rvplf5fA0y
S3b4bh1GO8s4kt4qq4A/4gPB0jxNBFGXPtyykI9j2d1e9Z1qW6PrSNt8TWjcx7ccaygSG04WKrtf
p4U17NHQM/uz7N8DlX/2OUjlJOOzHsux8vZtO/fA9dgIE9P1PLPltr+7fIxWvcuxxlzIXdFLfde3
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
5y9e/I8CAA==
'@
    $inputStream = [IO.MemoryStream]::new([Convert]::FromBase64String($encoded))
    $zip = [IO.Compression.GZipStream]::new($inputStream, [IO.Compression.CompressionMode]::Decompress)
    $reader = [IO.StreamReader]::new($zip, [Text.Encoding]::UTF8)
    try {
        $geometry = [Windows.Media.Geometry]::Parse($reader.ReadToEnd())
        $geometry.Freeze()
        return $geometry
    } finally { $reader.Dispose(); $zip.Dispose(); $inputStream.Dispose() }
}

function Update-MonitorFrame {
    param([Windows.FrameworkElement]$Surface)
    $width = $Surface.ActualWidth
    $height = $Surface.ActualHeight
    if ($width -lt 24 -or $height -lt 24) { return }
    # Chamfer the attached panels without clipping the ghost or fullscreen intro.
    $geometry = [Windows.Media.StreamGeometry]::new()
    $context = $geometry.Open()
    try {
        $context.BeginFigure([Windows.Point]::new(12, 0), $true, $true)
        $points = [Windows.Point[]]@(
            [Windows.Point]::new($width-12, 0)
            [Windows.Point]::new($width, 12)
            [Windows.Point]::new($width, $height*0.3)
            [Windows.Point]::new($width-6, $height*0.3+6)
            [Windows.Point]::new($width-6, $height*0.7-6)
            [Windows.Point]::new($width, $height*0.7)
            [Windows.Point]::new($width, $height-12)
            [Windows.Point]::new($width-12, $height)
            [Windows.Point]::new(12, $height)
            [Windows.Point]::new(0, $height-12)
            [Windows.Point]::new(0, $height*0.7)
            [Windows.Point]::new(6, $height*0.7-6)
            [Windows.Point]::new(6, $height*0.3+6)
            [Windows.Point]::new(0, $height*0.3)
            [Windows.Point]::new(0, 12)
        )
        $context.PolyLineTo($points, $true, $false)
    } finally { $context.Dispose() }
    $geometry.Freeze()
    $Surface.Clip = $geometry
}

function New-MonitorWindow {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        throw 'The WPF monitor requires STA. Run powershell.exe -STA -File WindowsUpdate.ps1 -Action Monitor.'
    }
    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:shell="clr-namespace:System.Windows.Shell;assembly=PresentationFramework"
        Title="Update" Width="760" SizeToContent="Height" MinWidth="640" MinHeight="480"
        WindowStyle="None" AllowsTransparency="True" ResizeMode="CanMinimize" WindowStartupLocation="CenterScreen"
        Background="Transparent" Foreground="#E5C56C" FontFamily="Consolas" FontSize="13"
        UseLayoutRounding="True" SnapsToDevicePixels="True" TextOptions.TextFormattingMode="Display">
  <shell:WindowChrome.WindowChrome>
    <shell:WindowChrome CaptionHeight="0" ResizeBorderThickness="0" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
  </shell:WindowChrome.WindowChrome>
  <Window.Resources>
    <RadialGradientBrush x:Key="DimBackdrop" Center="0.5,0.5" GradientOrigin="0.5,0.5" RadiusX="0.5" RadiusY="0.5">
      <GradientStop Color="#66000000" Offset="0"/>
      <GradientStop Color="#99000000" Offset="0.5"/>
      <GradientStop Color="#EB000000" Offset="1"/>
    </RadialGradientBrush>
    <Storyboard x:Key="GhostAttack" Duration="0:0:1.18" FillBehavior="Stop">
      <ObjectAnimationUsingKeyFrames Storyboard.TargetName="IntroLayer" Storyboard.TargetProperty="Visibility">
        <DiscreteObjectKeyFrame KeyTime="0" Value="{x:Static Visibility.Visible}"/>
        <DiscreteObjectKeyFrame KeyTime="0:0:1.18" Value="{x:Static Visibility.Collapsed}"/>
      </ObjectAnimationUsingKeyFrames>
      <DoubleAnimationUsingKeyFrames Storyboard.TargetName="IntroScale" Storyboard.TargetProperty="ScaleX">
        <DiscreteDoubleKeyFrame KeyTime="0" Value="0.015"/>
        <SplineDoubleKeyFrame KeyTime="0:0:0.45" Value="0.55" KeySpline="0.2,0 0.4,1"/>
        <LinearDoubleKeyFrame KeyTime="0:0:0.65" Value="0.6"/>
        <SplineDoubleKeyFrame KeyTime="0:0:0.71" Value="1.8" KeySpline="0.1,0 0.25,0.9"/>
        <LinearDoubleKeyFrame KeyTime="0:0:0.79" Value="1.98"/>
        <SplineDoubleKeyFrame KeyTime="0:0:1.01" Value="8" KeySpline="0.33,0.03 0.65,0.6"/>
      </DoubleAnimationUsingKeyFrames>
      <DoubleAnimationUsingKeyFrames Storyboard.TargetName="IntroScale" Storyboard.TargetProperty="ScaleY">
        <DiscreteDoubleKeyFrame KeyTime="0" Value="0.015"/>
        <SplineDoubleKeyFrame KeyTime="0:0:0.45" Value="0.55" KeySpline="0.2,0 0.4,1"/>
        <LinearDoubleKeyFrame KeyTime="0:0:0.65" Value="0.6"/>
        <SplineDoubleKeyFrame KeyTime="0:0:0.71" Value="1.8" KeySpline="0.1,0 0.25,0.9"/>
        <LinearDoubleKeyFrame KeyTime="0:0:0.79" Value="1.98"/>
        <SplineDoubleKeyFrame KeyTime="0:0:1.01" Value="8" KeySpline="0.33,0.03 0.65,0.6"/>
      </DoubleAnimationUsingKeyFrames>
      <DoubleAnimationUsingKeyFrames Storyboard.TargetName="IntroFocus" Storyboard.TargetProperty="Y">
        <DiscreteDoubleKeyFrame KeyTime="0" Value="0"/>
        <DiscreteDoubleKeyFrame KeyTime="0:0:0.79" Value="0"/>
        <SplineDoubleKeyFrame KeyTime="0:0:1.01" Value="472" KeySpline="0.33,0.03 0.65,0.6"/>
      </DoubleAnimationUsingKeyFrames>
      <DoubleAnimationUsingKeyFrames Storyboard.TargetName="IntroGhost" Storyboard.TargetProperty="Opacity">
        <DiscreteDoubleKeyFrame KeyTime="0" Value="1"/>
        <DiscreteDoubleKeyFrame KeyTime="0:0:1.05" Value="0"/>
      </DoubleAnimationUsingKeyFrames>
      <DoubleAnimationUsingKeyFrames Storyboard.TargetName="WindowSurface" Storyboard.TargetProperty="Opacity">
        <DiscreteDoubleKeyFrame KeyTime="0" Value="0"/>
        <DiscreteDoubleKeyFrame KeyTime="0:0:1.05" Value="1"/>
      </DoubleAnimationUsingKeyFrames>
      <DoubleAnimationUsingKeyFrames Storyboard.TargetName="DimLayer" Storyboard.TargetProperty="Opacity">
        <DiscreteDoubleKeyFrame KeyTime="0" Value="1"/>
        <DiscreteDoubleKeyFrame KeyTime="0:0:1.05" Value="0"/>
      </DoubleAnimationUsingKeyFrames>
      <DoubleAnimationUsingKeyFrames Storyboard.TargetName="Impact" Storyboard.TargetProperty="Opacity">
        <DiscreteDoubleKeyFrame KeyTime="0" Value="0"/>
        <DiscreteDoubleKeyFrame KeyTime="0:0:1.01" Value="0"/>
        <LinearDoubleKeyFrame KeyTime="0:0:1.03" Value="1"/>
        <DiscreteDoubleKeyFrame KeyTime="0:0:1.09" Value="1"/>
        <LinearDoubleKeyFrame KeyTime="0:0:1.18" Value="0"/>
      </DoubleAnimationUsingKeyFrames>
    </Storyboard>
    <Storyboard x:Key="TerminalAmbient">
      <DoubleAnimation Storyboard.TargetName="TextureOffset" Storyboard.TargetProperty="Y" From="0" To="4" Duration="0:0:0.8" RepeatBehavior="Forever"/>
      <DoubleAnimation Storyboard.TargetName="ScanOffset" Storyboard.TargetProperty="Y" From="-0.2" To="1.2" Duration="0:0:6" RepeatBehavior="Forever"/>
      <DoubleAnimation Storyboard.TargetName="LogoPath" Storyboard.TargetProperty="Opacity" From="0.6" To="0.78" Duration="0:0:2.4" AutoReverse="True" RepeatBehavior="Forever"/>
    </Storyboard>
    <SolidColorBrush x:Key="SceneSurface" Color="#111827"/>
    <RadialGradientBrush x:Key="TextShade" RadiusX="0.5" RadiusY="0.5">
      <GradientStop Color="#F0000000" Offset="0"/>
      <GradientStop Color="#D9000000" Offset="0.55"/>
      <GradientStop Color="#80000000" Offset="0.78"/>
      <GradientStop Color="#00000000" Offset="1"/>
    </RadialGradientBrush>
    <DropShadowEffect x:Key="LetterContrast" Color="Black" ShadowDepth="0" BlurRadius="3" Opacity="0.9"/>
    <SolidColorBrush x:Key="Ink" Color="#E5C56C"/>
    <SolidColorBrush x:Key="Muted" Color="#B0A074"/>
    <SolidColorBrush x:Key="Accent" Color="#F0CD67"/>
    <SolidColorBrush x:Key="Rule" Color="#6E5C2A"/>
    <SolidColorBrush x:Key="Warning" Color="#FFE28A"/>
    <SolidColorBrush x:Key="Error" Color="#FF9987"/>
    <SolidColorBrush x:Key="Success" Color="#B7D3A2"/>
    <DrawingBrush x:Key="Hatch" TileMode="Tile" Viewport="0,0,8,8" ViewportUnits="Absolute" Viewbox="0,0,8,8" ViewboxUnits="Absolute">
      <DrawingBrush.Drawing><GeometryDrawing Brush="#A78A37" Geometry="M 0,0 L 3,0 8,5 8,8 Z M 0,5 L 3,8 0,8 Z"/></DrawingBrush.Drawing>
    </DrawingBrush>
    <Style x:Key="Technical" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/><Setter Property="Foreground" Value="{StaticResource Muted}"/>
    </Style>
    <Style TargetType="Expander">
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Expander">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <ToggleButton x:Name="HeaderToggle" IsChecked="{Binding IsExpanded, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}"
                        Content="{TemplateBinding Header}" HorizontalAlignment="Center" Foreground="{TemplateBinding Foreground}" Cursor="Hand"
                        FocusVisualStyle="{x:Null}"
                        AutomationProperties.Name="{Binding Header, RelativeSource={RelativeSource TemplatedParent}}">
            <ToggleButton.Template><ControlTemplate TargetType="ToggleButton">
              <!-- Nonzero alpha keeps native layered-window hit testing inside the header padding. -->
              <Border x:Name="FocusFrame" BorderThickness="1" BorderBrush="#01000000" Background="#01000000" Padding="12,5">
                <StackPanel Orientation="Horizontal"><TextBlock x:Name="Mark" Text="[+] "/><ContentPresenter/></StackPanel>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property="IsChecked" Value="True"><Setter TargetName="Mark" Property="Text" Value="[-] "/></Trigger>
                <Trigger Property="IsKeyboardFocused" Value="True"><Setter Property="Foreground" Value="{StaticResource Accent}"/></Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate></ToggleButton.Template>
          </ToggleButton>
          <ContentPresenter x:Name="Details" Grid.Row="1" Visibility="Collapsed"/>
        </Grid>
        <ControlTemplate.Triggers><Trigger Property="IsExpanded" Value="True"><Setter TargetName="Details" Property="Visibility" Value="Visible"/></Trigger></ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Background" Value="Transparent"/><Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Rule}"/><Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Padding" Value="3,2"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Frame" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Frame" Property="Opacity" Value="0.88"/><Setter Property="Foreground" Value="#EED483"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Frame" Property="Opacity" Value="0.7"/><Setter Property="Foreground" Value="#FFF0B6"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter Property="Opacity" Value="0.7"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/><Setter Property="Cursor" Value="Arrow"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <SolidColorBrush x:Key="IconInk" Color="#FFF1BC"/>
    <Geometry x:Key="InstalledIcon">F1 M10,1 H12 V2 H10 Z M9,2 H12 V3 H9 Z M8,3 H11 V4 H8 Z M0,4 H2 V5 H0 Z M7,4 H10 V5 H7 Z M0,5 H3 V6 H0 Z M6,5 H9 V6 H6 Z M1,6 H4 V7 H1 Z M5,6 H8 V7 H5 Z M2,7 H7 V8 H2 Z M3,8 H6 V9 H3 Z M4,9 H5 V10 H4 Z</Geometry>
    <Geometry x:Key="FailureIcon">F1 M5,0 H7 V1 H5 Z M4,1 H8 V2 H4 Z M3,2 H5 V3 H3 Z M7,2 H9 V3 H7 Z M3,3 H5 V4 H3 Z M7,3 H9 V4 H7 Z M2,4 H4 V5 H2 Z M8,4 H10 V5 H8 Z M2,5 H4 V6 H2 Z M5,5 H7 V6 H5 Z M8,5 H10 V6 H8 Z M1,6 H3 V7 H1 Z M5,6 H7 V7 H5 Z M9,6 H11 V7 H9 Z M1,7 H3 V8 H1 Z M5,7 H7 V8 H5 Z M9,7 H11 V8 H9 Z M0,8 H2 V9 H0 Z M10,8 H12 V9 H10 Z M0,9 H2 V10 H0 Z M5,9 H7 V10 H5 Z M10,9 H12 V10 H10 Z M0,10 H12 V11 H0 Z M0,11 H12 V12 H0 Z</Geometry>
    <Geometry x:Key="SkippedIcon">F1 M3,0 H9 V1 H3 Z M2,1 H10 V2 H2 Z M1,2 H3 V3 H1 Z M8,2 H11 V3 H8 Z M0,3 H2 V4 H0 Z M7,3 H12 V4 H7 Z M0,4 H2 V5 H0 Z M6,4 H9 V5 H6 Z M10,4 H12 V5 H10 Z M0,5 H2 V6 H0 Z M5,5 H8 V6 H5 Z M10,5 H12 V6 H10 Z M0,6 H2 V7 H0 Z M4,6 H7 V7 H4 Z M10,6 H12 V7 H10 Z M0,7 H2 V8 H0 Z M3,7 H6 V8 H3 Z M10,7 H12 V8 H10 Z M0,8 H5 V9 H0 Z M10,8 H12 V9 H10 Z M1,9 H4 V10 H1 Z M9,9 H11 V10 H9 Z M2,10 H10 V11 H2 Z M3,11 H9 V12 H3 Z</Geometry>
    <Geometry x:Key="RebootIcon">F1 M3,0 H8 V1 H3 Z M2,1 H9 V2 H2 Z M1,2 H3 V3 H1 Z M7,2 H9 V3 H7 Z M0,3 H2 V4 H0 Z M8,3 H10 V4 H8 Z M0,4 H2 V5 H0 Z M8,4 H10 V5 H8 Z M0,5 H2 V6 H0 Z M6,5 H12 V6 H6 Z M0,6 H2 V7 H0 Z M7,6 H11 V7 H7 Z M0,7 H2 V8 H0 Z M8,7 H10 V8 H8 Z M0,8 H2 V9 H0 Z M1,9 H3 V10 H1 Z M10,9 H12 V10 H10 Z M2,10 H11 V11 H2 Z M3,11 H10 V12 H3 Z</Geometry>
    <Geometry x:Key="MinimizeIcon">F1 M1,8 H11 V9 H1 Z M1,9 H11 V10 H1 Z</Geometry>
    <Geometry x:Key="StopIcon">F1 M2,2 H10 V3 H2 Z M2,3 H10 V4 H2 Z M2,4 H10 V5 H2 Z M2,5 H10 V6 H2 Z M2,6 H10 V7 H2 Z M2,7 H10 V8 H2 Z M2,8 H10 V9 H2 Z M2,9 H10 V10 H2 Z</Geometry>
    <Geometry x:Key="LogIcon">F1 M1,1 H11 V2 H1 Z M1,2 H11 V3 H1 Z M1,5 H11 V6 H1 Z M1,6 H11 V7 H1 Z M1,9 H11 V10 H1 Z M1,10 H11 V11 H1 Z</Geometry>
    <Geometry x:Key="CloseIcon">F1 M0,0 H2 V1 H0 Z M10,0 H12 V1 H10 Z M0,1 H3 V2 H0 Z M9,1 H12 V2 H9 Z M1,2 H4 V3 H1 Z M8,2 H11 V3 H8 Z M2,3 H5 V4 H2 Z M7,3 H10 V4 H7 Z M3,4 H9 V5 H3 Z M4,5 H8 V6 H4 Z M4,6 H8 V7 H4 Z M3,7 H9 V8 H3 Z M2,8 H5 V9 H2 Z M7,8 H10 V9 H7 Z M1,9 H4 V10 H1 Z M8,9 H11 V10 H8 Z M0,10 H3 V11 H0 Z M9,10 H12 V11 H9 Z M0,11 H2 V12 H0 Z M10,11 H12 V12 H10 Z</Geometry>
    <Style x:Key="PixelIcon" TargetType="ContentControl">
      <Setter Property="Width" Value="34"/><Setter Property="Height" Value="34"/>
      <Setter Property="Foreground" Value="{StaticResource IconInk}"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ContentControl">
        <Viewbox Stretch="Uniform"><Grid Width="12" Height="12">
          <Path Data="{TemplateBinding Content}" Fill="#090C14" Stroke="#090C14" StrokeThickness="1.2" StrokeLineJoin="Miter"/>
          <Path Data="{TemplateBinding Content}" Fill="{TemplateBinding Foreground}"/>
        </Grid></Viewbox>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="IconButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Width" Value="32"/><Setter Property="Height" Value="28"/>
      <Setter Property="Foreground" Value="{StaticResource IconInk}"/>
      <Setter Property="AutomationProperties.Name" Value="{Binding Content, RelativeSource={RelativeSource Self}}"/>
      <Setter Property="ContentTemplate"><Setter.Value><DataTemplate>
        <Grid>
          <AccessText Text="{Binding}" Opacity="0" Width="0" Height="0"/>
          <ContentControl Content="{Binding Tag, RelativeSource={RelativeSource AncestorType=Button}}"
                          Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"
                          Style="{StaticResource PixelIcon}" Width="20" Height="20"/>
        </Grid>
      </DataTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="#15170F"/><Setter Property="Width" Value="12"/>
      <Setter Property="Template">
        <Setter.Value><ControlTemplate TargetType="ScrollBar">
          <Grid Background="{TemplateBinding Background}">
            <Track x:Name="PART_Track" IsDirectionReversed="True" Orientation="{TemplateBinding Orientation}">
              <Track.DecreaseRepeatButton><RepeatButton x:Name="PageBefore" Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/></Track.DecreaseRepeatButton>
              <Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="#8D783B" Margin="2"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
              <Track.IncreaseRepeatButton><RepeatButton x:Name="PageAfter" Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/></Track.IncreaseRepeatButton>
            </Track>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="Orientation" Value="Horizontal">
              <Setter TargetName="PART_Track" Property="IsDirectionReversed" Value="False"/>
              <Setter TargetName="PageBefore" Property="Command" Value="ScrollBar.PageLeftCommand"/>
              <Setter TargetName="PageAfter" Property="Command" Value="ScrollBar.PageRightCommand"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value>
      </Setter>
      <Style.Triggers><Trigger Property="Orientation" Value="Horizontal"><Setter Property="Height" Value="12"/><Setter Property="Width" Value="Auto"/></Trigger></Style.Triggers>
    </Style>
    <Style TargetType="ProgressBar">
      <Setter Property="Foreground" Value="{StaticResource Accent}"/><Setter Property="Background" Value="#292817"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ProgressBar">
        <Grid ClipToBounds="True">
          <Border x:Name="PART_Track" Background="{TemplateBinding Background}"/>
          <Border x:Name="PART_Indicator" HorizontalAlignment="Left" Background="{TemplateBinding Foreground}"/>
          <Rectangle IsHitTestVisible="False"><Rectangle.Fill>
            <DrawingBrush TileMode="Tile" Viewport="0,0,7,12" ViewportUnits="Absolute" Viewbox="0,0,7,12" ViewboxUnits="Absolute">
              <DrawingBrush.Drawing><GeometryDrawing Brush="#090B09" Geometry="M 5,0 L 7,0 7,12 5,12 Z"/></DrawingBrush.Drawing>
            </DrawingBrush>
          </Rectangle.Fill></Rectangle>
        </Grid>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
  </Window.Resources>
  <Grid ClipToBounds="True">
  <Border x:Name="DimLayer" Background="{StaticResource DimBackdrop}" Visibility="Collapsed" IsHitTestVisible="False"/>
  <Border x:Name="WindowSurface" Background="Transparent">
    <ScrollViewer x:Name="ShellScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <Grid x:Name="Scene">
        <Grid.RowDefinitions><RowDefinition x:Name="ChromeRow" Height="0"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <Viewbox x:Name="GhostView" Grid.Row="1" Height="500" Stretch="Uniform" HorizontalAlignment="Center">
          <Grid Width="700" Height="572">
            <Path x:Name="GhostBackplate" Fill="{DynamicResource SceneSurface}" Stretch="Fill" ToolTip="Trascina lo spettro per spostare la finestra"/>
            <Grid x:Name="AmbientField" IsHitTestVisible="False">
              <Grid x:Name="LogoHost">
                <Path x:Name="LogoPath" Fill="{StaticResource Accent}" Opacity="0.72" Stretch="Fill" AutomationProperties.Name="Spettro DaScript">
                  <Path.CacheMode><BitmapCache/></Path.CacheMode>
                </Path>
              </Grid>
            </Grid>
            <StackPanel x:Name="ChromeControls" Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Top" Margin="0,36,0,0" Background="{DynamicResource SceneSurface}">
              <Button x:Name="MinimizeButton" Content="Riduci a icona" Style="{StaticResource IconButton}" Tag="{StaticResource MinimizeIcon}" ToolTip="Riduci a icona"/>
        <WrapPanel x:Name="FooterActions" Margin="0" VerticalAlignment="Center" HorizontalAlignment="Center">
          <Button x:Name="StopButton" Style="{StaticResource IconButton}" Tag="{StaticResource StopIcon}" Content="_STOP" IsEnabled="False" ToolTip="Alt+S: cooperative stop; the current installation may finish before updates stop."/>
          <Button x:Name="ResultLogButton" Style="{StaticResource IconButton}" Tag="{StaticResource LogIcon}" ToolTip="{Binding Content, RelativeSource={RelativeSource Self}}" Content="Visualizza _log" Visibility="Collapsed" Margin="0"/>
          <Button x:Name="CloseButton" Style="{StaticResource IconButton}" Tag="{StaticResource CloseIcon}" Content="_Chiudi" ToolTip="Alt+C: chiude la finestra; il lavoro attivo continua in background."/>
        </WrapPanel>
            </StackPanel>
            <Ellipse x:Name="UpdateShade" Width="430" Height="240" Opacity="0.35" HorizontalAlignment="Center" VerticalAlignment="Top" Margin="0,205,0,0" Fill="{StaticResource TextShade}" IsHitTestVisible="False"/>
            <Grid Width="384" Height="190" HorizontalAlignment="Center" VerticalAlignment="Top" Margin="0,238,0,0">
              <Border x:Name="UpdateCard" Background="Transparent" Padding="8,10">
                <Grid>
                  <StackPanel x:Name="OperationalView">

                    <ContentControl x:Name="UpdateProgressText" Margin="0,0,0,4" Focusable="False" Effect="{StaticResource LetterContrast}"
                                    AutomationProperties.Name="{Binding Content, RelativeSource={RelativeSource Self}}">
                      <ContentControl.Template><ControlTemplate TargetType="ContentControl">
                        <Viewbox Height="64" Stretch="Uniform">
                          <Path Data="{TemplateBinding Tag}" Fill="{StaticResource Ink}"/>
                        </Viewbox>
                      </ControlTemplate></ContentControl.Template>
                    </ContentControl>


            <Grid Height="7" Width="320" HorizontalAlignment="Center" Margin="0,16,0,10">
              <ProgressBar x:Name="Progress" Minimum="0" Maximum="100" AutomationProperties.Name="WUA batch progress"/>
            </Grid>

                    <WrapPanel HorizontalAlignment="Center" Margin="0,10,0,6" TextElement.FontSize="18" TextElement.FontWeight="Bold" TextElement.Foreground="{StaticResource IconInk}" Effect="{StaticResource LetterContrast}">
              <WrapPanel.Resources><Style TargetType="TextBlock"><Setter Property="VerticalAlignment" Value="Center"/></Style></WrapPanel.Resources>
              <StackPanel Orientation="Horizontal" Margin="0,0,16,0">
                <ContentControl Content="{StaticResource InstalledIcon}" Style="{StaticResource PixelIcon}" Margin="0,0,8,0" ToolTip="Installati" AutomationProperties.Name="Installati"/>
                <TextBlock x:Name="InstalledCount" ToolTip="Installati" Text="--" Foreground="{StaticResource IconInk}"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" Margin="0,0,16,0">
                <ContentControl Content="{StaticResource FailureIcon}" Style="{StaticResource PixelIcon}" Foreground="{Binding Foreground, ElementName=FailureCount}" Margin="0,0,8,0" ToolTip="Errori" AutomationProperties.Name="Errori"/>
                <TextBlock x:Name="FailureCount" ToolTip="Errori" Text="--" Foreground="{StaticResource IconInk}"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" Margin="0,0,16,0">
                <ContentControl Content="{StaticResource SkippedIcon}" Style="{StaticResource PixelIcon}" Margin="0,0,8,0" ToolTip="Esclusi" AutomationProperties.Name="Esclusi"/>
                <TextBlock x:Name="SkippedCount" ToolTip="Esclusi" Text="--" Foreground="{StaticResource IconInk}"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal">
                <ContentControl Content="{StaticResource RebootIcon}" Style="{StaticResource PixelIcon}" Margin="0,0,8,0" ToolTip="Riavvii" AutomationProperties.Name="Riavvii"/>
                <TextBlock x:Name="RebootCount" ToolTip="Riavvii" Text="--" Foreground="{StaticResource IconInk}"/>
              </StackPanel>
            </WrapPanel>
                  </StackPanel>
                  <ScrollViewer x:Name="OutcomeView"  Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel Margin="6" VerticalAlignment="Center">
          <Path x:Name="OutcomeGhost" Data="{Binding Data, ElementName=LogoPath}" Fill="#9DE6ED" Visibility="Collapsed" Height="160" Stretch="Uniform" RenderTransformOrigin="0.5,0.5" Margin="0,0,0,24">
            <Path.CacheMode><BitmapCache RenderAtScale="2"/></Path.CacheMode>
          </Path>
          <StackPanel x:Name="OutcomeMessage" Effect="{StaticResource LetterContrast}">
            <Viewbox Stretch="Uniform" Height="38" Margin="0,0,0,10">
              <Path x:Name="OutcomeTitle" Fill="#9DE6ED"/>
            </Viewbox>
            <TextBlock x:Name="OutcomeDescription" TextAlignment="Center" TextWrapping="Wrap" FontSize="15" Foreground="#EDF1FA"/>
            <TextBlock x:Name="OutcomeCounts" TextAlignment="Center" TextWrapping="Wrap" FontSize="12" Foreground="#B8C3D9" Margin="0,6,0,0"/>
            <TextBox x:Name="OutcomeDetail" Visibility="Collapsed" IsReadOnly="True" TextWrapping="Wrap" MaxHeight="76" VerticalScrollBarVisibility="Auto" Margin="0,12,0,0"
                     Background="Transparent" Foreground="#CED5E5" BorderThickness="0" FontSize="12" AutomationProperties.Name="Dettaglio dell'esito"/>
          </StackPanel>
        </StackPanel>
      </ScrollViewer>
                </Grid>
              </Border>
              <Rectangle x:Name="TerminalTexture" IsHitTestVisible="False" Opacity="0.045" OpacityMask="{StaticResource TextShade}">
        <Rectangle.RenderTransform><TranslateTransform x:Name="TextureOffset"/></Rectangle.RenderTransform>
        <Rectangle.Fill>
        <DrawingBrush TileMode="Tile" Viewport="0,0,4,4" ViewportUnits="Absolute" Viewbox="0,0,4,4" ViewboxUnits="Absolute">
          <DrawingBrush.Drawing><GeometryDrawing Brush="#BDA04B" Geometry="M 0,0 L 4,0 4,1 0,1 Z"/></DrawingBrush.Drawing>
        </DrawingBrush>
      </Rectangle.Fill></Rectangle>
              <Rectangle x:Name="TerminalSweep" Visibility="Collapsed" IsHitTestVisible="False" OpacityMask="{StaticResource TextShade}"><Rectangle.Fill>
          <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#00E5C56C" Offset="0"/><GradientStop Color="#10E5C56C" Offset="0.04"/><GradientStop Color="#00E5C56C" Offset="0.12"/>
            <LinearGradientBrush.RelativeTransform><TranslateTransform x:Name="ScanOffset" Y="-0.2"/></LinearGradientBrush.RelativeTransform>
          </LinearGradientBrush>
        </Rectangle.Fill></Rectangle>
            </Grid>
          </Grid>
        </Viewbox>
        <StackPanel Grid.Row="2" Width="600" HorizontalAlignment="Center">
          <Border Width="2" Height="10" Background="{StaticResource Rule}"/>
          <Expander x:Name="ActivityLog" Header="ACTIVITY" IsExpanded="True" Foreground="{StaticResource Muted}" FontSize="14" ToolTip="Latest 60 lines">
            <Grid>
              <Border x:Name="ActivityPanel" Background="{DynamicResource SceneSurface}" Padding="16,10"><Grid x:Name="TerminalField" ClipToBounds="True" Height="140" Margin="0">
            <TextBox x:Name="LogText" MinHeight="110" Background="Transparent" Foreground="#D9C58D" BorderThickness="0" Padding="0"
                   FontSize="12" IsReadOnly="True" AcceptsReturn="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto"
                   HorizontalScrollBarVisibility="Auto" AutomationProperties.Name="Activity log and summary" SelectionBrush="#8D783B"/>
          </Grid></Border>
              <Path Data="{Binding Clip, ElementName=ActivityPanel}" Stroke="{StaticResource Rule}" StrokeThickness="1" IsHitTestVisible="False"/>

            </Grid>
          </Expander>
          <Border Width="2" Height="6" Background="{StaticResource Rule}"/>
          <Expander x:Name="Diagnostics" Header="DIAGNOSTICS" IsExpanded="False" Foreground="{StaticResource Muted}" FontSize="14">
            <Grid>
              <Border x:Name="DiagnosticsPanel" Background="{DynamicResource SceneSurface}" Padding="16,10">
                <ScrollViewer MaxHeight="190" VerticalScrollBarVisibility="Auto">
                  <StackPanel>
                    <WrapPanel  HorizontalAlignment="Center" TextElement.FontSize="10" Margin="0,2,0,4">
            <TextBlock Text="&gt; " Foreground="{StaticResource Muted}"/>
            <TextBlock x:Name="PhaseText" Text="WAITING" FontWeight="Bold"/>
            <TextBlock Text=" [" Foreground="{StaticResource Muted}"/>
            <TextBlock x:Name="StatusText" Text="READING STATUS"/>
            <TextBlock Text="]" Foreground="{StaticResource Muted}"/>
</WrapPanel>
            <TextBlock x:Name="CurrentUpdateText" Text="UPDATE --" TextWrapping="Wrap" TextAlignment="Center" MaxHeight="30" FontSize="11" TextTrimming="CharacterEllipsis"/>
            <WrapPanel HorizontalAlignment="Center" Margin="0,6,0,0">
              <TextBlock Text="WUA BATCH " Style="{StaticResource Technical}"/>
              <TextBlock x:Name="ProgressText" Text="--" FontWeight="Bold"/>
              <TextBlock Text="  "/>
              <TextBlock x:Name="ProgressCaption" Text="UNAVAILABLE" Style="{StaticResource Technical}"/>
            </WrapPanel>
        <ScrollViewer MaxHeight="50" VerticalScrollBarVisibility="Auto">
          <TextBlock x:Name="NoticeText" Text="Closing this window does not stop updates." Foreground="{StaticResource Muted}" TextWrapping="Wrap" TextAlignment="Center" FontSize="11"/>
        </ScrollViewer>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Center"><Border x:Name="Activity" Background="{StaticResource Accent}" Width="5" Height="5" Margin="0,0,6,0" Visibility="Collapsed" ToolTip="Visual pulse only; see worker and WUA timestamps."/> <TextBlock x:Name="WorkerText" Text="WORKER --" Style="{StaticResource Technical}"/></StackPanel>
                                <TextBlock x:Name="TimingText" Style="{StaticResource Technical}" TextWrapping="Wrap" TextAlignment="Center"/>
            <TextBlock x:Name="WuaResponseText" Style="{StaticResource Technical}" TextWrapping="Wrap" TextAlignment="Center"/>
            <TextBlock x:Name="DownloadText" Style="{StaticResource Technical}" TextWrapping="Wrap" TextAlignment="Center" Visibility="Collapsed"/>
            <TextBlock x:Name="PhaseDetail" Style="{StaticResource Technical}" TextWrapping="Wrap" TextAlignment="Center"/>

                    <ScrollViewer  MaxHeight="60" VerticalScrollBarVisibility="Auto" Margin="0,2,0,3">
            <TextBlock x:Name="DetailText" Text="Reading status..." TextWrapping="Wrap" TextAlignment="Center"/>
          </ScrollViewer>
                    <Border Height="1" Background="{StaticResource Rule}" Margin="0,8"/>
                    <TextBox x:Name="DiagnosticsText" IsReadOnly="True" TextWrapping="Wrap" MaxHeight="80" VerticalScrollBarVisibility="Auto"
                       Background="Transparent" Foreground="{StaticResource Muted}" BorderThickness="0" SelectionBrush="#8D783B"/>
                  </StackPanel>
                </ScrollViewer>
              </Border>
              <Path Data="{Binding Clip, ElementName=DiagnosticsPanel}" Stroke="{StaticResource Rule}" StrokeThickness="1" IsHitTestVisible="False"/>
            </Grid>
          </Expander>
          <StackPanel x:Name="PreviewControls" Visibility="Collapsed" Margin="0,0,0,8" Background="{DynamicResource SceneSurface}">
        <TextBlock Text="DaScript / ANTEPRIMA UI / Dati dimostrativi, nessun aggiornamento o riavvio" TextWrapping="Wrap" TextAlignment="Center" FontSize="11" Margin="0,0,0,6"/>
        <WrapPanel HorizontalAlignment="Center">
          <Button x:Name="PreviewPrevious" Content="&lt; Precedente" Margin="0,0,10,0"/>
          <ComboBox x:Name="PreviewSelector" Width="245" Foreground="#111827" AutomationProperties.Name="Schermata di anteprima"/>
          <Button x:Name="PreviewNext" Content="Successiva &gt;" Margin="10,0,10,0"/>
          <Button x:Name="PreviewIntro" Content="Rivedi intro"/>
        </WrapPanel>
      </StackPanel>
        </StackPanel>
      </Grid>
    </ScrollViewer>
  </Border>
      <Grid x:Name="IntroLayer" Background="Transparent" Visibility="Collapsed" IsHitTestVisible="False" ClipToBounds="True">
        <Path x:Name="IntroGhost" Data="{Binding Data, ElementName=LogoPath}" Fill="#F1EDFF" Width="600" Height="492" Stretch="Uniform"
              HorizontalAlignment="Center" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.42">
          <Path.CacheMode><BitmapCache RenderAtScale="4"/></Path.CacheMode>
          <Path.RenderTransform><TransformGroup><ScaleTransform x:Name="IntroScale"/><TranslateTransform x:Name="IntroFocus"/></TransformGroup></Path.RenderTransform>
        </Path>
        <Border x:Name="Impact" Background="Black" Opacity="0"/>
      </Grid>
  </Grid>

</Window>
'@
    $reader = [Xml.XmlNodeReader]::new($xaml)
    try { $window = [Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Dispose() }
    $area = [Windows.SystemParameters]::WorkArea
    $window.MinWidth = [Math]::Min($window.MinWidth, $area.Width)
    $window.MinHeight = [Math]::Min($window.MinHeight, $area.Height)
    $window.Width = [Math]::Min($window.Width, $area.Width)
    $window.MaxHeight = $area.Height
    $window.FindName('GhostView').Height = [Math]::Min(500, [Math]::Max(300, $area.Height-120))
    foreach ($name in @('ActivityPanel','DiagnosticsPanel')) {
        $window.FindName($name).add_SizeChanged({ param($sender, $eventArgs)
            Update-MonitorFrame $sender
        })
    }
    $window.FindName('GhostBackplate').add_MouseLeftButtonDown({ param($sender, $eventArgs)
        if ($eventArgs.LeftButton -eq 'Pressed') {
            [Windows.Window]::GetWindow($sender).DragMove()
            $eventArgs.Handled = $true
        }
    })
    foreach ($name in @('ActivityLog','Diagnostics')) {
        $resize = { param($sender, $eventArgs)
            $target = [Windows.Window]::GetWindow($sender)
            if ($target.IsLoaded -and $null -eq $target.Tag.WindowPlacement -and $target.WindowState -eq 'Normal') {
                $target.SizeToContent = 'Height'
                $target.UpdateLayout()
                $area = [Windows.SystemParameters]::WorkArea
                if ($target.Top -ge $area.Top -and $target.Top -lt $area.Bottom) {
                    $target.Top = [Math]::Max($area.Top, [Math]::Min($target.Top, $area.Bottom-$target.ActualHeight))
                }
            }
        }
        $window.FindName($name).add_Expanded($resize)
        $window.FindName($name).add_Collapsed($resize)
    }
    $window.FindName('MinimizeButton').add_Click({ param($sender, $eventArgs)
        [Windows.SystemCommands]::MinimizeWindow([Windows.Window]::GetWindow($sender))
    })
    $geometry = Get-MonitorLogoGeometry
    $window.FindName('LogoPath').Data = $geometry
    # The largest closed figure is the outer silhouette; smaller figures are the distressed cutouts.
    $outline = $null
    $largestArea = 0.0
    foreach ($figure in [Windows.Media.PathGeometry]::CreateFromGeometry($geometry).Figures) {
        if (-not $figure.IsClosed) { continue }
        $candidate = [Windows.Media.PathGeometry]::new()
        $candidate.Figures.Add($figure)
        $area = $candidate.GetArea()
        if ($area -gt $largestArea) { $largestArea = $area; $outline = $candidate }
    }
    if ($null -eq $outline) { throw 'The embedded ghost has no closed silhouette.' }
    $outline.Freeze()
    $window.FindName('GhostBackplate').Data = $outline
    $drawing = [Windows.Media.GeometryDrawing]::new([Windows.Media.BrushConverter]::new().ConvertFromString('#F1EDFF'), $null, $geometry)
    $window.Icon = [Windows.Media.DrawingImage]::new($drawing)
    $window.Icon.Freeze()
    $window.Tag = [pscustomobject]@{
        Outcome=''; ShowLog=$false; Motion=$true; Intro=$false; Storyboard=$null; Pulse=$false; Ambient=$false
        AlternateColor=[Windows.Media.Colors]::White
        WindowPlacement=$null; Closing=$false; ChangingPlacement=$false
        SceneBackground=$window.Resources['SceneSurface'].Clone()
    }
    $window.FindName('LogoHost').Tag = [pscustomobject]@{ Index=0L; Random=[Random]::new() }
    $window.FindName('LogText').Tag = [pscustomobject]@{ Target=''; Lines=@(); Visible=0 }
    Set-MonitorUpdateTitle $window 'UPDATE --'
    $window.FindName('ResultLogButton').add_Click({ param($sender, $eventArgs)
        $target = [Windows.Window]::GetWindow($sender)
        Stop-MonitorTransition $target
        $target.Tag.ShowLog = -not $target.Tag.ShowLog
        if ($target.Tag.ShowLog) { $target.FindName('ActivityLog').IsExpanded = $true }
        Set-MonitorScene $target
    })
    $window.add_Loaded({ param($sender, $eventArgs)
        if (-not $sender.Tag.Intro) {
            $sender.Tag.Intro = $true
            Start-MonitorTransition $sender 'GhostAttack'
        }
        Set-MonitorOutcomePulse $sender
        Set-MonitorAmbientAnimation $sender
    })
    $window.add_StateChanged({ param($sender, $eventArgs)
        if (-not $sender.Tag.ChangingPlacement -and
            ($sender.WindowState -eq 'Minimized' -or ($null -eq $sender.Tag.Storyboard -and $null -ne $sender.Tag.WindowPlacement))) {
            Stop-MonitorTransition $sender
        }
        Set-MonitorOutcomePulse $sender
        Set-MonitorAmbientAnimation $sender
    })
    $window.add_PreviewKeyDown({ param($sender, $eventArgs)
        if ($eventArgs.Key -eq 'Escape' -and $null -ne $sender.Tag.WindowPlacement) {
            Stop-MonitorTransition $sender
            Set-MonitorOutcomePulse $sender
            Set-MonitorAmbientAnimation $sender
            $eventArgs.Handled = $true
        }
    })
    $window.add_Closed({ param($sender, $eventArgs)
        Set-MonitorOutcomePulse $sender -Stop
        Set-MonitorAmbientAnimation $sender -Stop
        $sender.Tag.Closing = $true
        Stop-MonitorTransition $sender
    })
    foreach ($name in @('GhostAttack')) {
        $animation = $window.Resources[$name]
        $target = $window
        $stopTransition = ${function:Stop-MonitorTransition}
        $syncPulse = ${function:Set-MonitorOutcomePulse}
        $syncAmbient = ${function:Set-MonitorAmbientAnimation}
        $animation.add_Completed({
            if ($target.Tag.Storyboard -eq $animation) { & $stopTransition $target; & $syncPulse $target; & $syncAmbient $target }
        }.GetNewClosure())
    }
    return $window
}

function Stop-MonitorTransition {
    param([object]$Window)
    if ($null -ne $Window.Tag.Storyboard) {
        $Window.Tag.Storyboard.Remove($Window)
        $Window.Tag.Storyboard = $null
    }
    $placement = $Window.Tag.WindowPlacement
    # While minimized, retain the placement until restore without reactivating the window.
    if ($Window.WindowState -eq 'Minimized' -and -not $Window.Tag.Closing) { return }
    $Window.Tag.WindowPlacement = $null
    if ($null -eq $placement -or $Window.Tag.Closing) { return }
    $Window.Tag.ChangingPlacement = $true
    try {
        # Restore normal bounds before reapplying the original state.
        $Window.WindowState = 'Normal'
        $Window.ResizeMode = $placement.ResizeMode
        [Windows.Shell.WindowChrome]::SetWindowChrome($Window, $placement.Chrome)
        $Window.Left = $placement.Bounds.Left
        $Window.Top = $placement.Bounds.Top
        $Window.Width = $placement.Bounds.Width
        $Window.Height = $placement.Bounds.Height
        $Window.FindName('ChromeRow').Height = [Windows.GridLength]::new(0)
        $Window.FindName('ChromeControls').Visibility = 'Visible'
        $Window.FindName('Scene').IsHitTestVisible = $true
        $Window.FindName('OutcomeGhost').Height = 160
        $surface = $Window.FindName('WindowSurface')
        $surface.Width = [double]::NaN
        $surface.Height = [double]::NaN
        $surface.Margin = [Windows.Thickness]::new(0)
        $surface.HorizontalAlignment = 'Stretch'
        $surface.VerticalAlignment = 'Stretch'
        $surface.IsHitTestVisible = $true
        $surface.Background = [Windows.Media.Brushes]::Transparent
        $Window.FindName('DimLayer').Visibility = 'Collapsed'
        $Window.FindName('TerminalTexture').Visibility = 'Visible'
        $Window.FindName('AmbientField').Visibility = 'Visible'
        $Window.MaxHeight = $placement.MaxHeight
        $Window.SizeToContent = $placement.SizeToContent
        $Window.WindowState = $placement.State
    } finally { $Window.Tag.ChangingPlacement = $false }
}

function Start-MonitorTransition {
    param([object]$Window, [string]$Name)
    if ($Name -ne 'GhostAttack') { return }
    Stop-MonitorTransition $Window
    Set-MonitorOutcomePulse $Window -Stop
    Set-MonitorAmbientAnimation $Window -Stop
    try {
        if (-not $Window.Tag.Motion -or -not $Window.IsLoaded -or $Window.WindowState -eq 'Minimized' -or
            -not [Windows.SystemParameters]::ClientAreaAnimation -or [Windows.SystemParameters]::HighContrast -or
            ([Windows.Media.RenderCapability]::Tier -shr 16) -eq 0) { return }
        $Window.Tag.WindowPlacement = [pscustomobject]@{
            Bounds=$Window.RestoreBounds; State=$Window.WindowState; ResizeMode=$Window.ResizeMode
            Chrome=[Windows.Shell.WindowChrome]::GetWindowChrome($Window); Name=$Name
            SizeToContent=$Window.SizeToContent; MaxHeight=$Window.MaxHeight
        }
        $appOrigin = $Window.PointToScreen([Windows.Point]::new(0,0))
        $appSize = [Windows.Size]::new($Window.ActualWidth, $Window.ActualHeight)
        $Window.Tag.ChangingPlacement = $true
        # Native borderless maximization covers the current monitor, including its taskbar, in WPF units.
        [Windows.Shell.WindowChrome]::SetWindowChrome($Window, $null)
        # Removing WindowChrome resets the native target to SystemColors.WindowColor.
        [Windows.PresentationSource]::FromVisual($Window).CompositionTarget.BackgroundColor = [Windows.Media.Colors]::Transparent
        $Window.SizeToContent = 'Manual'
        $Window.MaxHeight = [double]::PositiveInfinity
        $Window.ResizeMode = 'NoResize'
        $Window.FindName('ChromeControls').Visibility = 'Collapsed'
        $Window.FindName('ChromeRow').Height = [Windows.GridLength]::new(0)
        $Window.FindName('Scene').IsHitTestVisible = $false
        # Per-pixel alpha dims the live desktop without fading the ghost or capturing the screen.
        $surface = $Window.FindName('WindowSurface')
        $surface.IsHitTestVisible = $false
        $surface.Background = [Windows.Media.Brushes]::Transparent
        $Window.FindName('DimLayer').Visibility = 'Visible'
        $Window.FindName('AmbientField').Visibility = 'Collapsed'
        $Window.FindName('TerminalTexture').Visibility = 'Collapsed'
        $Window.WindowState = 'Normal'
        $Window.WindowState = 'Maximized'
        $Window.UpdateLayout()
        if ($Name -eq 'GhostAttack') {
            # Reveal the app at its original desktop position behind the fullscreen ghost.
            $origin = $Window.PointFromScreen($appOrigin)
            $surface.HorizontalAlignment = 'Left'
            $surface.VerticalAlignment = 'Top'
            $surface.Width = $appSize.Width
            $surface.Height = $appSize.Height
            $surface.Margin = [Windows.Thickness]::new($origin.X, $origin.Y, 0, 0)
            $surface.Background = [Windows.Media.Brushes]::Transparent
            $Window.FindName('ChromeControls').Visibility = 'Visible'
            $Window.FindName('ChromeRow').Height = [Windows.GridLength]::new(0)
            $Window.FindName('TerminalTexture').Visibility = 'Visible'
            $Window.FindName('AmbientField').Visibility = 'Visible'
            $scale = 2.4 * [Math]::Max($Window.ActualWidth/600, $Window.ActualHeight/492)
            $readableScale = 0.85 * [Math]::Min($Window.ActualWidth/600, $Window.ActualHeight/492)
            foreach ($timeline in $Window.Resources[$Name].Children) {
                if ([Windows.Media.Animation.Storyboard]::GetTargetName($timeline) -eq 'IntroScale') {
                    $timeline.KeyFrames[3].Value = $readableScale
                    $timeline.KeyFrames[4].Value = $readableScale * 1.1
                    $timeline.KeyFrames[5].Value = $scale
                } elseif ([Windows.Media.Animation.Storyboard]::GetTargetName($timeline) -eq 'IntroFocus') {
                    # Keep the face near the screen center during the final close-up.
                    $timeline.KeyFrames[2].Value = 492 * (0.08 + 0.11*$scale)
                }
            }
        }
        $Window.Tag.Storyboard = $Window.Resources[$Name]
        $Window.Tag.Storyboard.Begin($Window, $true)
    } catch {
        # Base values are the usable static scene; failed effects must never hide a result.
        Stop-MonitorTransition $Window
        $Window.Tag.Motion = $false
    } finally { $Window.Tag.ChangingPlacement = $false }
}

function Get-MonitorOutcome {
    param([object]$State)
    # Presentation of worker decisions only. Never query WUA or infer completion from progress.
    $kind = ''
    switch ($State.Status) {
        'Completed' { $kind = if (@($State.Installed).Count) { 'Completed' } else { 'NoUpdates' } }
        'CompletedWithExclusions' { $kind = 'Partial' }
        'CompletedWithErrors' { $kind = if (@($State.Installed).Count) { 'Partial' } else { 'Error' } }
        'Blocked' { $kind = 'Error' }
        'Stopped' { $kind = 'Stopped' }
        'WaitingForReboot' { $kind = 'Reboot' }
    }
    if (-not $kind) { return $null }
    # Even a blocked run may still have a native operation in flight; keep telemetry visible.
    if ($State.ActiveOperation) { return $null }
    if ($State.RebootCommitted -and $kind -ne 'Error') { $kind = 'Reboot' }
    $titles = @{ NoUpdates='GIRO A VUOTO'; Completed='COMPLETATO'; Partial='PARZIALE'; Error='ERRORE'; Reboot='RIAVVIO RICHIESTO'; Stopped='INTERROTTO' }
    $descriptions = @{
        NoUpdates='Nessun aggiornamento trovato.'
        Completed='Aggiornamenti installati correttamente.'
        Partial='Alcuni aggiornamenti non sono stati installati.'
        Error='Operazione non riuscita. Dettagli nel log.'
        Reboot='Riavvio necessario per proseguire.'
        Stopped='Arresto richiesto dall''operatore.'
    }
    $colors = @{ NoUpdates='#A5BDD8'; Completed='#AFA4F5'; Partial='#F0CD67'; Error='#FF9987'; Reboot='#FFB16C'; Stopped='#B8C3D9' }
    $alternates = @{ NoUpdates='#30243F'; Completed='#153A37'; Partial='#402639'; Error='#40331D'; Reboot='#2F2543'; Stopped='#18383D' }
    $backgrounds = @{ NoUpdates='#182536'; Completed='#241D3B'; Partial='#30291E'; Error='#371F2B'; Reboot='#33241F'; Stopped='#202735' }
    return [pscustomobject]@{ Kind=$kind; Title=$titles[$kind]; Description=$descriptions[$kind]; Color=$colors[$kind]; AlternateColor=$alternates[$kind]; Background=$backgrounds[$kind] }
}

function Get-MonitorPixelTitle {
    param([string]$Text, [switch]$Distressed)
    # Small native vector alphabet: no font download, bitmap scaling or ASCII line wrapping.
    $glyphs = @{
        A='01110/10001/10001/11111/10001/10001/10001'; C='01111/10000/10000/10000/10000/10000/01111'
        D='11110/10001/10001/10001/10001/10001/11110'; E='11111/10000/10000/11110/10000/10000/11111'
        G='01110/10001/10000/10111/10001/10001/01110'
        H='10001/10001/10001/11111/10001/10001/10001'; I='111/010/010/010/010/010/111'
        L='10000/10000/10000/10000/10000/10000/11111'; M='10001/11011/10101/10101/10001/10001/10001'
        N='10001/11001/11001/10101/10011/10011/10001'; O='01110/10001/10001/10001/10001/10001/01110'
        P='11110/10001/10001/11110/10000/10000/10000'; Q='01110/10001/10001/10001/10101/10010/01101'
        R='11110/10001/10001/11110/10100/10010/10001'; S='01111/10000/10000/01110/00001/00001/11110'
        T='11111/00100/00100/00100/00100/00100/00100'; U='10001/10001/10001/10001/10001/10001/01110'
        V='10001/10001/10001/10001/10001/01010/00100'; Z='11111/00001/00010/00100/01000/10000/11111'
        '0'='01110/10001/10011/10101/11001/10001/01110'; '1'='00100/01100/00100/00100/00100/00100/01110'
        '2'='01110/10001/00001/00010/00100/01000/11111'; '3'='11110/00001/00001/01110/00001/00001/11110'
        '4'='00010/00110/01010/10010/11111/00010/00010'; '5'='11111/10000/10000/11110/00001/00001/11110'
        '6'='01110/10000/10000/11110/10001/10001/01110'; '7'='11111/00001/00010/00100/01000/01000/01000'
        '8'='01110/10001/10001/01110/10001/10001/01110'; '9'='01110/10001/10001/01111/00001/00001/01110'
        '%'='11001/11001/00010/00100/01000/10011/10011'; '-'='000/000/000/111/000/000/000'
    }
    $geometry = [Windows.Media.GeometryGroup]::new()
    $x = 0
    foreach ($letter in $Text.ToCharArray()) {
        if ($letter -eq ' ') { $x += 12; continue }
        $rows = $glyphs[[string]$letter] -split '/'
        for ($y=0; $y -lt 7; $y++) {
            for ($column=0; $column -lt $rows[$y].Length; $column++) {
                if ($rows[$y][$column] -eq '1') {
                    $geometry.Children.Add([Windows.Media.RectangleGeometry]::new([Windows.Rect]::new($x+$column*4, $y*4, 4, 4)))
                    if ($Distressed -and (($x/4 + $column*3 + $y*5) % 11) -eq 0) {
                        # EvenOdd fill cuts small, stable chips out of lit pixels.
                        $geometry.Children.Add([Windows.Media.RectangleGeometry]::new([Windows.Rect]::new($x+$column*4+2, $y*4, 2, 1)))
                    }
                }
            }
        }
        $x += ($rows[0].Length+1)*4
    }
    $geometry.Freeze()
    return $geometry
}

function Set-MonitorUpdateTitle {
    param([object]$Window, [string]$Text)
    $title = $Window.FindName('UpdateProgressText')
    if ($title.Content -ceq $Text) { return }
    $title.Tag = Get-MonitorPixelTitle $Text -Distressed
    $title.Content = $Text
}

function Set-MonitorAmbientAnimation {
    param([object]$Window, [switch]$Stop)
    $enabled = -not $Stop -and -not $Window.Tag.Outcome -and -not $Window.Tag.ShowLog -and
        $Window.IsLoaded -and -not $Window.Tag.Closing -and $Window.WindowState -ne 'Minimized' -and
        $null -eq $Window.Tag.Storyboard -and $null -eq $Window.Tag.WindowPlacement -and
        $Window.Tag.Motion -and [Windows.SystemParameters]::ClientAreaAnimation -and
        -not [Windows.SystemParameters]::HighContrast -and ([Windows.Media.RenderCapability]::Tier -shr 16) -gt 0
    if ([bool]$enabled -eq $Window.Tag.Ambient) { return }
    # Native clocks animate decoration only, independently of WUA progress and log content.
    if ($enabled) { $Window.Resources['TerminalAmbient'].Begin($Window, $true) }
    else { $Window.Resources['TerminalAmbient'].Remove($Window) }
    $Window.FindName('TerminalSweep').Visibility = $(if ($enabled) { 'Visible' } else { 'Collapsed' })
    $Window.Tag.Ambient = [bool]$enabled
}

function Set-MonitorOutcomePulse {
    param([object]$Window, [switch]$Stop)
    $enabled = -not $Stop -and $Window.Tag.Outcome -and -not $Window.Tag.ShowLog -and
        $Window.IsLoaded -and -not $Window.Tag.Closing -and $Window.WindowState -ne 'Minimized' -and
        $null -eq $Window.Tag.Storyboard -and $null -eq $Window.Tag.WindowPlacement -and
        $Window.Tag.Motion -and [Windows.SystemParameters]::ClientAreaAnimation -and
        -not [Windows.SystemParameters]::HighContrast -and ([Windows.Media.RenderCapability]::Tier -shr 16) -gt 0
    if ([bool]$enabled -eq $Window.Tag.Pulse) { return }
    $brush = $Window.Tag.SceneBackground
    if ($enabled) {
        # Alternate the result background only; logo, text and controls remain steady.
        $animation = [Windows.Media.Animation.ColorAnimationUsingKeyFrames]::new()
        $animation.Duration = [Windows.Duration]::new([TimeSpan]::FromSeconds(1.6))
        $animation.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        [void]$animation.KeyFrames.Add([Windows.Media.Animation.DiscreteColorKeyFrame]::new($brush.Color, [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::Zero)))
        [void]$animation.KeyFrames.Add([Windows.Media.Animation.DiscreteColorKeyFrame]::new($Window.Tag.AlternateColor, [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromSeconds(0.8))))
        $brush.BeginAnimation([Windows.Media.SolidColorBrush]::ColorProperty, $animation)
    } else { $brush.BeginAnimation([Windows.Media.SolidColorBrush]::ColorProperty, $null) }
    $Window.Tag.Pulse = [bool]$enabled
}

function Set-MonitorScene {
    param([object]$Window)
    $result = [bool]$Window.Tag.Outcome
    $showResult = $result -and -not $Window.Tag.ShowLog
    $Window.FindName('OperationalView').Visibility = $(if ($showResult) { 'Collapsed' } else { 'Visible' })
    $Window.FindName('OutcomeView').Visibility = $(if ($showResult) { 'Visible' } else { 'Collapsed' })
    $Window.FindName('AmbientField').Visibility = 'Visible'
    # Resource lookup may freeze brushes; keep the animated brush on the controls themselves.
    $Window.FindName('GhostBackplate').Fill = $Window.Tag.SceneBackground
    foreach ($name in @('ActivityPanel','DiagnosticsPanel','ChromeControls')) {
        $Window.FindName($name).Background = $Window.Tag.SceneBackground
    }
    $Window.FindName('LogoPath').Fill = $(if ($result) { $Window.FindName('OutcomeTitle').Fill } else { $Window.Resources['Accent'] })
    $Window.FindName('ResultLogButton').Visibility = $(if ($result) { 'Visible' } else { 'Collapsed' })
    $Window.FindName('ResultLogButton').Content = $(if ($Window.Tag.ShowLog) { 'Torna all''_esito' } else { 'Visualizza _log' })
    $Window.FindName('StopButton').Visibility = $(if ($result -and $Window.Tag.Outcome -ne 'Reboot') { 'Collapsed' } else { 'Visible' })
    $Window.FindName('NoticeText').Visibility = $(if ($showResult) { 'Collapsed' } else { 'Visible' })
    $ink = if ($result) { [Windows.Media.SolidColorBrush]::new($Window.FindName('OutcomeTitle').Fill.GetAnimationBaseValue([Windows.Media.SolidColorBrush]::ColorProperty)) } else { $Window.Resources['IconInk'] }
    foreach ($control in $Window.FindName('FooterActions').Children) {
        if ($control -is [Windows.Controls.Button]) { $control.Foreground = $ink }
    }
    Set-MonitorOutcomePulse $Window
    Set-MonitorAmbientAnimation $Window
}

function Update-MonitorOutcome {
    param([object]$Window, [object]$Snapshot)
    $state = $Snapshot.State
    $outcome = Get-MonitorOutcome $state
    $kind = if ($null -eq $outcome) { '' } else { $outcome.Kind }
    $changed = $Window.Tag.Outcome -ne $kind
    if ($changed) {
        Set-MonitorOutcomePulse $Window -Stop
        $Window.Tag.Outcome = $kind
        $Window.Tag.ShowLog = $false
    }
    if ($null -ne $outcome) {
        if ($changed) {
            $Window.FindName('OutcomeTitle').Data = Get-MonitorPixelTitle $outcome.Title
            [Windows.Automation.AutomationProperties]::SetName($Window.FindName('OutcomeTitle'), $outcome.Title)
            $brush = [Windows.Media.BrushConverter]::new().ConvertFromString($outcome.Color)
            $Window.FindName('OutcomeTitle').Fill = $brush
            $Window.FindName('OutcomeGhost').Fill = $brush
            $Window.Tag.AlternateColor = [Windows.Media.ColorConverter]::ConvertFromString($outcome.AlternateColor)
            $Window.Tag.SceneBackground = [Windows.Media.BrushConverter]::new().ConvertFromString($outcome.Background)
        }
        $description = $outcome.Description
        if ($kind -eq 'Reboot') {
            if ($state.RebootCommitted) { $description += ' Riavvio già confermato: non annullabile dalla finestra.' }
            elseif ($Snapshot.StopRequested) { $description += ' Arresto richiesto, in attesa del worker.' }
            elseif ($state.Phase -eq 'RestartCountdown' -and $state.Message -match '^Restart in (\d+) seconds\.') {
                $description += " Ultimo countdown comunicato: $($Matches[1]) s. Salvare il lavoro."
            }
        }
        if ($state.CleanupError) { $description += ' Pulizia incompleta: consultare il dettaglio.' }
        if ($kind -eq 'Error' -and $state.RebootCommitted) { $description += ' Esito del riavvio non confermato.' }
        $Window.FindName('OutcomeDescription').Text = $description
        $counts = @()
        if (@($state.Installed).Count) { $counts += 'Installati: ' + @($state.Installed).Count }
        $errors = @($state.Failures | Where-Object { -not $_.Resolved }).Count
        if ($errors) { $counts += 'Errori: ' + $errors }
        if (@($state.Skipped).Count) { $counts += 'Esclusi: ' + @($state.Skipped).Count }
        $Window.FindName('OutcomeCounts').Text = $counts -join '  /  '
        $Window.FindName('OutcomeCounts').Visibility = $(if ($counts.Count) { 'Visible' } else { 'Collapsed' })
        $detail = [string]$state.Message
        if ($state.CleanupError) { $detail += "`r`nPulizia incompleta: $($state.CleanupError)" }
        $Window.FindName('OutcomeDetail').Text = $detail
    } elseif ($changed) { $Window.Tag.SceneBackground = [Windows.Media.BrushConverter]::new().ConvertFromString('#111827') }
    Set-MonitorScene $Window

}

function Update-MonitorAnimation {
    param([object]$Window)
    Set-MonitorOutcomePulse $Window
    Set-MonitorAmbientAnimation $Window
    Update-MonitorLog $Window -Immediate:($Window.WindowState -eq 'Minimized' -or -not $Window.Tag.Motion)
    if ($Window.WindowState -ne 'Minimized') {
        $Window.FindName('LogoHost').Tag.Index++
        if ($null -ne $Window.FindName('Activity').Tag) {
            Update-MonitorTelemetry $Window $Window.FindName('Activity').Tag
        }
    }
}

function Update-MonitorLog {
    param([object]$Window, [string]$Text, [switch]$AcceptSnapshot, [switch]$Immediate)
    $log = $Window.FindName('LogText')
    $buffer = $log.Tag
    if ($AcceptSnapshot -and $Text -cne $buffer.Target) {
        $lines = @([regex]::Split($Text, '\r?\n'))
        if (-not $Text) { $lines = @() }
        # Preserve the visible overlap when the worker's rolling 60-line tail advances.
        $overlap = [Math]::Min($buffer.Lines.Count, $lines.Count)
        while ($overlap -gt 0) {
            $oldTail = $buffer.Lines[($buffer.Lines.Count-$overlap)..($buffer.Lines.Count-1)] -join "`r`n"
            $newHead = $lines[0..($overlap-1)] -join "`r`n"
            if ($oldTail -ceq $newHead) { break }
            $overlap--
        }
        $buffer.Visible = [Math]::Max(0, $buffer.Visible - ($buffer.Lines.Count-$overlap))
        $buffer.Target = $Text
        $buffer.Lines = $lines
    }
    if ($Immediate) {
        $buffer.Visible = $buffer.Lines.Count
    } elseif ($buffer.Visible -lt $buffer.Lines.Count) {
        $remaining = $buffer.Lines.Count - $buffer.Visible
        $step = if ($remaining -gt 15) { 4 } else { $Window.FindName('LogoHost').Tag.Random.Next(1,3) }
        $buffer.Visible = [Math]::Min($buffer.Lines.Count, $buffer.Visible+$step)
    }
    $shown = if ($buffer.Visible) { $buffer.Lines[0..($buffer.Visible-1)] -join "`r`n" } else { '' }
    if ($log.Text -cne $shown) {
        $follow = $log.VerticalOffset -ge ($log.ExtentHeight - $log.ViewportHeight - 2)
        $offset = $log.VerticalOffset
        if ($shown.StartsWith($log.Text, [StringComparison]::Ordinal)) { $log.AppendText($shown.Substring($log.Text.Length)) }
        else { $log.Text = $shown }
        if ($follow) { $log.ScrollToEnd() } else { $log.ScrollToVerticalOffset($offset) }
    }
}

function Format-MonitorDuration {
    param($Seconds)
    if ($null -eq $Seconds) { return '--' }
    $span = [TimeSpan]::FromSeconds($Seconds)
    return ('{0:00}:{1:00}:{2:00}' -f [Math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds)
}

function Update-MonitorTitle {
    param([object]$Window, [object]$Snapshot)
    $state = $Snapshot.State
    $labels = @{
        Queued='In attesa'; Scan='Ricerca'; Download='Download'; Install='Installazione'
        Verify='Verifica'; Resume='Ripresa'; Retry='Attesa nuovo tentativo'
        RestartCountdown='Riavvio richiesto'; Restart='Riavvio confermato'; WaitingForReboot='Riavvio richiesto'
        Cancelling='Arresto in corso'; OperationStillRunning='Operazione ancora attiva'
        Completed='Completato'; CompletedWithExclusions='Completato con esclusioni'
        CompletedWithErrors='Completato con errori'; Blocked='Bloccato'; Stopped='Interrotto'
    }
    $phase = if ($state.Status -in $script:TerminalStates) { [string]$state.Status } else { [string]$state.Phase }
    $label = if ($labels.ContainsKey($phase)) { $labels[$phase] } else { 'In corso' }
    if ($Snapshot.StopRequested -and $state.Status -notin $script:TerminalStates -and -not $state.RebootCommitted) { $label = 'Arresto richiesto' }
    if ($state.Status -eq 'Completed' -and @($state.Installed).Count -eq 0) { $label = 'Nessun aggiornamento' }
    if ($state.Status -eq 'Blocked' -and $state.ActiveOperation) { $label = 'Bloccato - operazione incerta' }
    $title = 'Update - ' + $label
    # Reuse validated, current telemetry; never infer overall completion from a percentage.
    if ($Window.FindName('ProgressCaption').Text -eq 'CURRENT OPERATION') {
        $title += ' - batch ' + $Window.FindName('ProgressText').Text
    } elseif ($Window.FindName('ProgressCaption').Text -eq 'LAST REPORTED COUNTDOWN') {
        $title += ' - ultimo countdown ' + $Window.FindName('ProgressText').Text
    }
    if ($Window.Title -cne $title) { $Window.Title = $title }
}

function Update-MonitorTelemetry {
    param([object]$Window, [object]$Snapshot, [DateTime]$Now=[DateTime]::UtcNow)
    $state = $Snapshot.State
    $sample = $state.WuaProgress
    $terminal = $state.Status -in $script:TerminalStates
    $active = [bool]$state.ActiveOperation
    $previousBoot = $null -ne $Snapshot.PSObject.Properties['PreviousBoot'] -and $Snapshot.PreviousBoot
    $heartbeatAge = Get-MonitorAgeSeconds $state.UpdatedUtc $Now
    $workerFresh = $null -ne $heartbeatAge -and $heartbeatAge -lt 30 -and -not $previousBoot
    $workerLabel = 'LAST HEARTBEAT'
    if ($active -and -not $previousBoot) {
        $workerLabel = if ($workerFresh) { 'ACTIVE' } else { 'NO RECENT HEARTBEAT' }
    }
    if ($previousBoot) { $workerLabel = 'WAITING FOR RESUME' }
    $Window.FindName('WorkerText').Text = "WORKER $workerLabel // $(Format-MonitorDuration $heartbeatAge)"
    $Window.FindName('WorkerText').Foreground = $Window.Resources[$(if ($active -and -not $workerFresh) { 'Warning' } else { 'Muted' })]
    $Window.FindName('Activity').Visibility = $(if ($active -and $workerFresh -and -not $terminal) { 'Visible' } else { 'Collapsed' })
    $Window.FindName('Progress').Value = 0
    $Window.FindName('ProgressText').Text = '--'
    $Window.FindName('ProgressCaption').Text = 'UNAVAILABLE'
    $updateTitle = 'UPDATE --'
    $Window.FindName('CurrentUpdateText').Text = 'UPDATE --'
    $Window.FindName('CurrentUpdateText').ToolTip = $null
    $Window.FindName('TimingText').Text = 'ELAPSED -- // LAST CHANGE --'
    $Window.FindName('WuaResponseText').Text = 'WUA PROGRESS --'
    $Window.FindName('WuaResponseText').Foreground = $Window.Resources['Muted']
    $Window.FindName('DownloadText').Visibility = 'Collapsed'
    $responseAge = $null
    $changeAge = $null
    $changeLabel = 'LAST CHANGE --'
    $diagnostic = "Worker state / heartbeat UTC: $($state.UpdatedUtc)`r`nOperation: $($state.ActiveOperation) // PID: $($state.OperationProcessId)`r`nOperation start UTC: $($state.OperationStartedUtc)`r`nOperation boot: $($state.OperationBootId)"
    if ($active -and -not $previousBoot) {
        $elapsed = Get-MonitorAgeSeconds $state.OperationStartedUtc $Now
        $response = 'WUA PROGRESS NOT AVAILABLE'
        if ($null -ne $sample) {
            $responseAge = Get-MonitorAgeSeconds $sample.LastResponseUtc $Now
            $changeAge = Get-MonitorAgeSeconds $sample.LastChangeUtc $Now
            $since = if ($sample.LastChangeUtc) { $sample.LastChangeUtc } else { $sample.ObservedUtc }
            $unchangedAge = Get-MonitorAgeSeconds $since $Now
            $changeLabel = if ($sample.LastChangeUtc) { "LAST CHANGE $(Format-MonitorDuration $changeAge) AGO" } else { "UNCHANGED $(Format-MonitorDuration $unchangedAge) // SINCE FIRST SAMPLE" }
            $fresh = $workerFresh -and $null -ne $responseAge -and $responseAge -lt 30 -and -not $sample.ReadError
            $response = if ($fresh) {
                if ($null -ne $unchangedAge -and $unchangedAge -ge 120) { 'NO PROGRESS CHANGE // WINDOWS UPDATE STILL RESPONDING' }
                elseif ($null -ne $changeAge -and $changeAge -lt 30) { 'PROGRESS CHANGED // WUA RESPONDING' }
                elseif (-not $sample.ObservedUtc) { 'WUA RESPONDING // PROGRESS UNAVAILABLE' }
                else { 'WUA RESPONDING // WAITING FOR PROGRESS CHANGE' }
            } else { 'NO RECENT WUA PROGRESS DATA' }
            if ($sample.ReadError) { $response = 'WUA PROGRESS READ FAILED // SEE DIAGNOSTICS' }
            if (-not $fresh) { $Window.FindName('WuaResponseText').Foreground = $Window.Resources['Warning'] }
            $diagnostic += "`r`nWUA last response UTC: $($sample.LastResponseUtc)`r`nFirst usable sample UTC: $($sample.ObservedUtc)`r`nLast observed change UTC: $($sample.LastChangeUtc)`r`nProgress read error: $($sample.ReadError)"
            if ($fresh -and -not $terminal -and $state.Phase -in @('Download','Install')) {
                if ($null -ne $sample.Index -and $sample.Index -ge 0 -and $sample.Index -lt $sample.Count) {
                    $title = if ($sample.Title) { $sample.Title } else { '--' }
                    $Window.FindName('CurrentUpdateText').Text = "UPDATE $($sample.Index+1)/$($sample.Count) // $title"
                    $Window.FindName('CurrentUpdateText').ToolTip = $title
                    $percent = Get-WuaProgressNumber $sample 'UpdatePercent' 100
                    if ($null -ne $percent) { $updateTitle = "UPDATE $percent%" }
                }
                $percent = Get-WuaProgressNumber $state 'ProgressPercent' 100
                if ($null -ne $percent) {
                    $Window.FindName('Progress').Value = $percent
                    $Window.FindName('ProgressText').Text = "$percent%"
                    $Window.FindName('ProgressCaption').Text = 'CURRENT OPERATION'
                }
                if ($state.ActiveOperation -eq 'Download') {
                    $bytes = @{}
                    foreach ($name in @('TotalBytesDownloaded','TotalBytesToDownload','CurrentUpdateBytesDownloaded','CurrentUpdateBytesToDownload')) {
                        $value = Get-WuaProgressNumber $sample $name
                        $bytes[$name] = if ($null -eq $value) { '--' } else { $value.ToString([Globalization.CultureInfo]::InvariantCulture) }
                    }
                    $Window.FindName('DownloadText').Text = "$(Get-DownloadPhaseLabel $sample.DownloadPhase) // BATCH $($bytes.TotalBytesDownloaded) / ~$($bytes.TotalBytesToDownload) bytes"
                    $Window.FindName('DownloadText').Visibility = 'Visible'
                    $diagnostic += "`r`nCurrent update bytes: $($bytes.CurrentUpdateBytesDownloaded) / ~$($bytes.CurrentUpdateBytesToDownload) (estimated total)"
                }
            }
        }
        if ($state.Status -eq 'Blocked') { $response = "BLOCKED // $response" }
        elseif ($state.Phase -eq 'Cancelling') { $response = "CANCELLING // $response" }
        elseif ($Snapshot.StopRequested) { $response = "STOP REQUESTED // $response" }
        $Window.FindName('WuaResponseText').Text = $response
        $Window.FindName('TimingText').Text = "ELAPSED $(Format-MonitorDuration $elapsed) // $changeLabel // WUA REPLY $(Format-MonitorDuration $responseAge) AGO"
    }
    if ($previousBoot) { $Window.FindName('WuaResponseText').Text = 'PREVIOUS BOOT DATA // WAITING FOR WORKER' }
    if ($state.Phase -eq 'RestartCountdown' -and -not $terminal -and $state.Message -match '^Restart in (\d+) seconds\.') {
        $Window.FindName('ProgressText').Text = $Matches[1] + 's'
        $Window.FindName('ProgressCaption').Text = 'LAST REPORTED COUNTDOWN'
    }
    $box = $Window.FindName('DiagnosticsText')
    if ($box.Text -cne $diagnostic) { $box.Text = $diagnostic }
    Set-MonitorUpdateTitle $Window $updateTitle
    Update-MonitorTitle $Window $Snapshot
}

function Update-MonitorView {
    param([object]$Window, [object]$Snapshot)
    $state = $Snapshot.State
    $terminal = $state.Status -in $script:TerminalStates
    $finished = $terminal -and -not $state.ActiveOperation
    $phases = @{
        Queued='QUEUED'; Scan='SCANNING'; Download='DOWNLOAD'; Install='INSTALLATION'
        Verify='VERIFYING'; Resume='RESUMING'; Retry='WAITING TO RETRY'
        RestartCountdown='RESTART PENDING'; Restart='RESTART COMMITTED'
        Cancelling='STOPPING'; OperationStillRunning='OPERATION STILL ACTIVE'
        Completed='COMPLETED'; CompletedWithExclusions='COMPLETED WITH EXCLUSIONS'
        CompletedWithErrors='COMPLETED WITH ERRORS'; Blocked='BLOCKED'; Stopped='STOPPED'
    }
    $phase = [string]$state.Phase
    if ($terminal) { $phase = [string]$state.Status }
    $heading = if ($phases.ContainsKey($phase)) { $phases[$phase] } else { $phase }
    $color = 'Accent'
    $status = 'RUNNING'
    switch ($state.Status) {
        'Completed' { $color='Success'; $status='COMPLETED' }
        'CompletedWithExclusions' { $color='Warning'; $status='WITH EXCLUSIONS' }
        'CompletedWithErrors' { $color='Error'; $status='WITH ERRORS' }
        'Blocked' { $color='Error'; $status='BLOCKED' }
        'Stopped' { $color='Muted'; $status='STOPPED' }
        'WaitingForReboot' { $color='Warning'; $status='RESTART' }
    }
    if ($state.Phase -eq 'Retry' -and -not $terminal) { $color='Warning'; $status='WAITING' }
    $brush = $Window.Resources[$color]
    $Window.FindName('PhaseText').Text = $heading
    $Window.FindName('PhaseText').Foreground = $brush
    $Window.FindName('StatusText').Text = $status
    $Window.FindName('StatusText').Foreground = $brush
    $Window.FindName('DetailText').Text = [string]$state.Message
    $upgradeLabels = @{ NotRequested='Not requested'; Requested='Requested'; Offered='Offered'; Completed='Completed'; NotOffered='Not offered'; NotCompleted='Not completed' }
    $upgrade = [string]$state.Windows11UpgradeStatus
    if ($upgradeLabels.ContainsKey($upgrade)) { $upgrade = $upgradeLabels[$upgrade] }
    $Window.FindName('PhaseDetail').Text = "Scans: $($state.Scans) // Windows 11: $upgrade"
    $failures = @($state.Failures | Where-Object { -not $_.Resolved }).Count
    $Window.FindName('InstalledCount').Text = [string]@($state.Installed).Count
    $Window.FindName('FailureCount').Text = [string]$failures
    $Window.FindName('FailureCount').Foreground = $Window.Resources[$(if ($failures) { 'Error' } else { 'IconInk' })]
    $Window.FindName('SkippedCount').Text = [string]@($state.Skipped).Count
    $Window.FindName('RebootCount').Text = [string]$state.Reboots
    $Window.FindName('Progress').Foreground = $brush
    $Window.FindName('ProgressText').Foreground = $brush
    $Window.FindName('Activity').Tag = $Snapshot
    Update-MonitorTelemetry $Window $Snapshot
    $notice = 'Closing this window does not stop updates.'
    if ($Snapshot.StopRequested) { $notice = 'Stop requested. Waiting for the current operation.' }
    if ($state.RebootCommitted) { $notice = 'Restart committed. Cannot be cancelled from this window.' }
    if ($terminal -and $state.ActiveOperation) { $notice = 'WUA may still be active. Check the log.' }
    if ($finished -and -not $state.RebootCommitted) { $notice = 'Result retained until this window closes.' }
    if ($state.CleanupError) { $notice = 'Cleanup incomplete: ' + $state.CleanupError }
    $updated = '--'
    if ($null -ne (Get-MonitorAgeSeconds $state.UpdatedUtc)) { $updated = [DateTimeOffset]::Parse([string]$state.UpdatedUtc).LocalDateTime.ToString('HH:mm:ss') }
    $Window.FindName('NoticeText').Text = "$notice  Last update: $updated"
    $Window.FindName('NoticeText').Foreground = $Window.Resources[$(if ($state.CleanupError) { 'Error' } else { 'Muted' })]
    $Window.FindName('StopButton').IsEnabled = -not $terminal -and -not $state.RebootCommitted -and -not $Snapshot.StopRequested
    $urgent = $terminal -or $Snapshot.StopRequested -or $state.RebootCommitted -or $state.Phase -eq 'RestartCountdown' -or $failures -gt 0 -or $state.CleanupError -or $Snapshot.Log -match '\[(ERROR|WARN|WARNING)\]'
    Update-MonitorLog $Window -Text $Snapshot.Log -AcceptSnapshot -Immediate:$urgent
    Update-MonitorOutcome $Window $Snapshot
}

function Get-MonitorSnapshot {
    param([string]$RunId, [bool]$RequestStop, [bool]$AcknowledgeFinal)
    $script:MonitorRunId = $RunId
    if ($RequestStop) { Invoke-Stop | Out-Null }
    if (-not $script:MonitorBootId) { $script:MonitorBootId = Get-BootId }
    $control = Enter-RunLock $script:ControlLockName
    try {
        $state = Get-State
        if ($null -eq $state -or $state.RunId -ne $RunId) {
            return [pscustomobject]@{ State=$null; Cleaned=($null -eq $state -and -not (Test-Path -LiteralPath $script:Root)) }
        }
        Initialize-RuntimeState $state
        $previousBoot = $state.ActiveOperation -and $state.OperationBootId -and $state.OperationBootId -ne $script:MonitorBootId
        $finished = $state.Status -in $script:TerminalStates -and -not $state.ActiveOperation
        Initialize-MemoryLog $RunId -ReadOnly
        $text = Read-MemoryLog
        if ($finished) {
            $text += "`r`n`r`nEXCLUSIONS:`r`n" + (($state.Skipped | ForEach-Object { "$($_.Title): $($_.Reason)" }) -join "`r`n")
            $text += "`r`n`r`nOPEN ERRORS:`r`n" + (($state.Failures | Where-Object { -not $_.Resolved } | ForEach-Object { "$($_.Title): $($_.Reason)" }) -join "`r`n")
        }
        Send-CompletionSound $state
        if ($finished -and $AcknowledgeFinal) { [IO.File]::WriteAllText($script:ResultReadPath, $RunId) }
        return [pscustomobject]@{ State=$state; Log=$text; StopRequested=(Test-Path -LiteralPath $script:StopPath); Finished=$finished; PreviousBoot=[bool]$previousBoot }
    } finally { Exit-RunLock $control }
}

function New-MonitorReader {
    # Only monitor I/O and the existing cooperative stop run here; no update worker is loaded.
    $session = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($name in @('Assert-Administrator','Enter-RunLock','Exit-RunLock','Read-JsonState','Get-State',
        'Initialize-Windows11UpgradeState','Initialize-RuntimeState','Invoke-Stop','Get-BootId',
        'Play-CompletionSound','Send-CompletionSound','Get-MonitorSnapshot',
        'Initialize-MemoryLog','Close-MemoryLog','Read-MemoryLog')) {
        $session.Commands.Add([Management.Automation.Runspaces.SessionStateFunctionEntry]::new($name, (Get-Item "Function:$name").Definition))
    }
    foreach ($name in @('Root','StatePath','BackupPath','StopPath','LogNamePrefix','ControlLockName',
        'NotificationPath','ResultReadPath','TerminalStates','TaskName')) {
        $session.Variables.Add([Management.Automation.Runspaces.SessionStateVariableEntry]::new($name, (Get-Variable -Name $name -Scope Script -ValueOnly), ''))
    }
    $session.Variables.Add([Management.Automation.Runspaces.SessionStateVariableEntry]::new('ErrorActionPreference', 'Stop', ''))
    $session.Variables.Add([Management.Automation.Runspaces.SessionStateVariableEntry]::new('MemoryLog', $null, ''))
    $session.Variables.Add([Management.Automation.Runspaces.SessionStateVariableEntry]::new('MemoryLogRunId', '', ''))
    $session.Variables.Add([Management.Automation.Runspaces.SessionStateVariableEntry]::new('MemoryLogError', '', ''))
    $session.Variables.Add([Management.Automation.Runspaces.SessionStateVariableEntry]::new('MonitorBootId', '', ''))
    $reader = [PowerShell]::Create($session)
    return $reader
}

function New-MonitorPreviewSnapshot {
    param([string]$Scene)
    $now = [DateTime]::UtcNow
    $state = [pscustomobject]@{
        Status='Running'; Phase=$Scene; Message='ANTEPRIMA: dati dimostrativi, nessuna operazione sul sistema.'
        UpdatedUtc=$now.ToString('o'); Scans=2; Reboots=0
        Installed=@(); Failures=@(); Skipped=@()
    }
    Initialize-RuntimeState $state
    if ($Scene -in @('Scan','Download','Install','StopPending','Stale','ActiveError')) {
        $state.ActiveOperation = if ($Scene -eq 'Scan') { 'Scan' } elseif ($Scene -eq 'Download') { 'Download' } else { 'Install' }
        $state.Phase = $state.ActiveOperation
        $state.OperationStartedUtc = $now.AddMinutes(-10).ToString('o')
        $state.OperationBootId = 'preview'
        if ($Scene -ne 'Scan') {
            $state.ProgressPercent = 42
            $state.WuaProgress = New-WuaProgress
            $state.WuaProgress.Index = 2
            $state.WuaProgress.Count = 8
            $state.WuaProgress.Title = 'Aggiornamento cumulativo Windows - esempio dimostrativo'
            $state.WuaProgress.UpdatePercent = 21
            $state.WuaProgress.BatchPercent = 42
            $state.WuaProgress.ObservedUtc = $now.AddMinutes(-5).ToString('o')
            $state.WuaProgress.LastResponseUtc = $now.ToString('o')
            $state.WuaProgress.LastChangeUtc = $now.AddMinutes(-3).ToString('o')
            if ($Scene -eq 'Download') {
                $state.WuaProgress.DownloadPhase = 2
                $state.WuaProgress.TotalBytesDownloaded = 420MB
                $state.WuaProgress.TotalBytesToDownload = 1000MB
            }
        }
    }
    switch ($Scene) {
        'Stale' { $state.UpdatedUtc = $now.AddMinutes(-2).ToString('o') }
        'ActiveError' { $state.Status='Blocked'; $state.Phase='OperationStillRunning'; $state.Message='ANTEPRIMA: operazione WUA di esito incerto; verificare il sistema.' }
        'NoUpdates' { $state.Status='Completed'; $state.Phase=$state.Status }
        'Completed' { $state.Status='Completed'; $state.Phase=$state.Status }
        'Partial' { $state.Status='CompletedWithErrors'; $state.Phase=$state.Status }
        'Excluded' { $state.Status='CompletedWithExclusions'; $state.Phase=$state.Status; $state.Skipped=@([pscustomobject]@{Title='Driver dimostrativo'; Reason='Driver excluded by operator'}) }
        'Error' { $state.Status='Blocked'; $state.Phase=$state.Status }
        'Reboot' { $state.Status='WaitingForReboot'; $state.Phase='RestartCountdown'; $state.Message='Restart in 75 seconds. PREVIEW: no restart will occur.' }
        'Committed' { $state.Status='WaitingForReboot'; $state.Phase='Restart'; $state.RebootCommitted=$true }
        'Stopped' { $state.Status='Stopped'; $state.Phase=$state.Status }
    }
    if ($Scene -in @('Completed','Partial','Download','Install','Reboot','Committed','Resume','StopPending')) {
        $state.Installed = @([pscustomobject]@{Title='Aggiornamento dimostrativo installato'})
    }
    if ($Scene -in @('Partial','Error')) {
        $state.Failures = @([pscustomobject]@{Title='Aggiornamento dimostrativo'; Reason='Errore dimostrativo: Result=4; HRESULT=0x80004005'; Resolved=$false})
    }
    $log = "[PREVIEW] Solo dati dimostrativi. Nessuna scansione, installazione o riavvio reale.`r`n[INFO] Scenario: $Scene`r`n[INFO] $($state.Message)"
    foreach ($failure in $state.Failures) { $log += "`r`n[ERROR] $($failure.Title): $($failure.Reason)" }
    foreach ($excluded in $state.Skipped) { $log += "`r`n[INFO] EXCLUDED: $($excluded.Title): $($excluded.Reason)" }
    return [pscustomobject]@{ State=$state; Log=$log; StopRequested=($Scene -eq 'StopPending'); PreviousBoot=$false }
}

function New-MonitorPreviewWindow {
    # Reuse the production view, but never attach its reader, worker or stop command.
    $window = New-MonitorWindow
    $window.FindName('PreviewControls').Visibility = 'Visible'
    $selector = $window.FindName('PreviewSelector')
    $scenes = @(
        @('Queued','In attesa'), @('Scan','Ricerca'), @('Download','Download'), @('Install','Installazione'),
        @('Verify','Verifica'), @('Retry','Attesa nuovo tentativo'), @('Stale','Dati non recenti'),
        @('Reboot','Riavvio: countdown'), @('Committed','Riavvio confermato'), @('Resume','Ripresa'),
        @('StopPending','Stop richiesto'), @('Stopped','Interrotto'), @('NoUpdates','Nessun aggiornamento'),
        @('Completed','Completato'), @('Partial','Parziale con errori'), @('Excluded','Con esclusioni'),
        @('Error','Errore'), @('ActiveError','Blocco con operazione incerta')
    )
    for ($index=0; $index -lt $scenes.Count; $index++) {
        $item = [Windows.Controls.ComboBoxItem]::new()
        $item.Content = '{0:00} / {1}' -f ($index+1), $scenes[$index][1]
        $item.Tag = $scenes[$index][0]
        [void]$selector.Items.Add($item)
    }
    $selector.add_SelectionChanged({ param($sender, $eventArgs)
        if ($null -eq $sender.SelectedItem) { return }
        $target = [Windows.Window]::GetWindow($sender)
        Stop-MonitorTransition $target
        $target.Tag.ShowLog = $false
        Update-MonitorView $target (New-MonitorPreviewSnapshot $sender.SelectedItem.Tag)
        $target.FindName('PreviewPrevious').IsEnabled = $sender.SelectedIndex -gt 0
        $target.FindName('PreviewNext').IsEnabled = $sender.SelectedIndex -lt $sender.Items.Count-1
    })
    $window.FindName('PreviewPrevious').add_Click({ param($sender, $eventArgs)
        $selector = [Windows.Window]::GetWindow($sender).FindName('PreviewSelector')
        if ($selector.SelectedIndex -gt 0) { $selector.SelectedIndex-- }
    })
    $window.FindName('PreviewNext').add_Click({ param($sender, $eventArgs)
        $selector = [Windows.Window]::GetWindow($sender).FindName('PreviewSelector')
        if ($selector.SelectedIndex -lt $selector.Items.Count-1) { $selector.SelectedIndex++ }
    })
    $window.FindName('PreviewIntro').add_Click({ param($sender, $eventArgs)
        Start-MonitorTransition ([Windows.Window]::GetWindow($sender)) 'GhostAttack'
    })
    $window.FindName('StopButton').ToolTip = 'Simula la richiesta di stop; scegli Interrotto per vedere la conferma.'
    $window.FindName('StopButton').add_Click({ param($sender, $eventArgs)
        $selector = [Windows.Window]::GetWindow($sender).FindName('PreviewSelector')
        $selector.SelectedItem = @($selector.Items | Where-Object { $_.Tag -eq 'StopPending' })[0]
    })
    $window.FindName('CloseButton').add_Click({ param($sender, $eventArgs)
        [Windows.Window]::GetWindow($sender).Close()
    })
    $selector.SelectedIndex = 3
    return $window
}

function Invoke-MonitorPreview {
    if (-not [Environment]::UserInteractive -or [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {
        throw 'The preview requires an interactive Windows desktop.'
    }
    $window = New-MonitorPreviewWindow
    $timer = [Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    # Keep samples static while allowing the real log reveal and native animations.
    $timer.add_Tick({ Update-MonitorLog $window; Set-MonitorAmbientAnimation $window; Set-MonitorOutcomePulse $window })
    $window.add_Closed({ $timer.Stop() })
    try { $timer.Start(); [void]$window.ShowDialog() }
    finally { $timer.Stop(); $window.Close() }
}

function Invoke-Monitor {
    Assert-Administrator
    if (-not [Environment]::UserInteractive -or [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {
        throw 'Monitor requires an interactive desktop. Use -Action Status in unattended sessions.'
    }
    $window = New-MonitorWindow
    $initial = Get-State
    if ($null -eq $initial) { $window.Close(); return }
    $runId = $initial.RunId
    if ($MonitorRunId -and $MonitorRunId -ne $runId) { $window.Close(); return }
    $script:MonitorRunId = $runId
    $mutex = [Threading.Mutex]::new($false, ('Local\DaScript-WindowsUpdate-Monitor-' + $runId))
    $owned = $false
    $reader = $null
    $timer = $null
    try {
        try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { return }
        $view = [pscustomobject]@{ FinalRead=$false; Detached=$false; Pending=$null; NextRead=[DateTime]::MinValue; RequestStop=$false; Stopping=$false }
        $reader = New-MonitorReader
        $timer = [Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(250)
        $refresh = {
            try {
                Update-MonitorAnimation $window
                if ($view.Detached) { $timer.Stop(); return }
                if ($null -ne $view.Pending) {
                    if (-not $view.Pending.IsCompleted) { return }
                    try {
                        $result = @($reader.EndInvoke($view.Pending))
                        if ($reader.HadErrors) { throw ($reader.Streams.Error | Out-String) }
                    } finally { $view.Pending = $null; $view.Stopping = $false }
                    $snapshot = $result[-1]
                    if ($null -eq $snapshot.State) {
                        if ($view.FinalRead) {
                            $window.FindName('NoticeText').Text = $(if ($snapshot.Cleaned) {
                                'Cleanup completed. Result retained in this window.'
                            } else { 'The previous session is no longer available.' })
                            $view.Detached = $true
                        } else { $window.Close() }
                        return
                    }
                    Update-MonitorView $window $snapshot
                    $view.FinalRead = $snapshot.Finished
                    $view.NextRead = [DateTime]::UtcNow.AddSeconds(3)
                }
                if ($view.RequestStop -or [DateTime]::UtcNow -ge $view.NextRead) {
                    $reader.Commands.Clear()
                    $reader.Streams.ClearStreams()
                    [void]$reader.AddCommand('Get-MonitorSnapshot').AddParameter('RunId', $runId).AddParameter('RequestStop', $view.RequestStop).AddParameter('AcknowledgeFinal', $view.FinalRead)
                    $view.Stopping = $view.RequestStop
                    $view.Pending = $reader.BeginInvoke()
                    $view.RequestStop = $false
                }
                if ($view.Stopping -or $view.RequestStop) { $window.FindName('StopButton').IsEnabled = $false }
            } catch {
                Stop-MonitorTransition $window
                $window.Tag.ShowLog = $true
                Set-MonitorScene $window
                $window.Title = 'Update - Errore monitor'
                $window.FindName('ActivityLog').IsExpanded = $true
                $window.FindName('Activity').Tag = $null
                $window.FindName('PhaseText').Text = 'READ / COMMAND FAILED'
                $window.FindName('PhaseText').Foreground = $window.Resources['Error']
                $window.FindName('StatusText').Text = 'MONITOR ERROR'
                $window.FindName('StatusText').Foreground = $window.Resources['Error']
                $window.FindName('NoticeText').Text = $_.Exception.Message
                $window.FindName('StopButton').IsEnabled = $false
                $window.FindName('Activity').Visibility = 'Collapsed'
                Update-MonitorLog $window -Immediate
                $window.FindName('Progress').Value = 0
                $window.FindName('ProgressText').Text = '--'
                $window.FindName('ProgressCaption').Text = 'STATUS UNAVAILABLE'
                $window.FindName('WorkerText').Text = 'WORKER DATA UNAVAILABLE'
                $window.FindName('WuaResponseText').Text = 'MONITOR READ FAILED // NO CURRENT DATA'
                Set-MonitorUpdateTitle $window 'UPDATE --'
                $window.FindName('CurrentUpdateText').Text = 'UPDATE --'
                $window.FindName('TimingText').Text = 'ELAPSED -- // LAST CHANGE --'
                $window.FindName('DownloadText').Visibility = 'Collapsed'
                $view.NextRead = [DateTime]::UtcNow.AddSeconds(3)
            }
        }
        $timer.add_Tick($refresh)
        $window.add_ContentRendered({ $timer.Start(); & $refresh })
        $window.FindName('StopButton').add_Click({
            $view.RequestStop = $true
            $window.FindName('StopButton').IsEnabled = $false
            $window.FindName('NoticeText').Text = 'Sending stop request...'
            & $refresh
        })
        $window.FindName('CloseButton').add_Click({ $window.Close() })
        $window.add_Closed({ $timer.Stop() })
        [void]$window.ShowDialog()
    } finally {
        if ($null -ne $timer) { $timer.Stop() }
        $window.Close()
        if ($null -ne $reader) {
            try {
                # Closing the view must not discard a cooperative stop already queued by its button.
                if ($null -ne $view.Pending) { $null = $reader.EndInvoke($view.Pending) }
                if ($view.RequestStop) {
                    $reader.Commands.Clear()
                    $reader.Streams.ClearStreams()
                    [void]$reader.AddCommand('Get-MonitorSnapshot').AddParameter('RunId', $runId).AddParameter('RequestStop', $true)
                    $null = $reader.Invoke()
                }
                if ($reader.HadErrors) { Write-Warning ($reader.Streams.Error | Out-String) }
            } catch { Write-Warning ('Monitor closing: ' + $_.Exception.Message) }
            finally {
                try {
                    $reader.Commands.Clear()
                    [void]$reader.AddCommand('Close-MemoryLog')
                    $null = $reader.Invoke()
                } finally { $reader.Dispose() }
            }
        }
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

try {
    switch ($Action) {
        'Start'   { Invoke-Start }
        'Worker'  { Invoke-Worker }
        'Status'  { Show-Status }
        'Monitor' { Invoke-Monitor }
        'Preview' { Invoke-MonitorPreview }
        'Stop'    { Invoke-Stop }
    }
} finally { Close-MemoryLog }
