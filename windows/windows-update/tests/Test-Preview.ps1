#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Use powershell.exe -STA.' }
$tokens = $null
$errors = $null
$source = Join-Path $PSScriptRoot '..\WindowsUpdate.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
# Load presentation functions only: operational code is not available to this test.
foreach ($node in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($node.Name -match 'Monitor|^Initialize-(RuntimeState|Windows11UpgradeState)$|^New-WuaProgress$|^Get-(WuaProgressNumber|DownloadPhaseLabel)$') {
        if ($node.Name -in @('Invoke-Monitor','Get-MonitorSnapshot','New-MonitorReader')) { continue }
        . ([scriptblock]::Create($node.Extent.Text))
    }
}
$script:TerminalStates = @('Completed','CompletedWithExclusions','CompletedWithErrors','Blocked','Stopped')
$script:checks = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Click-Button {
    param($Button)
    $Button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
}
function Click-Expander {
    param($Expander)
    [void]$Expander.ApplyTemplate()
    $toggle = $Expander.Template.FindName('HeaderToggle', $Expander)
    # Exercise OnToggle and the routed Click event, without desktop input automation.
    $method = [Windows.Controls.Primitives.ToggleButton].GetMethod('OnClick', [Reflection.BindingFlags]'Instance,NonPublic')
    $null = $method.Invoke($toggle, @())
    $owner = [Windows.Window]::GetWindow($Expander)
    $owner.UpdateLayout()
    Assert-True ($owner.WindowState -eq 'Normal' -and $owner.IsVisible) 'Expander activation minimized or hid the window.'
}
function Test-HeaderHitSurface {
    param($Window)
    $Window.UpdateLayout()
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new([int]$Window.ActualWidth, [int]$Window.ActualHeight, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($Window.Content)
    $pixel = [byte[]]::new(4)
    foreach ($name in @('ActivityLog','Diagnostics')) {
        $expander = $Window.FindName($name)
        $toggle = $expander.Template.FindName('HeaderToggle', $expander)
        foreach ($point in @(
            [Windows.Point]::new(5, $toggle.ActualHeight/2)
            [Windows.Point]::new($toggle.ActualWidth-5, $toggle.ActualHeight/2)
            [Windows.Point]::new($toggle.ActualWidth/2, 3)
            [Windows.Point]::new($toggle.ActualWidth/2, $toggle.ActualHeight-3)
        )) {
            $position = $toggle.TranslatePoint($point, $Window.Content)
            $bitmap.CopyPixels([Windows.Int32Rect]::new([int]$position.X,[int]$position.Y,1,1), $pixel, 4, 0)
            Assert-True ($pixel[3] -gt 0) "$name lets native mouse input pass through its header padding."
            $hit = $Window.InputHitTest($position)
            while ($null -ne $hit -and $hit -ne $toggle) { $hit = [Windows.Media.VisualTreeHelper]::GetParent($hit) }
            Assert-True ($hit -eq $toggle) "$name header padding routes input to a different control."
        }
    }
}
function Wait-AnimationTick {
    # Storyboard.Remove releases animated values on the next WPF timing tick.
    $frame = [Windows.Threading.DispatcherFrame]::new()
    $timer = [Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(100)
    $timer.add_Tick({ $timer.Stop(); $frame.Continue = $false })
    try { $timer.Start(); [Windows.Threading.Dispatcher]::PushFrame($frame) }
    finally { $timer.Stop() }
}
function Test-FrameRendering {
    param($Window)
    $Window.UpdateLayout()
    $ghost = $Window.FindName('GhostView')
    $surface = $Window.FindName('WindowSurface')
    $width = [int]$Window.ActualWidth
    $height = [int]$Window.ActualHeight
    Assert-True ($surface.Background.Color.A -eq 0 -and $Window.FindName('GhostBackplate').Fill.Color.A -eq 255) 'The ghost lost its opaque body or acquired a rectangular background.'
    Assert-True ($Window.FindName('GhostBackplate').Data.IsFrozen -and $Window.FindName('GhostBackplate').Data.Bounds -eq $Window.FindName('LogoPath').Data.Bounds) 'The ghost silhouette is not aligned with the embedded artwork.'
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new($width, $height, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($Window.Content)
    $pixel = [byte[]]::new(4)
    foreach ($point in @(@(2,2), @(($width-18),2), @(2,([Math]::Min($height-3,497))), @(($width-18),([Math]::Min($height-3,497))))) {
        $bitmap.CopyPixels([Windows.Int32Rect]::new($point[0],$point[1],1,1), $pixel, 4, 0)
        Assert-True ($pixel[3] -eq 0) 'A corner outside the ghost silhouette was painted opaque.'
    }
    foreach ($name in @('MinimizeButton','StopButton','CloseButton','Progress')) {
        $control = $Window.FindName($name)
        $center = $control.TranslatePoint([Windows.Point]::new($control.ActualWidth/2,$control.ActualHeight/2), $Window.Content)
        Assert-True ($center.X -ge 0 -and $center.X -lt $width -and $center.Y -ge 0 -and $center.Y -lt $height) "A control fell outside the ghost: $name"
        $bitmap.CopyPixels([Windows.Int32Rect]::new([int]$center.X,[int]$center.Y,1,1), $pixel, 4, 0)
        Assert-True ($pixel[3] -ge 254) "A control is outside its visible backing: $name"
    }
    Assert-True ($Window.ResizeMode -eq 'CanMinimize' -and $null -eq $Window.FindName('FrameResizeGrip') -and $null -eq $Window.FindName('MaximizeButton')) 'Manual resizing or maximization is still available.'
}
$window = New-MonitorPreviewWindow
try {
    $window.Tag.Motion = $false
    $window.Show()
    Test-FrameRendering $window
    Test-HeaderHitSurface $window
    $selector = $window.FindName('PreviewSelector')
    Assert-True ($selector.Items.Count -eq 18 -and $selector.SelectedItem.Tag -eq 'Install') 'Preview did not start on installation.'
    Assert-True ($window.FindName('PreviewControls').Visibility -eq 'Visible') 'Preview identification is missing.'
    Assert-True ($window.Icon -is [Windows.Media.DrawingImage] -and $window.Icon.IsFrozen -and $window.Icon.Drawing.Geometry -eq $window.FindName('LogoPath').Data) 'Window icon does not use the embedded ghost.'
    Assert-True ($window.Title -eq 'Update - Installazione - batch 42%') 'Initial window title does not describe the current operation.'
    $activity = $window.FindName('ActivityLog')
    Assert-True (-not $activity.IsExpanded -and -not $window.FindName('Diagnostics').IsExpanded -and $window.OwnedWindows.Count -eq 0) 'Panels must start closed.'
    [void]$activity.ApplyTemplate()
    $toggle = $activity.Template.FindName('HeaderToggle', $activity)
    Assert-True ($toggle.Content -eq 'ACTIVITY') 'Activity reused the Diagnostics label.'
    $initialHeight = $window.ActualHeight
    Click-Expander $activity
    $panel = $window.Tag.Panels['ActivityLog']
    Assert-True ($panel.IsVisible -and $panel.Owner -eq $window -and -not $panel.ShowInTaskbar -and $panel.ResizeMode -eq 'NoResize') 'Activity did not open an owned, fixed-size window.'
    Assert-True ([Windows.Window]::GetWindow($window.FindName('LogText')) -eq $panel) 'The live log did not move to Activity.'
    Update-MonitorLog $window -Immediate
    Assert-True ($window.FindName('LogText').Text -like '*PREVIEW*') 'Detached Activity lost its live log.'
    Click-Expander $window.FindName('Diagnostics')
    Assert-True ($window.OwnedWindows.Count -eq 2 -and $window.Tag.Panels['Diagnostics'].IsVisible) 'Panels cannot open independently.'
    Assert-True ([Math]::Abs($window.ActualHeight-$initialHeight) -lt 1) 'Opening panels resized the ghost.'
    Click-Button $panel.FindName('PanelClose')
    Assert-True (-not $activity.IsExpanded -and -not $window.Tag.Panels.ContainsKey('ActivityLog') -and $window.FindName('Diagnostics').IsExpanded) 'Panel close did not reset only its own toggle.'
    Click-Expander $window.FindName('Diagnostics')
    Click-Expander $activity
    Assert-True ($window.Tag.Panels['ActivityLog'].IsVisible -and [Windows.Window]::GetWindow($window.FindName('LogText')) -eq $window.Tag.Panels['ActivityLog']) 'Activity could not reopen the existing live content.'
    Click-Expander $activity
    Assert-True ($window.OwnedWindows.Count -eq 0 -and $window.ActualHeight -eq $initialHeight) 'Toggle close left a panel or resized the ghost.'
    Test-HeaderHitSurface $window
    $expected = @{NoUpdates='NoUpdates'; Completed='Completed'; Partial='Partial'; Excluded='Partial'; Error='Error'; Reboot='Reboot'; Committed='Reboot'; Stopped='Stopped'}
    for ($index=0; $index -lt $selector.Items.Count; $index++) {
        $selector.SelectedIndex = $index
        $scene = [string]$selector.SelectedItem.Tag
        $outcome = if ($expected.ContainsKey($scene)) { $expected[$scene] } else { '' }
        Assert-True ($window.Tag.Outcome -eq $outcome) "Wrong preview outcome: $scene"
        Assert-True ($window.Title -like 'Update - *') "Window title lost its base name: $scene"
        if ($scene -eq 'Stale') { Assert-True ($window.Title -notlike '*%*') 'Stale progress remained in the window title.' }
        if ($scene -eq 'Reboot') { Assert-True ($window.Title -like '*ultimo countdown 75s') 'Reboot title lost the reported countdown.' }
        if ($scene -eq 'StopPending') { Assert-True ($window.Title -like 'Update - Arresto richiesto*') 'Stop request was not reflected in the title.' }
        if ($scene -eq 'ActiveError') { Assert-True ($window.Title -eq 'Update - Bloccato - operazione incerta') 'Uncertain operation appeared completed in the title.' }
        Assert-True ($window.FindName('StopButton').IsEnabled -eq ($scene -notin @('Committed','Stopped','StopPending','NoUpdates','Completed','Partial','Excluded','Error','ActiveError'))) "Wrong stop availability: $scene"
        if ($outcome) {
            $activity.IsExpanded = $false
            Click-Button $window.FindName('ResultLogButton')
            Assert-True ($window.Tag.ShowLog -and $window.FindName('OperationalView').Visibility -eq 'Visible') "Log is inaccessible: $scene"
            Assert-True $activity.IsExpanded "Final log remained collapsed: $scene"
            Click-Button $window.FindName('ResultLogButton')
            Assert-True (-not $window.Tag.ShowLog -and $window.FindName('OutcomeView').Visibility -eq 'Visible') "Cannot return to result: $scene"
        }
    }
    $selector.SelectedIndex = 0
    Assert-True (-not $window.FindName('PreviewPrevious').IsEnabled) 'Previous enabled at first scene.'
    Click-Button $window.FindName('PreviewNext')
    Assert-True ($selector.SelectedIndex -eq 1) 'Next did not navigate.'
    Click-Button $window.FindName('PreviewPrevious')
    Assert-True ($selector.SelectedIndex -eq 0) 'Previous did not navigate.'
    $selector.SelectedIndex = $selector.Items.Count-1
    Assert-True (-not $window.FindName('PreviewNext').IsEnabled) 'Next enabled at last scene.'
    $selector.SelectedIndex = 3
    Click-Button $window.FindName('StopButton')
    Assert-True ($selector.SelectedItem.Tag -eq 'StopPending' -and -not $window.Tag.Outcome -and -not $window.FindName('StopButton').IsEnabled) 'Preview stop did not remain a pending request.'
    $window.SizeToContent = 'Manual'
    $window.Width = 640
    $window.Height = 480
    $window.UpdateLayout()
    Assert-True ($window.FindName('PreviewControls').ActualHeight -gt 0 -and $window.FindName('CloseButton').ActualHeight -gt 0) 'Minimum window size hides navigation or close.'
    Test-FrameRendering $window
    $selector.SelectedIndex = 3
    $window.Tag.Motion = $true
    Set-MonitorAmbientAnimation $window
    $enabled = [Windows.SystemParameters]::ClientAreaAnimation -and -not [Windows.SystemParameters]::HighContrast -and ([Windows.Media.RenderCapability]::Tier -shr 16) -gt 0
    Assert-True ($window.Tag.Ambient -eq $enabled) 'Ambient animation ignored native capability checks.'
    if ($enabled) {
        Assert-True $window.Tag.Float.Timer.IsEnabled 'Floating timer did not start.'
        $window.Tag.Float.Timer.Stop()
        $window.Tag.Float.Phase = 0.0
        $window.Tag.Float.Speed = 1.0
        Update-MonitorFloat $window 0.033 $true
        $firstSpeed = $window.Tag.Float.Speed
        $firstPosition = $window.FindName('FloatOffset').Y
        Assert-True ($firstSpeed -gt 0.8 -and $firstSpeed -lt 1 -and $firstPosition -gt 0 -and $firstPosition -lt 0.21) "Hover stopped or jumped abruptly: speed=$firstSpeed; y=$firstPosition."
        for ($tick=0; $tick -lt 60; $tick++) { Update-MonitorFloat $window 0.033 $true }
        $restPosition = $window.FindName('FloatOffset').Y
        Assert-True ($window.Tag.Float.Speed -lt 0.001 -and $restPosition -gt $firstPosition) 'Hover did not gradually settle in place.'
        Update-MonitorFloat $window 0.033 $false
        Assert-True ($window.Tag.Float.Speed -gt 0 -and $window.Tag.Float.Speed -lt 0.2 -and [Math]::Abs($window.FindName('FloatOffset').Y-$restPosition) -lt 0.05) 'Mouse leave did not accelerate smoothly.'
        Set-MonitorFloatAnimation $window
        Wait-AnimationTick
        Assert-True ($window.Tag.Float.Timer.IsEnabled -and $window.Tag.Float.Clock.IsRunning) 'Native floating timer failed to tick.'
        $ambient = $window.Resources['TerminalAmbient']
        $ambient.Pause($window)
        $ambient.SeekAlignedToLastTick($window, [TimeSpan]::FromMilliseconds(600), 'BeginTime')
        Assert-True ($window.FindName('TextureOffset').Y -gt 0 -and $window.FindName('ScanOffset').Y -gt -0.2) 'Native ambient clock did not move the CRT texture or sweep.'
        Assert-True ($window.FindName('LogoPath').Opacity -gt 0.6 -and $window.FindName('LogoPath').Opacity -lt 0.78) 'Ghost animation did not advance.'
        $ambient.Resume($window)
        $selector.SelectedIndex = 13
        Wait-AnimationTick
        Assert-True (-not $window.Tag.Ambient -and $window.FindName('TextureOffset').Y -eq 0) "Outcome retained operational animation clocks: active=$($window.Tag.Ambient); offset=$($window.FindName('TextureOffset').Y)."
        $selector.SelectedIndex = 3
        Assert-True $window.Tag.Ambient 'Returning to operation did not restart ambient animation.'
        $window.WindowState = 'Minimized'
        Assert-True (-not $window.Tag.Ambient) 'Minimized window retained ambient animation.'
        Assert-True (-not $window.Tag.Float.Timer.IsEnabled) 'Minimized window retained the floating timer.'
        $window.WindowState = 'Normal'
        Assert-True $window.Tag.Ambient 'Restoring the window did not restart ambient animation.'
        Assert-True $window.Tag.Float.Timer.IsEnabled 'Restoring the window did not resume floating.'
        $window.Tag.Motion = $false
        Set-MonitorAmbientAnimation $window
        Wait-AnimationTick
        Assert-True (-not $window.Tag.Ambient -and $window.FindName('TextureOffset').Y -eq 0) 'Static fallback did not stop the texture.'
        Assert-True (-not $window.Tag.Float.Timer.IsEnabled) 'Static fallback retained the floating timer.'
        $window.Tag.Motion = $true
        Set-MonitorAmbientAnimation $window
    }
    Click-Button $window.FindName('CloseButton')
    Assert-True (-not $window.IsVisible) 'Close did not close the preview.'
    Assert-True (-not $window.Tag.Ambient) 'Closed window retained ambient animation.'
    Assert-True ($window.OwnedWindows.Count -eq 0 -and $window.Tag.Panels.Count -eq 0) 'Closing the ghost left orphan panels.'
    Assert-True ($null -eq $window.Tag.Float.Timer -or -not $window.Tag.Float.Timer.IsEnabled) 'Closed window retained the floating timer.'
    Write-Output "PASS: $script:checks preview checks; real WPF controls/events, synthetic in-memory data, no worker or system changes."
} finally { $window.Close() }
