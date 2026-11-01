#Requires -Version 5.1
param([switch]$ReadOnlyChild, [string]$LogPrefix, [string]$RunId, [string]$LockName)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$source = Join-Path $PSScriptRoot '..\MSP-WindowsUpdate.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$names = @('Initialize-MemoryLog','Close-MemoryLog','Read-MemoryLog','Write-Log','Enter-RunLock','Exit-RunLock')
foreach ($node in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]}, $false)) {
    if ($node.Name -in $names) { . ([scriptblock]::Create($node.Extent.Text)) }
}
$script:MemoryLog = $null
$script:MemoryLogRunId = ''
$script:MemoryLogError = ''
if ($ReadOnlyChild) {
    $script:LogNamePrefix = $LogPrefix
    $script:ControlLockName = $LockName
    $guard = Enter-RunLock $script:ControlLockName
    try {
        Initialize-MemoryLog $RunId -ReadOnly
        if ($null -eq $script:MemoryLog) { throw $script:MemoryLogError }
        Read-MemoryLog
    } finally { Close-MemoryLog; Exit-RunLock $guard }
    exit
}
$script:checks = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
$runId = [Guid]::NewGuid().ToString('N')
$script:LogNamePrefix = 'Local\DaScript-log-test-'
$script:ControlLockName = 'Local\DaScript-log-lock-' + $runId
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('DaScript-log-test-' + $runId)
[void][IO.Directory]::CreateDirectory($testRoot)
# A disk-writing regression would create this file.
$script:LogPath = Join-Path $testRoot 'activity.log'
$owner = $null
$retainer = $null
$child = $null
try {
    # Pre-create with the test user's ACL so the test also works without elevation.
    $owner = [IO.MemoryMappedFiles.MemoryMappedFile]::CreateNew($script:LogNamePrefix + $runId, 1MB)
    Initialize-MemoryLog $runId
    Assert-True ($null -ne $script:MemoryLog -and -not (Read-MemoryLog)) 'New memory log was not empty.'
    $owner.Dispose()
    $owner = $null
    for ($i=1; $i -le 65; $i++) { Write-Log ("Synthetic event {0:D3}" -f $i) }
    $lines = @((Read-MemoryLog) -split '\r?\n')
    Assert-True ($lines.Count -eq 60 -and $lines[0] -like '*event 006' -and $lines[-1] -like '*event 065') 'Memory tail did not retain exactly the latest 60 events.'
    $unicode = 'Unicode ' + [char]0x00E8 + [char]0x4E2D
    Write-Log $unicode 'WARN'
    Assert-True ((Read-MemoryLog).Contains('[WARN] ' + $unicode)) 'Unicode or severity was lost.'
    Write-Log "First line`r`nSecond line" 'ERROR'
    Assert-True ((Read-MemoryLog) -like '*[[]ERROR] First line Second line') 'Multiline message changed the history line count.'
    Write-Log ('x' * 10000)
    $last = @((Read-MemoryLog) -split '\r?\n')[-1]
    Assert-True ($last.Length -le 4096 -and $last.EndsWith(' ... [truncated]')) 'Oversized messages were not bounded explicitly.'
    Write-Log 'Cross-process marker'

    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $info.Arguments = '-NoProfile -NonInteractive -File "{0}" -ReadOnlyChild -LogPrefix "{1}" -RunId "{2}" -LockName "{3}"' -f $PSCommandPath, $script:LogNamePrefix, $runId, $script:ControlLockName
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $child = [Diagnostics.Process]::Start($info)
    $stdout = $child.StandardOutput.ReadToEndAsync()
    $stderr = $child.StandardError.ReadToEndAsync()
    if (-not $child.WaitForExit(10000)) { $child.Kill(); throw 'Test reader process timed out.' }
    Assert-True ($child.ExitCode -eq 0 -and $stdout.Result -like '*Cross-process marker*') ('Separate reader process failed: ' + $stderr.Result)

    $retainer = [IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting($script:LogNamePrefix + $runId, [IO.MemoryMappedFiles.MemoryMappedFileRights]::Read)
    Close-MemoryLog
    Initialize-MemoryLog $runId
    Assert-True ((Read-MemoryLog) -like '*Cross-process marker*') 'A live reader did not retain history across writer reopen.'
    Close-MemoryLog
    $retainer.Dispose()
    $retainer = $null
    Initialize-MemoryLog $runId -ReadOnly
    Assert-True ($null -eq $script:MemoryLog -and (Read-MemoryLog) -like 'No in-memory activity log*') 'History survived release of every mapping handle, or absence was hidden.'
    Write-Log 'No disk fallback when memory is unavailable'
    Assert-True (@(Get-ChildItem -LiteralPath $testRoot -Force).Count -eq 0) 'Activity logging wrote a file to disk.'
    Initialize-MemoryLog $runId
    Assert-True ($null -ne $script:MemoryLog -and -not (Read-MemoryLog)) 'Writer could not create a fresh protected memory log.'
    Write-Log 'Fresh history'
    Assert-True ((Read-MemoryLog) -like '*Fresh history' -and (Read-MemoryLog) -notlike '*Cross-process marker*') 'Fresh history included a released log.'
    Close-MemoryLog
    Write-Output "PASS: $script:checks memory-log checks (native shared memory and separate reader process; no updates or restarts)."
} finally {
    Close-MemoryLog
    if ($null -ne $owner) { $owner.Dispose() }
    if ($null -ne $retainer) { $retainer.Dispose() }
    if ($null -ne $child) { $child.Dispose() }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -eq ('DaScript-log-test-' + $runId)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
