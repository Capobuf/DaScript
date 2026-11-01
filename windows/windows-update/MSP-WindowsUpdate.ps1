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
    [switch]$IncludeDrivers,
    [switch]$IncludeOptional,
    [switch]$IncludeFeatureUpgrades,
    [switch]$AllowServerReboot,
    [switch]$NoMonitor
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TaskName = 'MSP-WindowsUpdate'
$script:Root = Join-Path $env:ProgramData 'MSPTools\WindowsUpdate'
$script:WorkerPath = Join-Path $script:Root 'MSP-WindowsUpdate.ps1'
$script:StatePath = Join-Path $script:Root 'state.json'
$script:BackupPath = Join-Path $script:Root 'state.json.bak'
$script:StopPath = Join-Path $script:Root 'stop.request'
$script:LogPath = Join-Path $script:Root 'activity.log'
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
    if ($type -ne 1 -and $version -lt [version]'6.2') {
        throw 'Windows Server 2012 or later is required.'
    }
    # ProductType identifies servers without relying on localized edition names.
    return [pscustomobject]@{
        IsServer = ($type -ne 1)
        Caption  = [string]$os.Caption
        Version  = [string]$os.Version
    }
}

function Test-UwfEnabled {
    try {
        $uwf = @(Get-CimInstance -Namespace 'root/standardcimv2/embedded' -ClassName UWF_Filter -ErrorAction Stop)
    } catch {
        # Missing WMI namespace/class means UWF is not installed on this OS.
        if ($_.Exception -is [Microsoft.Management.Infrastructure.CimException] -and
            [string]$_.Exception.StatusCode -in @('InvalidNamespace', 'InvalidClass')) {
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
    try {
        $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
        if ($null -ne $task) {
            Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction Stop
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
    $State.Reboots = [int]$State.Reboots + 1
    $State.Status = 'WaitingForReboot'
    $State.RebootBootId = Get-BootId
    $State.RebootRequestedUtc = [DateTime]::UtcNow.ToString('o')
    Set-Phase $State 'Restart' ("Reboot $($State.Reboots)/$($State.MaxReboots): $Reason")
    if (Test-StopRequested $State) { return }
    # The countdown gives the operator a chance to issue Stop (shutdown /a).
    & "$env:SystemRoot\System32\shutdown.exe" /r /t 90 /c 'MSP Windows Update: automatic restart to continue installing updates.' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Finish-Run $State 'Blocked' ('Windows refused the scheduled reboot (exit code ' + $LASTEXITCODE + ').')
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
    param([object]$State, [object]$SearchResult)
    $regular = [Collections.Generic.List[object]]::new()
    $exclusive = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $SearchResult.Updates.Count; $index++) {
        $update = $SearchResult.Updates.Item($index)
        $id = Get-UpdateId $update
        $title = [string]$update.Title
        if ([int]$update.Type -eq 2 -and -not [bool]$State.IncludeDrivers) {
            Add-Skipped $State $id $title 'Driver excluded by default'
            continue
        }
        if ([bool]$update.IsBeta) {
            Add-Skipped $State $id $title 'Beta update excluded'
            continue
        }
        if (-not [bool]$State.IncludeFeatureUpgrades -and (Test-FeatureUpgrade $update)) {
            Add-Skipped $State $id $title 'Feature upgrade excluded by default'
            continue
        }
        if (-not [bool]$State.IncludeOptional) {
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
    $downloadResult = $downloader.Download()
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
    if ([bool]$installer.RebootRequiredBeforeInstallation) {
        Schedule-Reboot $State 'Reboot is required before the next installation batch.'
        return $false
    }
    $installResult = $installer.Install()
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
    if ([bool]$installResult.RebootRequired -or (Test-UpdateRebootPending)) {
        Schedule-Reboot $State 'Windows Update requires a reboot.'
    }
    return $anySucceeded
}

function Invoke-Worker {
    Assert-Administrator
    [void](Get-SupportedPlatform)
    $state = Get-State
    if ($null -eq $state) { throw 'State file is missing.' }
    if ($state.Status -in $script:TerminalStates) { return }
    if (Test-StopRequested $state) { return }
    $bootId = Get-BootId
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
        $state.ConsecutiveErrors = 0
        Set-Phase $state 'Resume' 'System rebooted; resuming Windows Update.'
        Start-Sleep -Seconds 30
    }
    try {
        if ([DateTime]::Parse([string]$state.StartedUtc).ToUniversalTime() -lt [DateTime]::UtcNow.AddDays(-7)) {
            Finish-Run $state 'Blocked' 'Seven-day maintenance deadline exceeded.'
            return
        }
        if (Test-UwfEnabled) {
            Finish-Run $state 'Blocked' 'Unified Write Filter is active. Use Windows UWF servicing mode instead.'
            return
        }
        for ($pass = 1; $pass -le 30; $pass++) {
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
            $searchResult = $searcher.Search('IsInstalled=0 and IsHidden=0')
            if ([int]$searchResult.ResultCode -ne 2) {
                throw ("Search returned ResultCode=$($searchResult.ResultCode)")
            }
            $candidates = @(Get-Candidates $state $searchResult)
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
                    $_.Reason -eq 'Unable to classify optional update safely'
                })
                if ($openFailures.Count -gt 0 -or $skippedAttention.Count -gt 0) {
                    Finish-Run $state 'CompletedWithErrors' ("No more eligible updates; failures=$($openFailures.Count), requires-attention=$($skippedAttention.Count).")
                } else {
                    Finish-Run $state 'Completed' 'Two scans found no further eligible updates.'
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
        if ([int]$state.ConsecutiveErrors -ge [int]$state.MaxAttempts) {
            Finish-Run $state 'Blocked' ("Repeated Windows Update error: $message")
        } else {
            Set-Phase $state 'Retry' 'Temporary error; retry scheduled in 15 minutes.'
        }
    }
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
    Initialize-Directory
    $previous = Get-State
    if ($null -ne $previous -and $previous.Status -notin $script:TerminalStates) {
        Write-Host 'An update run is already active:'
        Show-Status
        return
    }
    Remove-TaskSafely
    if (Test-Path -LiteralPath $script:StopPath) { Remove-Item -LiteralPath $script:StopPath -Force }
    if ([IO.Path]::GetFullPath($PSCommandPath) -ne [IO.Path]::GetFullPath($script:WorkerPath)) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $script:WorkerPath -Force
    }
    $state = [pscustomobject]@{
        Version=2; RunId=[Guid]::NewGuid().ToString('N'); Status='Running'
        Phase='Queued'; Message='Queued for installation'; UpdatedUtc=''
        StartedUtc=[DateTime]::UtcNow.ToString('o'); Scans=0; EmptyScans=0
        Reboots=0; RebootBootId=''; RebootRequestedUtc=''; ConsecutiveErrors=0; LastError=''
        MaxReboots=$MaxReboots; MaxAttempts=$MaxAttempts
        IncludeDrivers=[bool]$IncludeDrivers
        IncludeOptional=[bool]$IncludeOptional
        IncludeFeatureUpgrades=[bool]$IncludeFeatureUpgrades
        IsServer=[bool]$platform.IsServer
        AllowServerReboot=[bool]$AllowServerReboot
        PlatformCaption=[string]$platform.Caption
        PlatformVersion=[string]$platform.Version
        Installed=@(); Skipped=@(); Failures=@()
    }
    Save-State $state
    Write-Log ("Started $($state.RunId); platform=$($state.PlatformCaption) $($state.PlatformVersion); server=$($state.IsServer); drivers=$($state.IncludeDrivers); optional=$($state.IncludeOptional); upgrades=$($state.IncludeFeatureUpgrades)")

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Action Worker' -f $script:WorkerPath
    $taskAction = New-ScheduledTaskAction -Execute $psExe -Argument $arguments
    $startupTrigger = New-ScheduledTaskTrigger -AtStartup
    $retryTrigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) `
        -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Days 365)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    try {
        Register-ScheduledTask -TaskName $script:TaskName -Action $taskAction `
            -Trigger @($startupTrigger, $retryTrigger) -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $script:TaskName
    } catch {
        $state.Status = 'Blocked'
        Set-Phase $state 'Blocked' ('Failed to create or start the scheduled task: ' + $_.Exception.Message)
        Remove-TaskSafely
        throw
    }
    Write-Host ('Started. Logs: ' + $script:LogPath)
    if (-not $NoMonitor) { Invoke-Monitor }
}

function Show-Status {
    $state = Get-State
    if ($null -eq $state) {
        Write-Host 'No MSP Windows Update run found.'
        return
    }
    $openFailures = @($state.Failures | Where-Object { -not $_.Resolved })
    [pscustomobject]@{
        Status=$state.Status; Phase=$state.Phase; Detail=$state.Message
        Scans=$state.Scans; Reboots=$state.Reboots
        Installed=@($state.Installed).Count
        Failures=$openFailures.Count
        Skipped=@($state.Skipped).Count
        StartedUtc=$state.StartedUtc; UpdatedUtc=$state.UpdatedUtc
        Log=$script:LogPath
    } | Format-List | Out-Host
}

function Invoke-Stop {
    Assert-Administrator
    $state = Get-State
    if ($null -eq $state) { throw 'No active run found.' }
    if ($state.Status -in $script:TerminalStates) {
        Write-Host ('Already finished: ' + $state.Status)
        return
    }
    [IO.File]::WriteAllText($script:StopPath, [DateTime]::UtcNow.ToString('o'))
    # Never abort a reboot that this maintenance run did not request.
    if ($state.Status -eq 'WaitingForReboot') {
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & "$env:SystemRoot\System32\shutdown.exe" /a 2>$null | Out-Null
        } finally {
            $ErrorActionPreference = $previousPreference
        }
    }
    Write-Host 'Stop requested. Current download/install operation may finish first.'
    $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if ($state.Status -eq 'WaitingForReboot' -or $null -eq $task -or $task.State -ne 'Running') {
        Finish-Run $state 'Stopped' 'Operator cancelled the maintenance run.'
    }
}

function Invoke-Monitor {
    Write-Host 'Monitoring background task. Press S to stop safely; closing this window will NOT stop the task.' 
    $lastLine = ''
    while ($true) {
        $state = Get-State
        if ($null -eq $state) { break }
        $line = ('{0} | {1} | scans={2} | reboot={3} | {4}' -f `
            $state.UpdatedUtc, $state.Status, $state.Scans, $state.Reboots, $state.Message)
        if ($line -ne $lastLine) { Write-Host $line; $lastLine = $line }
        if ($state.Status -in $script:TerminalStates) { Show-Status; break }
        $key = $null
        try {
            if (-not [Console]::IsInputRedirected -and [Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
            }
        } catch {
            # A console is optional; the worker remains unattended in session 0.
        }
        if ($null -ne $key -and $key.Key -eq [ConsoleKey]::S) {
            Invoke-Stop
        }
        Start-Sleep -Seconds 3
    }
}

switch ($Action) {
    'Start'   { Invoke-Start }
    'Worker'  { Invoke-Worker }
    'Status'  { Show-Status }
    'Monitor' { Invoke-Monitor }
    'Stop'    { Invoke-Stop }
}
