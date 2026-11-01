#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tokens = $null
$errors = $null
$source = Join-Path $PSScriptRoot '..\bootstrap.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
# Isolate startup/cleanup/exit: never execute elevation, consent or a network request.
$statements = $ast.EndBlock.Statements
if ($statements[-2] -isnot [Management.Automation.Language.TryStatementAst] -or
    $statements[-1] -isnot [Management.Automation.Language.IfStatementAst]) { throw 'Bootstrap tail not found.' }
$tail = $statements[-2].Extent.Text + "`r`n" + $statements[-1].Extent.Text
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('DaScript-bootstrap-exit-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$checks = 0
try {
    foreach ($case in @('Success','KeepConsole','NoMonitor','Redirected','OtherHost','DownloadError','WorkerError','CleanupError')) {
        # Synthetic host conditions let hidden child processes exercise both exit paths.
        $body = $tail.Replace('[Environment]::UserInteractive', '$true').Replace(
            '[Diagnostics.Process]::GetCurrentProcess().SessionId', '1').Replace(
            '$Host.Name', "'$(if ($case -eq 'OtherHost') { 'OtherHost' } else { 'ConsoleHost' })'").Replace(
            '[Console]::IsInputRedirected', $(if ($case -eq 'Redirected') { '$true' } else { '$false' }))
        $setup = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$KeepConsole = $case -eq 'KeepConsole'
$NoMonitor = $case -eq 'NoMonitor'
$AllowServerReboot = $false
$Windows11Upgrade = 'Skip'
$uri = [Uri]'https://example.invalid/unused'
function Invoke-WebRequest {
    param($Uri, [switch]$UseBasicParsing, $OutFile)
    if ($case -eq 'DownloadError') { throw 'Synthetic download error' }
    $code = if ($case -eq 'WorkerError') { 'exit 7' } else { 'exit 0' }
    [IO.File]::WriteAllText($OutFile, $code)
}
if ($case -eq 'CleanupError') {
    function Remove-Item { param($LiteralPath, [switch]$Force) throw 'Synthetic cleanup error' }
}
'@
        $download = Join-Path $testRoot ($case + '.ps1')
        $payload = '$case = ''' + $case + "'`r`n" + '$download = ''' + $download.Replace("'", "''") + "'`r`n" + $setup
        # Invoke-Expression matches the normal URL launch; exit must terminate this child only.
        $payload += "`r`ntry { Invoke-Expression '" + $body.Replace("'", "''") + "' } catch { Write-Output ('ERROR: ' + `$_.Exception.Message) }`r`nWrite-Output 'RETURNED'"
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $info.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload))
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $child = [Diagnostics.Process]::Start($info)
        try {
            $stdout = $child.StandardOutput.ReadToEndAsync()
            $stderr = $child.StandardError.ReadToEndAsync()
            if (-not $child.WaitForExit(10000)) { $child.Kill(); throw "Child timed out: $case" }
            $output = $stdout.Result
            if ($child.ExitCode -ne 0 -or $stderr.Result) { throw "Child failed: $case $($stderr.Result)" }
            if (($output -match 'RETURNED') -ne ($case -ne 'Success')) { throw "Wrong session exit: $case $output" }
            if (($output -match 'ERROR:') -ne ($case -like '*Error')) { throw "Wrong error handling: $case $output" }
            if ((Test-Path -LiteralPath $download) -ne ($case -eq 'CleanupError')) { throw "Wrong temporary cleanup: $case" }
            $checks++
        } finally { $child.Dispose() }
    }
    Write-Output "PASS: $checks bootstrap exit scenarios (real PowerShell child exits; synthetic host/download/worker; no updates)."
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -like 'DaScript-bootstrap-exit-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
