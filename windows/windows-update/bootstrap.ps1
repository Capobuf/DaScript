#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$AllowServerReboot,
    [switch]$NoMonitor
)

$ErrorActionPreference = 'Stop'
# Pin the worker to the reviewed Git commit rather than a mutable branch.
$workerUrl = 'https://raw.githubusercontent.com/Capobuf/DaScript/1fabcd2f407496515a743add3e8da068cc637c1e/windows/windows-update/MSP-WindowsUpdate.ps1'

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open Windows PowerShell as Administrator.'
}
$uri = [Uri]$workerUrl
if ($uri.Scheme -ne 'https') { throw 'HTTPS is required.' }
$download = Join-Path $env:TEMP ('MSP-WindowsUpdate-' + [Guid]::NewGuid().ToString('N') + '.ps1')
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $uri -UseBasicParsing -OutFile $download

    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $download, '-Action', 'Start')
    if ($AllowServerReboot) { $arguments += '-AllowServerReboot' }
    if ($NoMonitor) { $arguments += '-NoMonitor' }
    & $powershell @arguments
    if ($LASTEXITCODE -ne 0) { throw "MSP Windows Update returned exit code $LASTEXITCODE." }
} finally {
    if (Test-Path -LiteralPath $download) {
        Remove-Item -LiteralPath $download -Force
    }
}
