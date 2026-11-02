#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Preview,
    [ValidateSet('Running','NoUpdates','Completed','Partial','Error','Reboot','Stopped')]
    [string]$PreviewOutcome = 'Running'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Run this test with powershell.exe -STA.' }
$tokens = $null
$errors = $null
$source = Join-Path $PSScriptRoot '..\WindowsUpdate.ps1'
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
function Wait-MonitorTransition {
    param($Window)
    $frame = [Windows.Threading.DispatcherFrame]::new()
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    $pulse = [Windows.Threading.DispatcherTimer]::new()
    $pulse.Interval = [TimeSpan]::FromMilliseconds(20)
    $pulse.add_Tick({
        if ($null -eq $Window.Tag.Storyboard -or $deadline.Elapsed.TotalSeconds -gt 5) {
            $pulse.Stop()
            $frame.Continue = $false
        }
    })
    try { $pulse.Start(); [Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $pulse.Stop() }
    Assert-True ($null -eq $Window.Tag.Storyboard) 'Transition did not complete within five seconds.'
}
function Test-MonitorTransitions {
    param($Window, $State, $Snapshot)
    $State.ActiveOperation = ''
    $State.RebootCommitted = $false
    $State.Failures = @()
    $State.Skipped = @()
    $State.Installed = @()
    $Snapshot.StopRequested = $false
    $cases = @{
        Completed='NoUpdates'; CompletedWithExclusions='Partial'; CompletedWithErrors='Error'
        Blocked='Error'; Stopped='Stopped'; WaitingForReboot='Reboot'; Running=''
    }
    foreach ($status in $cases.Keys) {
        $State.Status = $status
        Update-MonitorView $Window $Snapshot
        Assert-True ($Window.Tag.Outcome -eq $cases[$status]) "Wrong outcome for $status."
    }
    $State.Status = 'Completed'
    Update-MonitorView $Window $Snapshot
    Assert-True ($Window.FindName('OutcomeDescription').Text -eq 'Nessun aggiornamento trovato.' -and [Windows.Automation.AutomationProperties]::GetName($Window.FindName('OutcomeTitle')) -eq 'GIRO A VUOTO') 'Empty scan did not use the concise title and factual summary.'
    $State.Installed = @([pscustomobject]@{Title='Synthetic successful update'})
    Update-MonitorView $Window $Snapshot
    Assert-True ($Window.Tag.Outcome -eq 'Completed') 'Real installed count was ignored.'
    $State.Status = 'CompletedWithErrors'
    $State.Failures = @([pscustomobject]@{Title='Synthetic failure'; Reason='Result=4; HRESULT=0x8024200A'; Resolved=$false})
    Update-MonitorView $Window $Snapshot
    Assert-True ($Window.Tag.Outcome -eq 'Partial' -and $Window.FindName('OutcomeCounts').Text -like '*Errori: 1*') 'Mixed results were presented as success.'
    $State.Status = 'Blocked'
    $State.Message = 'Synthetic search failure: ResultCode=4'
    Update-MonitorView $Window $Snapshot
    Assert-True ($Window.Tag.Outcome -eq 'Error' -and $Window.FindName('OutcomeDetail').Text -eq $State.Message) 'Scan failure lost its diagnostic detail.'
    $State.ActiveOperation = 'Scan'
    Update-MonitorView $Window $Snapshot
    Assert-True (-not $Window.Tag.Outcome -and $Window.FindName('OperationalView').Visibility -eq 'Visible') 'Uncertain WUA operation was presented as finished.'
    $State.ActiveOperation = ''
    $State.Status = 'WaitingForReboot'
    $State.Phase = 'RestartCountdown'
    $State.Message = 'Restart in 75 seconds. Save your work.'
    Update-MonitorView $Window $Snapshot
    Assert-True ($Window.Tag.Outcome -eq 'Reboot' -and $Window.FindName('OutcomeDescription').Text -like '*75 s*' -and $Window.FindName('StopButton').IsEnabled) 'Reboot screen lost real countdown or cooperative stop.'
    $State.RebootCommitted = $true
    Update-MonitorView $Window $Snapshot
    Assert-True (-not $Window.FindName('StopButton').IsEnabled -and $Window.FindName('OutcomeDescription').Text -like '*non annullabile*') 'Committed reboot offered cancellation.'
    $State.Status = 'Running'
    $State.Phase = 'Resume'
    $State.RebootCommitted = $false
    Update-MonitorView $Window $Snapshot
    Assert-True (-not $Window.Tag.Outcome -and $Window.FindName('OutcomeView').Visibility -eq 'Collapsed') 'Resume retained the reboot result.'
    $Snapshot.StopRequested = $true
    Update-MonitorView $Window $Snapshot
    Assert-True (-not $Window.Tag.Outcome) 'Stop request was confused with completed cancellation.'
    $State.Status = 'Stopped'
    Update-MonitorView $Window $Snapshot
    Assert-True ($Window.Tag.Outcome -eq 'Stopped') 'Confirmed cancellation was lost.'
    $Window.FindName('ResultLogButton').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Assert-True ($Window.Tag.ShowLog -and $Window.FindName('OperationalView').Visibility -eq 'Visible') 'Final log action did not open the existing log.'
    $Window.FindName('ResultLogButton').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Assert-True (-not $Window.Tag.ShowLog -and $Window.FindName('OutcomeView').Visibility -eq 'Visible') 'Cannot return from log to result.'

    # Native WPF rendering/clock tests with synthetic state; no worker or WUA execution.
    $Window.Tag.Motion = $false
    $Window.Show()
    $Window.UpdateLayout()
    Assert-True ($Window.FindName('IntroLayer').Visibility -eq 'Collapsed' -and $Window.FindName('Scene').Opacity -eq 1) 'Static fallback hid the view.'
    Assert-True ($Window.AllowsTransparency -and $Window.Background.Color.A -eq 0 -and $Window.FindName('WindowSurface').Background.Color.A -eq 0 -and $Window.FindName('GhostBackplate').Fill.Color.A -eq 255) 'Static fallback lost its opaque operational surface.'
    foreach ($name in @('GhostAttack')) {
        $storyboard = $Window.Resources[$name]
        $storyboard.Begin($Window, $true)
        $Window.Tag.Storyboard = $storyboard
        $storyboard.Pause($Window)
        $storyboard.SeekAlignedToLastTick($Window, [TimeSpan]::FromMilliseconds(450), 'BeginTime')
        $Window.Width = 640
        $Window.Height = 480
        $Window.UpdateLayout()
        if ($name -eq 'GhostAttack') {
            Assert-True ($Window.FindName('IntroLayer').Visibility -eq 'Visible' -and $Window.FindName('IntroScale').ScaleX -gt 0.015 -and $Window.FindName('IntroScale').ScaleX -lt 0.56) "Native attack clock: visibility=$($Window.FindName('IntroLayer').Visibility); scale=$($Window.FindName('IntroScale').ScaleX); time=$($storyboard.GetCurrentTime($Window))."
            $storyboard.SeekAlignedToLastTick($Window, [TimeSpan]::Zero, 'BeginTime')
            Assert-True ($Window.FindName('IntroScale').ScaleX -eq 0.015) 'Intro does not start with a tiny logo.'
            $storyboard.SeekAlignedToLastTick($Window, [TimeSpan]::FromMilliseconds(1010), 'BeginTime')
            Assert-True ($Window.FindName('IntroScale').ScaleX -gt 1 -and $Window.FindName('WindowSurface').Opacity -eq 0) 'App was revealed before the masking flash.'
            $storyboard.SeekAlignedToLastTick($Window, [TimeSpan]::FromMilliseconds(1050), 'BeginTime')
            Assert-True ($Window.FindName('Impact').Opacity -eq 1 -and $Window.FindName('WindowSurface').Opacity -eq 1 -and $Window.FindName('IntroGhost').Opacity -eq 0) 'Flash did not fully cover the window reveal.'
        }
        $storyboard.Resume($Window)
        $storyboard.SeekAlignedToLastTick($Window, [TimeSpan]::FromSeconds(4), 'BeginTime')
        Assert-True ($null -eq $Window.Tag.Storyboard -and $Window.FindName('IntroLayer').Visibility -eq 'Collapsed' -and $Window.FindName('Scene').Opacity -eq 1) 'A finite animation left the UI hidden or kept running.'
        Stop-MonitorTransition $Window
    }
    $Window.Tag.Motion = $true
    Start-MonitorTransition $Window 'GhostAttack'
    $enabled = [Windows.SystemParameters]::ClientAreaAnimation -and -not [Windows.SystemParameters]::HighContrast -and ([Windows.Media.RenderCapability]::Tier -shr 16) -gt 0
    Assert-True (($null -ne $Window.Tag.Storyboard) -eq $enabled) 'Animation capability selection failed.'
    if ($enabled) {
        $Window.Tag.Storyboard.SeekAlignedToLastTick($Window, [TimeSpan]::FromMilliseconds(450), 'BeginTime')
        $Window.UpdateLayout()
        Assert-True ($Window.WindowState -eq 'Maximized' -and $Window.ResizeMode -eq 'NoResize' -and $null -eq [Windows.Shell.WindowChrome]::GetWindowChrome($Window)) 'Transition did not enter native fullscreen.'
        Assert-True ($Window.FindName('IntroLayer').ActualHeight -eq $Window.ActualHeight -and -not $Window.FindName('WindowSurface').IsHitTestVisible) 'Intro does not cover the screen or allows interaction during transition.'
        Add-Type -AssemblyName System.Windows.Forms
        $screen = [Windows.Forms.Screen]::FromHandle([Windows.Interop.WindowInteropHelper]::new($Window).Handle).Bounds
        $origin = $Window.PointToScreen([Windows.Point]::new(0,0))
        $corner = $Window.PointToScreen([Windows.Point]::new($Window.ActualWidth,$Window.ActualHeight))
        Assert-True ([Math]::Abs($origin.X-$screen.Left) -le 1 -and [Math]::Abs($origin.Y-$screen.Top) -le 1 -and [Math]::Abs($corner.X-$screen.Right) -le 1 -and [Math]::Abs($corner.Y-$screen.Bottom) -le 1) 'Fullscreen does not cover the current monitor including the taskbar.'
    }
    $Window.WindowState = 'Minimized'
    Assert-True ($null -eq $Window.Tag.Storyboard -and $Window.WindowState -eq 'Minimized') 'Minimize left transition clocks attached or restored focus.'
    $Window.WindowState = 'Normal'
    Stop-MonitorTransition $Window
    if ($enabled) {
        $bounds = $Window.RestoreBounds
        foreach ($name in @('GhostAttack')) {
            $appOrigin = $Window.PointToScreen([Windows.Point]::new(0,0))
            Start-MonitorTransition $Window $name
            $Window.Tag.Storyboard.Pause($Window)
            Assert-True ($null -ne $Window.Tag.WindowPlacement) "$name did not save the original placement."
            $Window.Tag.Storyboard.SeekAlignedToLastTick($Window, [TimeSpan]::FromMilliseconds(450), 'BeginTime')
            if ($name -eq 'GhostAttack') {
                $State.Status = 'Blocked'
                Update-MonitorView $Window $Snapshot
            }
            $Window.UpdateLayout()
            $target = [Windows.PresentationSource]::FromVisual($Window).CompositionTarget
            Assert-True ($target.UsesPerPixelOpacity -and $target.BackgroundColor.A -eq 0) "$name has an opaque native backdrop: $($target.BackgroundColor)."
            $render = [Windows.Media.Imaging.RenderTargetBitmap]::new([int]$Window.ActualWidth, [int]$Window.ActualHeight, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
            $render.Render($Window)
            $pixel = [byte[]]::new(4)
            $render.CopyPixels([Windows.Int32Rect]::new(2,2,1,1), $pixel, 4, 0)
            Assert-True ($pixel[0] -eq 0 -and $pixel[1] -eq 0 -and $pixel[2] -eq 0 -and $pixel[3] -eq 235) "$name did not render the dark translucent vignette corners."
            $vignette = [Windows.Media.Imaging.RenderTargetBitmap]::new([int]$Window.ActualWidth, [int]$Window.ActualHeight, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
            $vignette.Render($Window.FindName('DimLayer'))
            $center = [byte[]]::new(4)
            $vignette.CopyPixels([Windows.Int32Rect]::new([int]($Window.ActualWidth/2),[int]($Window.ActualHeight/2),1,1), $center, 4, 0)
            Assert-True ($center[0] -eq 0 -and $center[1] -eq 0 -and $center[2] -eq 0 -and $center[3] -ge 102 -and $center[3] -le 104) "$name vignette center is not substantially clearer than its edges."
            Assert-True ($Window.Opacity -eq 1 -and $Window.FindName('IntroGhost').Opacity -eq 1) "$name faded the window or ghost instead of the backdrop."
            if ($name -eq 'GhostAttack') {
                $Window.Tag.Storyboard.SeekAlignedToLastTick($Window, [TimeSpan]::FromSeconds(0.95), 'BeginTime')
                $surface = $Window.FindName('WindowSurface')
                $surfaceOrigin = $surface.PointToScreen([Windows.Point]::new(0,0))
                Assert-True ($surface.Opacity -eq 0 -and $surface.Width -eq $bounds.Width -and $surface.Height -eq $bounds.Height) 'App is not hidden at its original size before the flash.'
                Assert-True ([Math]::Abs($surfaceOrigin.X-$appOrigin.X) -le 1 -and [Math]::Abs($surfaceOrigin.Y-$appOrigin.Y) -le 1) 'App moved on the desktop during its reveal.'
                $Window.Tag.Storyboard.SeekAlignedToLastTick($Window, [TimeSpan]::FromMilliseconds(750), 'BeginTime')
                $logo = $Window.FindName('IntroGhost')
                $readableBounds = $logo.TransformToAncestor($Window).TransformBounds([Windows.Rect]::new(0,0,$logo.ActualWidth,$logo.ActualHeight))
                Assert-True ([Windows.Rect]::new(0,0,$Window.ActualWidth,$Window.ActualHeight).Contains($readableBounds) -and $logo.Opacity -eq 1 -and $Window.FindName('Impact').Opacity -eq 0) 'The impact logo was cropped or covered before it could be recognized.'
                $readableScale = $Window.FindName('IntroScale').ScaleX
                $Window.Tag.Storyboard.SeekAlignedToLastTick($Window, [TimeSpan]::FromMilliseconds(780), 'BeginTime')
                Assert-True ($Window.FindName('IntroScale').ScaleX -gt $readableScale) 'The approach stopped before the final close-up.'
                $Window.Tag.Storyboard.SeekAlignedToLastTick($Window, [TimeSpan]::FromSeconds(1.01), 'BeginTime')
                $ghost = $Window.FindName('IntroGhost')
                $ghostBounds = $ghost.TransformToAncestor($Window).TransformBounds([Windows.Rect]::new(0,0,$ghost.ActualWidth,$ghost.ActualHeight))
                Assert-True ($ghostBounds.Contains([Windows.Rect]::new(0,0,$Window.ActualWidth,$Window.ActualHeight)) -and $Window.FindName('IntroLayer').Opacity -eq 1) 'Ghost does not grow beyond the screen bounds before the flash.'
                $face = $ghost.TransformToAncestor($Window).Transform([Windows.Point]::new(300,492*0.31))
                Assert-True ([Math]::Abs($face.X-$Window.ActualWidth/2) -lt 2 -and [Math]::Abs($face.Y-$Window.ActualHeight/2) -lt $Window.ActualHeight*0.02) "Face=$face; screen=$($Window.ActualWidth)x$($Window.ActualHeight); focus=$($Window.FindName('IntroFocus').Y); scale=$($Window.FindName('IntroScale').ScaleX)."
            }
            $Window.Tag.Storyboard.Resume($Window)
            Wait-MonitorTransition $Window
            Assert-True ($null -eq $Window.Tag.WindowPlacement -and $Window.WindowState -eq 'Normal' -and $Window.ResizeMode -eq 'CanMinimize') "$name did not restore the window at real timeline completion: state=$($Window.WindowState); resize=$($Window.ResizeMode); saved=$($Window.Tag.WindowPlacement)."
            Assert-True ([Math]::Abs($Window.Left-$bounds.Left) -lt 1 -and [Math]::Abs($Window.Top-$bounds.Top) -lt 1 -and [Math]::Abs($Window.Width-$bounds.Width) -lt 1 -and [Math]::Abs($Window.Height-$bounds.Height) -lt 1) "$name lost the original position or dimensions."
            Assert-True ($Window.FindName('ChromeControls').Visibility -eq 'Visible' -and $null -ne [Windows.Shell.WindowChrome]::GetWindowChrome($Window)) "$name did not restore native window controls."
            Assert-True ($Window.FindName('GhostBackplate').Fill -eq $Window.Tag.SceneBackground -and $Window.FindName('WindowSurface').Background.Color.A -eq 0 -and $Window.FindName('GhostBackplate').Fill.Color.A -eq 255) "$name did not restore the latest outcome background."
            Assert-True ($Window.FindName('DimLayer').Visibility -eq 'Collapsed' -and [double]::IsNaN($Window.FindName('WindowSurface').Width) -and $Window.FindName('WindowSurface').Opacity -eq 1) "$name left a vignette or fixed-size/faded app after completion."
        }
        $Window.WindowState = 'Maximized'
        Start-MonitorTransition $Window 'GhostAttack'
        $Window.Tag.Storyboard.SkipToFill($Window)
        Wait-MonitorTransition $Window
        Assert-True ($Window.WindowState -eq 'Maximized' -and $null -eq $Window.Tag.WindowPlacement) 'Originally maximized window was not restored.'
        $Window.WindowState = 'Normal'
        Assert-True ([Math]::Abs($Window.Width-$bounds.Width) -lt 1 -and [Math]::Abs($Window.Left-$bounds.Left) -lt 1) 'Fullscreen corrupted the maximized window restore bounds.'
        Start-MonitorTransition $Window 'GhostAttack'
        $escape = [Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice, [Windows.PresentationSource]::FromVisual($Window), 0, [Windows.Input.Key]::Escape)
        $escape.RoutedEvent = [Windows.Input.Keyboard]::PreviewKeyDownEvent
        $Window.RaiseEvent($escape)
        Assert-True ($escape.Handled -and $null -eq $Window.Tag.WindowPlacement -and $Window.WindowState -eq 'Normal') 'Escape did not restore the window.'
        Start-MonitorTransition $Window 'GhostAttack'
        $Window.WindowState = 'Minimized'
        $Window.WindowState = 'Maximized'
        Assert-True ($Window.WindowState -eq 'Normal' -and $null -eq $Window.Tag.WindowPlacement) 'Restoring a minimized fullscreen animation retained fullscreen.'
    }
    $intro = $Window.Resources['GhostAttack']
    $intro.Begin($Window, $true)
    $Window.Tag.Storyboard = $intro
    $intro.SeekAlignedToLastTick($Window, [TimeSpan]::FromMilliseconds(1000), 'BeginTime')
    $State.Status = 'Completed'
    Update-MonitorView $Window $Snapshot
    Assert-True ($Window.Tag.Storyboard -eq $intro -and $Window.Tag.Outcome -eq 'Completed') 'An early worker result interrupted or restarted the intro.'
    Stop-MonitorTransition $Window
    $State.Status = 'Completed'
    Update-MonitorView $Window $Snapshot
    Assert-True ($null -eq $Window.Tag.Storyboard -and $null -eq $Window.Tag.WindowPlacement -and $Window.WindowState -eq 'Normal') 'Completion replayed the fullscreen intro.'
    Assert-True ($Window.FindName('FooterActions').HorizontalAlignment -eq 'Center' -and $Window.FindName('NoticeText').Visibility -eq 'Collapsed' -and $Window.FindName('OutcomeDetail').Visibility -eq 'Collapsed') 'Result footer or verbose detail was not simplified.'
    if ($enabled) {
        Assert-True ($Window.Tag.Pulse -and $Window.Tag.SceneBackground.HasAnimatedProperties) 'Result color alternation did not start.'
        $background = $Window.Tag.SceneBackground
        $ink = $Window.FindName('OutcomeTitle').Fill
        $originalInk = $ink.Color
        $frame = [Windows.Threading.DispatcherFrame]::new()
        $pulse = [Windows.Threading.DispatcherTimer]::new()
        $pulse.Interval = [TimeSpan]::FromMilliseconds(1000)
        $pulse.add_Tick({ $pulse.Stop(); $frame.Continue = $false })
        try { $pulse.Start(); [Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $pulse.Stop() }
        Assert-True ($background.Color -eq $Window.Tag.AlternateColor -and $Window.FindName('GhostBackplate').Fill -eq $background) 'Native color clock did not alternate the result background.'
        Assert-True (-not $ink.HasAnimatedProperties -and $ink.Color -eq $originalInk -and $Window.FindName('OutcomeGhost').Fill -eq $ink) 'Background pulse also changed the logo or title.'
        $Window.FindName('ResultLogButton').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Assert-True (-not $Window.Tag.Pulse -and -not $background.HasAnimatedProperties) 'Result colors kept animating while reading the log.'
        $Window.FindName('ResultLogButton').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Assert-True $Window.Tag.Pulse 'Returning to the result did not resume its colors.'
        $Window.WindowState = 'Minimized'
        Assert-True (-not $Window.Tag.Pulse) 'Minimized window retained its color animation.'
        $Window.WindowState = 'Normal'
        Assert-True $Window.Tag.Pulse 'Restoring the result did not resume its colors.'
        $Window.Tag.Motion = $false
        Set-MonitorOutcomePulse $Window
        Assert-True (-not $Window.Tag.Pulse) 'Static fallback retained blinking.'
        $Window.Tag.Motion = $true
    }
    foreach ($dpi in @(96,192)) {
        foreach ($status in @('Completed','CompletedWithExclusions','CompletedWithErrors','Blocked','WaitingForReboot','Stopped')) {
            $State.Status = $status
            Update-MonitorView $Window $Snapshot
            Stop-MonitorTransition $Window
            $Window.UpdateLayout()
            $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new(640*$dpi/96, 480*$dpi/96, $dpi, $dpi, [Windows.Media.PixelFormats]::Pbgra32)
            $bitmap.Render($Window)
            Assert-True ($Window.FindName('OutcomeTitle').ActualWidth -gt 0 -and $Window.FindName('OutcomeTitle').Data.IsFrozen) "Pixel title did not render for $status at $dpi DPI."
        }
    }
}
$testBase = Join-Path ([IO.Path]::GetTempPath()) ('DaScript-monitor-tests-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testBase)
$script:Root = $testBase
$script:StatePath = Join-Path $testBase 'state.json'
$script:BackupPath = Join-Path $testBase 'state.json.bak'
$script:LogNamePrefix = 'Local\DaScript-monitor-log-'
$script:MemoryLog = $null
$script:MemoryLogRunId = ''
$script:MemoryLogError = ''
$script:StopPath = Join-Path $testBase 'stop.request'
$script:NotificationPath = Join-Path $testBase 'completion-notified'
$script:ResultReadPath = Join-Path $testBase 'result-read'
$script:ControlLockName = 'Local\DaScript-monitor-test-' + [Guid]::NewGuid().ToString('N')
$script:TaskName = 'Unused-monitor-test'
$script:MonitorRunId = ''
$script:TerminalStates = @('Completed','CompletedWithExclusions','CompletedWithErrors','Blocked','Stopped')
$state = [pscustomobject]@{
    RunId=[Guid]::NewGuid().ToString('N'); Status='Running'; Phase='Install'
    Message='Install 42%: Windows cumulative update - synthetic preview'
    UpdatedUtc=[DateTime]::UtcNow.ToString('o'); Scans=2; Reboots=1
    Installed=@([pscustomobject]@{Title='Synthetic update'})
    Failures=@(); Skipped=@()
}
Initialize-RuntimeState $state
$state.ProgressPercent = 42
$state.ActiveOperation = 'Install'
$state.OperationStartedUtc = [DateTime]::UtcNow.AddMinutes(-10).ToString('o')
$state.OperationBootId = Get-BootId
$state.WuaProgress = New-WuaProgress
$state.WuaProgress.Index = 2
$state.WuaProgress.Count = 8
$state.WuaProgress.Title = 'Windows cumulative update - synthetic preview'
$state.WuaProgress.UpdatePercent = 21
$state.WuaProgress.BatchPercent = 42
$state.WuaProgress.LastResponseUtc = [DateTime]::UtcNow.ToString('o')
$state.WuaProgress.ObservedUtc = [DateTime]::UtcNow.AddMinutes(-5).ToString('o')
$state.WuaProgress.LastChangeUtc = [DateTime]::UtcNow.AddMinutes(-3).ToString('o')
$window = $null
$reader = $null
$logOwner = $null
try {
    # Default creator ACL keeps this isolated preview usable without elevation.
    $logOwner = [IO.MemoryMappedFiles.MemoryMappedFile]::CreateNew($script:LogNamePrefix + $state.RunId, 1MB)
    Initialize-MemoryLog $state.RunId
    $sampleLog = @'
2026-01-01 10:00:00 [INFO] PREVIEW: synthetic data, no system changes.
2026-01-01 10:00:01 [INFO] Queued for installation.
2026-01-01 10:00:02 [INFO] Scanning for updates (scan 1).
2026-01-01 10:00:03 [INFO] Found 1 update(s); processing 1.
2026-01-01 10:00:04 [INFO] Download 100%: Synthetic update
2026-01-01 10:00:05 [INFO] Installed: Synthetic update
2026-01-01 10:00:06 [INFO] Synthetic reboot and resume; no restart executed.
2026-01-01 10:00:07 [INFO] Scanning for updates (scan 2).
2026-01-01 10:00:08 [INFO] Found 1 update(s); processing 1.
2026-01-01 10:00:09 [INFO] Download 100%: Synthetic cumulative update
2026-01-01 10:00:10 [INFO] Installing 1 update(s).
2026-01-01 10:00:11 [INFO] Install 0%: Synthetic cumulative update
2026-01-01 10:00:12 [INFO] Install 21%: Synthetic cumulative update
2026-01-01 10:00:13 [INFO] Install 42%: Synthetic cumulative update
'@
    foreach ($line in ($sampleLog -split '\r?\n')) { Write-Log ($line -replace '^.*?\[INFO\] ', '') }
    Save-State $state
    $window = New-MonitorWindow
    Assert-True ($window -is [Windows.Window]) 'XAML did not produce a WPF Window.'
    Assert-True ($window.WindowStyle -eq 'None' -and $null -ne [Windows.Shell.WindowChrome]::GetWindowChrome($window)) 'Terminal chrome lost native move/resize support.'
    $signal = $window.FindName('LogoHost')
    $logo = $window.FindName('LogoPath').Data
    Assert-True ($logo.IsFrozen -and $logo.Bounds.Width -eq 1180 -and $logo.Bounds.Height -eq 964) 'Embedded vector logo is missing or invalid.'
    $snapshot = [pscustomobject]@{State=$state; Log='Synthetic log'; StopRequested=$false}
    Update-MonitorView $window $snapshot
    Assert-True ($window.FindName('UpdateProgressText').Content -eq 'UPDATE 21%' -and $window.FindName('CurrentUpdateText').Text -like 'UPDATE 3/8*') 'Current update percentage or batch position is missing.'
    Assert-True ($window.FindName('WuaResponseText').Text -eq 'NO PROGRESS CHANGE // WINDOWS UPDATE STILL RESPONDING') 'Responsive but unchanged progress was misclassified.'
    Assert-True ($window.FindName('WorkerText').Text -like 'WORKER ACTIVE*' -and $window.FindName('TimingText').Text -like 'ELAPSED 00:10:*LAST CHANGE 00:03:*') 'Independent heartbeat or operation timers are missing.'
    Assert-True (-not $window.FindName('Diagnostics').IsExpanded -and $window.FindName('DiagnosticsText').Text -like '*WUA last response UTC:*') 'Diagnostics is not available on demand.'
    foreach ($invalid in @($null, '', -1, 101, 'NaN', 'bad', 0.5)) {
        $state.WuaProgress.UpdatePercent = $invalid
        Update-MonitorView $window $snapshot
        Assert-True ($window.FindName('UpdateProgressText').Content -eq 'UPDATE --') 'Invalid current update percentage was displayed.'
    }
    $state.WuaProgress.UpdatePercent = 21
    $now = [DateTime]::UtcNow
    $state.UpdatedUtc = $now.AddSeconds(-40).ToString('o')
    Update-MonitorTelemetry $window $snapshot $now
    Assert-True ($window.FindName('WorkerText').Text -like '*NO RECENT HEARTBEAT*' -and $window.FindName('ProgressText').Text -eq '--' -and $window.FindName('Activity').Visibility -eq 'Collapsed') 'Stale heartbeat retained apparent activity or progress.'
    $state.UpdatedUtc = $now.ToString('o')
    $state.WuaProgress.LastResponseUtc = $now.AddSeconds(-40).ToString('o')
    Update-MonitorTelemetry $window $snapshot $now
    Assert-True ($window.FindName('WorkerText').Text -like '*ACTIVE*' -and $window.FindName('WuaResponseText').Text -eq 'NO RECENT WUA PROGRESS DATA' -and $window.FindName('ProgressText').Text -eq '--') 'Worker heartbeat was mistaken for a WUA reply.'
    $state.WuaProgress.LastResponseUtc = $now.ToString('o')
    $state.WuaProgress.ReadError = 'Synthetic progress read failed'
    Update-MonitorView $window $snapshot
    Assert-True ($window.FindName('WuaResponseText').Text -like '*READ FAILED*' -and $window.FindName('DiagnosticsText').Text -like '*Synthetic progress read failed*' -and $window.FindName('ProgressText').Text -eq '--') 'Progress read error retained valid-looking values.'
    $state.WuaProgress.ReadError = ''
    $snapshot | Add-Member NoteProperty PreviousBoot $true
    Update-MonitorView $window $snapshot
    Assert-True ($window.FindName('CurrentUpdateText').Text -eq 'UPDATE --' -and $window.FindName('WuaResponseText').Text -like '*PREVIOUS BOOT DATA*') 'Previous boot progress was displayed as current.'
    $snapshot.PreviousBoot = $false
    $state.WuaProgress.LastChangeUtc = $now.ToString('o')
    Update-MonitorView $window $snapshot
    Assert-True ($window.FindName('WuaResponseText').Text -like 'PROGRESS CHANGED*') 'Actual progress change was not distinguished.'
    $state.ActiveOperation = 'Download'
    $state.Phase = 'Download'
    $state.WuaProgress.DownloadPhase = 3
    $state.WuaProgress.TotalBytesDownloaded = 4096
    $state.WuaProgress.TotalBytesToDownload = 8192
    Update-MonitorView $window $snapshot
    Assert-True ($window.FindName('DownloadText').Text -eq 'VERIFYING // BATCH 4096 / ~8192 bytes') 'Download phase or estimated bytes are missing.'
    $state.ActiveOperation = 'Install'
    $state.Phase = 'Install'
    Update-MonitorView $window $snapshot
    Assert-True ($window.FindName('DownloadText').Visibility -eq 'Collapsed') 'Install displayed previous download details.'
    $index = $signal.Tag.Index
    Update-MonitorAnimation $window
    Assert-True ($signal.Tag.Index -eq $index+1 -and $null -eq $window.FindName('LogoGlow')) 'Polling must not run a permanent decorative animation.'
    $window.WindowState = 'Minimized'
    Update-MonitorAnimation $window
    Assert-True ($signal.Tag.Index -eq $index+1) 'Minimized window kept updating telemetry.'
    $window.WindowState = 'Normal'
    Assert-True ($window.FindName('LogText').Text -eq 'Synthetic log' -and $window.FindName('Progress').Value -eq 42) 'Presentation changed operational content.'
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
    $state.ActiveOperation = ''
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
    Assert-True (-not $window.FindName('StopButton').IsEnabled -and $window.FindName('NoticeText').Text -like 'Stop requested*') 'Stop request was not represented as pending.'
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
        Assert-True ($null -eq $window.FindName('LogoGlow') -and $window.FindName('ProgressText').Text -eq '--') "Terminal status $status started decorative animation or fabricated progress."
    }
    $state.Status = 'Blocked'
    $state.ActiveOperation = 'Install'
    Update-MonitorView $window $snapshot
    Assert-True ($window.FindName('NoticeText').Text -like '*may still be active*') 'Blocked active WUA operation was presented as finished.'
    $state.CleanupError = 'Synthetic cleanup error'
    Update-MonitorView $window $snapshot
    Assert-True ($window.FindName('NoticeText').Text -like 'Cleanup incomplete:*') 'Cleanup error was hidden.'
    $state.CleanupError = ''
    $state.ActiveOperation = ''
    $state.Status = 'CompletedWithErrors'
    $state.Phase = 'CompletedWithErrors'
    $state.Failures = @(
        [pscustomobject]@{Title='Synthetic failure'; Reason='Synthetic reason'; Resolved=$false}
        [pscustomobject]@{Title='Synthetic input required'; Reason='Result=4; HRESULT=0x8024200A; WU_E_UH_CANREQUIREINPUT: Manual intervention required.'; Resolved=$false}
    )
    $state.Skipped = @([pscustomobject]@{Title='Synthetic exclusion'; Reason='Driver excluded by operator'})
    Save-State $state
    $reader = New-MonitorReader
    [void]$reader.AddCommand('Get-MonitorSnapshot').AddParameter('RunId',$state.RunId)
    $guard = Enter-RunLock $script:ControlLockName
    try {
        $pending = $reader.BeginInvoke()
        Assert-True (-not $pending.AsyncWaitHandle.WaitOne(200)) 'Snapshot bypassed the control lock.'
        $window.FindName('Diagnostics').IsExpanded = $true
        $before = $signal.Tag.Index
        $frame = [Windows.Threading.DispatcherFrame]::new()
        $pulse = [Windows.Threading.DispatcherTimer]::new()
        $pulse.Interval = [TimeSpan]::FromMilliseconds(30)
        $pulse.add_Tick({
            Update-MonitorAnimation $window
            if ($signal.Tag.Index -ge $before+3) { $pulse.Stop(); $frame.Continue = $false }
        })
        try { $pulse.Start(); [Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $pulse.Stop() }
        Assert-True ($window.FindName('Diagnostics').IsExpanded -and $signal.Tag.Index -eq $before+3 -and -not $pending.IsCompleted) 'Diagnostics or dispatcher animation blocked on the reader.'
        $window.FindName('NoticeText').Text = 'UI remains available while the reader waits.'
        Assert-True ($window.FindName('NoticeText').Text -like 'UI remains*') 'Background lock blocked access to UI controls.'
    } finally { Exit-RunLock $guard }
    Assert-True ($pending.AsyncWaitHandle.WaitOne(10000)) 'Background snapshot timed out.'
    $result = @($reader.EndInvoke($pending))
    if ($reader.HadErrors) { throw ($reader.Streams.Error | Out-String) }
    $result = $result[-1]
    Assert-True ($result.Log -like '*PREVIEW: synthetic data*') 'Background reader lost shared in-memory history.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $testBase 'activity.log'))) 'Monitor test wrote an activity log to disk.'
    Assert-True ($result.Finished -and $result.Log -like '*Synthetic failure: Synthetic reason*' -and $result.Log -like '*Synthetic exclusion*') 'Final snapshot omitted outcome details.'
    Assert-True ($result.Log -like '*OPEN ERRORS:*Synthetic input required: Result=4; HRESULT=0x8024200A;*Manual intervention required.*') 'Final snapshot hid the actual interaction failure.'
    Assert-True (-not [IO.File]::Exists($script:ResultReadPath)) 'Result acknowledged before UI consumption.'
    Update-MonitorView $window $result
    Assert-True ($window.FindName('LogText').Text -ceq $result.Log) 'Final result was acknowledged before the complete log was displayed.'
    Assert-True ($window.FindName('FailureCount').Text -eq '2' -and $window.FindName('SkippedCount').Text -eq '1') 'An actual interaction failure was counted as an exclusion.'
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
    $state.Message = 'Install 42%: Windows cumulative update - synthetic preview'
    $state.ProgressPercent = 42
    $state.WuaProgress.LastResponseUtc = [DateTime]::UtcNow.ToString('o')
    $state.Failures = @()
    $state.Skipped = @()
    Save-State $state
    $reader.Commands.Clear()
    [void]$reader.AddCommand('Get-MonitorSnapshot').AddParameter('RunId',$state.RunId).AddParameter('RequestStop',$true)
    $stopped = @($reader.Invoke())[-1]
    if ($reader.HadErrors) { throw ($reader.Streams.Error | Out-String) }
    Assert-True ($stopped.StopRequested -and (Get-State).Status -eq 'Running') 'UI stop changed worker state.'
    $state.OperationBootId = 'cimboot:1'
    Save-State $state
    $reader.Commands.Clear()
    [void]$reader.AddCommand('Get-MonitorSnapshot').AddParameter('RunId',$state.RunId)
    $oldBoot = @($reader.Invoke())[-1]
    if ($reader.HadErrors) { throw ($reader.Streams.Error | Out-String) }
    Assert-True $oldBoot.PreviousBoot 'Background reader accepted progress from a previous boot.'
    $state.OperationBootId = Get-BootId
    Save-State $state
    [IO.File]::Delete($script:StopPath)
    $reader.Commands.Clear()
    [void]$reader.AddCommand('Close-MemoryLog')
    $null = $reader.Invoke()
    $reader.Dispose()
    $reader = $null
    Test-MonitorTransitions $window $state $snapshot
    $window.Close()
    $window = $null
    Write-Output "PASS: $script:checks WPF checks (PowerShell $($PSVersionTable.PSVersion), native XAML/controls, synthetic states and background I/O; no updates or restarts)."
    if ($Preview) {
        $previewStates = @{ NoUpdates='Completed'; Completed='Completed'; Partial='CompletedWithErrors'; Error='Blocked'; Reboot='WaitingForReboot'; Stopped='Stopped' }
        if ($PreviewOutcome -ne 'Running') {
            $state.Status = $previewStates[$PreviewOutcome]
            $state.Phase = $state.Status
            $state.ActiveOperation = ''
            $state.RebootCommitted = $false
            $state.Failures = @()
            $state.Installed = @()
            $state.Message = 'ANTEPRIMA SINTETICA: nessuna operazione Windows Update o riavvio reale.'
            if ($PreviewOutcome -in @('Completed','Partial')) { $state.Installed = @([pscustomobject]@{Title='Synthetic success'}) }
            if ($PreviewOutcome -in @('Partial','Error')) { $state.Failures = @([pscustomobject]@{Title='Synthetic error'; Reason='Synthetic failure'; Resolved=$false}) }
            Save-State $state
        }
        Invoke-Monitor
    }
} finally {
    if ($null -ne $window) { $window.Close() }
    if ($null -ne $reader) {
        $reader.Commands.Clear()
        [void]$reader.AddCommand('Close-MemoryLog')
        $null = $reader.Invoke()
        $reader.Dispose()
    }
    Close-MemoryLog
    if ($null -ne $logOwner) { $logOwner.Dispose() }
    $resolved = [IO.Path]::GetFullPath($testBase)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -like 'DaScript-monitor-tests-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
